-- Tests for src/openwrt/led.lua (the board's LEDs as the controller switches
-- them, and Locate).
-- Run from the package directory: lua tests/run_tests.lua

local led = dofile("src/openwrt/led.lua")

-- The settings a trigger creates when it is set, at the kernel's defaults.
local TRIGGER_DEFAULTS = {
	netdev = {device_name = "", link = "0", rx = "0", tx = "0", interval = "50"},
	timer  = {delay_on = "500", delay_off = "500"},
}

-- A /sys/class/leds that behaves like the kernel's for what led.lua does:
-- setting a trigger replaces its settings with that trigger's defaults,
-- removing one (trigger none) turns the LED off, and writing brightness 0
-- removes the trigger. `leds`: name -> {trigger, brightness, attrs}.
-- Returns the LED table (live) and the other files (baseline, tmp).
local function sysfs(leds)
	local files = {}
	local orig = {led._read_file, led._write_file, led._rename, led._remove, led._sh}
	local function split(path)
		local name, file = path:match("^/sys/class/leds/([^/]+)/(.+)$")
		return name and leds[name], file
	end
	led._read_file = function(path)
		local l, file = split(path)
		if not l then return files[path] end
		if file == "trigger" then
			local out = {}
			for _, t in ipairs({"none", "timer", "heartbeat", "netdev", "phy0tpt", "default-on"}) do
				out[#out + 1] = (t == l.trigger) and ("[" .. t .. "]") or t
			end
			return table.concat(out, " ") .. "\n"
		elseif file == "brightness" then
			return tostring(l.brightness) .. "\n"
		end
		local v = l.attrs and l.attrs[file]
		return v and (v .. "\n") or nil
	end
	led._write_file = function(path, contents)
		local l, file = split(path)
		if not l then files[path] = contents; return true end
		if file == "trigger" then
			if contents == "none" and l.trigger ~= "none" then l.brightness = 0 end
			l.trigger = contents
			l.attrs = {}
			for k, v in pairs(TRIGGER_DEFAULTS[contents] or {}) do l.attrs[k] = v end
		elseif file == "brightness" then
			local b = tonumber(contents)
			if b == 0 then l.trigger = "none"; l.attrs = {} end
			l.brightness = b
		else
			if not (l.attrs and l.attrs[file] ~= nil) then return false end
			l.attrs[file] = contents
		end
		return true
	end
	led._rename = function(from, to) files[to] = files[from]; files[from] = nil; return true end
	led._remove = function(path) files[path] = nil; return true end
	led._sh = function(cmd)
		if cmd:find("^ls ") then
			local names = {}
			for n in pairs(leds) do names[#names + 1] = n end
			return table.concat(names, "\n") .. "\n"
		end
		files["sh:" .. cmd] = true
		return ""
	end
	local function restore_stubs()
		led._read_file, led._write_file, led._rename, led._remove, led._sh =
			orig[1], orig[2], orig[3], orig[4], orig[5]
	end
	return leds, files, restore_stubs
end

-- An E8450 after boot: the running LED on, the internet LED on a netdev
-- trigger, a radio LED on its throughput trigger, an unused LED off.
local function e8450()
	return {
		["power:blue"]   = {trigger = "none", brightness = 1},
		["power:orange"] = {trigger = "none", brightness = 0},
		["inet:blue"]    = {trigger = "netdev", brightness = 0,
			attrs = {device_name = "br-lan.1", link = "1", rx = "1", tx = "0", interval = "50"}},
		["mt76-phy0"]    = {trigger = "phy0tpt", brightness = 0},
	}
end

local function with(fn)
	local leds, files, done = sysfs(e8450())
	local ok, err = pcall(fn, leds, files)
	done()
	if not ok then error(err, 2) end
end

local function all_dark(leds)
	for name, l in pairs(leds) do
		if l.trigger ~= "none" or l.brightness ~= 0 then return false, name end
	end
	return true
end

return {
	{
		name = "led: off darkens every LED, on puts each back as the board had it",
		fn = function()
			with(function(leds, files)
				assert_true(led.set_enabled(false), "switched off")
				local dark, lit = all_dark(leds)
				assert_true(dark, "every LED is dark (lit: " .. tostring(lit) .. ")")
				assert_true(files[led.BASELINE_FILE] ~= nil, "the board's state is kept in tmpfs")

				assert_true(led.set_enabled(true), "switched on")
				assert_eq(leds["power:blue"].trigger, "none", "the running LED needs no trigger")
				assert_eq(leds["power:blue"].brightness, 1, "and is on again")
				assert_eq(leds["power:orange"].brightness, 0, "an LED that was off stays off")
				assert_eq(leds["mt76-phy0"].trigger, "phy0tpt",
					"a radio LED gets its throughput trigger back (OpenWrt's turnon loses it)")
				local inet = leds["inet:blue"]
				assert_eq(inet.trigger, "netdev", "the netdev trigger is back")
				assert_eq(inet.attrs.device_name, "br-lan.1", "on the same device")
				assert_eq(inet.attrs.link, "1", "with its link mode")
				assert_eq(inet.attrs.rx, "1", "and rx")
				assert_eq(inet.attrs.tx, "0", "and without tx, as configured")
				assert_nil(files[led.BASELINE_FILE], "nothing left to undo, so the snapshot is gone")
			end)
		end
	},
	{
		name = "led: on without an earlier off touches nothing",
		fn = function()
			with(function(leds, files)
				leds["power:blue"].brightness = 1
				assert_true(led.set_enabled(true), "switched on")
				assert_eq(leds["mt76-phy0"].trigger, "phy0tpt", "untouched")
				assert_nil(files[led.BASELINE_FILE], "no snapshot taken")
			end)
		end
	},
	{
		name = "led: nil (never pushed) leaves the board alone",
		fn = function()
			with(function(leds)
				assert_false(led.set_enabled(nil), "nothing to do")
				assert_eq(leds["power:blue"].brightness, 1, "untouched")
			end)
		end
	},
	{
		name = "led: a second off (or a restart while off) never snapshots the dark state",
		fn = function()
			with(function(leds)
				led.set_enabled(false)
				led.set_enabled(false)   -- a repeated push, or the startup reapply
				led.set_enabled(true)
				assert_eq(leds["power:blue"].brightness, 1, "the board's state, not the dark one")
				assert_eq(leds["mt76-phy0"].trigger, "phy0tpt", "the board's trigger, not none")
			end)
		end
	},
	{
		name = "led: a torn or foreign snapshot file is ignored, not trusted",
		fn = function()
			with(function(_, files)
				files[led.BASELINE_FILE] = "{not json"
				assert_nil(led.load_baseline(), "undecodable")
				files[led.BASELINE_FILE] = '{"order":"x","leds":{}}'
				assert_nil(led.load_baseline(), "wrong shape")
			end)
		end
	},
	{
		name = "led: restore refuses a snapshot naming a path, not a sysfs attribute",
		fn = function()
			with(function(leds)
				local wrote = {}
				local w = led._write_file
				led._write_file = function(path, c) wrote[#wrote + 1] = path; return w(path, c) end
				led.restore("inet:blue", {trigger = "netdev", attrs = {{"../../../etc/passwd", "x"}}})
				led._write_file = w
				for _, p in ipairs(wrote) do
					assert_true(not p:find("..", 1, true), "no write outside the LED: " .. p)
				end
				assert_false(led.restore("../x", {trigger = "none"}), "an LED name with a path is refused")
				assert_eq(leds["inet:blue"].trigger, "netdev", "the trigger itself was set")
			end)
		end
	},
	{
		name = "led: while off, an LED something relit goes dark again and its new state is kept",
		fn = function()
			with(function(leds)
				led.set_enabled(false)
				assert_eq(led.reassert(), 0, "nothing relit yet")
				-- LuCI saved the LED page: OpenWrt's led service put the
				-- internet LED on a netdev trigger for another device.
				leds["inet:blue"] = {trigger = "netdev", brightness = 0,
					attrs = {device_name = "lan4", link = "1", rx = "0", tx = "0", interval = "50"}}
				assert_eq(led.reassert(), 1, "one LED relit")
				assert_true(all_dark(leds), "dark again")
				led.set_enabled(true)
				assert_eq(leds["inet:blue"].attrs.device_name, "lan4",
					"switched on, it does what it is now configured to do")
			end)
		end
	},
	{
		name = "led: Locate blinks the status LED and hands it back to the board",
		fn = function()
			with(function(leds, files)
				assert_true(led.locate_start("power:blue"), "blinking")
				assert_eq(leds["power:blue"].trigger, "timer", "on the timer trigger")
				assert_eq(leds["power:blue"].attrs.delay_on, "250", "fast blink on-phase")
				assert_eq(leds["power:blue"].attrs.delay_off, "250", "fast blink off-phase")
				assert_eq(leds["mt76-phy0"].trigger, "phy0tpt", "no other LED is touched")
				assert_true(led.locate_stop("power:blue", true), "stopped")
				assert_eq(leds["power:blue"].trigger, "none", "no trigger, as before")
				assert_eq(leds["power:blue"].brightness, 1,
					"and ON: the steady running LED, not left dark by the trigger removal")
				assert_nil(files[led.BASELINE_FILE], "nothing left overridden")
			end)
		end
	},
	{
		name = "led: Locate with the LEDs off blinks, then goes back to dark",
		fn = function()
			with(function(leds)
				led.set_enabled(false)
				led.locate_start("power:blue")
				assert_eq(leds["power:blue"].trigger, "timer", "the blink shows even with LEDs off")
				assert_eq(led.reassert("power:blue"), 0, "the blink is not undone while locating")
				led.locate_stop("power:blue", false)
				assert_true(all_dark(leds), "dark again after Locate")
				led.set_enabled(true)
				assert_eq(leds["power:blue"].brightness, 1, "and the board's state after that")
			end)
		end
	},
	{
		name = "led: switching off during a Locate spares the blink, which then ends dark",
		fn = function()
			with(function(leds)
				led.locate_start("power:blue")
				led.set_enabled(false, "power:blue")
				assert_eq(leds["power:blue"].trigger, "timer", "the blink goes on")
				assert_eq(leds["mt76-phy0"].trigger, "none", "everything else is dark")
				led.locate_stop("power:blue", false)
				assert_true(all_dark(leds), "and so is the status LED once Locate ends")
				led.set_enabled(true)
				assert_eq(leds["power:blue"].brightness, 1,
					"the snapshot is from before the blink, not of it")
			end)
		end
	},
	{
		name = "led: switching on during a Locate leaves the blink, which ends in the board's state",
		fn = function()
			with(function(leds, files)
				led.set_enabled(false)
				led.locate_start("power:blue")
				led.set_enabled(true, "power:blue")
				assert_eq(leds["mt76-phy0"].trigger, "phy0tpt", "the rest is back")
				assert_eq(leds["power:blue"].trigger, "timer", "the blink goes on")
				assert_true(files[led.BASELINE_FILE] ~= nil, "the snapshot stays for the blink")
				led.locate_stop("power:blue", true)
				assert_eq(leds["power:blue"].brightness, 1, "the board's state")
				assert_nil(files[led.BASELINE_FILE], "then it goes")
			end)
		end
	},
	{
		name = "led: a Locate that ended in a reboot has nothing to stop",
		fn = function()
			with(function(leds)
				-- The reboot cleared the tmpfs snapshot and the blink with it.
				assert_false(led.locate_stop("power:blue", true), "nothing to do")
				assert_eq(leds["power:blue"].brightness, 1, "the board's own state stands")
			end)
		end
	},
	{
		name = "led: no status LED means Locate is a no-op",
		fn = function()
			assert_false(led.locate_start(nil), "no LED")
			assert_false(led.locate_stop(nil, true), "no LED")
			assert_false(led.locate_start(""), "empty name")
		end
	},
	{
		name = "led: the single-LED scheme is undone through diag.sh's own post-boot state",
		fn = function()
			with(function(_, files)
				led.restore_status_leds()
				local ran
				for k in pairs(files) do
					if k:find("^sh:") and k:find("set_state done", 1, true) then ran = k end
				end
				assert_true(ran ~= nil, "diag.sh set_state done")
				assert_true(ran:find("/etc/diag.sh", 1, true) ~= nil, "guarded by diag.sh existing")
			end)
		end
	},
	{
		name = "led: a netdev LED whose device was renamed follows, live and in the snapshot",
		fn = function()
			with(function(leds)
				leds["inet:blue"].attrs.device_name = "switch.1"
				led.repoint({{sysfs = "inet:blue", from = "switch.1", to = "br-lan.1"}})
				assert_eq(leds["inet:blue"].attrs.device_name, "br-lan.1", "the running trigger follows")
				assert_eq(leds["inet:blue"].attrs.link, "1", "keeping its modes")

				-- Held dark: the rename must reach the snapshot, or switching
				-- on would put the old name back.
				leds["inet:blue"].attrs.device_name = "switch.1"
				led.set_enabled(false)
				led.repoint({{sysfs = "inet:blue", from = "switch.1", to = "br-lan.1"}})
				assert_eq(leds["inet:blue"].trigger, "none", "a dark LED stays dark")
				led.set_enabled(true)
				assert_eq(leds["inet:blue"].attrs.device_name, "br-lan.1", "and comes back on the new device")

				led.repoint({{sysfs = "../x", from = "a", to = "b"}, {sysfs = "power:blue"}})
				assert_eq(leds["power:blue"].brightness, 1, "odd entries are ignored")
			end)
		end
	},
}
