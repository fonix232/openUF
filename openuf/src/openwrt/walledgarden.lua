--[[
	The guest walled garden's domain half: the names of the controller's
	"Pre-Authorization Access" list (unifi/guest.lua's wg_allowed /
	wg_restricted), resolved on the AP and handed to guestguard.lua as
	addresses for the three chains the controller declares for them
	(ALLOWED_DOMAIN_IN / _OUT, RESTRICTED_DOMAIN_IN). The firmware does the
	same with nslookup (U7LR 6.8.2's /bin/walled_action.sh): twice per name
	against round-robin records, IPv4 only, deduplicated, and re-run by the
	cron job the controller pushes along with the garden
	(`*/10 * * * *  syswrapper.sh refresh-walled-garden 1`, sysconf.lua).

	The daemon is single-threaded and a blackholed resolver costs 5 s per
	lookup (musl's res_msend cap), so nothing here waits on DNS. A round is a
	background shell loop writing a file; the heartbeat starts one, comes back
	for the file on later ticks and never blocks. Bounded on all three sides:
	  * names: unifi/guest.lua caps each list at WG_MAX_SITES;
	  * time per lookup: `timeout LOOKUP nslookup`;
	  * time per round: the loop asks nothing once BUDGET seconds have passed.
	A round that is not back after ROUND_MAX is given up on, so a wedged shell
	cannot hold the garden's refresh off for good.

	What a round answers is kept per name, and a name that does not resolve
	keeps the addresses it had: a name that stops resolving must neither open
	the garden (an allowed site) nor close it (a restricted one). A name that
	never resolved is not enforced, and said so. Answers are untrusted input
	to nft statements: only a strictly formed, unicast IPv4 address is kept, and
	at most MAX_IPS per name.
]]--

local guest = require("unifi.guest")

local M = {}

M.BUDGET    = 20
M.LOOKUP    = 5
M.ROUND_MAX = M.BUDGET + M.LOOKUP + 15
M.MAX_IPS   = 16
-- After a round that left a name unanswered, rather than waiting for the
-- controller's cron job.
M.RETRY     = 120

M.OUT_PREFIX   = "/tmp/openuf-wg."
M.REQUEST_FILE = "/tmp/openuf-wg-request"
-- A request the daemon never saw (it was down, or the whole AP) is not
-- served hours later: the next cron run asks again.
M.MAX_AGE = 1800

M._exec = function(cmd) return os.execute(cmd) end
M._remove = os.remove
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- A strictly formed dotted quad that can be a guest's destination: no leading
-- zeros (octal in some parsers), not 0/8, loopback, multicast or reserved.
function M.is_ipv4(s)
	if type(s) ~= "string" then return false end
	local o = {s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")}
	if #o ~= 4 then return false end
	for i = 1, 4 do
		local n = tonumber(o[i])
		if #o[i] > 3 or n > 255 or (#o[i] > 1 and o[i]:sub(1, 1) == "0") then return false end
		o[i] = n
	end
	return o[1] ~= 0 and o[1] ~= 127 and o[1] < 224
end

-- Every IPv4 in one name's resolver output, in the resolver's order. Taken
-- only after the first "Name:" line -- the lines before it are the resolver's
-- own address, the cut walled_action.sh's awk makes. Both shapes are read:
-- "Address 1: <ip>" (the firmware's busybox) and the repeated "Name:" /
-- "Address: <ip>" pairs of OpenWrt 25.12's nslookup. AAAA answers fall out on
-- is_ipv4, since the chains are IPv4 only.
local function addresses(text)
	local out, named = {}, false
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if line:match("^Name:") then
			named = true
		elseif named then
			local a = line:match("^Address%s*%d*:%s*(%S+)")
			if a and M.is_ipv4(a) then out[#out + 1] = a end
		end
	end
	return out
end

-- The round's output file as {name = {ip, ...}} for the names that answered,
-- and whether the loop stopped on its budget. The file is a series of
-- "@@ <name>" lines each followed by one nslookup's output, ending in "@end"
-- or "@cut".
function M.parse_round(text, names)
	local want, sections, cut = {}, {}, false
	for _, n in ipairs(names) do want[n] = true end
	local cur
	for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
		local n = line:match("^@@ (%S+)$")
		if line == "@cut" then
			cut, cur = true, nil
		elseif n then
			cur = want[n] and {n, ""} or nil
			if cur then sections[#sections + 1] = cur end
		elseif cur then
			cur[2] = cur[2] .. line .. "\n"
		end
	end
	local map = {}
	for _, sec in ipairs(sections) do
		local list = map[sec[1]] or {}
		local seen = {}
		for _, ip in ipairs(list) do seen[ip] = true end
		for _, ip in ipairs(addresses(sec[2])) do
			if not seen[ip] and #list < M.MAX_IPS then
				seen[ip] = true
				list[#list + 1] = ip
			end
		end
		if #list > 0 then map[sec[1]] = list end
	end
	return map, cut
end

-- The new {name = {ip, ...}} for names, from this round's answers over the
-- last good ones. Returns the map, whether the flattened address set changed
-- against prev, and whether any name has no answer (for the retry).
function M.merge(names, prev, answered)
	prev = type(prev) == "table" and prev or {}
	local map, unanswered = {}, false
	for _, name in ipairs(names) do
		if answered[name] then
			map[name] = answered[name]
		elseif prev[name] then
			unanswered = true
			io.stderr:write("walledgarden: " .. name .. " did not resolve -- keeping the last "
				.. #prev[name] .. " address(es)\n")
			map[name] = prev[name]
		else
			unanswered = true
			io.stderr:write("walledgarden: " .. name .. " did not resolve and has no earlier answer -- not enforced\n")
		end
	end
	return map, M.flat(map) ~= M.flat(prev), unanswered
end

function M.flat(m)
	local l = {}
	for _, ips in pairs(type(m) == "table" and m or {}) do
		for _, ip in ipairs(ips) do l[#l + 1] = ip end
	end
	table.sort(l)
	return table.concat(l, " ")
end

-- A {name = {ip, ...}} map as one sorted, deduplicated address list, which is
-- what the rules are built from: two names behind the same CDN address must
-- not become two identical rules. Revalidated, since the map comes back from
-- state.json.
function M.addresses(map)
	local seen, out = {}, {}
	for _, ips in pairs(type(map) == "table" and map or {}) do
		for _, ip in ipairs(type(ips) == "table" and ips or {}) do
			if M.is_ipv4(ip) and not seen[ip] then
				seen[ip] = true
				out[#out + 1] = ip
			end
		end
	end
	table.sort(out)
	return out
end

-- The names a store keeps, and only those: what the controller stopped
-- pushing is dropped. Returns the pruned store and whether it differs.
function M.prune(store, names)
	if type(store) ~= "table" then return nil, false end
	local keep, out, changed = {}, {}, false
	for _, n in ipairs(names) do keep[n] = true end
	for name, ips in pairs(store) do
		if keep[name] then out[name] = ips else changed = true end
	end
	return out, changed
end

-- The shell loop of one round, on one line. Names are is_hostname-checked, so
-- they carry no character a shell would read; `timeout` is used where busybox
-- has it.
local function round_cmd(names)
	return ('q() { if command -v timeout >/dev/null 2>&1; then timeout %d nslookup "$1"; else nslookup "$1"; fi; }; '
		.. 't0=$(date +%%s); for n in %s; do for p in 1 2; do '
		.. 'if [ $(( $(date +%%s) - t0 )) -ge %d ]; then echo @cut; break 2; fi; '
		.. 'echo "@@ $n"; q "$n" 2>/dev/null </dev/null || break; done; done; echo @end')
		:format(M.LOOKUP, table.concat(names, " "), M.BUDGET)
end

-- The round in flight, if any: {id, started, names}.
M._round = nil

-- Start a round for names unless one is in flight. Returns true when it
-- started one.
function M.start(names, now)
	if M._round then return false end
	local safe = {}
	for _, n in ipairs(names) do
		if guest.is_hostname(n) then safe[#safe + 1] = n end
	end
	if #safe == 0 then return false end
	local id = string.format("%.0f", now)
	local out = M.OUT_PREFIX .. id
	-- Whatever an abandoned round left behind.
	M._exec("rm -f " .. M.OUT_PREFIX .. "* 2>/dev/null")
	M._exec("( " .. round_cmd(safe) .. " ) > " .. out .. ".tmp 2>/dev/null"
		.. " && mv " .. out .. ".tmp " .. out .. " </dev/null >/dev/null 2>&1 &")
	M._round = {id = id, started = now, names = safe}
	return true
end

-- The finished round, if there is one: {answered = {name = {ip...}}, cut},
-- or {lost = true} for one given up on. nil while it is still running (or
-- when none is).
function M.poll(now)
	local r = M._round
	if not r then return nil end
	local out = M.OUT_PREFIX .. r.id
	local text = M._read_file(out)
	if not text then
		if now - r.started <= M.ROUND_MAX and now >= r.started - 60 then return nil end
		M._round = nil
		io.stderr:write("walledgarden: a lookup round did not come back in " .. M.ROUND_MAX .. " s -- given up\n")
		return {lost = true}
	end
	M._remove(out)
	M._round = nil
	local answered, cut = M.parse_round(text, r.names)
	return {answered = answered, cut = cut}
end

-- True when the hook left a request that is still fresh. The file is removed
-- either way, so one request is served at most once.
function M.requested(now)
	local raw = M._read_file(M.REQUEST_FILE)
	if not raw then return false end
	M._remove(M.REQUEST_FILE)
	local at = tonumber(raw:match("%d+"))
	if not at then return false end
	local late = now - at
	if late > M.MAX_AGE or late < -60 then
		io.stderr:write("walledgarden: ignoring a stale refresh-walled-garden request\n")
		return false
	end
	return true
end

return M
