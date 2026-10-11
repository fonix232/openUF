-- Tests for src/config.lua (settings: board description < UCI < local.json).
-- Run from the package directory: lua tests/run_tests.lua

local config = dofile("src/config.lua")
local cjson = require("cjson")

-- A cursor over a whole package: get_all(pkg) is every section by name,
-- get_all(pkg, sec) one of them. `main` alone may be given as a flat table.
local function cursor(main, others)
	local all = {}
	if main then
		all.main = main
		main[".type"] = main[".type"] or "openuf"
	end
	for name, s in pairs(others or {}) do all[name] = s end
	return {get_all = function(_, pkg, sec)
		if pkg ~= "openuf" then return nil end
		if sec == nil then return all end
		return all[sec]
	end}
end

local function sec(stype, opts)
	local s = {[".type"] = stype}
	for k, v in pairs(opts or {}) do s[k] = v end
	return s
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

local function any_match(list, pat)
	for _, m in ipairs(list) do if m:find(pat) then return true end end
	return false
end

-- load() with the board description, local.json and local.lua stubbed.
-- files: {json = text or nil, lua = fn or nil}. Returns dev, config, warnings.
local function load_with(c, files, board)
	local orig = {config._exists, config._read, config._dofile, config._describe}
	files = files or {}
	config._exists = function(p)
		if p == config.JSON_FILE then return files.json ~= nil end
		if p == config.LOCAL_FILE then return files.lua ~= nil end
		return false
	end
	config._read = function(p) if p == config.JSON_FILE then return files.json end end
	config._dofile = function(p) if p == config.LOCAL_FILE then files.lua() end end
	config._describe = function()
		return board or {conf = {net = {lan_cpueth = "eth1", ports = {{idx = 1, ifname = "lan1"},
			{idx = 5, ifname = "eth1"}}}, led = "green:status"}, identity = {model = "U6IW"}}
	end
	local dev, conf
	local warned = quietly(function() dev, conf = config.load(c) end)
	config._exists, config._read, config._dofile, config._describe = orig[1], orig[2], orig[3], orig[4]
	return dev, conf, warned
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
			assert_nil(c.debug_caps, "no research overrides by default")
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
		name = "config: get reads one option without the board description",
		fn = function()
			assert_eq(config.get("state_file", cursor({state_file = "/srv/state.json"})),
				"/srv/state.json", "set")
			assert_eq(config.get("state_file", cursor(nil)), "/etc/openuf/state.json", "no section")
			assert_nil(config.get("no_such_option", cursor({})), "unknown")
		end
	},
	{
		name = "config: get sees local.json over UCI, so the hooks agree with the daemon",
		fn = function()
			local orig = {config._exists, config._read}
			config._exists = function(p) return p == config.JSON_FILE end
			config._read = function() return '{"config": {"state_file": "/srv/j.json", "inform_url": null}}' end
			local sf = config.get("state_file", cursor({state_file = "/srv/uci.json"}))
			local url = config.get("inform_url", cursor({inform_url = "http://x:8080/inform"}))
			config._exists, config._read = orig[1], orig[2]
			assert_eq(sf, "/srv/j.json", "local.json wins")
			assert_eq(url, "http://unifi:8080/inform", "null: the built-in default")
		end
	},

	-- ── UCI sections ────────────────────────────────────────────────────────
	{
		name = "config: sections are recognised by type and fixed name; others are ignored, loudly",
		fn = function()
			local secs
			local warned = quietly(function()
				secs = config.classify({
					main     = sec("openuf", {l2guard = "0"}),
					other    = sec("openuf", {l2guard = "1"}),
					board    = sec("board", {led = "x"}),
					na       = sec("radio_policy", {htmode_max = "HE80"}),
					ng       = sec("radio_policy"),
					cfg0a1b2c = sec("radio_policy", {htmode_max = "HE40"}),
					n_a      = sec("radio_policy", {htmode_max = "HE40"}),
					debug    = sec("debug"),
					wifi     = sec("wifi-iface"),
				})
			end)
			assert_eq(secs.main.l2guard, "0", "openuf 'main' is the options")
			assert_eq(secs.board.led, "x", "board 'board'")
			assert_not_nil(secs.policies.na, "radio_policy 'na'")
			assert_not_nil(secs.policies.ng, "radio_policy 'ng'")
			assert_nil(secs.policies.cfg0a1b2c, "an anonymous policy has no band")
			assert_nil(secs.policies.n_a, "nor a misnamed one")
			assert_true(any_match(warned, "'other'"), "a second openuf section is reported")
			assert_true(any_match(warned, "'cfg0a1b2c'"), "the anonymous policy is reported")
			assert_true(any_match(warned, "'n_a'"), "the misnamed policy is reported")
			assert_true(any_match(warned, "unknown section type"), "an unknown type is reported")
			assert_eq(#warned, 4, "and nothing else")
		end
	},
	{
		name = "config: a radio_policy section is typed; a bad value is dropped, loudly",
		fn = function()
			local p
			local warned = quietly(function()
				p = config.policy({[".type"] = "radio_policy", htmode_max = "HE80",
					htmode_floor = "HT80", acs_exclude_dfs = "1", channel = {"36", "149"}}, "na")
			end)
			assert_eq(p.htmode_max, "HE80", "an htmode")
			assert_nil(p.htmode_floor, "there is no HT80")
			assert_eq(p.acs_exclude_dfs, true, "a boolean")
			assert_eq(p.channels[1], 36, "the UCI list `channel` becomes channels, numbers")
			assert_eq(p.channels[2], 149, "in order")
			assert_eq(#warned, 1, "the bad htmode is reported")

			quietly(function()
				p = config.policy({acs_exclude_dfs = "0", channel = "36 40"}, "na")
			end)
			assert_eq(p.acs_exclude_dfs, false, "false is a value, not absence")
			assert_eq(#p.channels, 2, "an option of words reads as a list")

			for _, bad in ipairs({"he80", "HE90", "HE", "80", "VHT320x"}) do
				quietly(function() p = config.policy({htmode_max = bad}, "na") end)
				assert_nil(p, bad .. " is not an htmode, and the section sets nothing")
			end
			warned = quietly(function()
				p = config.policy({channel = {"36", "40a"}, acs_exclude_dfs = "maybe"}, "na")
			end)
			assert_nil(p, "one bad channel drops the whole list; a bad boolean is absent")
			assert_eq(#warned, 2, "both reported")
			quietly(function() p = config.policy({channel = {"0"}}, "na") end)
			assert_nil(p, "channel 0 is not a channel")
			quietly(function() p = config.policy({channel = {"234"}}, "na") end)
			assert_nil(p, "nor is 234")
		end
	},
	{
		name = "config: an empty radio_policy section is no policy at all",
		fn = function()
			-- rf_config treats a present entry, even an empty one, as the band's
			-- owner of acs_exclude_dfs and channels and tears down the
			-- controller's. The shipped config has both sections empty.
			local p
			local warned = quietly(function() p = config.policy({[".type"] = "radio_policy",
				[".name"] = "na", [".anonymous"] = false}, "na") end)
			assert_nil(p, "nothing set: no entry")
			assert_eq(#warned, 0, "the .meta keys are not options")
			local dev = {conf = {}}
			quietly(function() config.from_uci({na = sec("radio_policy"), ng = sec("radio_policy")}, dev) end)
			assert_nil(dev.conf.radio, "no dev.conf.radio from two empty sections")
		end
	},
	{
		name = "config: unknown options are reported in every section",
		fn = function()
			local warned = quietly(function()
				config.from_uci({main = sec("openuf", {l2gaurd = "0"}),
					board = sec("board", {leds = "x"}),
					na = sec("radio_policy", {channels = {"36"}}),
					debug = sec("debug", {fw_cap = "1"})}, {conf = {}})
			end)
			assert_true(any_match(warned, "main: unknown option 'l2gaurd'"), "main")
			assert_true(any_match(warned, "board: unknown option 'leds'"), "board")
			assert_true(any_match(warned, "radio_policy.na: unknown option 'channels'"),
				"radio_policy: the UCI name is the singular list `channel`")
			assert_true(any_match(warned, "debug: unknown option 'fw_cap'"), "debug")
		end
	},
	{
		name = "config: the board section corrects the LED and the radios reported",
		fn = function()
			local b
			quietly(function() b = config.board({led = "green:status", hwassign = {"radio0", "radio_2"}}) end)
			assert_eq(b.led, "green:status", "led")
			assert_eq(b.hwassign[2], "radio_2", "hwassign is a list")
			local warned = quietly(function() b = config.board({led = "../../x", hwassign = {"radio-0"}}) end)
			assert_nil(b.led, "a path is not an LED name")
			assert_nil(b.hwassign, "a name UCI cannot hold is not a wifi-device")
			assert_eq(#warned, 2, "both reported")
			quietly(function() b = config.board({hwassign = "radio0 radio1"}) end)
			assert_eq(#b.hwassign, 2, "an option of words reads as a list")
		end
	},
	{
		name = "config: the debug section's caps take decimal or 0x hex",
		fn = function()
			local d
			quietly(function() d = config.debug_caps({fw_caps = "0x110", wifi_caps = "12", wifi_caps2 = "0X40"}) end)
			assert_eq(d.fw_caps, 0x110, "hex")
			assert_eq(d.wifi_caps, 12, "decimal")
			assert_eq(d.wifi_caps2, 0x40, "upper-case X")
			local warned = quietly(function() d = config.debug_caps({fw_caps = "abc", wifi_caps = "-1"}) end)
			assert_nil(d, "nothing valid: no debug_caps at all")
			assert_eq(#warned, 2, "both reported")
			assert_nil(config.debug_caps({}), "an empty section claims nothing")
		end
	},
	{
		name = "config: load layers UCI over the board description",
		fn = function()
			local dev, c = load_with(cursor({l2guard = "0"}, {
				board = sec("board", {led = "blue:power", hwassign = {"radio1"}}),
				na = sec("radio_policy", {htmode_max = "HE80", channel = {"36", "40"}}),
				debug = sec("debug", {fw_caps = "0x10"}),
			}))
			assert_eq(c.l2guard, false, "an option")
			assert_eq(c.debug_caps.fw_caps, 16, "the debug caps")
			assert_eq(dev.conf.led, "blue:power", "UCI's LED over the board's")
			assert_eq(dev.conf.hwassign[1], "radio1", "hwassign")
			assert_eq(dev.conf.radio.na.htmode_max, "HE80", "the policy")
			assert_nil(dev.conf.radio.ng, "only the band that set something")
			assert_eq(dev.conf.net.lan_cpueth, "eth1", "the rest of the board description stays")
			local dev2 = load_with(cursor({}, {board = sec("board")}))
			assert_eq(dev2.conf.led, "green:status", "an empty board section keeps the board's LED")
		end
	},

	-- ── local.json ──────────────────────────────────────────────────────────
	{
		name = "config: local.json deep-merges over UCI: board < UCI < local.json",
		fn = function()
			local json = [[{
				"config": {"l2guard": true, "stun_local_port": 4000, "inform_url": null,
				           "debug_payload_extra": {"uplink": {"type": "wireless"}}},
				"dev": {"conf": {
					"led": "white:status",
					"radio": {"na": {"htmode_max": "HE40", "acs_exclude_dfs": null},
					          "ng": {"htmode_floor": "HE20"}},
					"net": {"lan_cpueth": "wan", "ports": [{"idx": 5, "ifname": "wan"}]}
				}, "identity": {"model_display": "Bench AP"}}
			}]]
			local dev, c, warned = load_with(cursor({l2guard = "0", inform_url = "http://u:8080/inform"}, {
				board = sec("board", {led = "blue:power"}),
				na = sec("radio_policy", {htmode_max = "HE80", acs_exclude_dfs = "1", channel = {"36"}}),
			}), {json = json})
			assert_eq(#warned, 0, "a valid file is applied silently")
			assert_eq(c.l2guard, true, "local.json over UCI")
			assert_eq(c.stun_local_port, 4000, "an int")
			assert_eq(c.inform_url, "http://unifi:8080/inform", "null: back to the built-in default")
			assert_eq(c.debug_payload_extra.uplink.type, "wireless", "an arbitrary table")
			assert_eq(dev.conf.led, "white:status", "local.json over UCI over the board")
			assert_eq(dev.conf.radio.na.htmode_max, "HE40", "a policy key replaced")
			assert_nil(dev.conf.radio.na.acs_exclude_dfs, "null removes a key")
			assert_eq(dev.conf.radio.na.channels[1], 36, "untouched keys stay (deep merge)")
			assert_eq(dev.conf.radio.ng.htmode_floor, "HE20", "a band added")
			assert_eq(dev.conf.net.lan_cpueth, "wan", "a net field")
			assert_eq(#dev.conf.net.ports, 1, "an array replaces, never merges")
			assert_eq(dev.identity.model_display, "Bench AP", "identity merged")
			assert_eq(dev.identity.model, "U6IW", "keeping the rest")
		end
	},
	{
		name = "config: local.json is applied before the derived fields",
		fn = function()
			local _, c = load_with(cursor({}), {json = '{"config": {"system_ntp": false, "ssh_adopt": true, "unhandled_file": "off"}}'})
			assert_eq(type(c.controller_system), "table", "the system gate sees local.json")
			assert_false(c.controller_system.ntp, "ntp off")
			assert_eq(c.bootstrap_adopt_user, "ubnt", "ssh_adopt names the account")
			assert_eq(c.unhandled_file, false, "off")
		end
	},
	{
		name = "config: a local.json that does not parse is ignored entirely, loudly",
		fn = function()
			local dev, c, warned = load_with(cursor({l2guard = "0"}),
				{json = '{"config": {"l2guard": true}, "dev": {"conf": {"led": "x"}}'})
			assert_eq(c.l2guard, false, "UCI stands")
			assert_eq(dev.conf.led, "green:status", "nothing of it applied")
			assert_true(any_match(warned, "REJECTED"), "said loudly")
			assert_true(any_match(warned, "not valid JSON"), "with the reason")
			-- ({"config": []} is an empty object to cjson, so an empty patch.)
			for _, text in ipairs({"", "[]", "42", '"x"', '{"config": null}'}) do
				local _, c2, w2 = load_with(cursor({l2guard = "0"}), {json = text})
				assert_eq(c2.l2guard, false, "rejected: " .. text)
				assert_true(any_match(w2, "REJECTED"), "and said so: " .. text)
			end
		end
	},
	{
		name = "config: a type error anywhere rejects the whole file; nothing is half-applied",
		fn = function()
			local cases = {
				'{"config": {"l2guard": "0"}}',                       -- a string for a bool
				'{"config": {"stun_local_port": 3478.5}}',            -- not whole
				'{"config": {"inform_url": 1}}',
				'{"config": {"debug_caps": {"fw_caps": "0x10"}}}',    -- JSON caps are numbers
				'{"config": {"debug_payload_extra": [1]}}',
				'{"dev": {"conf": {"led": "../x"}}}',
				'{"dev": {"conf": {"hwassign": ["radio-0"]}}}',
				'{"dev": {"conf": {"hwassign": "radio0"}}}',
				'{"dev": {"conf": {"radio": {"na": {"htmode_max": "HE90"}}}}}',
				'{"dev": {"conf": {"radio": {"na": {"channels": ["36"]}}}}}',
				'{"dev": {"conf": {"radio": {"na": {"acs_exclude_dfs": 1}}}}}',
				'{"dev": {"conf": {"net": {"ports": [{"idx": "1", "ifname": "lan1"}]}}}}',
				'{"dev": {"conf": {"net": null}}}',
				'{"dev": {"identity": null}}',
			}
			for _, body in ipairs(cases) do
				-- Each case also carries a valid change, which must not land.
				local text = body:gsub("^{", '{"config": {"l2guard": true}, ', 1)
				if body:find('^{"config"') then
					text = body:gsub('^{"config": {', '{"config": {"own_config": false, ', 1)
				end
				local dev, c, warned = load_with(cursor({l2guard = "0"}), {json = text})
				assert_eq(c.l2guard, false, "rejected whole: " .. text)
				assert_eq(c.own_config, true, "rejected whole: " .. text)
				assert_eq(dev.conf.led, "green:status", "rejected whole: " .. text)
				assert_true(any_match(warned, "REJECTED"), "said so: " .. text)
			end
		end
	},
	{
		name = "config: unknown keys in local.json are reported and dropped, the rest applies",
		fn = function()
			local dev, c, warned = load_with(cursor({}), {json = [[{
				"config": {"l2guard": false, "l2gaurd": true, "controller_system": false},
				"dev": {"conf": {"led": "x:y", "config": {}, "radio": {"ac": {}}}, "ports": []},
				"modelmap": "auto"
			}]]})
			assert_eq(c.l2guard, false, "the known key applies")
			assert_nil(c.l2gaurd, "the typo does not")
			assert_eq(c.controller_system, true, "derived fields are not settable")
			assert_eq(dev.conf.led, "x:y", "dev applies")
			assert_nil(dev.ports, "an unknown dev key is dropped")
			assert_nil(dev.conf.radio and dev.conf.radio.ac, "an unknown band is dropped")
			assert_true(any_match(warned, "local.json.modelmap: unknown key"), "top level reported")
			assert_true(any_match(warned, "local.json.config.l2gaurd: unknown key"), "config reported")
			assert_true(any_match(warned, "local.json.dev.conf.config: unknown key"),
				"the options are not reachable through dev.conf")
			assert_true(any_match(warned, "local.json.dev.conf.radio.ac: unknown key"), "band reported")
			assert_false(any_match(warned, "REJECTED"), "not a rejection")
		end
	},
	{
		name = "config: an empty JSON array replaces; an empty object merges",
		fn = function()
			local dev = load_with(cursor({}, {board = sec("board", {hwassign = {"radio0"}})}),
				{json = '{"dev": {"conf": {"hwassign": []}}}'})
			assert_eq(#dev.conf.hwassign, 0, "[] clears the list (every radio reported)")
			local dev2 = load_with(cursor({}, {na = sec("radio_policy", {htmode_max = "HE80"})}),
				{json = '{"dev": {"conf": {"radio": {"na": {}}}}}'})
			assert_eq(dev2.conf.radio.na.htmode_max, "HE80", "{} changes nothing")
			local dev3 = load_with(cursor({}, {na = sec("radio_policy", {htmode_max = "HE80"})}),
				{json = '{"dev": {"conf": {"radio": null}}}'})
			assert_nil(dev3.conf.radio, "null removes every policy")
			local dev4 = load_with(cursor({}, {na = sec("radio_policy", {htmode_max = "HE80"})}),
				{json = '{"dev": {"conf": {"radio": {"na": {"htmode_max": null}, "ng": {}}}}}'})
			assert_nil(dev4.conf.radio.na, "a band left with no keys has no policy")
			assert_nil(dev4.conf.radio.ng, "nor does one given an empty object")
		end
	},
	{
		name = "config: an empty array where the schema has one replaces, though cjson cannot mark it",
		fn = function()
			-- OpenWrt's lua-cjson 2.1.0 decodes [] and {} to the same empty
			-- table; the validator knows hwassign and channels are arrays.
			local patch = config.check_json('{"dev": {"conf": {"hwassign": [ ], '
				.. '"radio": {"na": {"channels": [\n], "htmode_max": "HE80"}}}}}')
			assert_not_nil(patch, "accepted")
			local dev = {conf = {hwassign = {"radio0"}, radio = {na = {channels = {36, 40}}}}}
			config.merge_patch(dev, patch.dev)
			assert_eq(#dev.conf.hwassign, 0, "[] replaced the list")
			assert_eq(#dev.conf.radio.na.channels, 0, "an inner [] too")
			assert_eq(dev.conf.radio.na.htmode_max, "HE80", "its sibling merged")
			assert_not_nil(config.check_json('{"dev": {"conf": {"hwassign": {}}}}'),
				"{} where an array belongs: indistinguishable from [], taken as one")
			assert_nil(config.check_json('{"dev": {"conf": {"hwassign": {"a": 1}}}}'), "a real object is not")
			local t = config._decode('{"c": "x[]y"}')
			assert_eq(t.c, "x[]y", "[] inside a string is text")
		end
	},
	{
		name = "config: get decodes local.json once per content, not once per option",
		fn = function()
			local orig = {config._exists, config._read, config.read_json}
			local reads = 0
			local text = '{"config": {"state_file": "/srv/j.json"}}'
			config._get_memo = nil
			config._exists = function(p) return p == config.JSON_FILE end
			config._read = function() return text end
			config.read_json = function(p) reads = reads + 1; return orig[3](p) end
			config.get("state_file", cursor({}))
			config.get("inform_url", cursor({}))
			local after_two = reads
			text = '{"config": {"state_file": "/srv/k.json"}}'
			local sf = config.get("state_file", cursor({}))
			config._exists, config._read, config.read_json = orig[1], orig[2], orig[3]
			config._get_memo = nil
			assert_eq(after_two, 1, "two options, one decode")
			assert_eq(sf, "/srv/k.json", "a changed file is read again")
			assert_eq(reads, 2, "once more")
		end
	},
	{
		name = "config: merge_patch follows RFC 7396",
		fn = function()
			local N = config.NULL
			local t = config.merge_patch({a = "b", c = {d = "e", f = "g"}}, {a = "z", c = {f = N}})
			assert_eq(t.a, "z", "replace")
			assert_eq(t.c.d, "e", "deep keep")
			assert_nil(t.c.f, "null removes")
			t = config.merge_patch({a = {1, 2}}, {a = {3}})
			assert_eq(#t.a, 1, "arrays replace")
			t = config.merge_patch({a = "x"}, {a = {b = "c"}})
			assert_eq(t.a.b, "c", "an object over a scalar starts from {}")
			t = config.merge_patch({a = {b = "c"}}, {a = "x"})
			assert_eq(t.a, "x", "a scalar over an object replaces it")
		end
	},
	{
		name = "config: local.json changes a copy of the identity, never the catalogue's table",
		fn = function()
			local shared = {model = "U6IW", model_display = "U6 In-Wall"}
			local dev = load_with(cursor({}), {json = '{"dev": {"identity": {"model_display": "X"}}}'},
				{conf = {net = {}}, identity = shared})
			assert_eq(dev.identity.model_display, "X", "changed")
			assert_eq(shared.model_display, "U6 In-Wall", "the catalogue entry is not")
		end
	},

	-- ── local.lua, deprecated ───────────────────────────────────────────────
	{
		name = "config: local.lua still runs, last and with a deprecation warning",
		fn = function()
			local seen_json
			local before = rawget(_G, "config")
			local dev, c, warned = load_with(cursor({l2guard = "0"}), {
				json = '{"config": {"stun_local_port": 4000}}',
				lua = function()
					seen_json = _G.config.stun_local_port
					_G.config.stun_local_port = 5000
					_G.config.debug_caps = {fw_caps = 1}
					_G.dev.tweaked = true
				end,
			})
			assert_eq(seen_json, 4000, "it sees local.json's result")
			assert_eq(c.stun_local_port, 5000, "and wins over it, as it always won")
			assert_eq(c.l2guard, false, "UCI applied")
			assert_eq(c.debug_caps.fw_caps, 1, "it can still set a research table")
			assert_true(dev.tweaked, "and reach the board description")
			assert_true(any_match(warned, "local%.lua is DEPRECATED"), "the warning")
			assert_eq(rawget(_G, "config"), before, "globals put back")
			local _, _, quiet = load_with(cursor({}), {})
			assert_false(any_match(quiet, "DEPRECATED"), "no local.lua: no warning")
		end
	},
	{
		name = "config: a local.lua that errors is reported and the layers below it stand",
		fn = function()
			local _, c, warned = load_with(cursor({l2guard = "0"}), {lua = function() error("boom") end})
			assert_eq(c.l2guard, false, "UCI stands")
			assert_true(any_match(warned, "boom"), "the error is logged")
		end
	},

	-- ── The shipped config ──────────────────────────────────────────────────
	{
		name = "config: the shipped /etc/config/openuf sets nothing but the defaults, silently",
		fn = function()
			-- A small reader for the UCI file format (config/option/list lines).
			local f = assert(io.open("files/openuf.config", "r"))
			local all, cur = {}, nil
			for line in f:lines() do
				local t, n = line:match("^config%s+(%S+)%s+'([^']*)'")
				local ok, ov = line:match("^%s+option%s+(%S+)%s+'([^']*)'")
				local lk, lv = line:match("^%s+list%s+(%S+)%s+'([^']*)'")
				if t then
					assert_true(n:match("^[%w_]+$") ~= nil, "a valid section name: " .. n)
					cur = {[".type"] = t, [".name"] = n}
					all[n] = cur
				elseif ok then cur[ok] = ov
				elseif lk then cur[lk] = cur[lk] or {}; table.insert(cur[lk], lv) end
			end
			f:close()
			for _, s in ipairs({"main", "board", "ng", "na", "debug"}) do
				assert_not_nil(all[s], "ships section " .. s)
			end
			local dev = {conf = {led = "board:led"}}
			local c
			local warned = quietly(function() c = config.from_uci(all, dev) end)
			assert_eq(#warned, 0, "no warnings")
			assert_eq(c.inform_url, "http://unifi:8080/inform", "default inform URL")
			assert_nil(c.debug_caps, "no caps claimed")
			assert_nil(dev.conf.radio, "no radio policy")
			assert_nil(dev.conf.hwassign, "every radio")
			assert_eq(dev.conf.led, "board:led", "the board's LED")
		end
	},
	{
		name = "config: uci-defaults adds each shipped section where absent, and only there",
		fn = function()
			local ud = assert(io.open("files/openuf.uci-defaults", "r"))
			local src = ud:read("*a")
			ud:close()
			local list = src:match("for s in ([^;]+); do")
			assert_not_nil(list, "the section loop")
			local want = {main = "openuf", board = "board", ng = "radio_policy", na = "radio_policy",
				debug = "debug"}
			local n = 0
			for name, stype in list:gmatch("([%w_]+)=([%w_]+)") do
				assert_eq(want[name], stype, "section " .. name .. " has the type config.lua reads")
				n = n + 1
			end
			assert_eq(n, 5, "all five")
			assert_true(src:find('uci -q get "openuf.${s%%=*}" >/dev/null || ', 1, true) ~= nil,
				"only where absent")
			for _, b in ipairs(config.BANDS) do assert_eq(want[b], "radio_policy", "every band: " .. b) end
		end
	},
	{
		name = "config: a debug cap is a 32-bit mask; bit 31 is fine, 2^32 is not",
		fn = function()
			local d
			quietly(function() d = config.debug_caps({fw_caps = "0x80000000", wifi_caps = "0xffffffff"}) end)
			assert_eq(d.fw_caps, 2147483648, "bit 31")
			assert_eq(d.wifi_caps, 4294967295, "all 32 bits")
			local warned = quietly(function() d = config.debug_caps({fw_caps = "0x100000000"}) end)
			assert_nil(d, "33 bits refused")
			assert_eq(#warned, 1, "and reported")
		end
	},
}
