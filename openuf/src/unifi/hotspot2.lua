--[[
	hotspot2.lua -- Hotspot 2.0 / Passpoint out of a WLAN's aaa.<n> block: the
	controller's side. The device side, hostapd's lines, is
	openwrt/hotspot2.lua. Called by unifi/wlan.lua for an Enterprise WLAN.
]]--

local wire = require("unifi.wire")

local M = {}

-- Hotspot 2.0 / Passpoint out of one aaa.<n> block (keys without the prefix).
-- Decompiled from 10.6.106 (VAZShipWTNxlo's hs20 helpers), not yet seen on the
-- wire. Sent only for an Enterprise WLAN, and only to a device claiming
-- fw_caps 0x800000 -- without it such a WLAN is dropped from the push. Every
-- Enterprise WLAN without Hotspot 2.0 carries aaa.<n>.hs20.status=disabled.
-- With it:
--
--   hs20.status=enabled
--   hs20.access_network_type=<0..15>  hs20.internet / asra / esr / uesa=enabled|disabled
--   hs20.venue_group / venue_type=<n> hs20.disable_dgaf=enabled|disabled
--   hs20.deauth_req_timeout=<s>       hs20.t_c_filename / t_c_timestamp
--   hs20.gas_comeback_delay / gas_frag_limit (only with gas_advanced)
--   hs20.network_availability=<(v4 << 2) + v6>
--   hs20.network_auth_type=<n> + hs20.network_auth_url
--   hs20.anqp_domain_id=<n>           hs20.hessid=<MAC>
--   hs20.venue_name.<k>.lang / .name / .url
--   hs20.hs20_domain_name_list=<a,b,...>
--   hs20.nai_realm.<k>.status / .encoding / .name / .eap_method
--   hs20.nai_realm.<k>.eap_method.auth.<j>.id / .val
--   hs20.<k>.roaming_consortium=<OI hex>
--   hs20.3gpp.<k>.mcc / .mnc
--   hs20.friendly_name.<k>.language / .text
--   hs20.capab.<k>.protocol / .port / .status   (protocol as an IP number)
--   hs20.qos.status=enabled + hs20.qos.exception.<k>.dcsp/.up + hs20.qos.map.<k>.low/.high
--   hs20.metrics.status=enabled + .info / .downlink_speed / .uplink_speed /
--     .downlink_load / .uplink_load / .measurement
--   hs20.icon.<k>.*, osu.<k>.*, hs20.osu_ssid   (online sign-up: not carried)
--
-- Everything ends up on a hostapd config line (openwrt/hotspot2.lua), so each
-- value is checked for its shape here and a bad one is dropped with a log line.
-- Returns nil unless hs20.status=enabled.
---@param a table<string,string>
---@param ssid string?
---@return Hs20Intent?
function M.parse(a, ssid)
	if type(a) ~= "table" or a["hs20.status"] ~= "enabled" then return nil end
	local function warn(what)
		io.stderr:write(("inform: WLAN %q: Hotspot 2.0 %s ignored\n"):format(tostring(ssid), what))
	end
	local function int(k, lo, hi)
		local raw = a["hs20." .. k]
		local v = tonumber(raw)
		if v and v == math.floor(v) and v >= lo and v <= hi then return v end
		if raw ~= nil and raw ~= "" then warn(k) end
		return nil
	end
	local function txt(v, max)
		return type(v) == "string" and #v >= 1 and #v <= (max or 252)
			and v:match("^[%w%p ]+$") ~= nil
	end
	local function url_ok(v)
		return type(v) == "string" and #v <= 250 and v:match("^https?://[%w%p]+$") ~= nil
	end
	local function sorted_idx(pattern)
		local out = {}
		for k in pairs(a) do
			local i = k:match(pattern)
			if i then out[#out + 1] = tonumber(i) end
		end
		table.sort(out)
		return out
	end
	local h = {
		access_network_type  = int("access_network_type", 0, 15),
		internet             = wire.bool(a["hs20.internet"]),
		asra                 = wire.bool(a["hs20.asra"]),
		esr                  = wire.bool(a["hs20.esr"]),
		uesa                 = wire.bool(a["hs20.uesa"]),
		venue_group          = int("venue_group", 0, 255),
		venue_type           = int("venue_type", 0, 255),
		disable_dgaf         = wire.bool(a["hs20.disable_dgaf"]),
		deauth_req_timeout   = int("deauth_req_timeout", 0, 65535),
		gas_comeback_delay   = int("gas_comeback_delay", 1, 65535),
		gas_frag_limit       = int("gas_frag_limit", 1, 65535),
		network_availability = int("network_availability", 0, 255),
		network_auth_type    = int("network_auth_type", 0, 3),
		anqp_domain_id       = int("anqp_domain_id", 0, 65535),
	}
	local nurl = a["hs20.network_auth_url"]
	if h.network_auth_type and nurl and nurl ~= "" then
		if url_ok(nurl) then h.network_auth_url = nurl else warn("network_auth_url") end
	end
	local tcf, tct = a["hs20.t_c_filename"], a["hs20.t_c_timestamp"]
	if tcf and tcf ~= "" then
		if tcf:match("^[%w%._%-]+$") and #tcf <= 255 then h.t_c_filename = tcf
		else warn("t_c_filename") end
	end
	if tct and tct ~= "" then
		if tct:match("^%d+$") and #tct <= 10 then h.t_c_timestamp = tonumber(tct)
		else warn("t_c_timestamp") end
	end
	local hessid = a["hs20.hessid"]
	if hessid and hessid ~= "" then
		if wire.is_mac(hessid) then h.hessid = hessid:lower() else warn("hessid") end
	end
	local dl = a["hs20.hs20_domain_name_list"]
	if dl and dl ~= "" then
		if dl:match("^[%w%.%-,]+$") and #dl <= 255 then h.domain_names = dl
		else warn("domain name list") end
	end
	h.venue_names, h.venue_urls = {}, {}
	for _, k in ipairs(sorted_idx("^hs20%.venue_name%.(%d+)%.name$")) do
		local p = "hs20.venue_name." .. k .. "."
		local lang, name, vurl = a[p .. "lang"] or "eng", a[p .. "name"], a[p .. "url"]
		if lang:match("^%a%a%a?$") and txt(name, 252) then
			h.venue_names[#h.venue_names + 1] = {lang = lang, name = name}
			if vurl and vurl ~= "" then
				if url_ok(vurl) then
					h.venue_urls[#h.venue_urls + 1] = {idx = #h.venue_names, url = vurl}
				else warn("venue URL " .. k) end
			end
		else warn("venue name " .. k) end
	end
	h.nai_realms = {}
	for _, k in ipairs(sorted_idx("^hs20%.nai_realm%.(%d+)%.name$")) do
		local p = "hs20.nai_realm." .. k .. "."
		if a[p .. "status"] ~= "disabled" then
			local enc, name, eap = a[p .. "encoding"] or "0", a[p .. "name"], a[p .. "eap_method"]
			local ok = (enc == "0" or enc == "1") and type(name) == "string"
				and name:match("^[%w%.%-;]+$") ~= nil and #name <= 200
			local method
			if ok and eap and eap ~= "" then
				ok = eap:match("^%d%d?%d?$") ~= nil
				method = eap
				for _, j in ipairs(sorted_idx("^hs20%.nai_realm%." .. k .. "%.eap_method%.auth%.(%d+)%.id$")) do
					local id = a[p .. "eap_method.auth." .. j .. ".id"]
					local val = a[p .. "eap_method.auth." .. j .. ".val"]
					if id and val and id:match("^%d%d?%d?$") and val:match("^%d%d?%d?$") then
						method = method .. "[" .. id .. ":" .. val .. "]"
					else ok = false end
				end
			end
			if ok then
				h.nai_realms[#h.nai_realms + 1] = {encoding = tonumber(enc), name = name, eap = method}
			else warn("NAI realm " .. k) end
		end
	end
	h.roaming_consortiums = {}
	for _, k in ipairs(sorted_idx("^hs20%.(%d+)%.roaming_consortium$")) do
		local oi = a["hs20." .. k .. ".roaming_consortium"]
		-- An OI is 3 to 15 octets, written as hex.
		if oi and oi:match("^%x+$") and #oi % 2 == 0 and #oi >= 6 and #oi <= 30 then
			h.roaming_consortiums[#h.roaming_consortiums + 1] = oi:lower()
		else warn("roaming consortium " .. k) end
	end
	h.cell_nets = {}
	for _, k in ipairs(sorted_idx("^hs20%.3gpp%.(%d+)%.mcc$")) do
		local mcc, mnc = a["hs20.3gpp." .. k .. ".mcc"], a["hs20.3gpp." .. k .. ".mnc"]
		if mcc and mnc and mcc:match("^%d%d%d$") and mnc:match("^%d%d%d?$") then
			h.cell_nets[#h.cell_nets + 1] = mcc .. "," .. mnc
		else warn("3GPP network " .. k) end
	end
	h.friendly_names = {}
	for _, k in ipairs(sorted_idx("^hs20%.friendly_name%.(%d+)%.text$")) do
		local lang = a["hs20.friendly_name." .. k .. ".language"] or "eng"
		local t = a["hs20.friendly_name." .. k .. ".text"]
		if lang:match("^%a%a%a?$") and txt(t, 252) then
			h.friendly_names[#h.friendly_names + 1] = {lang = lang, text = t}
		else warn("operator friendly name " .. k) end
	end
	h.conn_capabs = {}
	local cstatus = {closed = 0, open = 1, unknown = 2}
	for _, k in ipairs(sorted_idx("^hs20%.capab%.(%d+)%.protocol$")) do
		local p = "hs20.capab." .. k .. "."
		local proto, port = tonumber(a[p .. "protocol"]), tonumber(a[p .. "port"])
		local st = cstatus[a[p .. "status"] or ""] or tonumber(a[p .. "status"])
		if proto and proto >= 0 and proto <= 255 and port and port >= 0 and port <= 65535
				and st and st >= 0 and st <= 2 then
			h.conn_capabs[#h.conn_capabs + 1] = {proto = proto, port = port, status = st}
		else warn("connection capability " .. k) end
	end
	if wire.bool(a["hs20.qos.status"]) then
		-- A whole number in [lo, hi]: "6.5", "-1" and "0x10" are not.
		local function n_in(v, lo, hi)
			local n = type(v) == "string" and v:match("^%d+$") and tonumber(v) or nil
			return (n and n >= lo and n <= hi) and n or nil
		end
		local ex, ranges, bad = {}, {}, false
		for _, k in ipairs(sorted_idx("^hs20%.qos%.exception%.(%d+)%.dcsp$")) do
			-- An exception: one DSCP value (0-63) to one user priority (0-7).
			local d = n_in(a["hs20.qos.exception." .. k .. ".dcsp"], 0, 63)
			local u = n_in(a["hs20.qos.exception." .. k .. ".up"], 0, 7)
			if d and u then ex[#ex + 1] = d .. "," .. u else bad = true end
		end
		for _, k in ipairs(sorted_idx("^hs20%.qos%.map%.(%d+)%.low$")) do
			-- A range of DSCP values (0-63, low <= high) for one user
			-- priority, or 255,255 for a priority no DSCP maps to.
			local lo = n_in(a["hs20.qos.map." .. k .. ".low"], 0, 255)
			local hi = n_in(a["hs20.qos.map." .. k .. ".high"], 0, 255)
			if lo and hi and ((lo == 255 and hi == 255) or (lo <= 63 and hi <= 63 and lo <= hi)) then
				ranges[#ranges + 1] = lo .. "," .. hi
			else
				bad = true
			end
		end
		-- hostapd takes up to 21 exceptions and exactly eight ranges (UP 0..7),
		-- and refuses the line -- and with it the BSS -- for a value out of
		-- range, so one bad entry drops the map.
		if not bad and #ranges == 8 and #ex <= 21 then
			local all = {}
			for _, e in ipairs(ex) do all[#all + 1] = e end
			for _, r in ipairs(ranges) do all[#all + 1] = r end
			h.qos_map_set = table.concat(all, ",")
		else
			warn(("QoS map (%d ranges, %d exceptions)"):format(#ranges, #ex))
		end
	end
	if wire.bool(a["hs20.metrics.status"]) then
		local info = int("metrics.info", 0, 15)
		local ds = int("metrics.downlink_speed", 0, 4294967295)
		local us = int("metrics.uplink_speed", 0, 4294967295)
		local dload, uload = int("metrics.downlink_load", 0, 255), int("metrics.uplink_load", 0, 255)
		local lmd = int("metrics.measurement", 0, 65535)
		if info and ds and us and dload and uload and lmd then
			-- %.0f, not %d: a kbps speed can exceed a 32-bit C long on MIPS.
			h.wan_metrics = string.format("%02x:%.0f:%.0f:%d:%d:%d", info, ds, us, dload, uload, lmd)
		end
	end
	for k in pairs(a) do
		if k:match("^hs20%.icon%.") or k:match("^osu%.") then h.osu_dropped = true end
	end
	if h.osu_dropped then warn("online sign-up (OSU providers, icons)") end
	return h
end

return M
