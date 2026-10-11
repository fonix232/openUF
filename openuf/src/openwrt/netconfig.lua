--[[
	The controller's "IP Settings" (DHCP vs Static) push: the validator its
	values pass before they are recorded. Delivered via the inform response's
	`system_cfg` field -- a flat OpenWrt-UCI-style key=value blob (same format
	as `mgmt_cfg`, different keys). Confirmed live against a real controller:
	static IP is `netconf.1.ip`/`netconf.1.netmask`, gateway is
	`route.1.gateway`, DNS is `resolv.nameserver.N.ip`, and DHCP-vs-static is
	signalled by the presence/absence of `dhcpc.1.*` sub-keys (not an explicit
	flag) -- see PROTOCOL-VALIDATION.md.

	The settings themselves are applied as UCI on the management interface
	(netmodel.apply_addressing), with netifd doing the work and the plan's
	rollback window guarding it. They used to be `ip addr` commands on
	lan_cpueth, which on most boards is a bridge port, while netifd's DHCP
	client kept running on the bridge.
]]--

local M = {}

-- Strict IPv4 dotted-quad check. Exported so provision.lua can refuse a
-- malformed push before RECORDING it in state.json, not only before applying
-- it.
function M.is_ipv4(s)
	if type(s) ~= "string" then return false end
	local octets = {s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")}
	if #octets ~= 4 then return false end
	for _, o in ipairs(octets) do
		if #o > 3 or tonumber(o) > 255 then return false end
	end
	return true
end

return M
