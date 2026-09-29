--[[
	The board's LEDs, as the controller switches them.

	The controller's LED setting (mgmt_cfg led_enabled: the device's own
	Default/On/Off override, resolved against the site-wide Device LED
	switch) is one boolean, so openUF treats it as a switch over everything
	the board does with its LEDs, not over one LED:

	  on   the LEDs do what OpenWrt configured them to do: the status LED
	       diag.sh lights at the end of boot, the netdev/switch/radio
	       activity triggers from /etc/config/system and the drivers'
	       defaults (an mt76 radio LED on phyNtpt)
	  off  every LED dark
	  nil  never pushed: the board is left alone

	Off is reversible because the board's own state is snapshotted first:
	each LED's trigger, the settings that trigger was configured with
	(netdev device_name/link/rx/tx, timer delays, ...), its brightness and
	colour. OpenWrt's own "led turnoff/turnon" pair cannot be used for this:
	turnon only puts back LEDs that have a UCI section or a diag.sh role, so
	an mt76 radio LED lost its activity trigger for good after one off/on.

	The snapshot lives in tmpfs (BASELINE_FILE), which is exactly the
	lifetime of the kernel state it describes: a daemon restart finds it and
	knows the LEDs are dark by its own hand, a reboot clears both and the
	board comes up in its own state again. It is taken once per boot, the
	first time openUF overrides anything, and only then -- a snapshot taken
	while openUF holds the LEDs dark would record the dark state as the
	board's.

	Locate blinks the board's status LED (dev.conf.led, board.lua) through
	the same snapshot, and puts it back to whatever the switch says.

	Nothing here raises: these run from the inform dispatch, and a cosmetic
	setting must not take the daemon down.
]]--

local cjson = require("cjson")

local M = {}

M.LED_ROOT = "/sys/class/leds/"
M.BASELINE_FILE = "/var/run/openuf-leds.json"

-- The settings each trigger takes, written back in this order after the
-- trigger itself (setting a trigger resets them). netdev's device_name goes
-- first: the mode flags apply to the device already named. The link_* speed
-- flags and "link" exclude each other in the kernel, and writing a saved 0
-- only clears its own bit, so any order of those restores what was read.
M.TRIGGER_ATTRS = {
	netdev    = {"device_name", "link", "link_10", "link_100", "link_1000", "link_2500",
		"link_5000", "link_10000", "half_duplex", "full_duplex", "rx", "tx", "interval"},
	timer     = {"delay_on", "delay_off"},
	oneshot   = {"delay_on", "delay_off", "invert"},
	heartbeat = {"invert"},
	pattern   = {"pattern", "repeat"},
}

-- Injectable: file writer, for sysfs LED control and the snapshot.
M._write_file = function(path, contents)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(contents)
	f:close()
	return true
end

-- Injectable: file reader. nil when the file is missing or unreadable.
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- Injectable: the rename that makes a snapshot write atomic, and the delete.
M._rename = os.rename
M._remove = os.remove

-- Injectable: shell, for listing /sys/class/leds and running diag.sh.
M._sh = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a")
	h:close()
	return s or ""
end

local function trim(s)
	return type(s) == "string" and (s:gsub("^%s+", ""):gsub("%s+$", "")) or nil
end

local function valid_name(name)
	return type(name) == "string" and name ~= "" and not name:find("/", 1, true)
		and name ~= "." and name ~= ".."
end

local function attr(name, file)
	return trim(M._read_file(M.LED_ROOT .. name .. "/" .. file))
end

local function set(name, file, value)
	return M._write_file(M.LED_ROOT .. name .. "/" .. file, tostring(value))
end

-- The active trigger from a sysfs `trigger` file, which lists every
-- available trigger and brackets the current one:
--   "none timer heartbeat netdev [phy0tpt] phy1tpt"
local function active_trigger(name)
	local s = M._read_file(M.LED_ROOT .. name .. "/trigger")
	return type(s) == "string" and s:match("%[(%S-)%]") or nil
end

-- The LEDs the kernel has registered, sorted so restores run in a stable
-- order.
function M.list()
	local names = {}
	for n in M._sh("ls " .. M.LED_ROOT):gmatch("%S+") do
		if valid_name(n) then names[#names + 1] = n end
	end
	table.sort(names)
	return names
end

-- One LED's state, enough to put it back: {trigger, brightness, color,
-- attrs}. nil when the LED cannot be read at all.
function M.snapshot(name)
	local trigger = active_trigger(name)
	local brightness = tonumber(attr(name, "brightness") or "")
	if not trigger and not brightness then return nil end
	local s = {trigger = trigger or "none", brightness = brightness or 0,
		color = attr(name, "multi_intensity")}
	local names = M.TRIGGER_ATTRS[s.trigger]
	if names then
		s.attrs = {}
		for _, a in ipairs(names) do
			local v = attr(name, a)
			if v then s.attrs[#s.attrs + 1] = {a, v} end
		end
	end
	return s
end

-- Put one LED back to a snapshot. The trigger goes first because setting
-- one resets its settings; brightness only means something without one
-- (with a trigger, writing 0 would remove it again).
function M.restore(name, s)
	if not (valid_name(name) and type(s) == "table") then return false end
	if s.color then set(name, "multi_intensity", s.color) end
	local trigger = type(s.trigger) == "string" and s.trigger or "none"
	set(name, "trigger", trigger)
	if trigger == "none" then
		set(name, "brightness", tonumber(s.brightness) or 0)
	elseif type(s.attrs) == "table" then
		for _, kv in ipairs(s.attrs) do
			if type(kv) == "table" and type(kv[1]) == "string" and valid_name(kv[1]) then
				set(name, kv[1], kv[2])
			end
		end
	end
	return true
end

-- One LED off: no trigger, brightness 0 (leds.sh's led_off, in its order).
function M.dark(name)
	if not valid_name(name) then return false end
	set(name, "trigger", "none")
	set(name, "brightness", 0)
	return true
end

function M.is_dark(name)
	return active_trigger(name) == "none" and tonumber(attr(name, "brightness") or "") == 0
end

-- The snapshot of this boot: {order = {names}, leds = {name = state}}, or
-- nil when openUF has not overridden any LED since the board came up.
function M.load_baseline()
	local s = M._read_file(M.BASELINE_FILE)
	if not s or s == "" then return nil end
	local ok, b = pcall(cjson.decode, s)
	if not ok or type(b) ~= "table" or type(b.order) ~= "table" or type(b.leds) ~= "table" then
		return nil
	end
	return b
end

local function save_baseline(b)
	local tmp = M.BASELINE_FILE .. ".tmp"
	if not M._write_file(tmp, cjson.encode(b)) then return false end
	return M._rename(tmp, M.BASELINE_FILE) and true or false
end

local function drop_baseline()
	M._remove(M.BASELINE_FILE)
end

-- The snapshot, taken now if this boot has none yet. See the header for
-- why it must only ever be taken while the board is in its own state.
local function baseline()
	local b = M.load_baseline()
	if b then return b end
	b = {order = {}, leds = {}}
	for _, n in ipairs(M.list()) do
		local s = M.snapshot(n)
		if s then
			b.order[#b.order + 1] = n
			b.leds[n] = s
		end
	end
	save_baseline(b)
	return b
end

-- The controller's switch. enabled: true/false as pushed (nil: never
-- pushed, nothing to do). skip names an LED to leave alone, the one Locate
-- is blinking; its turn comes at locate_stop.
function M.set_enabled(enabled, skip)
	if enabled == nil then return false end
	if enabled then
		local b = M.load_baseline()
		if not b then return true end   -- nothing of openUF's to undo
		for _, n in ipairs(b.order) do
			if n ~= skip then M.restore(n, b.leds[n]) end
		end
		if not skip then drop_baseline() end
		return true
	end
	local b = baseline()
	for _, n in ipairs(b.order) do
		if n ~= skip then M.dark(n) end
	end
	return true
end

-- While the switch is off: something relit an LED (LuCI saving the LED
-- page runs "service led restart", a sysupgrade check runs diag.sh). That
-- state is what the board is now configured to do, so it becomes the LED's
-- snapshot, and the LED goes dark again. Returns how many were relit.
-- Two sysfs reads per LED, no fork.
function M.reassert(skip)
	local b = M.load_baseline()
	if not b then return 0 end
	local relit = 0
	for _, n in ipairs(b.order) do
		if n ~= skip and not M.is_dark(n) then
			local s = M.snapshot(n)
			if s then b.leds[n] = s end
			M.dark(n)
			relit = relit + 1
		end
	end
	if relit > 0 then save_baseline(b) end
	return relit
end

-- Locate: the fast identify blink on the status LED, after making sure the
-- snapshot exists to put it back from.
function M.locate_start(led)
	if not valid_name(led) then return false end
	baseline()
	set(led, "trigger", "timer")
	set(led, "delay_on", 250)
	set(led, "delay_off", 250)
	return true
end

-- End of Locate: the status LED goes back to what the switch says -- dark
-- when off, its snapshot otherwise -- and with the switch not off, nothing
-- else is overridden any more, so the snapshot goes too. No snapshot means
-- the device rebooted since the blink started, which already ended it.
function M.locate_stop(led, enabled)
	if not valid_name(led) then return false end
	local b = M.load_baseline()
	if not b then return false end
	if enabled == false then
		M.dark(led)
	else
		if b.leds[led] then M.restore(led, b.leds[led]) else M.dark(led) end
		drop_baseline()
	end
	return true
end

-- One-time undo of the previous scheme, which forced one LED (the first
-- status/power/system/run LED by name) to "trigger none, brightness on/off"
-- and left it there for the rest of the boot. Those were always status
-- LEDs, and diag.sh's "done" state is how the board sets them after boot:
-- boot LED off, running LED on.
function M.restore_status_leds()
	M._sh("[ -f /etc/diag.sh ] && . /etc/diag.sh && set_state done")
end

return M
