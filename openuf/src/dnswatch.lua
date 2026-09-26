--[[
	Which wireless clients have received a DNS answer -- the proof the
	controller wants before it counts a connection as successful.

	A STA_ASSOC_TRACKER `success` event is only recorded (the client's WiFi
	connection history, the connectivity statistics) when the device says it saw
	the client get a DNS response (`dns_resp_seen: "yes"`); anything else is held
	as an unverified attempt and never stored (10.6.106,
	devmgr.w.a.VsCpQiCuGEvNvUNmH and wifi.connectivity.a.ctfbDsCjrxgkv). openUF
	used to send "N/A" -- honest, and invisible.

	So it observes it: an nftables bridge table adds the destination MAC of every
	forwarded DNS answer (UDP or TCP source port 53) to a timed set. The work is
	done in the kernel on frames the bridge forwards anyway; openUF reads the set
	once per heartbeat. Needs kmod-nft-bridge (in openUF's package list). Kernel
	state, so ensure() re-creates it after a reboot or anything that flushed it.
]]--

local M = {}

M.TABLE   = "bridge openuf_ev"
M.SET     = "dnsok"
M.NFT_FILE = "/tmp/openuf-ev.nft"

M._exec  = function(cmd) return os.execute(cmd) end
M._popen = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a") or ""
	h:close()
	return s
end

local function exec_ok(s) return s == true or s == 0 end

M.RULESET = [[
table bridge openuf_ev {
	set dnsok {
		type ether_addr
		flags dynamic,timeout
		timeout 30m
	}
	chain dns_answers {
		type filter hook forward priority 0; policy accept;
		udp sport 53 add @dnsok { ether daddr }
		tcp sport 53 add @dnsok { ether daddr }
	}
}
]]

-- Create the table unless it is already there. Returns true when it exists.
function M.ensure()
	if exec_ok(M._exec("nft list set " .. M.TABLE .. " " .. M.SET .. " >/dev/null 2>&1")) then
		return true
	end
	local f = io.open(M.NFT_FILE, "w")
	if not f then return false end
	f:write(M.RULESET)
	f:close()
	local ok = exec_ok(M._exec("nft -f " .. M.NFT_FILE .. " >/dev/null 2>&1"))
	os.remove(M.NFT_FILE)
	if not ok then
		io.stderr:write("openuf: dnswatch: nft rejected the DNS-answer table (kmod-nft-bridge "
			.. "missing?); connection events will report DNS as N/A\n")
	end
	return ok
end

-- Drop the table: connection events are switched off (option sta_events).
function M.remove()
	M._exec("nft delete table " .. M.TABLE .. " >/dev/null 2>&1")
end

-- The set of client MACs that received a DNS answer recently: {mac -> true}.
function M.seen()
	local out = {}
	local text = M._popen("nft list set " .. M.TABLE .. " " .. M.SET)
	for mac in text:gmatch("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)") do
		out[mac:lower()] = true
	end
	return out
end

return M
