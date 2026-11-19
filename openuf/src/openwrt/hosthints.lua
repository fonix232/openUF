--[[
	Wireless clients' addresses, for LuCI's host hints.

	LuCI names a MAC (the dashboard's client list, Network -> Wireless) from
	rpcd's luci-rpc getHostHints: DHCP leases, /etc/ethers and the neighbour
	table, then a reverse lookup (network.rrdns) of each address it has. An
	AP runs no DHCP server and talks to few of its clients, so most stations
	have no address there, and no name. The gateway's DNS answers the reverse
	lookup for every DHCP client, on every VLAN; only the address is missing.

	So it is observed: an nftables bridge table adds the source address of
	each frame a wireless interface brings into the bridge to a timed set,
	MAC . IPv4 (the wired ports are left out, or the gateway's MAC would
	collect every address on the internet). Each minute the set goes to
	/tmp/dhcp.leases as dnsmasq leases. Each carries the name rpcd's own
	reverse lookup (network.rrdns) gives its address: the host hints resolve
	the address themselves, but Status > Overview's DHCP table shows only a
	lease's own name. Never while dnsmasq runs, nor over a file openUF did
	not write: the file is someone else's then.
]]--

local util = require("openwrt.util")

local M = {}

M.TABLE  = "bridge openuf_hosts"
M.LEASES = "/tmp/dhcp.leases"
-- A client silent for an hour is dropped from the set.
M.TIMEOUT = 3600
-- What each written lease claims; rewritten every heartbeat, so it only
-- matters for a file left behind (openUF stopped, or a dnsmasq started later
-- reading it as its own).
M.LEASE_TTL = 600
-- A copy of the last file written, which tells openUF's file from another's.
M.OURS = "/tmp/openuf-hosthints.leases"
-- How long a looked-up name is kept: a found name, and an address with none.
M.NAME_TTL, M.NONAME_TTL = 3600, 600
M._names = {}

M._exec  = function(cmd) return os.execute(cmd) end
M._popen = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a") or ""
	h:close()
	return s
end

-- The table for these wireless ifnames. Every statement is idempotent, so a
-- re-run (the ifnames changed, or the periodic re-check) keeps what the set
-- has learned.
function M.script(ifnames)
	local t = M.TABLE
	local lines = {
		"add table " .. t,
		"add set " .. t .. " wifi { type ifname; }",
		("add set %s staips { type ether_addr . ipv4_addr; size 4096; flags dynamic,timeout; timeout %ds; }")
			:format(t, M.TIMEOUT),
		"add chain " .. t .. " learn { type filter hook prerouting priority -100; policy accept; }",
		"flush chain " .. t .. " learn",
		"add rule " .. t .. " learn iifname @wifi ip saddr != 0.0.0.0 update @staips { ether saddr . ip saddr }",
		"add rule " .. t .. " learn iifname @wifi arp saddr ip != 0.0.0.0 update @staips { ether saddr . arp saddr ip }",
		"flush set " .. t .. " wifi",
	}
	local names = {}
	for _, n in ipairs(ifnames) do
		if util.valid_ifname(n) then names[#names + 1] = '"' .. n .. '"' end
	end
	if #names > 0 then
		lines[#lines + 1] = "add element " .. t .. " wifi { " .. table.concat(names, ", ") .. " }"
	end
	return table.concat(lines, "\n") .. "\n"
end

-- Install or update the table for vap_by_ifname's keys (the heartbeat's
-- wireless interfaces). Only when they changed or force (the periodic check
-- that a reboot or flush did not take it).
function M.ensure(vap_by_ifname, force)
	local names = {}
	for n in pairs(vap_by_ifname or {}) do names[#names + 1] = n end
	table.sort(names)
	local key = table.concat(names, " ")
	if key == M._applied and not force then return true end
	local ok = util.nft_run(M.script(names), M._exec, true)
	M._applied = ok and key or nil
	if not ok then
		io.stderr:write("openuf: hosthints: nft rejected the client address table "
			.. "(kmod-nft-bridge missing?); LuCI will not name wireless clients\n")
	end
	return ok
end

-- {mac -> ip} from an `nft list set` dump; of a client's several addresses
-- the one seen last (the most time left).
function M.parse(text)
	local out, left = {}, {}
	for mac, ip, dur in tostring(text or ""):gmatch(
		"(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x) %. (%d+%.%d+%.%d+%.%d+) expires ([%dhms]+)") do
		local us = 0
		for n, unit in dur:gmatch("(%d+)(%a+)") do
			us = us + tonumber(n) * (({ms = 1, s = 1000, m = 60000, h = 3600000})[unit] or 0)
		end
		mac = mac:lower()
		if not left[mac] or us > left[mac] then out[mac], left[mac] = ip, us end
	end
	return out
end

-- {ip -> name} for these addresses: the cached ones, and one rrdns call
-- (rpcd-mod-rrdns, through the AP's resolver, the gateway) for the rest.
-- A name is a lease's one field: anything but a plain DNS name is dropped.
function M.names(ips, now)
	local ask = {}
	for _, ip in ipairs(ips) do
		local c = M._names[ip]
		if not c or now >= c.expires then ask[#ask + 1] = '"' .. ip .. '"' end
	end
	if #ask > 0 then
		local ok, cjson = pcall(require, "cjson")
		local got = ok and select(2, pcall(cjson.decode, M._popen("ubus call network.rrdns lookup '{\"addrs\":["
			.. table.concat(ask, ",") .. "],\"timeout\":2000,\"limit\":1000}'"))) or nil
		got = type(got) == "table" and got or {}
		for _, q in ipairs(ask) do
			local ip = q:sub(2, -2)
			local n = got[ip]
			n = type(n) == "string" and n:match("^[%w][%w%.%-_]*$") and #n <= 253 and n or nil
			M._names[ip] = {name = n, expires = now + (n and M.NAME_TTL or M.NONAME_TTL)}
		end
	end
	local out = {}
	for _, ip in ipairs(ips) do out[ip] = M._names[ip] and M._names[ip].name end
	return out
end

-- dnsmasq's lease lines: "<expiry> <mac> <ip> <name> <client-id>", "*"
-- for a name rrdns did not find.
function M.leases(by_mac, now, names)
	local macs = {}
	for mac in pairs(by_mac) do macs[#macs + 1] = mac end
	table.sort(macs)
	local lines = {}
	for _, mac in ipairs(macs) do
		lines[#lines + 1] = ("%.0f %s %s %s *\n"):format(now + M.LEASE_TTL, mac, by_mac[mac],
			names and names[by_mac[mac]] or "*")
	end
	return table.concat(lines)
end

local function read(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- Whether the lease file's text is openUF's: absent, the last one written
-- (M.OURS), or nothing but nameless leases (what openUF wrote before names).
function M.ours(text)
	if not text or text == read(M.OURS) then return true end
	for line in text:gmatch("[^\n]+") do
		if not line:match("^%d+ %S+ %S+ %* %*$") then return false end
	end
	return true
end

-- One heartbeat: the set to the lease file, unless dnsmasq (or anyone else)
-- owns it.
function M.publish(now)
	if util.exec_ok(M._exec("pidof dnsmasq >/dev/null 2>&1")) then return false end
	if not M.ours(read(M.LEASES)) then return false end
	local by_mac = M.parse(M._popen("nft list set " .. M.TABLE .. " staips"))
	local ips = {}
	for _, ip in pairs(by_mac) do ips[#ips + 1] = ip end
	local text = M.leases(by_mac, now, M.names(ips, now))
	for _, path in ipairs({M.OURS, M.LEASES}) do
		local f = io.open(path .. ".tmp", "w")
		if not f then return false end
		f:write(text)
		f:close()
		if not os.rename(path .. ".tmp", path) then return false end
	end
	return true
end

return M
