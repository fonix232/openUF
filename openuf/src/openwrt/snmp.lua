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
	the device had is kept once in /etc/openuf/snmpd.orig (mode 0600: it may
	hold a community; written only when no copy exists yet, so a crash
	between the copy and the state save can never make openUF's own config
	the "original"), with whether snmpd was enabled (st.snmp_was_enabled),
	and the config is rewritten from the push -- one read-only community
	(v1/v2c), one v3 user, sysLocation/sysContact -- so a community or user
	the controller does not know about is never left answering. When the
	controller turns SNMP off (the block is absent from a FULL system_cfg,
	one carrying ebtables.status; a partial push decides nothing) the kept
	file goes back, and snmpd is restarted on it, or stopped and disabled
	if it was not enabled before. st.snmp_owned is the ledger that tells a
	device openUF configured from one it never touched; st.snmp_applied is a
	SHA-256 of what was applied, never the community or password itself.

	SNMP on with nothing usable (a v3 password net-snmp refuses, v3 on the
	nossl build, an unusable community) does NOT put the stock config back,
	which answers `public`: snmpd is stopped and disabled, and the log says
	why.
]]--

local M = {}

M.CONFIG     = "/etc/config/snmpd"
M.BACKUP     = "/etc/openuf/snmpd.orig"
M.INIT       = "/etc/init.d/snmpd"
M.APK_DB     = "/lib/apk/db/installed"
-- installed / v3_capable are asked every heartbeat (report.fw_caps); the
-- answer is kept this long rather than reading the whole apk database.
M.CACHE_TTL  = 600

M._exec = function(cmd) return os.execute(cmd) end
M._time = os.time
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end
-- private: readable by root only (chmod 600 before the data goes in).
M._write_file = function(path, data, private)
	local tmp = path .. ".tmp"
	os.remove(tmp)
	local f = io.open(tmp, "w")
	if not f then return false end
	if private then
		f:close()
		local rc = os.execute("chmod 600 '" .. tmp .. "'")
		if rc ~= 0 and rc ~= true then
			os.remove(tmp)
			return false
		end
		f = io.open(tmp, "w")
		if not f then
			os.remove(tmp)
			return false
		end
	end
	local ok = f:write(data)
	local closed = f:close()
	if not (ok and closed and os.rename(tmp, path)) then
		os.remove(tmp)
		return false
	end
	return true
end
M._uci = nil   -- nil = require("uci") on first use

local function get_uci()
	if not M._uci then M._uci = require("uci") end
	return M._uci
end

-- os.execute's success on Lua 5.1 (0) and 5.2+ (true).
local exec_ok = require("openwrt.util").exec_ok

local warned = false

M._cache = {}
local function cached(name, fn)
	local c, now = M._cache[name], M._time()
	if c and now - c.at < M.CACHE_TTL and now >= c.at then return c.v end
	local v = fn()
	M._cache[name] = {v = v, at = now}
	return v
end

function M.installed()
	return cached("installed", function() return M._read_file(M.INIT) ~= nil end)
end

-- The ssl build: libnetsnmp linked with OpenSSL, the only one with AES/DES
-- privacy. Read from apk's database (25.12 has no opkg).
function M.v3_capable()
	if not M.installed() then return false end
	return cached("v3", function()
		local db = "\n" .. (M._read_file(M.APK_DB) or "")
		return db:find("\nP:snmpd%-ssl\n") ~= nil or db:find("\nP:libnetsnmp%-ssl\n") ~= nil
	end)
end

-- A digest of everything the config below is built from, so an unchanged
-- push restarts nothing. Hashed: it is kept in state.json, and the
-- community and password must not be.
local function fingerprint(i)
	return require("unifi.crypto").sha256_hex(table.concat({
		tostring(i.v1v2c), tostring(i.v3), i.community or "", i.user or "",
		i.password or "", i.location or "", i.contact or "",
	}, "\1"))
end
local UNUSABLE = "unusable"

-- net-snmp's createUser (and OpenWrt's init script, which skips the user
-- otherwise) wants both the SHA and the AES passphrase 8 characters or
-- longer; openUF uses the controller's one password for both.
local function v3_pass_ok(p)
	return type(p) == "string" and #p >= 8 and #p <= 64
end

local function write_config(cursor, i)
	local names = {}
	cursor:foreach("snmpd", nil, function(s) names[#names + 1] = s[".name"] end)
	for _, n in ipairs(names) do cursor:delete("snmpd", n) end
	local function sec(name, stype, opts)
		cursor:set("snmpd", name, stype)
		for k, v in pairs(opts) do cursor:set("snmpd", name, k, v) end
	end
	if not i then
		-- Nothing usable: a config that answers nobody, and says off.
		sec("general", "snmpd", {enabled = "0"})
		cursor:commit("snmpd")
		return
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

-- Take /etc/config/snmpd over: keep the device's file (once) and whether
-- snmpd was enabled. false when the copy cannot be made -- then nothing is
-- touched.
local function take_over(st)
	if st.snmp_owned then return true end
	if not M._read_file(M.BACKUP) then
		local orig = M._read_file(M.CONFIG)
		if orig and not M._write_file(M.BACKUP, orig, true) then
			io.stderr:write("openuf: SNMP: cannot keep a copy of " .. M.CONFIG
				.. " in " .. M.BACKUP .. " -- not taking snmpd over\n")
			return false
		end
	end
	st.snmp_was_enabled = exec_ok(M._exec(M.INIT .. " enabled >/dev/null 2>&1"))
	st.snmp_owned = true
	return true
end

local function restore(st)
	local orig = M._read_file(M.BACKUP)
	if orig and M._write_file(M.CONFIG, orig) then
		os.remove(M.BACKUP)
	else
		local cursor = get_uci().cursor()
		cursor:set("snmpd", "general", "snmpd")
		cursor:set("snmpd", "general", "enabled", "0")
		cursor:commit("snmpd")
	end
	if M.installed() then
		if st.snmp_was_enabled == false then
			M._exec(M.INIT .. " stop >/dev/null 2>&1")
			M._exec(M.INIT .. " disable >/dev/null 2>&1")
		else
			M._exec(M.INIT .. " restart >/dev/null 2>&1")
		end
	end
	st.snmp_owned, st.snmp_applied, st.snmp_was_enabled = nil, nil, nil
	io.stderr:write("openuf: SNMP off -- snmpd config restored\n")
end

-- Apply one parsed intent. st carries the ledger (snmp_owned, snmp_applied,
-- snmp_was_enabled). full: the push was a full system_cfg, the only kind
-- whose missing snmp block means "off". Returns true when snmpd was
-- (re)configured, disabled or restored.
---@param intent SnmpIntent?
---@param st table
---@param full boolean?
function M.apply(intent, st, full)
	if type(intent) ~= "table" then return false end
	if not intent.enabled then
		if not st.snmp_owned or not full then return false end
		restore(st)
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
	end
	if i.v3 and not v3_pass_ok(i.password) then
		io.stderr:write("openuf: SNMPv3 password must be 8 to 64 characters (SHA and AES) "
			.. "-- v3 user not configured\n")
		i.v3 = false
	end
	if not i.v1v2c and not i.v3 then
		if st.snmp_owned and st.snmp_applied == UNUSABLE then return false end
		if not take_over(st) then return false end
		write_config(get_uci().cursor(), nil)
		M._exec(M.INIT .. " stop >/dev/null 2>&1")
		M._exec(M.INIT .. " disable >/dev/null 2>&1")
		st.snmp_applied = UNUSABLE
		io.stderr:write("openuf: the controller has SNMP Monitoring on, but nothing in it is "
			.. "usable here -- snmpd stopped and disabled rather than left on its stock config\n")
		return true
	end
	local fp = fingerprint(i)
	if st.snmp_owned and st.snmp_applied == fp then return false end
	if not take_over(st) then return false end
	write_config(get_uci().cursor(), i)
	M._exec(M.INIT .. " enable >/dev/null 2>&1")
	M._exec(M.INIT .. " restart >/dev/null 2>&1")
	st.snmp_applied = fp
	return true
end

return M
