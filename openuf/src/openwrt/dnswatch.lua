--[[
	When each wireless client received its first DHCP ACK and its first DNS
	answer -- the DHCP and DNS phases of the controller's connection timing.

	The controller counts a connection from an AP on firmware 6.2.1 or later
	(openUF presents 6.8.2) as successful only when its STA_ASSOC_TRACKER
	`success` carries traffic_delta > 0 and dns_responses > 0; a success without
	them is held in memory for ten minutes and dropped (10.6.106,
	devmgr.w.a.VsCpQiCuGEvNvUNmH, data.hyFnQ.supportTrafficStaTrackerEvents).
	dns_resp_seen, which older firmware reports, is not read at all.
	traffic_delta is the time to the client's first DNS answer, ip_delta the
	time to its DHCP ACK; the 802.11 steps before them come from hostapd
	(openwrt/staphase.uc).

	So they are observed: an nftables bridge table adds each client to a timed
	set on the first DHCP ACK (keyed by the packet's chaddr: an ACK may go out
	to the broadcast address) and the first DNS answer (UDP or TCP source port
	53) forwarded to it. "add" never refreshes an element, so what remains of
	its timeout dates the packet to the millisecond; the collector clears a
	client's elements when a new connection of it starts. The work is done in
	the kernel on frames the bridge forwards anyway; openUF reads the sets once
	per heartbeat. Needs kmod-nft-bridge (in openUF's package list). Kernel
	state, so ensure() re-creates it after a reboot or anything that flushed
	it.
]]--

local M = {}

M.TABLE    = "bridge openuf_ev"
M.NFT_FILE = "/tmp/openuf-ev.nft"
-- Long enough for the slowest DNS answer the controller accepts (its deltas
-- stop at one minute) to still be readable at the next heartbeat.
M.TIMEOUT  = 70

M._exec  = function(cmd) return os.execute(cmd) end
M._popen = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a") or ""
	h:close()
	return s
end
-- Wall clock in microseconds, the collector's clock.
M._now_us = function()
	local ok, socket = pcall(require, "socket")
	if ok and socket.gettime then return math.floor(socket.gettime() * 1000000) end
	return os.time() * 1000000
end

local function exec_ok(s) return s == true or s == 0 end

-- Created and deleted before it is defined, so one nft transaction replaces
-- whatever an older openUF left under the same name.
M.RULESET = ([[
table bridge openuf_ev
delete table bridge openuf_ev
table bridge openuf_ev {
	set dhcpfirst {
		typeof @th,288,48
		flags dynamic,timeout
		timeout %ds
	}
	set dnsfirst {
		type ether_addr
		flags dynamic,timeout
		timeout %ds
	}
	chain answers {
		type filter hook forward priority 0; policy accept;
		udp sport 67 udp dport 68 add @dhcpfirst { @th,288,48 }
		udp sport 53 add @dnsfirst { ether daddr }
		tcp sport 53 add @dnsfirst { ether daddr }
	}
}
]]):format(M.TIMEOUT, M.TIMEOUT)

-- Create the table unless it is already there. Returns true when it exists.
function M.ensure()
	if exec_ok(M._exec("nft list set " .. M.TABLE .. " dnsfirst >/dev/null 2>&1")) then
		return true
	end
	local f = io.open(M.NFT_FILE, "w")
	if not f then return false end
	f:write(M.RULESET)
	f:close()
	local ok = exec_ok(M._exec("nft -f " .. M.NFT_FILE .. " >/dev/null 2>&1"))
	os.remove(M.NFT_FILE)
	if not ok then
		io.stderr:write("openuf: dnswatch: nft rejected the DHCP/DNS timing table "
			.. "(kmod-nft-bridge missing?); connections will not be reported\n")
	end
	return ok
end

-- Drop the table: connection events are switched off (option sta_events).
function M.remove()
	M._exec("nft delete table " .. M.TABLE .. " >/dev/null 2>&1")
end

-- "1m2s", "59s990ms", "990ms" -> microseconds.
function M.parse_duration(s)
	local us = 0
	for n, unit in tostring(s or ""):gmatch("(%d+)(%a+)") do
		local mult = ({ms = 1000, s = 1000000, m = 60000000, h = 3600000000,
			d = 86400000000})[unit]
		if mult then us = us + tonumber(n) * mult end
	end
	return us
end

-- The elements of one set in an `nft list table` dump: {key -> expires_us}.
local function set_elements(text, name)
	local body = text:match("set " .. name .. " {(.-)\n\t}")
	local out = {}
	if not body then return out end
	for key, dur in body:gmatch("([%x:x]+) expires ([%dhms]+)") do
		out[key] = M.parse_duration(dur)
	end
	return out
end

-- The first DHCP ACK and the first DNS answer each client received within
-- the timeout, dated in µs on the wall clock:
-- {dhcp = {mac -> t}, dns = {mac -> t}}.
function M.firsts()
	local at = M._now_us()
	local text = M._popen("nft list table " .. M.TABLE)
	local timeout = M.TIMEOUT * 1000000
	local out = {dhcp = {}, dns = {}}
	for key, left in pairs(set_elements(text, "dhcpfirst")) do
		-- The key is the 48-bit chaddr as a number, leading zeros dropped.
		local hex = key:match("^0x(%x+)$")
		if hex and #hex <= 12 then
			hex = ("0"):rep(12 - #hex) .. hex:lower()
			out.dhcp[hex:gsub("(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)", "%1:%2:%3:%4:%5:%6")] =
				at - (timeout - left)
		end
	end
	for key, left in pairs(set_elements(text, "dnsfirst")) do
		if key:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
			out.dns[key:lower()] = at - (timeout - left)
		end
	end
	return out
end

return M
