-- Tests for src/hook/syswrapper.lua (set-adopt, set-inform, reset-inform).
-- Run from project root: lua tests/run_tests.lua

SYSWRAPPER_TEST_MODE = true

-- syswrapper.lua needs to find state.lua; load state first and inject it
local state = dofile("src/state.lua")

-- Redirect state to a temp file so tests don't touch /etc/openuf
state._state_file = "/tmp/openuf_test_sysw.json"

local sw = dofile("src/hook/syswrapper.lua")

-- Inject state module into syswrapper
sw._set_state(state)

-- Helper: reset the state file before each test
local function reset_state()
	os.remove("/tmp/openuf_test_sysw.json")
end

return {
	-- ── is_hex32 ──────────────────────────────────────────────────────────
	{
		name = "syswrapper: is_hex32 accepts valid 32-char hex",
		fn = function()
			assert_true(sw.is_hex32("ba86f2bbe107c7c57eb5f2690775c712"), "valid key")
			assert_true(sw.is_hex32("AABBCCDDEEFF00112233445566778899"), "uppercase")
		end
	},
	{
		name = "syswrapper: is_hex32 rejects wrong length",
		fn = function()
			assert_false(sw.is_hex32("ba86f2"),                              "too short")
			assert_false(sw.is_hex32("ba86f2bbe107c7c57eb5f2690775c712aa"), "too long")
			assert_false(sw.is_hex32(""),                                    "empty")
		end
	},
	{
		name = "syswrapper: is_hex32 rejects non-hex characters",
		fn = function()
			assert_false(sw.is_hex32("zz86f2bbe107c7c57eb5f2690775c712"), "non-hex z")
			assert_false(sw.is_hex32("ba86f2bbe107c7c57eb5f26907_5c712"), "underscore")
		end
	},
	-- ── is_url ────────────────────────────────────────────────────────────
	{
		name = "syswrapper: is_url accepts http and https",
		fn = function()
			assert_true(sw.is_url("http://192.168.1.1:8080/inform"),  "http")
			assert_true(sw.is_url("https://unifi.example.com/inform"), "https")
		end
	},
	{
		name = "syswrapper: is_url rejects bare hostname and other schemes",
		fn = function()
			assert_false(sw.is_url("192.168.1.1:8080/inform"), "no scheme")
			assert_false(sw.is_url("ftp://host/path"),         "ftp scheme")
			assert_false(sw.is_url(""),                        "empty")
		end
	},
	-- ── set-adopt ─────────────────────────────────────────────────────────
	{
		name = "syswrapper: set-adopt stores authkey and sets adopted=true",
		fn = function()
			reset_state()
			local key = "deadbeefdeadbeefdeadbeefdeadbeef"
			local url = "http://10.0.0.1:8080/inform"
			assert_true(sw.cmd_set_adopt(url, key), "set-adopt succeeds")
			local st = state.load()
			assert_true(st.adopted,          "adopted is true")
			assert_eq(st.authkey, key,       "authkey stored")
			assert_eq(st.inform_url, url,    "inform_url stored")
		end
	},
	{
		name = "syswrapper: set-adopt normalises authkey to lowercase",
		fn = function()
			reset_state()
			local key_upper = "DEADBEEFDEADBEEFDEADBEEFDEADBEEF"
			sw.cmd_set_adopt("http://10.0.0.1:8080/inform", key_upper)
			local st = state.load()
			assert_eq(st.authkey, key_upper:lower(), "authkey lowercased")
		end
	},
	{
		name = "syswrapper: set-adopt rejects invalid authkey",
		fn = function()
			reset_state()
			assert_false(sw.cmd_set_adopt("http://10.0.0.1:8080/inform", "tooshort"), "short key rejected")
			assert_false(sw.cmd_set_adopt("http://10.0.0.1:8080/inform", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"), "non-hex rejected")
		end
	},
	{
		name = "syswrapper: set-adopt rejects invalid URL",
		fn = function()
			reset_state()
			local key = "deadbeefdeadbeefdeadbeefdeadbeef"
			assert_false(sw.cmd_set_adopt("10.0.0.1:8080/inform", key), "no scheme rejected")
		end
	},
	-- ── set-inform ────────────────────────────────────────────────────────
	{
		name = "syswrapper: set-inform updates inform_url without touching authkey",
		fn = function()
			reset_state()
			-- Pre-set a custom authkey via adopt
			sw.cmd_set_adopt("http://old:8080/inform", "deadbeefdeadbeefdeadbeefdeadbeef")
			local key_before = state.load().authkey

			sw.cmd_set_inform("http://new-controller:8080/inform")
			local st = state.load()
			assert_eq(st.inform_url, "http://new-controller:8080/inform", "url updated")
			assert_eq(st.authkey, key_before, "authkey unchanged by set-inform")
		end
	},
	{
		name = "syswrapper: set-inform rejects invalid URL",
		fn = function()
			assert_false(sw.cmd_set_inform("not-a-url"), "rejected")
		end
	},
	-- ── reset-inform ──────────────────────────────────────────────────────
	{
		name = "syswrapper: reset-inform sets adopted=false and clears authkey",
		fn = function()
			reset_state()
			-- First adopt
			sw.cmd_set_adopt("http://10.0.0.1:8080/inform", "deadbeefdeadbeefdeadbeefdeadbeef")
			assert_true(state.load().adopted, "sanity: adopted before reset")

			sw.cmd_reset_inform()
			local st = state.load()
			assert_false(st.adopted,                        "adopted is false after reset")
			assert_eq(st.authkey, state.DEFAULT_KEY,        "authkey reset to default")
		end
	},
	{
		name = "syswrapper: the state_file option is honoured, so all three processes agree",
		fn = function()
			-- inform.lua and announce.lua move state.json when the option is
			-- set; the hook must look in the same place or an SSH set-adopt
			-- writes a file the daemon never reads.
			local conf = dofile("src/config.lua")
			local orig = conf._cursor
			package.loaded["uci"] = {cursor = function()
				return {get_all = function() return {state_file = "/srv/openuf/state.json"} end}
			end}
			local got = sw._conf_state_file("src/")
			package.loaded["uci"] = {cursor = function()
				return {get_all = function() return nil end}
			end}
			local default = sw._conf_state_file("src/")
			package.loaded["uci"] = nil
			conf._cursor = orig
			assert_eq(got, "/srv/openuf/state.json", "the option is read")
			assert_eq(default, "/etc/openuf/state.json", "unset: the default path")
			assert_nil(sw._conf_state_file("/nonexistent-dir-openuf/"),
				"no config.lua beside the hook is not an error either")
		end
	},
	{
		name = "syswrapper: 11k-scan leaves a dated request for the daemon",
		fn = function()
			local file = "/tmp/openuf_test_11k_request"
			sw._scan_request_file(file)
			local real = io.stdout
			io.stdout = {write = function() end}
			local ok = sw.cmd_11k_scan()
			io.stdout = real
			assert_true(ok, "written")
			local f = io.open(file, "r"); local raw = f:read("*a"); f:close()
			os.remove(file)
			assert_true(math.abs(tonumber(raw:match("%d+")) - os.time()) <= 2, "dated now")
		end
	},
	{
		name = "syswrapper: reprovision clears cfgversion so the controller re-sends its config",
		fn = function()
			reset_state()
			local s = state.load()
			s.adopted, s.cfgversion, s.cfgversion_effective = true, "abc123", "abc123"
			state.save(s)
			local real = io.stdout
			io.stdout = {write = function() end}
			sw.cmd_reprovision()
			io.stdout = real
			local after = state.load()
			assert_eq(after.cfgversion, "", "cleared")
			assert_eq(after.adopted, true, "adoption untouched")
			assert_eq(after.cfgversion_effective, "abc123", "the applied record untouched")
		end
	},
	{
		name = "adopt-shell: accepts 10.6's /usr/bin form and a matching MAC, refuses the rest",
		fn = function()
			local dir = "/tmp/openuf_test_adoptshell_" .. tostring(os.time())
			os.execute("mkdir -p " .. dir)
			local f = io.open(dir .. "/sw", "w")
			f:write("#!/bin/sh\necho RAN \"$@\"\n")
			f:close()
			os.execute("chmod +x " .. dir .. "/sw")
			f = io.open(dir .. "/state.json", "w")
			f:write('{"mac":"00:00:5e:00:53:3e","adopted":false}')
			f:close()
			local key = string.rep("ab", 16)
			local function run(cmd)
				local h = io.popen("OPENUF_SYSWRAPPER=" .. dir .. "/sw OPENUF_STATE=" .. dir
					.. "/state.json sh src/hook/adopt-shell.sh -c '" .. cmd .. "' 2>&1")
				local out = h:read("*a")
				h:close()
				return out
			end
			local url = "http://10.0.0.1:8080/inform"
			assert_true(run("syswrapper.sh set-adopt " .. url .. " " .. key):find("RAN set%-adopt") ~= nil,
				"bare form")
			assert_true(run("/usr/bin/syswrapper.sh set-adopt " .. url .. " " .. key):find("RAN set%-adopt") ~= nil,
				"10.6 absolute path")
			assert_true(run("/usr/bin/syswrapper.sh set-adopt " .. url .. " " .. key .. " 00:00:5E:00:53:3E")
				:find("RAN set%-adopt " .. url .. " " .. key .. "\n", 1, true) == nil
				and run("/usr/bin/syswrapper.sh set-adopt " .. url .. " " .. key .. " 00:00:5E:00:53:3E")
				:find("RAN set-adopt", 1, true) ~= nil, "own MAC, any case; not passed on")
			assert_true(run("/usr/bin/syswrapper.sh set-adopt " .. url .. " " .. key .. " 00:11:22:33:44:55")
				:find("not this device", 1, true) ~= nil, "another device's MAC refused")
			assert_true(run("/bin/sh -c id"):find("not permitted", 1, true) ~= nil, "other commands refused")
			assert_true(run("syswrapper.sh set-adopt " .. url .. " " .. key .. "; id")
				:find("RAN", 1, true) == nil, "no command chaining")
			os.execute("rm -rf " .. dir)
		end
	},

}
