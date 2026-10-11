--[[
	guest.lua -- the controller's guest-network restrictions (the GUESTIN /
	GUESTOUT part of system_cfg's ebtables.* block, plus wireless.<n>.is_guest
	and ipset.*), parsed into a neutral chain/rule model that
	openwrt/guestguard.lua enforces.

	What the controller sends (10.6.106, config.ubntconf.YcZSaTCMOYFEMGE,
	decompiled with CFR; PROTOCOL-VALIDATION.md § `ebtables.*` -- guest):
	for every WLAN with is_guest it hooks the VAP into two nat chains,

	  -t nat -A PREROUTING  --in-interface  ath<n> -j GUESTIN
	  -t nat -A POSTROUTING --out-interface ath<n> -j GUESTOUT

	and fills them: DHCP and ARP allowed, DNS through GUEST_DNS (and, with
	"restricted DNS", only to ALLOW_DNS_SERVERS), the pre-authorization
	subnets allowed, IPv6 and other broadcasts dropped, 224.0.0.0/4 and the
	post-authorization-restricted subnets dropped. The subnets come inline
	(--ip-dst) on a device without fw_caps 0x40000 -- openUF's case -- or as
	ipset references (--set guest_pre_allow / guest_restricted) on one with
	it; both are read.

	The captive portal (LAB-VALIDATED UPSTREAM ONLY, unconfirmed on hardware;
	PROTOCOL-VALIDATION.md, "Guest portal (Hotspot)"). With a portal on,
	GUESTIN's policy is DROP and the AUTHORIZED_GUESTS / REDIRECT_* chains
	mark and redirect unauthorised guests to the controller. With
	redirector.status=enabled and a usable redirector.url, spec_from() keeps
	all of it in wire order, the default-deny included, and leaves the
	device's own parts of those four chains to guestguard: AUTHORIZED_GUESTS
	is pushed empty and filled here from authorize-guest, REDIRECT_HTTP hands
	the frame to the bridge for the local answer (openwrt/guestportal.lua),
	REDIRECT_HTTPS drops, and REDIRECT_DNS accepts -- openUF runs no resolver,
	so DNS passes for every guest. Without a portal URL the portal cannot be
	shown, and spec_from() strips the machinery instead: the guests are
	restricted like on a portal-less guest WLAN and reach the internet
	without seeing the portal.

	Rules are replayed in wire order, so -I (insert at the head) and -A
	(append) end up where the stock firmware's ebtables would put them.
]]--

local wire = require("unifi.wire")

local M = {}

-- The chains of the portal's authorisation flow. Their bodies are the
-- device's (guestguard), never the wire's.
M.PORTAL_CHAINS = {
	AUTHORIZED_GUESTS = true, REDIRECT_HTTP = true, REDIRECT_HTTPS = true,
	REDIRECT_DNS = true,
}
-- The two chains a guest VAP is hooked into, and the hook each one hangs off.
M.ENTRY = {GUESTIN = "in", GUESTOUT = "out"}

-- ─── Small validators (everything here ends up on an nft command line) ──────

local function ipv4_cidr(s)
	if type(s) ~= "string" then return nil end
	local a, b, c, d, p = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)/?(%d*)$")
	if not a then return nil end
	for _, o in ipairs({a, b, c, d}) do
		if #o > 3 or tonumber(o) > 255 then return nil end
	end
	if p ~= "" and (#p > 2 or tonumber(p) > 32) then return nil end
	return s
end
M.ipv4_cidr = ipv4_cidr

local function port(s)
	local n = tonumber(s)
	if n and s:match("^%d+$") and n >= 1 and n <= 65535 then return n end
	return nil
end

local function chain_name(s)
	return type(s) == "string" and s:match("^[A-Z][A-Z0-9_]*$") and #s <= 28 and s or nil
end

local function set_name(s)
	return type(s) == "string" and s:match("^[%a_][%w_]*$") and #s <= 31 and s or nil
end

local PROTO = {
	["0x800"] = "ipv4", ["0x0800"] = "ipv4", IPv4 = "ipv4", ipv4 = "ipv4",
	["0x86dd"] = "ipv6", ["0x86DD"] = "ipv6", IPv6 = "ipv6", ipv6 = "ipv6",
	arp = "arp", ARP = "arp", ["0x806"] = "arp", ["0x0806"] = "arp",
	LENGTH = "length",
}
local L4 = {["6"] = "tcp", ["17"] = "udp", tcp = "tcp", udp = "udp", TCP = "tcp", UDP = "udp"}
local PKTTYPE = {broadcast = "broadcast", multicast = "multicast", host = "host", otherhost = "other"}
local ARPOP = {Request = "request", Reply = "reply", ["1"] = "request", ["2"] = "reply"}
local VERDICT = {ACCEPT = "accept", DROP = "drop", RETURN = "return"}

-- ─── One ebtables fragment ───────────────────────────────────────────────────

local function tokens(s)
	local t = {}
	for w in s:gmatch("%S+") do t[#t + 1] = w end
	return t
end

-- Whether a fragment belongs to the guest machinery (and not to l2guard's
-- BPDU / 802.1Q rules or the mDNS filter): a nat-table user chain, or a
-- PREROUTING/POSTROUTING rule that jumps into GUESTIN/GUESTOUT.
function M.is_guest_rule(cmd)
	if type(cmd) ~= "string" then return false end
	local t = tokens(cmd)
	if t[1] ~= "-t" or t[2] ~= "nat" then return false end
	if t[3] == "-N" then return true end
	if t[3] ~= "-A" and t[3] ~= "-I" then return false end
	if t[4] ~= "PREROUTING" and t[4] ~= "POSTROUTING" then return true end
	return cmd:match("%-j GUEST[A-Z]+$") ~= nil
end

-- Parse one fragment. Returns a table describing it, or nil + reason.
--   {op = "new", chain, policy}
--   {op = "hook", dir = "in"|"out", devname, chain}
--   {op = "rule", chain, insert, pos, match = {...}, target, in_interface}
local function parse_cmd(cmd)
	local t = tokens(cmd)
	if t[1] ~= "-t" or t[2] ~= "nat" then return nil, "not the nat table" end
	if t[3] == "-N" then
		local name = chain_name(t[4])
		if not name then return nil, "odd chain name" end
		if t[5] == nil then return {op = "new", chain = name} end
		if t[5] == "-P" and VERDICT[t[6] or ""] and t[7] == nil then
			return {op = "new", chain = name, policy = VERDICT[t[6]]}
		end
		return nil, "odd chain definition"
	end
	if t[3] ~= "-A" and t[3] ~= "-I" then return nil, "not -A/-I/-N" end
	local chain = chain_name(t[4])
	if not chain then return nil, "odd chain name" end
	local r = {op = "rule", chain = chain, insert = (t[3] == "-I"), match = {}}
	local i = 5
	if r.insert and t[i] and t[i]:match("^%d+$") then
		r.pos = tonumber(t[i]); i = i + 1
	end
	local m = r.match
	while i <= #t do
		local k, v = t[i], t[i + 1]
		if k == "-j" then
			if v == nil then return nil, "no target" end
			if t[i + 2] ~= nil then
				-- -j mark --mark-or ..., -j redirect --redirect-target ...:
				-- the portal's packet marking, never a plain verdict.
				r.target_ext = v
			end
			r.target = v
			break
		elseif k == "-p" or k == "--proto" then
			local p = v and (PROTO[v] or (v:match("^0x%x%x%x%x?$") and tonumber(v:sub(3), 16)))
			if not p then return nil, "odd protocol" end
			m.proto = p
		elseif k == "--pkttype-type" then
			m.pkttype = PKTTYPE[v or ""]
			if not m.pkttype then return nil, "odd pkttype" end
		elseif k == "--ip-proto" or k == "--ip-protocol" then
			m.l4 = L4[v or ""]
			if not m.l4 then return nil, "odd ip protocol" end
		elseif k == "--ip-sport" or k == "--ip-source-port" then
			m.sport = v and port(v)
			if not m.sport then return nil, "odd source port" end
		elseif k == "--ip-dport" or k == "--ip-destination-port" then
			m.dport = v and port(v)
			if not m.dport then return nil, "odd destination port" end
		elseif k == "--ip-dst" or k == "--ip-destination" then
			m.dst = ipv4_cidr(v)
			if not m.dst then return nil, "odd destination address" end
		elseif k == "--ip-src" or k == "--ip-source" then
			m.src = ipv4_cidr(v)
			if not m.src then return nil, "odd source address" end
		elseif k == "--arp-opcode" then
			m.arp_op = ARPOP[v or ""]
			if not m.arp_op then return nil, "odd ARP opcode" end
		elseif k == "--set" then
			m.set = set_name(v)
			if not m.set then return nil, "odd set name" end
		elseif k == "--set-flags" then
			if v ~= "dst" and v ~= "src" then return nil, "odd set flags" end
			m.set_dir = v
		elseif k == "--set-family" then
			if v ~= "inet" then return nil, "odd set family" end
		elseif k == "--in-interface" or k == "-i" then
			if not v then return nil, "no interface" end
			r.in_interface = v
		elseif k == "--out-interface" or k == "-o" then
			if not v then return nil, "no interface" end
			r.out_interface = v
		else
			return nil, "unsupported option " .. k
		end
		i = i + 2
	end
	if not r.target then return nil, "no target" end
	-- The ebtables IPv4 options only exist after -p IPv4, and the ports only
	-- after a TCP/UDP --ip-proto: keep that coupling, so a rule never widens.
	-- (--set is typed by its ipset instead: hash:net or the portal's hash:mac.)
	if (m.l4 or m.dst or m.src) and m.proto ~= "ipv4" then
		return nil, "IPv4 match without -p IPv4"
	end
	if (m.sport or m.dport) and not m.l4 then return nil, "port without --ip-proto" end
	if m.arp_op and m.proto ~= "arp" then return nil, "ARP opcode without -p arp" end
	if m.set and not m.set_dir then return nil, "set without --set-flags" end
	-- The hooks into GUESTIN/GUESTOUT.
	if chain == "PREROUTING" or chain == "POSTROUTING" then
		local dir = chain == "PREROUTING" and "in" or "out"
		local dev = dir == "in" and r.in_interface or r.out_interface
		if M.ENTRY[r.target] == dir and dev and next(m) == nil and not r.target_ext then
			return {op = "hook", dir = dir, devname = dev, chain = r.target}
		end
		return nil, "unsupported hook"
	end
	if r.out_interface then return nil, "--out-interface inside a guest chain" end
	-- Inside GUESTIN, --in-interface ath<n> only qualifies the EAPOL (and
	-- Broadcom 0x886c / 802.3 length) accepts of a WPA2 guest VAP. The device
	-- cannot name ath<n>, so such a rule applies to every guest VAP -- harmless
	-- for an ethertype accept, and refused for anything wider.
	if r.in_interface and not (next(m, next(m)) == nil
			and (type(m.proto) == "number" or m.proto == "length")) then
		return nil, "interface-specific rule"
	end
	return r
end

-- ─── system_cfg ──────────────────────────────────────────────────────────────

-- The guest restrictions in a system_cfg blob, or nil when the blob has no
-- ebtables block at all (a partial push: leave things as they are). A full
-- push always carries ebtables.status, enabled or not, so that key is the
-- signal that the absence of guest rules means "no guest WLAN".
---@param sys_raw string
---@return GuestRules?
function M.parse(sys_raw)
	if type(sys_raw) ~= "string" then return nil end
	local kv, cmds, seen = {}, {}, false
	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		local k, v = line:match("^([^=]+)=(.*)$")
		if k then
			if k == "ebtables.status" then
				seen = true
				kv[k] = v
			else
				local n = k:match("^ebtables%.(%d+)%.cmd$")
				if n then
					cmds[#cmds + 1] = {n = tonumber(n), cmd = v}
				elseif k:match("^wireless%.%d+%.") or k:match("^ipset%.")
						or k == "redirector.status" or k == "redirector.url" then
					kv[k] = v
				end
			end
		end
	end
	if not seen then return nil end
	table.sort(cmds, function(a, b) return a.n < b.n end)

	local out = {
		enabled = (kv["ebtables.status"] == "enabled"),
		ssids = {}, guest_devnames = {}, conflicts = {},
		hooks = {["in"] = {}, out = {}},
		chains = {}, order = {}, sets = {}, set_types = {},
		unknown = {}, unenforced = {},
	}
	-- Where the portal is, while it is on. Spliced into a Location header:
	-- one token, http(s) only.
	local url = kv["redirector.url"]
	if kv["redirector.status"] == "enabled" and type(url) == "string"
			and url:match("^https?://[%w%.%-:%[%]]+%S*$") and not url:find("[%c\"<>\\']") then
		out.portal_url = url
	end

	-- Which WLANs are guest WLANs: wireless.<n>.is_guest, joined to the SSID.
	-- One SSID carried by a guest WLAN and a non-guest one (two WLANs of the
	-- same name on different bands) cannot be told apart on the device, which
	-- matches VAPs by SSID: refused and reported rather than guessed.
	local by_ssid = {}
	for k, v in pairs(kv) do
		local n = k:match("^wireless%.(%d+)%.is_guest$")
		if n then
			local ssid = kv["wireless." .. n .. ".ssid"]
			if ssid and ssid ~= "" then
				local g = (v == "true")
				local cur = by_ssid[ssid]
				if cur == nil then by_ssid[ssid] = g elseif cur ~= g then by_ssid[ssid] = "conflict" end
				if g then
					local dev = kv["wireless." .. n .. ".devname"]
					if dev then out.guest_devnames[#out.guest_devnames + 1] = dev end
				end
			end
		end
	end
	for ssid, g in pairs(by_ssid) do
		if g == true then out.ssids[#out.ssids + 1] = ssid
		elseif g == "conflict" then out.conflicts[#out.conflicts + 1] = ssid end
	end
	table.sort(out.ssids)
	table.sort(out.conflicts)
	table.sort(out.guest_devnames)

	-- ipset.<n>.name / ipset.<n>.entry.<m>.value (fw_caps 0x40000 only).
	local set_idx = {}
	for k, v in pairs(kv) do
		local n = k:match("^ipset%.(%d+)%.name$")
		if n and set_name(v) then set_idx[n] = v end
	end
	for n, name in pairs(set_idx) do
		local entries = {}
		for k, v in pairs(kv) do
			local m = k:match("^ipset%." .. n .. "%.entry%.(%d+)%.value$")
			if m then entries[#entries + 1] = {tonumber(m), v} end
		end
		table.sort(entries, function(a, b) return a[1] < b[1] end)
		local list = {}
		for _, e in ipairs(entries) do
			if ipv4_cidr(e[2]) then list[#list + 1] = e[2] end
		end
		out.sets[name] = list
		out.set_types[name] = kv["ipset." .. n .. ".type"]
	end

	-- Replay the fragments in wire order.
	for _, c in ipairs(cmds) do
		if M.is_guest_rule(c.cmd) and c.cmd:find("--logical-", 1, true) then
			-- -t nat -A PREROUTING --logical-in br<vlan> -j GUESTIN: a wired
			-- guest network on the device's own ports. Not applied.
			out.unenforced[#out.unenforced + 1] = c.cmd
		elseif M.is_guest_rule(c.cmd) then
			local r, why = parse_cmd(c.cmd)
			if not r then
				out.unknown[#out.unknown + 1] = c.cmd .. "  [" .. tostring(why) .. "]"
			elseif r.op == "new" then
				if not out.chains[r.chain] then
					out.chains[r.chain] = {policy = r.policy, rules = {}}
					out.order[#out.order + 1] = r.chain
				elseif r.policy then
					out.chains[r.chain].policy = r.policy
				end
			elseif r.op == "hook" then
				local list = out.hooks[r.dir]
				list[#list + 1] = r.devname
			else
				local ch = out.chains[r.chain]
				if not ch then
					out.unknown[#out.unknown + 1] = c.cmd .. "  [chain not defined]"
				else
					local rule = {match = r.match, target = r.target, target_ext = r.target_ext,
						in_interface = r.in_interface, cmd = c.cmd}
					if r.insert then
						table.insert(ch.rules, math.min(r.pos or 1, #ch.rules + 1), rule)
					else
						ch.rules[#ch.rules + 1] = rule
					end
				end
			end
		end
	end
	return out
end

-- What to enforce. Returns {enabled = false} when there is nothing to do
-- (no guest WLAN, the block disabled, or no GUESTIN chain), else
--   {enabled = true, portal, portal_url, ssids,
--    chains = {[name] = {policy, rules, portal}}, order,
--    sets = {[name] = {cidr...}}}
-- with every rule the device can express, in order. A portal chain kept for
-- enforcement (portal_url set) has no rules and `portal` = its name:
-- guestguard writes its body. Dropped on the way: rules that name a chain
-- nobody defined, mark/redirect targets, and -- without a portal URL -- the
-- portal's chains, the jumps into them and its DROP policies (see the
-- header). `dropped` lists them for the log.
---@param parsed GuestRules?
---@return GuestSpec
function M.spec_from(parsed)
	if type(parsed) ~= "table" or not parsed.enabled or #(parsed.ssids or {}) == 0
		or not (parsed.chains and parsed.chains.GUESTIN and parsed.chains.GUESTOUT) then
		return {enabled = false}
	end
	local portal = (parsed.chains.GUESTIN.policy == "drop")
	local enforce = portal and parsed.portal_url ~= nil
	local spec = {enabled = true, portal = portal, portal_url = enforce and parsed.portal_url or nil,
		ssids = parsed.ssids, chains = {}, order = {}, sets = {}, set_types = {}, dropped = {}}
	local used_sets = {}
	for _, name in ipairs(parsed.order) do
		if M.PORTAL_CHAINS[name] and enforce then
			for _, r in ipairs(parsed.chains[name].rules) do spec.dropped[#spec.dropped + 1] = r.cmd end
			spec.chains[name] = {policy = "return", rules = {}, portal = name}
			spec.order[#spec.order + 1] = name
		elseif not M.PORTAL_CHAINS[name] then
			local src = parsed.chains[name]
			local policy = src.policy
			-- ebtables' default for a user chain is ACCEPT.
			if policy == nil then policy = "accept" end
			-- The portal's default-deny (GUESTIN) and its DNS hijack
			-- (GUEST_DNS -> REDIRECT_DNS, DROP otherwise): without the
			-- portal, guests are let through like on a portal-less WLAN.
			if portal and not enforce and (name == "GUESTIN" or name == "GUEST_DNS") and policy == "drop" then
				policy = "accept"
			end
			local rules = {}
			for _, r in ipairs(src.rules) do
				local ok, verdict = true, VERDICT[r.target]
				if not verdict then
					if r.target_ext or (M.PORTAL_CHAINS[r.target] and not enforce) then
						ok = false
					elseif parsed.chains[r.target] then
						verdict = "jump"
					else
						ok = false
					end
				end
				-- An ipset that is not a set of IPv4 networks (the portal's
				-- hash:mac guest_authorized_mac) or was never sent.
				if ok and r.match.set and not (parsed.sets[r.match.set]
						and (parsed.set_types or {})[r.match.set] == "hash:net") then
					ok = false
				end
				if ok then
					if r.match.set then used_sets[r.match.set] = true end
					rules[#rules + 1] = {match = r.match, verdict = verdict,
						jump = verdict == "jump" and r.target or nil}
				else
					spec.dropped[#spec.dropped + 1] = r.cmd
				end
			end
			spec.chains[name] = {policy = policy, rules = rules}
			spec.order[#spec.order + 1] = name
		end
	end
	for name in pairs(used_sets) do spec.sets[name] = parsed.sets[name] end
	return spec
end

-- ─── Guest portal bookkeeping (PROTOCOL-VALIDATION.md, "Guest portal") ──────
--
-- On a guest WLAN with the portal on, the controller compares each station's
-- reported `authorized` with its own guest records on every inform: a
-- station it has no record for but that reports authorized gets
-- unauthorize-guest, and one it has a record for that reports unauthorized
-- gets authorize-guest. An absent `authorized` counts as true, so without
-- this every station on such a WLAN drew an unauthorize-guest per inform
-- (lab, 10.4.57: guest_kicks 77 in about 10 minutes) and authorize-guest was
-- never sent at all.

-- Cap on st.guest_authorized. Past it the oldest authorization goes first;
-- the controller re-sends authorize-guest for any guest it still has a
-- record for, so a dropped entry costs one inform, not access.
M.LEDGER_MAX = 512

local function norm_mac(s)
	s = type(s) == "string" and s:lower():match("^%s*(%S+)%s*$")
	return wire.is_mac(s) and s or nil
end
M.norm_mac = norm_mac

-- The wlanconf ids (aaa.<n>.id) on which a station must pass the portal:
-- the wireless.<n>.is_guest WLANs while redirector.status=enabled (it reads
-- "disabled" with the portal off; a guest WLAN without the portal is only
-- restricted, and the controller does not check `authorized` there). nil
-- when the blob has no redirector.status, a partial push.
---@param sys_raw string
---@return table<string, boolean>?
function M.portal_wlans(sys_raw)
	if type(sys_raw) ~= "string" then return nil end
	local status, ids, is_guest = nil, {}, {}
	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		local k, v = line:match("^([^=]+)=(.*)$")
		if k == "redirector.status" then
			status = v
		elseif k then
			local n = k:match("^aaa%.(%d+)%.id$")
			if n then ids[n] = v end
			n = k:match("^wireless%.(%d+)%.is_guest$")
			if n and v == "true" then is_guest[n] = true end
		end
	end
	if status == nil then return nil end
	local out = {}
	if status == "enabled" then
		for n in pairs(is_guest) do
			if ids[n] and ids[n] ~= "" then out[ids[n]] = true end
		end
	end
	return out
end

-- Record (authorize-guest) or drop (unauthorize-guest) one authorization in
-- st.guest_authorized ({mac = epoch s}). Returns false for a malformed MAC,
-- which records nothing.
function M.authorize(st, mac, authorized, now)
	mac = norm_mac(mac)
	if not mac then return false end
	st.guest_authorized = st.guest_authorized or {}
	if not authorized then
		st.guest_authorized[mac] = nil
		return true
	end
	st.guest_authorized[mac] = now
	local n, oldest, oldest_t = 0, nil, nil
	for m, t in pairs(st.guest_authorized) do
		n = n + 1
		if not oldest_t or t < oldest_t then oldest, oldest_t = m, t end
	end
	if n > M.LEDGER_MAX then
		st.guest_authorized[oldest] = nil
	end
	return true
end

-- The ledger as a sorted list (guestguard's openuf_authorized set).
function M.authorized_macs(st)
	local out = {}
	for mac in pairs(type(st) == "table" and type(st.guest_authorized) == "table"
			and st.guest_authorized or {}) do
		out[#out + 1] = mac
	end
	table.sort(out)
	return out
end

-- The `authorized` a station on the WLAN wlan_id reports: the ledger's word
-- on a portal WLAN, true everywhere else (what the controller assumes anyway).
function M.sta_authorized(st, wlan_id, mac)
	local wlans = type(st) == "table" and st.guest_wlans
	if not (type(wlans) == "table" and wlan_id and wlans[wlan_id]) then return true end
	return type(st.guest_authorized) == "table" and st.guest_authorized[tostring(mac):lower()] ~= nil
end

return M
