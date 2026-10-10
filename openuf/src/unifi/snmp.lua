--[[
	snmp.lua -- the site's SNMP Monitoring setting out of system_cfg.

	Decompiled from 10.6.106 (com.ubnt.service.config.lwueNrOWUBYJX, called
	by the AP generator VAZShipWTNxlo with prefix "" and key "community");
	not yet seen on the wire. Sent only while SNMP is on:

	  snmp.status=enabled
	  snmp.version=1_2c | 3 | all        (v1/v2c, v3, both)
	  snmp.location=<text>               (device snmp_location, when set)
	  snmp.contact=<text>                (device snmp_contact, when set)
	  snmp.community=<string>            v1/v2c only, default "public"
	  snmp.user.1.name=<user>            v3 only
	  snmp.user.1.password=<password>    v3 only

	v1/v2c is sent to every device; v3 only to one claiming fw_caps 0x4000
	(supportsSNMPv3). There is no snmp.status=disabled: SNMP off is the
	absence of the block, so a full system_cfg without it means "off".
]]--

local M = {}

-- Values reach snmpd.conf through OpenWrt's init script, which writes some of
-- them inside double quotes: printable, no quote, backslash or whitespace.
local function token(s, max)
	return type(s) == "string" and #s >= 1 and #s <= (max or 64)
		and s:match("^[%w%p]+$") ~= nil and not s:find('["\\]')
end

-- Free text (location/contact): printable ASCII, no quote or backslash.
local function text(s)
	return type(s) == "string" and #s >= 1 and #s <= 255
		and s:match("^[%w%p ]+$") ~= nil and not s:find('["\\]')
end

-- Returns nil when the blob is not a system_cfg at all; otherwise
-- {enabled = bool, v1v2c = bool, v3 = bool, community, location, contact,
--  user, password} -- enabled = false when the block is absent.
---@param sys_raw string
---@return SnmpIntent?
function M.parse(sys_raw)
	if type(sys_raw) ~= "string" then return nil end
	local kv = {}
	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		local k, v = line:match("^snmp%.([%w%._]+)=(.*)$")
		if k then kv[k] = v end
	end
	if kv.status ~= "enabled" then return {enabled = false} end
	local ver = kv.version
	local out = {
		enabled  = true,
		v1v2c    = (ver == "1_2c" or ver == "all"),
		v3       = (ver == "3" or ver == "all"),
		location = text(kv.location) and kv.location or nil,
		contact  = text(kv.contact) and kv.contact or nil,
	}
	if out.v1v2c then
		if token(kv.community) then
			out.community = kv.community
		else
			io.stderr:write("inform: snmp: unusable community string, v1/v2c not enabled\n")
			out.v1v2c = false
		end
	end
	if out.v3 then
		-- net-snmp's createUser needs a passphrase of 8 characters or more.
		if token(kv["user.1.name"], 32) and token(kv["user.1.password"], 64)
				and #kv["user.1.password"] >= 8 then
			out.user, out.password = kv["user.1.name"], kv["user.1.password"]
		else
			io.stderr:write("inform: snmp: unusable v3 user or password (8+ printable "
				.. "characters, no quotes or spaces), v3 not enabled\n")
			out.v3 = false
		end
	end
	if not out.v1v2c and not out.v3 then out.enabled = false end
	return out
end

return M
