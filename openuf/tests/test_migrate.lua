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
			local o = migrate.options(legacy, modelmap)
			assert_eq(o.modelmap, "generic-dualband-ap", "model map kept")
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
		name = "migrate: research tables become local.lua, which Lua can load back",
		fn = function()
			local legacy = migrate.read(read("tests/fixtures/conf.lua.legacy"))
			local src = migrate.local_lua(legacy)
			assert_not_nil(src, "written")
			local env = {config = {}}
			local chunk = assert(loadstring(src))
			setfenv(chunk, env)
			chunk()
			assert_eq(env.config.debug_caps.fw_caps, 123, "number")
			assert_eq(env.config.debug_caps.wifi_caps, "x", "string")
			assert_nil(migrate.local_lua({}), "nothing to write")
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
			local lf = "/tmp/openuf_test_local.lua"
			os.remove(lf)
			local orig = migrate._config.LOCAL_FILE
			migrate._config.LOCAL_FILE = lf
			local keys = migrate.apply("tests/fixtures/conf.lua.legacy", cursor)
			migrate._config.LOCAL_FILE = orig
			assert_eq(set[".main"], "openuf", "section created")
			assert_eq(set.l2guard, "0", "option set")
			assert_true(committed, "committed")
			assert_true(#keys >= 6, "reported")
			local f = io.open(lf, "r")
			assert_not_nil(f, "local.lua written for the research table")
			assert_true(f:read("*a"):find("config.debug_caps", 1, true) ~= nil, "with debug_caps")
			f:close()
			os.remove(lf)
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
			assert_nil(o.modelmap, "auto is the default")
		end
	},
}
