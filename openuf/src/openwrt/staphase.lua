--[[
	The raw timeline of each client connection, for the controller's
	connection timing: the 802.11 steps hostapd announces (openwrt/staphase.uc,
	the collector procd runs next to the daemon) joined with the first DHCP ACK
	and DNS answer nftables saw (openwrt/dnswatch.lua). Times are µs on the
	wall clock; turning them into the controller's deltas is
	unifi/staevents.lua's job.
]]--

local M = {}

M.FILE = "/tmp/openuf-phases.json"

M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- The collector's file, decoded; nil when it is missing or unreadable.
function M.read()
	local text = M._read_file(M.FILE)
	if not text or text == "" then return nil end
	local ok, doc = pcall(require("cjson").decode, text)
	if not ok or type(doc) ~= "table" then return nil end
	return doc
end

-- {connections = {mac -> {auth, assoc, authorized, dhcp, dns, signal, vap}},
--  failures = {{seq, mac, at, auth, assoc, signal, vap}, ...}}
-- firsts: dnswatch.firsts(). vap_by_ifname: hostapd interface -> the
-- vap_table name the controller knows the SSID by (report.lua).
function M.collect(doc, firsts, vap_by_ifname)
	local out = {connections = {}, failures = {}}
	if type(doc) ~= "table" then return out end
	firsts = firsts or {}
	vap_by_ifname = vap_by_ifname or {}
	local dhcp, dns = firsts.dhcp or {}, firsts.dns or {}
	for _, c in ipairs(type(doc.connections) == "table" and doc.connections or {}) do
		local mac = type(c.mac) == "string" and c.mac:lower()
		if mac and tonumber(c.auth) and tonumber(c.authorized) then
			out.connections[mac] = {
				auth = tonumber(c.auth), assoc = tonumber(c.assoc),
				authorized = tonumber(c.authorized), signal = tonumber(c.signal),
				dhcp = dhcp[mac], dns = dns[mac], vap = vap_by_ifname[c.ifname],
			}
		end
	end
	for _, f in ipairs(type(doc.failures) == "table" and doc.failures or {}) do
		local mac = type(f.mac) == "string" and f.mac:lower()
		if mac and tonumber(f.seq) and tonumber(f.at) then
			out.failures[#out.failures + 1] = {
				seq = tonumber(f.seq), mac = mac, at = tonumber(f.at),
				auth = tonumber(f.auth), assoc = tonumber(f.assoc),
				signal = tonumber(f.signal), vap = vap_by_ifname[f.ifname],
			}
		end
	end
	return out
end

return M
