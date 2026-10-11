--[[
	Hotspot 2.0 / Passpoint: the parsed aaa.<n>.hs20.* block
	(unifi/hotspot2.parse) as hostapd BSS config lines.

	They go out through `list hostapd_bss_options`, the raw lines OpenWrt's
	ap.uc appends after everything it generates itself. Its own hs20/iw_*
	options are not used: iface_interworking() in 25.12 overwrites
	domain_name with the 3GPP list whenever anqp_3gpp_cell_net is set, and an
	array option is joined with spaces onto one line, where hostapd expects
	one line per venue name, realm or capability. Raw lines say exactly what
	hostapd reads. Every key below is hostapd's own (hostapd/config_file.c,
	hostapd.conf), and the build must have CONFIG_HS20 (`hostapd -vhs20`,
	which implies Interworking): sysinfo.hs20_supported gates the fw_caps
	0x800000 claim on it.

	Not carried: online sign-up (OSU providers and icons; hostapd dropped
	its OSU server support) and Terms and Conditions without a server URL
	(the push names no hs20_t_c_server_url, so only the filename and
	timestamp go out, as RADIUS attributes).
]]--

local M = {}

local function b(v) return v and "1" or "0" end

-- {"interworking=1", "hs20=1", ...} for one VAP, or {} when h is nil.
-- dgaf_disable: wireless.<n>.dgaf_disable, which the controller sends next
-- to the hs20 block's own disable_dgaf; either one disables it.
---@param h Hs20Intent?
---@param dgaf_disable boolean?
---@return string[]
function M.lines(h, dgaf_disable)
	local out = {}
	if type(h) ~= "table" then return out end
	local function add(k, v) if v ~= nil then out[#out + 1] = k .. "=" .. tostring(v) end end
	add("interworking", "1")
	add("hs20", "1")
	add("access_network_type", h.access_network_type)
	if h.internet ~= nil then add("internet", b(h.internet)) end
	if h.asra ~= nil then add("asra", b(h.asra)) end
	if h.esr ~= nil then add("esr", b(h.esr)) end
	if h.uesa ~= nil then add("uesa", b(h.uesa)) end
	add("venue_group", h.venue_group)
	add("venue_type", h.venue_type)
	add("hessid", h.hessid)
	if h.disable_dgaf or dgaf_disable then add("disable_dgaf", "1") end
	add("hs20_deauth_req_timeout", h.deauth_req_timeout)
	add("anqp_domain_id", h.anqp_domain_id)
	add("gas_comeback_delay", h.gas_comeback_delay)
	add("gas_frag_limit", h.gas_frag_limit)
	if h.network_availability then
		add("ipaddr_type_availability", string.format("%02x", h.network_availability))
	end
	if h.network_auth_type then
		-- One octet as hex, then the redirect URL for types 0 and 2.
		local url = (h.network_auth_type == 0 or h.network_auth_type == 2)
			and h.network_auth_url or ""
		add("network_auth_type", string.format("%02x", h.network_auth_type) .. url)
	end
	for _, v in ipairs(h.venue_names or {}) do add("venue_name", v.lang .. ":" .. v.name) end
	for _, v in ipairs(h.venue_urls or {}) do add("venue_url", v.idx .. ":" .. v.url) end
	add("domain_name", h.domain_names)
	for _, r in ipairs(h.nai_realms or {}) do
		add("nai_realm", r.encoding .. "," .. r.name .. (r.eap and ("," .. r.eap) or ""))
	end
	for _, oi in ipairs(h.roaming_consortiums or {}) do add("roaming_consortium", oi) end
	if h.cell_nets and #h.cell_nets > 0 then
		add("anqp_3gpp_cell_net", table.concat(h.cell_nets, ";"))
	end
	for _, f in ipairs(h.friendly_names or {}) do
		add("hs20_oper_friendly_name", f.lang .. ":" .. f.text)
	end
	for _, c in ipairs(h.conn_capabs or {}) do
		add("hs20_conn_capab", c.proto .. ":" .. c.port .. ":" .. c.status)
	end
	add("qos_map_set", h.qos_map_set)
	add("hs20_wan_metrics", h.wan_metrics)
	add("hs20_t_c_filename", h.t_c_filename)
	add("hs20_t_c_timestamp", h.t_c_timestamp)
	return out
end

return M
