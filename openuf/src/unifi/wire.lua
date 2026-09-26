--[[
	wire.lua -- the controller's value encodings, and the validators every
	wire-supplied value passes before it reaches a command line or UCI.
]]--

local M = {}

-- A boolean as the controller writes it ("1"/"true"/"enabled"); nil when the
-- key was absent, which callers treat differently from false.
function M.bool(v)
	if v == nil then return nil end
	return v == "1" or v == "true" or v == "enabled"
end

-- Tri-state read of a `status` key for the radio/VAP disable controls:
--   nil       -> the key was absent; leave whatever UCI already has alone
--   false     -> explicitly enabled
--   true      -> explicitly disabled
-- The absent case matters: a blob that never carries the key must not
-- re-enable a radio or SSID the user disabled by hand in /etc/config/wireless.
function M.status_disabled(v)
	if v == nil then return nil end
	return v == "disabled"
end

-- 32 hex chars = 16 bytes = a valid AES-128 key (matches syswrapper.lua's check)
function M.is_hex32(s)
	return type(s) == "string" and #s == 32 and s:match("^[0-9a-fA-F]+$") ~= nil
end

-- Exactly "aa:bb:cc:dd:ee:ff". Wire-supplied MACs -- the MAC filter's ACL, the
-- Multicast/Broadcast Blocker's allow-list -- end up inside nft and
-- hostapd_cli command lines (bcfilter.lua, firewall.lua) or in UCI lists
-- hostapd parses, so anything not of this shape is refused at the boundary
-- rather than escaped. The controller is authenticated once adopted, but
-- before that the inform channel is plain HTTP under the well-known default
-- key and a forged setparam is within reach of anyone on the path; this is
-- what keeps that from becoming a shell.
function M.is_mac(s)
	return type(s) == "string" and s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

return M
