--[[
	Client blocking, driven by the controller's "Block"/"Unblock" client
	actions. Delivered as a one-shot inform-response cmd (`{"_type":"cmd",
	"cmd":"block-sta"|"unblock-sta","mac":"<mac>"}`) and, authoritatively, as
	the setparam's blocked_sta list -- see PROTOCOL-VALIDATION.md and
	provision.lua. The device remembers the block (state.blocked_stas) and
	reconciles it at startup.

	Enforcement is nftables, in a dedicated `bridge openuf` table so it never
	collides with (or gets wiped by) OpenWrt's own fw4-managed tables. Live
	kernel state, not UCI: rebuilt from the persisted list after a restart
	(M.reconcile, called on block/unblock and at inform.lua startup).

	One set (`blocked_macs`) holds every blocked MAC and three rules match
	against it: frames from and to it through the bridge (forward), and
	frames from it to the AP itself (input: the AP's own address, DHCP or DNS
	it may serve, its web UI). The whole table is replaced in one `nft -f`
	transaction -- the old table goes and the new one appears together, or
	nothing changes -- and read back afterwards: a command that ran is not a
	command that succeeded.

	Kicking the client off the air is ucihelper.disconnect_station's job
	(every VAP, hostapd del_client), called by provision.lua.
]]--

local M = {}

-- Injectable: shell command runner and command reader, for real `nft`.
M._exec = function(cmd) return os.execute(cmd) end
M._popen = function(cmd)
	local p = io.popen(cmd .. " 2>/dev/null")
	if not p then return "" end
	local out = p:read("*a") or ""
	p:close()
	return out
end
M._tmpname = os.tmpname

M.TABLE = "bridge openuf"

-- os.execute's success on Lua 5.1 (0) and 5.2+ (true).
local exec_ok = require("openwrt.util").exec_ok

-- Exactly "aa:bb:cc:dd:ee:ff". Every MAC below goes into an nft script; the
-- list comes from the controller by way of state.json, which is also
-- hand-editable, so this module refuses anything else itself.
local function is_mac(s)
	return type(s) == "string" and s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

-- The nft script that replaces the table with one blocking macs (valid,
-- lowercase, deduplicated). `add table` first, so the `delete` never fails
-- on a fresh boot.
function M.script(macs)
	local els = {}
	for _, m in ipairs(macs) do els[#els + 1] = m end
	local lines = {
		"add table " .. M.TABLE,
		"delete table " .. M.TABLE,
		"table " .. M.TABLE .. " {",
		"\tset blocked_macs {",
		"\t\ttype ether_addr",
	}
	if #els > 0 then lines[#lines + 1] = "\t\telements = { " .. table.concat(els, ", ") .. " }" end
	for _, l in ipairs({
		"\t}",
		"\tchain block {",
		"\t\ttype filter hook forward priority 0; policy accept;",
		"\t\tether saddr @blocked_macs drop",
		"\t\tether daddr @blocked_macs drop",
		"\t}",
		"\tchain input {",
		"\t\ttype filter hook input priority 0; policy accept;",
		"\t\tether saddr @blocked_macs drop",
		"\t}",
		"}",
	}) do lines[#lines + 1] = l end
	return table.concat(lines, "\n") .. "\n"
end

-- The MACs `nft list set` shows in blocked_macs, as a set; nil when the set
-- (or nft) is not there.
function M.read_back()
	local out = M._popen("nft list set " .. M.TABLE .. " blocked_macs")
	if not out:find("blocked_macs", 1, true) then return nil end
	local got = {}
	for m in out:gmatch("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)") do got[m:lower()] = true end
	return got
end

-- Rebuild the blocklist to exactly match blocked_macs (a list of MAC
-- strings). Safe with an empty list (an empty set, blocking nothing) and to
-- repeat. Returns true when the table was replaced and reads back as asked.
function M.reconcile(blocked_macs)
	local macs, seen = {}, {}
	for _, mac in ipairs(blocked_macs or {}) do
		if is_mac(mac) then
			local m = mac:lower()
			if not seen[m] then seen[m] = true; macs[#macs + 1] = m end
		else
			io.stderr:write(("firewall: ignoring malformed blocked MAC %q\n"):format(tostring(mac)))
		end
	end
	local path = M._tmpname()
	local f = io.open(path, "w")
	if not f then
		io.stderr:write("firewall: cannot write the nft script -- blocked clients not enforced\n")
		return false
	end
	f:write(M.script(macs))
	f:close()
	local rc = M._exec("nft -f '" .. path .. "' 2>/dev/null")
	os.remove(path)
	if not exec_ok(rc) then
		io.stderr:write("firewall: nft rejected the blocklist -- " .. #macs
			.. " blocked client(s) not enforced\n")
		return false
	end
	local got = M.read_back()
	if not got then
		io.stderr:write("firewall: nft shows no blocklist after loading it -- blocked clients not enforced\n")
		return false
	end
	local n = 0
	for _ in pairs(got) do n = n + 1 end
	for _, m in ipairs(macs) do
		if not got[m] then
			io.stderr:write("firewall: " .. m .. " is not in the blocklist nft shows\n")
			return false
		end
	end
	if n ~= #macs then
		io.stderr:write("firewall: the blocklist nft shows holds " .. n .. " MACs, not " .. #macs .. "\n")
		return false
	end
	return true
end

-- Injectable: run a command and return its output.
M._read = function(cmd)
	local p = io.popen(cmd)
	if not p then return "" end
	local out = p:read("*a") or ""
	p:close()
	return out
end

-- The hostapd control sockets that exist and which socket each one is, as
-- one string: a single read of /proc/net/unix, no fork. hostapd opens a
-- BSS's socket when it sets the BSS up, so the inode changes whenever a
-- hostapd restart or a BSS torn down and rebuilt has thrown that BSS's
-- runtime deny list away. A BSS reloaded in place keeps its socket, so this
-- does not see that.
function M.hostapd_sockets()
	local t = {}
	for inode, path in (M._read_file("/proc/net/unix") or ""):gmatch("(%d+) (/var/run/hostapd/%S+)") do
		t[#t + 1] = path .. "=" .. inode
	end
	table.sort(t)
	return table.concat(t, " ")
end

-- Injectable: a file's contents, or nil.
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function macs_in(text)
	local out = {}
	for line in (text or ""):gmatch("[^\n]+") do
		local mac = line:lower():match("^%s*(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
		if mac then out[mac] = true end
	end
	return out
end

--[[
	The refusal half of a block, as the UniFi firmware has it: the driver
	refuses association from a blocked MAC (iwpriv addmac_blksta on every
	user and guest VAP, re-applied whenever one comes up; firmware-confirmed
	for 3.9.27 to 4.0.15). hostapd's equivalent is its deny ACL, which turns
	away authentication and association and drops any station it already
	has with that MAC. The nft drop stays as the backstop: hostapd checks
	its accept list first, so a MAC filter in allow mode that lists a
	blocked MAC still lets it associate.

	The runtime list lives only in hostapd: a restart or a BSS reload
	resets it to what the BSS's config file says (deny_mac_file, the
	controller's MAC filter in deny mode). So the list is read back and
	repaired on every call, and the caller keeps calling while anything is
	blocked. Every runtime entry the config file doesn't list is taken to be
	openUF's: nothing else on OpenWrt adds deny ACL entries at runtime
	(usteer and DAWN ban through ubus). That makes the sync stateless, so an
	unblock while openUF was not running is still cleaned up.

	blocked: the MAC list; bsses: the AP BSS netdevs. Returns true when
	another look is needed: a BSS that did not answer, or a change made that
	the next call will read back.
]]--
function M.deny_sync(blocked, bsses)
	local want = {}
	for _, m in ipairs(blocked or {}) do
		m = tostring(m):lower()
		if is_mac(m) then want[m] = true end
	end
	local names = {}
	for _, b in ipairs(bsses or {}) do
		if type(b) == "string" and b:match("^[%w%._%-]+$") then names[#names + 1] = b end
	end
	if #names == 0 then return next(want) ~= nil end

	local script = {}
	for _, b in ipairs(names) do
		script[#script + 1] = "echo '@ " .. b .. "'; hostapd_cli -i " .. b
			.. " deny_acl SHOW 2>/dev/null || echo FAIL"
	end
	script[#script + 1] = "echo '@'; for f in /var/run/hostapd-*.conf; do"
		.. " grep -E '^(interface|bss|deny_mac_file)=' \"$f\"; done 2>/dev/null"
	local shown, failed, deny_file = {}, {}, {}
	local cur, conf_bss
	for line in M._read(table.concat(script, "; ")):gmatch("[^\n]+") do
		local marker = line:match("^@ ?(.*)$")
		if marker then
			cur = marker ~= "" and marker or nil
			if cur then shown[cur] = {} end
		elseif cur then
			if line:match("^FAIL") then failed[cur] = true
			else
				local mac = line:lower():match("^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
				if mac then shown[cur][mac] = true end
			end
		else
			local key, val = line:match("^([%w_]+)=(.*)$")
			if key == "interface" or key == "bss" then conf_bss = val
			elseif key == "deny_mac_file" and conf_bss then deny_file[conf_bss] = val end
		end
	end

	local cmds, again = {}, false
	for _, b in ipairs(names) do
		if failed[b] or not shown[b] then
			again = true
		else
			local keep = deny_file[b] and macs_in(M._read_file(deny_file[b])) or {}
			for m in pairs(want) do
				if not shown[b][m] then
					cmds[#cmds + 1] = "hostapd_cli -i " .. b .. " deny_acl ADD_MAC " .. m
				end
			end
			for m in pairs(shown[b]) do
				if not want[m] and not keep[m] then
					cmds[#cmds + 1] = "hostapd_cli -i " .. b .. " deny_acl DEL_MAC " .. m
				end
			end
		end
	end
	if #cmds > 0 then
		table.sort(cmds)
		M._exec("{ " .. table.concat(cmds, "; ") .. "; } >/dev/null 2>&1")
		again = true
	end
	return again
end

-- Immediately kick mac if it's currently associated to any of the given
-- wireless interfaces (ifnames), on top of the nft drop rule from
-- M.reconcile -- the drop rule alone stops future traffic, but a station
-- already associated stays associated (just unable to pass data) until it's
-- actually deauthenticated. Best-effort per interface: a station is only
-- ever associated to one radio at a time, so every other call here is
-- expected to (harmlessly) fail to find it.
function M.deauth(mac, ifnames)
	if not is_mac(mac) then return false end
	for _, ifname in ipairs(ifnames or {}) do
		M._exec("hostapd_cli -i " .. ifname .. " deauthenticate " .. mac .. " 2>/dev/null")
	end
	return true
end

return M
