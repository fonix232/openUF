-- Tests for src/migrate.lua (a tarball install's conf.lua into UCI).
-- Run from the package directory: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local migrate = dofile("src/migrate.lua")

local function read(p)
	local f = assert(io.open(p, "r"))
	local s = f:read("*a")
	f:close()
	return s
end

return {
	{
		name = "migrate: only what a legacy conf.lua changed from the defaults reaches UCI",
		fn = function()
			local legacy, modelmap = migrate.read(read("tests/fixtures/conf.lua.legacy"))
			assert_eq(modelmap, "generic-dualband-ap", "the model map it named")
			local err = io.stderr
			io.stderr = {write = function() end}
			local o = migrate.options(legacy, modelmap)
			io.stderr = err
			assert_nil(o.modelmap, "no model map option any more")
			assert_eq(o.l2guard, "0", "switched off")
			assert_eq(o.bridge_rollback_timeout, "60", "number")
			assert_eq(o.system_ntp, "0", "one system part off")
			assert_nil(o.system_timezone, "the others stay default")
			assert_eq(o.ssh_adopt, "1", "bootstrap account")
			assert_eq(o.rrm_enrichment, "0", "a missing line meant off for this one")
			assert_nil(o.use_only_unifi_wlan, "true, the default: not written")
			assert_nil(o.inform_url, "the shipped URL is the default")
			assert_nil(o.debug_caps, "tables do not go to UCI")
		end
	},
	{
		name = "migrate: research tables go to the debug section and local.json",
		fn = function()
			local legacy = migrate.read(read("tests/fixtures/conf.lua.legacy"))
			local dbg = migrate.debug_options(legacy)
			assert_eq(dbg.fw_caps, "0x7b", "a number becomes a debug option, in hex")
			assert_nil(dbg.wifi_caps, "a non-number was never claimed: dropped")
			local config = migrate._config
			local warn = config._warn
			config._warn = function() end
			local p = config.debug_caps(dbg)
			config._warn = warn
			assert_eq(p.fw_caps, 123, "and config.lua reads it back")
			assert_nil(migrate.local_json(legacy), "no debug_payload_extra: no local.json")
			local text = migrate.local_json({debug_payload_extra = {uplink = {type = "wireless"}}})
			assert_not_nil(text, "written")
			local patch = config.check_json(text)
			assert_not_nil(patch, "a local.json config.lua accepts")
			assert_eq(patch.config.debug_payload_extra.uplink.type, "wireless", "with the table")
		end
	},
	{
		name = "migrate: apply sets the options on openuf.main and commits",
		fn = function()
			local set, committed = {}, false
			local cursor = {
				get = function() return nil end,
				set = function(_, pkg, sec, k, v)
					if v == nil then set["." .. sec] = k else set[k] = v end
				end,
				commit = function(_, pkg) committed = (pkg == "openuf") end,
			}
			local err = io.stderr
			io.stderr = {write = function() end}
			local lf = "/tmp/openuf_test_local.json"
			os.remove(lf)
			local orig = migrate._config.JSON_FILE
			migrate._config.JSON_FILE = lf
			local keys = migrate.apply("tests/fixtures/conf.lua.legacy", cursor)
			migrate._config.JSON_FILE = orig
			io.stderr = err
			assert_eq(set[".main"], "openuf", "section created")
			assert_eq(set[".debug"], "debug", "debug section created")
			assert_eq(set.l2guard, "0", "option set")
			assert_eq(set.fw_caps, "0x7b", "research caps set")
			assert_true(committed, "committed")
			assert_true(#keys >= 5, "reported")
			assert_nil(io.open(lf, "r"), "no payload table: no local.json")
		end
	},
	{
		name = "migrate: a conf.lua that fails to run still yields its model map, and no options",
		fn = function()
			local legacy, mm = migrate.read('\ndev = dofile("modelmap/auto.lua")\nerror("boom")\n')
			assert_eq(mm, "auto", "model map from the text")
			local o = migrate.options(legacy, mm)
			assert_eq(o.rrm_enrichment, "0", "absent meant off")
			assert_eq(o.use_only_unifi_wlan, "0", "absent meant off")
			assert_nil(o.modelmap, "never written")
		end
	},
}
