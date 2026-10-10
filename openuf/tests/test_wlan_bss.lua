-- Tests for the per-WLAN BSS knobs: aaa.<n>.wpa.group_rekey, tdls_prohibit,
-- country_beacon, 11k.status, sae.groups.<i>.group and wireless.<n>.uapsd,
-- parsed by inform._parse_wifi_system_cfg (unifi/wlan.lua) and applied by
-- ucihelper.apply_config (openwrt/ucihelper.lua) into a recording mock UCI.
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true

local inform    = dofile("src/inform.lua")
local ucihelper = require("openwrt.ucihelper")

-- A minimal libuci stand-in: set/get/delete/foreach/commit, rejecting the
-- section names libuci would silently discard.
local function new_mock_uci()
	local db, order = {}, {}
	local cursor = {}
	function cursor:set(config, section, a, b)
		if not tostring(section):match("^[%w_]+$") then
			error("mock uci: invalid section name '" .. tostring(section) .. "'", 2)
		end
		db[config] = db[config] or {}
		order[config] = order[config] or {}
		if not db[config][section] then
			db[config][section] = {[".name"] = section}
			order[config][#order[config] + 1] = section
		end
		if b == nil then
			db[config][section][".type"] = a
		elseif type(b) == "table" then
			local list = {}
			for i, v in ipairs(b) do list[i] = tostring(v) end
			db[config][section][a] = list
		else
			db[config][section][a] = b
		end
	end
	function cursor:get(config, section, option)
		local s = db[config] and db[config][section]
		if option == nil then
			if s then return s[".type"] end
			return nil, "Entry not found"
		end
		local v = s and s[option]
		if v == nil then return nil, "Entry not found" end
		return v
	end
	function cursor:delete(config, section, option)
		if option ~= nil then
			if db[config] and db[config][section] then db[config][section][option] = nil end
			return
		end
		if db[config] then db[config][section] = nil end
		for i, name in ipairs(order[config] or {}) do
			if name == section then table.remove(order[config], i); break end
		end
	end
	function cursor:foreach(config, stype, fn)
		for _, name in ipairs(order[config] or {}) do
			local s = db[config][name]
			if s and s[".type"] == stype then fn(s) end
		end
	end
	function cursor:commit() end
	return {cursor = function() return cursor end}, db
end

local function with_uci(fn)
	local mock, db = new_mock_uci()
	local saved = {ucihelper._uci, ucihelper._popen, ucihelper._read_file,
		ucihelper._run_cmd, ucihelper._bcfilter, ucihelper._shaper}
	local real_stderr = io.stderr
	ucihelper._uci = mock
	ucihelper._popen = function() return "" end
	ucihelper._read_file = function() return nil end
	ucihelper._run_cmd = function() return true end
	ucihelper._bcfilter = {reconcile = function() end}
	ucihelper._shaper = {reconcile = function() end}
	ucihelper._phy_caps_cache = nil
	local log = {}
	io.stderr = {write = function(_, s) log[#log + 1] = s end}
	local c = mock.cursor()
	c:set("wireless", "radio0", "wifi-device")
	c:set("wireless", "radio0", "band", "2g")
	c:set("wireless", "radio1", "wifi-device")
	c:set("wireless", "radio1", "band", "5g")
	local ok, err = pcall(fn, db, c, log)
	io.stderr = real_stderr
	ucihelper._uci, ucihelper._popen, ucihelper._read_file,
		ucihelper._run_cmd, ucihelper._bcfilter, ucihelper._shaper =
		saved[1], saved[2], saved[3], saved[4], saved[5], saved[6]
	ucihelper._phy_caps_cache = nil
	if not ok then error(err, 2) end
end

-- Two WLANs, one per radio, in the generator's own order and vocabulary.
-- "corp" is WPA2/WPA3 with every knob turned away from its default, and its
-- SAE groups arrive out of index order; "iot" is WPA2 at the defaults.
local function cfg(over)
	over = over or {}
	local lines = {
		"radio.1.phyname=radio0", "radio.2.phyname=radio1",
		"aaa.1.ssid=corp", "aaa.1.devname=ath0", "aaa.1.wpa=2",
		"aaa.1.wpa.key.1.mgmt=SAE", "aaa.1.wpa.psk=hunter2222",
		"aaa.1.wpa3.support=enabled", "aaa.1.wpa3.transition=enabled",
		"aaa.1.wpa.group_rekey=" .. (over.rekey or "600"),
		"aaa.1.tdls_prohibit=enabled",
		"aaa.1.country_beacon=" .. (over.cb1 or "enabled"),
		"aaa.1.11k.status=enabled",
		"aaa.1.sae.groups.2.group=19", "aaa.1.sae.groups.1.group=20",
		"aaa.1.sae.has_groups=" .. (over.has_groups or "enabled"),
		"wireless.1.ssid=corp", "wireless.1.parent=radio1", "wireless.1.devname=ath0",
		"wireless.1.uapsd=enabled",
		"aaa.2.ssid=iot", "aaa.2.devname=ath1", "aaa.2.wpa=2",
		"aaa.2.wpa.key.1.mgmt=WPA-PSK", "aaa.2.wpa.psk=hunter2222",
		"aaa.2.wpa.group_rekey=3600",
		"aaa.2.tdls_prohibit=disabled",
		"aaa.2.country_beacon=" .. (over.cb2 or "disabled"),
		"aaa.2.11k.status=disabled",
		"wireless.2.ssid=iot", "wireless.2.parent=radio0", "wireless.2.devname=ath1",
		"wireless.2.uapsd=disabled",
	}
	if over.extra then lines[#lines + 1] = over.extra end
	return table.concat(lines, "\n") .. "\n"
end

local function apply(sys, opts)
	local radio_table, vap_table = inform._parse_wifi_system_cfg(sys)
	ucihelper.apply_config({radio_table = radio_table, vap_table = vap_table}, nil, opts)
	return radio_table, vap_table
end

-- Strip every key this feature reads from a system_cfg.
local function without_knobs(sys)
	return (sys:gsub("[^\n]*group_rekey[^\n]*\n", "")
		:gsub("[^\n]*tdls_prohibit[^\n]*\n", "")
		:gsub("[^\n]*country_beacon[^\n]*\n", "")
		:gsub("[^\n]*11k%.status[^\n]*\n", "")
		:gsub("[^\n]*sae%.[^\n]*\n", "")
		:gsub("[^\n]*uapsd[^\n]*\n", ""))
end

return {
	{
		name = "wlan bss: the six keys parse to typed fields, SAE groups in index order",
		fn = function()
			local _, vaps = inform._parse_wifi_system_cfg(cfg())
			local corp, iot = vaps[1], vaps[2]
			assert_eq(corp.ssid, "corp", "first vap")
			assert_eq(corp.group_rekey, 600, "group_rekey")
			assert_eq(corp.tdls_prohibit, true, "tdls_prohibit")
			assert_eq(corp.country_beacon, true, "country_beacon")
			assert_eq(corp.rrm_enabled, true, "11k.status")
			assert_eq(corp.uapsd, true, "uapsd")
			assert_eq(table.concat(corp.sae_groups, " "), "20 19", "groups.<i> order, not line order")
			assert_eq(iot.group_rekey, 3600, "default rekey")
			assert_eq(iot.tdls_prohibit, false, "explicit off")
			assert_eq(iot.country_beacon, false, "explicit off")
			assert_eq(iot.rrm_enabled, false, "explicit off")
			assert_eq(iot.uapsd, false, "explicit off")
			assert_nil(iot.sae_groups, "no SAE groups on a PSK WLAN")
		end
	},
	{
		name = "wlan bss: absent keys stay nil, and bad values are refused",
		fn = function()
			local _, vaps = inform._parse_wifi_system_cfg(without_knobs(cfg()))
			for _, f in ipairs({"group_rekey", "tdls_prohibit", "country_beacon",
					"rrm_enabled", "uapsd", "sae_groups"}) do
				assert_nil(vaps[1][f], f .. " absent")
			end
			local real = io.stderr
			io.stderr = {write = function() end}
			local _, bad = inform._parse_wifi_system_cfg(cfg({rekey = "86401",
				extra = "aaa.1.sae.groups.3.group=19;reboot"}))
			local _, nogroups = inform._parse_wifi_system_cfg(cfg({has_groups = "disabled"}))
			io.stderr = real
			assert_nil(bad[1].group_rekey, "rekey above the wlanconf maximum")
			assert_eq(table.concat(bad[1].sae_groups, " "), "20 19",
				"a group that is not a plain number never reaches a raw hostapd line")
			assert_nil(nogroups[1].sae_groups, "groups only with sae.has_groups=enabled")
		end
	},
	{
		name = "wlan bss: per-BSS knobs reach their wifi-iface options",
		fn = function()
			with_uci(function(db)
				apply(cfg())
				local corp = db.wireless.openuf_radio1_corp
				local iot  = db.wireless.openuf_radio0_iot
				assert_eq(corp.wpa_group_rekey, "600", "wpa_group_rekey")
				assert_eq(corp.tdls_prohibit, "1", "tdls_prohibit on")
				assert_eq(corp.uapsd, "1", "uapsd on")
				assert_eq(corp.ieee80211k, "1", "802.11k on")
				assert_eq(iot.wpa_group_rekey, "3600", "default rekey written")
				assert_eq(iot.tdls_prohibit, "0", "tdls_prohibit off")
				assert_eq(iot.uapsd, "0", "uapsd off")
				assert_eq(iot.ieee80211k, "0", "802.11k off")
				local raw = table.concat(corp.hostapd_bss_options or {}, "|")
				assert_contains(raw, "sae_groups=20 19", "SAE groups as a raw BSS line")
				assert_nil(iot.hostapd_bss_options, "no SAE line on a PSK WLAN")
				assert_nil(corp.sae_groups, "not a wifi-iface option")
			end)
		end
	},
	{
		name = "wlan bss: without the keys no option is written, OpenWrt's defaults stand",
		fn = function()
			with_uci(function(db)
				apply(without_knobs(cfg()))
				for _, sec in ipairs({"openuf_radio1_corp", "openuf_radio0_iot"}) do
					local s = db.wireless[sec]
					for _, o in ipairs({"wpa_group_rekey", "tdls_prohibit", "uapsd", "ieee80211k"}) do
						assert_nil(s[o], sec .. "." .. o)
					end
				end
				assert_nil(db.wireless.radio0.country_ie, "radio0 untouched")
				assert_nil(db.wireless.radio1.country_ie, "radio1 untouched")
			end)
		end
	},
	{
		name = "wlan bss: Band Steering still forces 802.11k on over a WLAN's own off",
		fn = function()
			with_uci(function(db)
				apply(cfg(), {band_steering_active = true})
				assert_eq(db.wireless.openuf_radio0_iot.ieee80211k, "1", "forced on")
				assert_eq(db.wireless.openuf_radio0_iot.rrm_neighbor_report, "1", "with reports")
			end)
		end
	},
	{
		name = "wlan bss: 802.11d off reaches a 2.4 GHz radio, is refused on 5 GHz with 802.11h on",
		fn = function()
			with_uci(function(db, _, log)
				apply(cfg({cb1 = "disabled", cb2 = "disabled"}))
				assert_eq(db.wireless.radio0.country_ie, "0", "2.4 GHz: off")
				assert_eq(db.wireless.radio0.openuf_country_ie, "none", "board had no value")
				assert_nil(db.wireless.radio1.country_ie,
					"5 GHz: hostapd refuses ieee80211h without ieee80211d")
				assert_contains(table.concat(log), "802.11h", "and says why")
			end)
		end
	},
	{
		name = "wlan bss: 802.11d off reaches a 5 GHz radio whose 802.11h is off",
		fn = function()
			with_uci(function(db, c)
				c:set("wireless", "radio1", "doth", "0")
				apply(cfg({cb1 = "disabled"}))
				assert_eq(db.wireless.radio1.country_ie, "0", "no 11h, so 11d may go")
			end)
		end
	},
	{
		name = "wlan bss: 802.11d folds per radio -- any WLAN on it switches it on",
		fn = function()
			with_uci(function(db)
				-- Both WLANs on radio0: one on, one off.
				local sys = cfg({cb1 = "enabled", cb2 = "disabled"})
					:gsub("wireless%.1%.parent=radio1", "wireless.1.parent=radio0")
				apply(sys)
				assert_eq(db.wireless.radio0.country_ie, "1", "on wins")
			end)
		end
	},
	{
		name = "wlan bss: the board's 802.11d comes back once no WLAN carries the key",
		fn = function()
			with_uci(function(db, c)
				c:set("wireless", "radio0", "country_ie", "1")
				apply(cfg({cb2 = "disabled"}))
				assert_eq(db.wireless.radio0.country_ie, "0", "controller's off")
				assert_eq(db.wireless.radio0.openuf_country_ie, "1", "board value kept")
				apply(cfg({cb2 = "enabled"}))
				assert_eq(db.wireless.radio0.openuf_country_ie, "1", "stamp not overwritten")
				apply(without_knobs(cfg()))
				assert_eq(db.wireless.radio0.country_ie, "1", "board value restored")
				assert_nil(db.wireless.radio0.openuf_country_ie, "stamp removed")
			end)
		end
	},
	{
		name = "wlan bss: an unset board 802.11d is deleted again, not left at the pushed value",
		fn = function()
			with_uci(function(db)
				apply(cfg({cb1 = "enabled"}))
				assert_eq(db.wireless.radio1.country_ie, "1", "pushed on")
				apply(without_knobs(cfg()))
				assert_nil(db.wireless.radio1.country_ie, "back to OpenWrt's default")
				assert_nil(db.wireless.radio1.openuf_country_ie, "stamp removed")
			end)
		end
	},
	{
		name = "wlan bss: a disabled WLAN does not vote on its radio's 802.11d",
		fn = function()
			with_uci(function(db)
				local sys = cfg({cb1 = "enabled", cb2 = "disabled"})
					:gsub("wireless%.1%.parent=radio1", "wireless.1.parent=radio0")
					.. "wireless.1.status=disabled\n"
				apply(sys)
				assert_eq(db.wireless.radio0.country_ie, "0", "only the live WLAN counts")
			end)
		end
	},
}
