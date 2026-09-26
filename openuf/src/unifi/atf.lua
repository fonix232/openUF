--[[
	atf.lua -- the controller's Airtime Fairness switch out of system_cfg.

	The AP's own setting (device panel, REST `device.atf_enabled`), pushed as

	  atf.status=enabled          always, whenever the block is sent
	  atf.mode=enabled|disabled   the switch

	and only to a device claiming wifi_caps 0x20 (supportATFConfig(), see
	openwrt/report.lua). Captured on 10.4.57 (PROTOCOL-VALIDATION.md,
	Capability bitmasks). `mode` is enabled when the device's atf_enabled is on
	and the site's advanced features are on, which 10.x always writes back to
	true, so in practice it follows atf_enabled alone. openwrt/airtime.lua
	carries it out.
]]--

local M = {}

-- true/false for atf.mode, nil when the block (or its mode) is absent or
-- carries an unknown value, which leaves the current setting alone.
---@param sys_raw string  system_cfg
---@return boolean?
function M.parse(sys_raw)
	if type(sys_raw) ~= "string" then return nil end
	local mode = sys_raw:match("\natf%.mode=([%w_]+)")
		or sys_raw:match("^atf%.mode=([%w_]+)")
	if mode == "enabled" then return true end
	if mode == "disabled" then return false end
	return nil
end

return M
