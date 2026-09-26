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
