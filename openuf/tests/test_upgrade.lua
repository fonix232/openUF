-- Tests for src/openwrt/upgrade.lua (OpenWrt upgrades through UniFi's upgrade flow).
-- Run from project root: lua tests/run_tests.lua

local upgrade = dofile("src/openwrt/upgrade.lua")

-- Real `owut check` output from an E8450 on SNAPSHOT (2026-09-25).
local CHECK_NEWER = [[
ASU-Server     https://sysupgrade.openwrt.org
Target         mediatek/mt7622
Profile        linksys_e8450-ubi (linksys,e8450-ubi)
Version-from   SNAPSHOT r36162-ac2ed40b48 (kernel 6.18.44)
Version-to     SNAPSHOT r36556-ad1b1f2d36 (kernel 6.18.52)
88 packages are out-of-date
It is safe to proceed with an upgrade (re-run with '--verbose' for details)
]]

local function with_release(rev, fn)
	local orig = upgrade._read_file
	upgrade._read_file = function(p)
		if p == upgrade.RELEASE_FILE then return "DISTRIB_REVISION='r" .. rev .. "-ac2ed40b48'\n" end
		return orig(p)
	end
	local ok, err = pcall(fn)
	upgrade._read_file = orig
	if not ok then error(err, 0) end
end

return {
	{
		name = "upgrade: static scheme reports the ufmodel version untouched",
		fn = function()
			with_release(36162, function()
				assert_eq(upgrade.version("6.8.2.15592", {}), "6.8.2.15592", "default")
			end)
		end
	},
	{
		name = "upgrade: openwrt scheme puts the OpenWrt revision in the build field (opt-in only)",
		fn = function()
			with_release(36162, function()
				assert_eq(upgrade.version("6.8.2.15592", {version_scheme = "openwrt"}),
					"6.8.2.36162", "revision as build")
				assert_eq(upgrade.version("6.8.2.15592", {upgrade_mode = "owut"}),
					"6.8.2.15592", "owut mode alone keeps the catalogue string (no permanent badge)")
			end)
		end
	},
	{
		name = "upgrade: a learned catalogue version replaces the built-in one",
		fn = function()
			with_release(36162, function()
				assert_eq(upgrade.version("6.8.2.15592", {}, "6.8.3.16001"), "6.8.3.16001", "learned")
				assert_eq(upgrade.version("6.8.2.15592", {}, "unknown"), "6.8.2.15592", "garbage ignored")
			end)
		end
	},
	{
		name = "upgrade: an available update is advertised one step below the catalogue",
		fn = function()
			with_release(36162, function()
				upgrade.update_available = true
				assert_eq(upgrade.version("6.8.2.15592", {upgrade_mode = "owut", advertise_updates = true}),
					"6.8.1.36162", "patch - 1")
				assert_eq(upgrade.version("6.8.0.15592", {upgrade_mode = "owut", advertise_updates = true}),
					"6.7.99.36162", "borrow")
				upgrade.update_available = false
				assert_eq(upgrade.version("6.8.2.15592", {upgrade_mode = "owut", advertise_updates = true}),
					"6.8.2.15592", "nothing to install: the catalogue string again")
			end)
		end
	},
	{
		name = "upgrade: required_version holds the badge off unless owut has a build",
		fn = function()
			local owut = {upgrade_mode = "owut", advertise_updates = true}
			upgrade.update_available = false
			assert_eq(upgrade.required_version("6.0.0", {}), upgrade.HOLD_VERSION, "default: held")
			assert_eq(upgrade.required_version("6.0.0", nil), upgrade.HOLD_VERSION, "no config: held")
			assert_eq(upgrade.required_version("6.0.0", owut), upgrade.HOLD_VERSION, "owut: nothing newer")
			upgrade.update_available = true
			assert_eq(upgrade.required_version("6.0.0", owut), "6.0.0", "owut build: let through")
			assert_eq(upgrade.required_version("6.0.0", {upgrade_mode = "owut"}), upgrade.HOLD_VERSION,
				"a stale result without advertise_updates stays held")
			upgrade.update_available = false
		end
	},
	{
		-- The controller's own rule (10.6.106, CFR): upgradable when the
		-- catalogue differs from `version` and compare(catalogue, required)
		-- is not -1, comparing dotted integers left to right.
		name = "upgrade: the payload pair satisfies the controller's upgradable rule as intended",
		fn = function()
			local function cmp(a, b)
				local x, y = {}, {}
				for n in a:gmatch("%d+") do x[#x + 1] = tonumber(n) end
				for n in b:gmatch("%d+") do y[#y + 1] = tonumber(n) end
				for i = 1, math.min(#x, #y) do
					if x[i] < y[i] then return -1 elseif x[i] > y[i] then return 1 end
				end
				return 0
			end
			local function upgradable(catalogue, conf)
				local v = upgrade.version("6.8.2.15592", conf)
				return catalogue ~= v and cmp(catalogue, upgrade.required_version("6.0.0", conf)) ~= -1
			end
			local owut = {upgrade_mode = "owut", advertise_updates = true}
			with_release(36162, function()
				upgrade.update_available = false
				assert_false(upgradable("8.8.14.20179", {}), "a newer Ubiquiti release: no badge")
				assert_false(upgradable("8.8.14.20179", owut), "owut on, nothing newer: no badge")
				upgrade.update_available = true
				assert_true(upgradable("8.8.14.20179", owut), "owut build: badge")
				assert_true(upgradable("6.8.2.15592", owut), "owut build, same catalogue: badge")
				upgrade.update_available = false
			end)
		end
	},
	{
		name = "upgrade: a check whose owut printed nothing still finishes",
		fn = function()
			local orig_read, orig_exec, orig_running = upgrade._read_file, upgrade._exec, upgrade._running
			local conf = {advertise_updates = true, advertise_interval = 30}
			upgrade._exec = function() end
			upgrade._running = function() return false end
			upgrade._next_check, upgrade._check_started, upgrade.update_available = 0, nil, true
			upgrade.tick(1000, conf)
			assert_eq(upgrade._check_started, 1000, "check started")
			upgrade._read_file = function(p)
				if p == upgrade.CHECK_FILE then return "__done__\n" end
				return orig_read(p)
			end
			upgrade.tick(1010, conf)
			assert_nil(upgrade._check_started, "finished")
			assert_false(upgrade.update_available, "nothing to install")
			upgrade.tick(1031, conf)
			assert_eq(upgrade._check_started, 1031, "the next check runs on schedule")
			upgrade._read_file, upgrade._exec, upgrade._running = orig_read, orig_exec, orig_running
			upgrade._next_check, upgrade._check_started, upgrade.update_available = 0, nil, false
		end
	},
	{
		name = "upgrade: parse_check reads owut's verdict",
		fn = function()
			assert_true(upgrade.parse_check(CHECK_NEWER), "newer SNAPSHOT build, safe")
			assert_false(upgrade.parse_check(CHECK_NEWER:gsub("r36556", "r36162")), "same build")
			assert_false(upgrade.parse_check(CHECK_NEWER:gsub("It is safe to proceed[^\n]*", "ERROR")),
				"not safe")
			assert_true(upgrade.parse_check(CHECK_NEWER:gsub("Version%-to     SNAPSHOT", "Version-to     25.12.5")),
				"a different release")
		end
	},
	{
		name = "upgrade: start refuses without owut mode, owut or the bootstrap",
		fn = function()
			local orig_exists, orig_exec, orig_running = upgrade._exists, upgrade._exec, upgrade._running
			local ran = nil
			upgrade._exec = function(c) ran = c end
			upgrade._running = function() return false end
			upgrade._exists = function() return true end
			assert_false((upgrade.start({})), "not in owut mode")
			upgrade._exists = function(p) return p ~= upgrade.BOOTSTRAP end
			local ok, why = upgrade.start({upgrade_mode = "owut"})
			assert_false(ok, "no bootstrap")
			assert_true(why:find("bootstrap", 1, true) ~= nil, "says why")
			upgrade._exists = function() return true end
			assert_true((upgrade.start({upgrade_mode = "owut"})), "starts")
			assert_true(ran and ran:find("owut upgrade", 1, true) ~= nil, "owut upgrade launched")
			upgrade._exists, upgrade._exec, upgrade._running = orig_exists, orig_exec, orig_running
		end
	},
	{
		name = "upgrade: owut leaves openUF's own installed packages out of the ASU build",
		fn = function()
			local orig = upgrade._installed
			upgrade._installed = function(p) return p == "openuf" end
			assert_eq(upgrade.owut_args(), " --remove openuf", "only what is installed")
			upgrade._installed = function() return true end
			assert_eq(upgrade.owut_args(), " --remove openuf,luci-app-openuf", "both, comma-separated")
			upgrade._installed = function() return false end
			assert_eq(upgrade.owut_args(), "", "nothing to remove on a tarball install")
			upgrade._installed = orig
		end
	},
}
