-- Tests for src/config.lua (settings from UCI /etc/config/openuf).
-- Run from the package directory: lua tests/run_tests.lua

local config = dofile("src/config.lua")

-- A cursor over one `main` section.
local function cursor(main)
	return {get_all = function(_, pkg, sec)
		if pkg == "openuf" and sec == "main" then return main end
		return nil
	end}
end

local function quietly(fn)
	local warned = {}
	local orig = config._warn
	config._warn = function(m) warned[#warned + 1] = m end
	local ok, err = pcall(fn)
	config._warn = orig
	if not ok then error(err, 0) end
	return warned
end

return {
	{
		name = "config: an empty section is a working configuration of defaults",
		fn = function()
			local c = config.options({})
			assert_eq(c.inform_url, "http://unifi:8080/inform", "inform URL")
			assert_eq(c.use_only_unifi_wlan, true, "controller WLANs only")
			assert_eq(c.rrm_enrichment, true, "802.11k reports")
			assert_eq(c.controller_system, true, "all three system parts")
			assert_eq(c.stun_local_port, 3478, "ints are numbers")
			assert_eq(c.upgrade_mode, nil, "unset strings stay nil")
			assert_eq(c.unhandled_file, "/etc/openuf/unhandled.json", "ledger file")
			assert_nil(c.bootstrap_adopt_user, "no SSH adoption account")
			assert_nil(c.debug_caps, "research tables only come from local.lua")
		end
	},
	{
		name = "config: UCI values are typed; a bad one falls back to the default, loudly",
		fn = function()
			local c
			local warned = quietly(function()
				c = config.options({l2guard = "0", sta_events = "off", stun = "yes",
					bridge_rollback_timeout = "60", stun_local_port = "abc",
					own_config = "maybe", country_override = "", upgrade_mode = "owut"})
			end)
			assert_eq(c.l2guard, false, "0")
			assert_eq(c.sta_events, false, "off")
			assert_eq(c.stun, true, "yes")
			assert_eq(c.bridge_rollback_timeout, 60, "number")
			assert_eq(c.stun_local_port, 3478, "not a number: default")
			assert_eq(c.own_config, true, "not a boolean: default")
			assert_nil(c.country_override, "empty string is unset")
			assert_eq(c.upgrade_mode, "owut", "string")
			assert_eq(#warned, 2, "the two bad values are reported")
		end
	},
	{
		name = "config: the three system options build sysconf's controller_system gate",
		fn = function()
			assert_eq(config.options({system_ntp = "0", system_timezone = "0", system_cron = "0"})
				.controller_system, false, "none")
			local g = config.options({system_ntp = "0"}).controller_system
			assert_eq(type(g), "table", "some")
			assert_eq(g.timezone, true, "timezone on")
			assert_eq(g.ntp, false, "ntp off")
			assert_eq(g.cron, true, "cron on")
			local sysconf = dofile("src/openwrt/sysconf.lua")
			assert_false(sysconf.enabled(g, "ntp"), "sysconf reads the gate as meant")
			assert_true(sysconf.enabled(g, "cron"), "and the other parts stay on")
		end
	},
	{
		name = "config: unhandled_file off keeps the ledger in memory; ssh_adopt names the account",
		fn = function()
			assert_eq(config.options({unhandled_file = "off"}).unhandled_file, false, "off")
			assert_eq(config.options({unhandled_file = "/tmp/u.json"}).unhandled_file, "/tmp/u.json", "path")
			assert_eq(config.options({ssh_adopt = "1"}).bootstrap_adopt_user, "ubnt", "ubnt/ubnt")
		end
	},
	{
		name = "config: load returns the board description and the options, and local.lua may change either",
		fn = function()
			local orig = {config._exists, config._dofile, config._describe}
			local loaded = {}
			config._exists = function(p) return p == config.LOCAL_FILE end
			config._describe = function()
				loaded[#loaded + 1] = "board"
				return {conf = {net = {}}, openuf = {uap = {ufmodel = "auto"}}}
			end
			config._dofile = function(p)
				loaded[#loaded + 1] = p
				_G.config.debug_caps = {fw_caps = 1}
				_G.dev.tweaked = true
			end
			local before = rawget(_G, "config")
			local dev, c = config.load(cursor({l2guard = "0"}))
			config._exists, config._dofile, config._describe = orig[1], orig[2], orig[3]
			assert_eq(loaded[1], "board", "the board first")
			assert_eq(loaded[2], config.LOCAL_FILE, "then local.lua")
			assert_eq(c.l2guard, false, "UCI applied")
			assert_eq(c.debug_caps.fw_caps, 1, "local.lua set a research table")
			assert_true(dev.tweaked, "and could reach the model map")
			assert_eq(rawget(_G, "config"), before, "globals put back")
		end
	},
	{
		name = "config: get reads one option without a model map",
		fn = function()
			assert_eq(config.get("state_file", cursor({state_file = "/srv/state.json"})),
				"/srv/state.json", "set")
			assert_eq(config.get("state_file", cursor(nil)), "/etc/openuf/state.json", "no section")
			assert_nil(config.get("no_such_option", cursor({})), "unknown")
		end
	},
}
