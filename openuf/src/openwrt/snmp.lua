--[[
	The controller's SNMP Monitoring setting (unifi/snmp.lua) on OpenWrt's
	net-snmp agent.

	OpenWrt 25.12 packages net-snmp as `snmpd-ssl` / `snmpd-nossl` (43 KiB
	each, plus libnetsnmp at ~1.1 MiB), configured from /etc/config/snmpd by
	its init script, which also understands `config v3` users (createUser +
	rouser). openUF does not depend on it: with no /etc/init.d/snmpd the push
	is logged once and nothing else happens. v3 needs privacy (the gateway
	side of the same setting uses SHA authentication and AES privacy with
	one passphrase, 10.6.106 tmTjAksIyMivqmlnYPu), so v3 -- and the fw_caps
	0x4000 claim -- needs the ssl build (M.v3_capable).

	While the controller has SNMP on, openUF owns /etc/config/snmpd: the file
	the device had is kept once in /etc/openuf/snmpd.orig, and the config is
	rewritten from the push -- one read-only community (v1/v2c), one v3 user,
	sysLocation/sysContact -- so a community or user the controller does not
	know about is never left answering. When the controller turns SNMP off
	(the block is absent from a full system_cfg) the kept file goes back and
	snmpd is restarted on it; st.snmp_owned is the ledger that tells a
	device openUF configured from one it never touched.
]]--

local M = {}

M.CONFIG     = "/etc/config/snmpd"
M.BACKUP     = "/etc/openuf/snmpd.orig"
M.INIT       = "/etc/init.d/snmpd"
M.APK_DB     = "/lib/apk/db/installed"

M._exec = function(cmd) return os.execute(cmd) end
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end
M._write_file = function(path, data)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(data)
	f:close()
	return true
end
M._uci = nil   -- nil = require("uci") on first use

local function get_uci()
	if not M._uci then M._uci = require("uci") end
	return M._uci
end

local warned = false

function M.installed()
	return M._read_file(M.INIT) ~= nil
end

-- The ssl build: libnetsnmp linked with OpenSSL, the only one with AES/DES
-- privacy. Read from apk's database (25.12 has no opkg).
function M.v3_capable()
	if not M.installed() then return false end
	local db = "\n" .. (M._read_file(M.APK_DB) or "")
	return db:find("\nP:snmpd%-ssl\n") ~= nil or db:find("\nP:libnetsnmp%-ssl\n") ~= nil
end

-- A fingerprint of everything the config below is built from, so an
-- unchanged push restarts nothing.
local function fingerprint(i)
	return table.concat({
		tostring(i.v1v2c), tostring(i.v3), i.community or "", i.user or "",
		i.password or "", i.location or "", i.contact or "",
	}, "\1")
end

local function write_config(cursor, i)
	local names = {}
	cursor:foreach("snmpd", nil, function(s) names[#names + 1] = s[".name"] end)
	for _, n in ipairs(names) do cursor:delete("snmpd", n) end
	local function sec(name, stype, opts)
		cursor:set("snmpd", name, stype)
		for k, v in pairs(opts) do cursor:set("snmpd", name, k, v) end
	end
	sec("agent", "agent", {agentaddress = "UDP:161,UDP6:161"})
	sec("general", "snmpd", {enabled = "1",
		snmp_version = (i.v1v2c and i.v3) and "v1/v2c/v3" or (i.v3 and "v3" or "v1/v2c")})
	local sys = {}
	if i.location then sys.sysLocation = i.location end
	if i.contact then sys.sysContact = i.contact end
	sec("system", "system", sys)
	sec("all", "view", {viewname = "all", type = "included", oid = ".1"})
	if i.v1v2c then
		sec("public", "com2sec", {secname = "ro", source = "default", community = i.community})
		sec("public6", "com2sec6", {secname = "ro", source = "default", community = i.community})
		sec("public_v1", "group", {group = "public", version = "v1", secname = "ro"})
		sec("public_v2c", "group", {group = "public", version = "v2c", secname = "ro"})
		sec("public_access", "access", {group = "public", context = "none", version = "any",
			level = "noauth", prefix = "exact", read = "all", write = "none", notify = "none"})
	end
	if i.v3 then
		sec("openuf_v3", "v3", {username = i.user, allow_write = "0",
			auth_type = "SHA", auth_pass = i.password,
			privacy_type = "AES", privacy_pass = i.password, RestrictOID = "no"})
	end
	cursor:commit("snmpd")
end

-- Apply one parsed intent. st carries the ledger (snmp_owned, snmp_applied).
-- Returns true when snmpd was (re)configured or restored.
---@param intent SnmpIntent?
---@param st table
function M.apply(intent, st)
	if type(intent) ~= "table" then return false end
	if not intent.enabled then
		if not st.snmp_owned then return false end
		local orig = M._read_file(M.BACKUP)
		if orig then
			M._write_file(M.CONFIG, orig)
			os.remove(M.BACKUP)
		else
			local cursor = get_uci().cursor()
			cursor:set("snmpd", "general", "snmpd")
			cursor:set("snmpd", "general", "enabled", "0")
			cursor:commit("snmpd")
		end
		if M.installed() then M._exec(M.INIT .. " restart >/dev/null 2>&1") end
		st.snmp_owned, st.snmp_applied = nil, nil
		io.stderr:write("openuf: SNMP off -- snmpd config restored\n")
		return true
	end
	if not M.installed() then
		if not warned then
			warned = true
			io.stderr:write("openuf: the controller has SNMP Monitoring on, but snmpd is not "
				.. "installed (apk add snmpd-ssl) -- nothing applied\n")
		end
		return false
	end
	local i = {}
	for k, v in pairs(intent) do i[k] = v end
	if i.v3 and not M.v3_capable() then
		io.stderr:write("openuf: SNMPv3 needs snmpd-ssl (privacy) -- v3 user not configured\n")
		i.v3 = false
		if not i.v1v2c then return false end
	end
	local fp = fingerprint(i)
	if st.snmp_owned and st.snmp_applied == fp then return false end
	if not st.snmp_owned then
		local orig = M._read_file(M.CONFIG)
		if orig then M._write_file(M.BACKUP, orig) end
	end
	write_config(get_uci().cursor(), i)
	M._exec(M.INIT .. " enable >/dev/null 2>&1")
	M._exec(M.INIT .. " restart >/dev/null 2>&1")
	st.snmp_owned, st.snmp_applied = true, fp
	return true
end

return M
