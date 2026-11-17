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
	collect every address on the internet). Each heartbeat the set goes to
	/tmp/dhcp.leases as dnsmasq leases with no name ("*"), which rpcd reads
	and resolves itself. Never while dnsmasq runs, nor over a file holding
	anything but such leases: the file is someone else's then.
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

-- dnsmasq's lease lines: "<expiry> <mac> <ip> <name> <client-id>".
function M.leases(by_mac, now)
	local macs = {}
	for mac in pairs(by_mac) do macs[#macs + 1] = mac end
	table.sort(macs)
	local lines = {}
	for _, mac in ipairs(macs) do
		lines[#lines + 1] = ("%.0f %s %s * *\n"):format(now + M.LEASE_TTL, mac, by_mac[mac])
	end
	return table.concat(lines)
end

-- Whether text could be ours: absent, or nothing but nameless leases.
function M.ours(text)
	if not text then return true end
	for line in text:gmatch("[^\n]+") do
		if not line:match("^%d+ %S+ %S+ %* %*$") then return false end
	end
	return true
end

-- One heartbeat: the set to the lease file, unless dnsmasq (or anyone else)
-- owns it.
function M.publish(now)
	if util.exec_ok(M._exec("pidof dnsmasq >/dev/null 2>&1")) then return false end
	local cur = io.open(M.LEASES, "r")
	if cur then
		local text = cur:read("*a")
		cur:close()
		if not M.ours(text) then return false end
	end
	local text = M.leases(M.parse(M._popen("nft list set " .. M.TABLE .. " staips")), now)
	local tmp = M.LEASES .. ".openuf"
	local f = io.open(tmp, "w")
	if not f then return false end
	f:write(text)
	f:close()
	return os.rename(tmp, M.LEASES) and true or false
end

return M
