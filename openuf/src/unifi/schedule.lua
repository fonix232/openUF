--[[
	schedule.lua -- a WLAN Schedule out of system_cfg, and whether it has the
	WLAN on at a given moment. Pure: the device side (openwrt/wlansched.lua)
	supplies the local time and carries the result out.

	Decompiled from 10.6.106 (com.ubnt.service.config.VAZShipWTNxlo, the WLAN
	generator, and com.ubnt.service.at's schedule classes); not yet seen on
	the wire. Sent per WLAN when the wlanconf has a schedule:

	  wireless.<n>.schedule_enabled=enabled
	  wireless.<n>.schedule_<day>.<i>=HHMM-HHMM   with fw_caps 0x1000
	  wireless.<n>.schedule_<day>=HHMM-HHMM       without it (the last block wins)
	  wireless.<n>.schedule_invert=enabled        with fw_caps 0x400000

	<day> is sun..sat. "2359" as an end means the end of the day. A block
	that crosses midnight is split by the controller.

	What a block means depends on schedule_invert. The 10.6 UI's schedule is a
	"WiFi Blackout Schedule" ("Specify times when this WiFi instance should be
	disabled"). To a device without fw_caps 0x400000 the controller sends the
	COMPLEMENT of those blocks (bnjutafutalctv_0.NvfcKfHPI): the times the
	WLAN is on, a day with no blackout as 0000-2359, and a day blacked out
	from end to end as no key at all. With 0x400000 it sends the blackout
	blocks as they are, plus schedule_invert=enabled. So:

	  no invert: blocks are ON times, a day without blocks is OFF all day
	  invert:    blocks are OFF times, a day without blocks is ON all day
]]--

local M = {}

M.DAYS = {"sun", "mon", "tue", "wed", "thu", "fri", "sat"}
local DAY_INDEX = {}
for i, d in ipairs(M.DAYS) do DAY_INDEX[d] = i end

-- "HHMM" -> minutes since midnight; "2359" (and anything later) as an end is
-- the end of the day, 1440.
local function minutes(s, is_end)
	if type(s) ~= "string" or not s:match("^%d%d%d%d$") then return nil end
	local h, m = tonumber(s:sub(1, 2)), tonumber(s:sub(3, 4))
	if h > 23 or m > 59 then return nil end
	local v = h * 60 + m
	if is_end and v >= 23 * 60 + 59 then v = 1440 end
	return v
end

-- One "HHMM-HHMM" value -> {s=, e=} in minutes, or nil.
function M.parse_block(v)
	if type(v) ~= "string" then return nil end
	local a, b = v:match("^(%d%d%d%d)%-(%d%d%d%d)$")
	local s, e = minutes(a, false), minutes(b, true)
	if not s or not e or e <= s then return nil end
	return {s = s, e = e}
end

-- The schedule of one wireless.<n> block (keys without the prefix), or nil
-- when the WLAN has none. Returns {invert = bool, days = {sun = {{s,e}..}..}}.
-- Malformed blocks are dropped (and named in `bad`, for the caller's log).
function M.parse(w)
	if type(w) ~= "table" then return nil end
	local en = w.schedule_enabled
	if en ~= "enabled" and en ~= "true" then return nil end
	local out = {invert = (w.schedule_invert == "enabled" or w.schedule_invert == "true"),
		days = {}}
	local bad = {}
	-- Indexed keys in index order, so a stable result for the same push.
	local keys = {}
	for k in pairs(w) do
		if k:match("^schedule_%a%a%a$") or k:match("^schedule_%a%a%a%.%d+$") then
			keys[#keys + 1] = k
		end
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local day = k:match("^schedule_(%a%a%a)")
		if DAY_INDEX[day] then
			local b = M.parse_block(w[k])
			if b then
				out.days[day] = out.days[day] or {}
				table.insert(out.days[day], b)
			else
				bad[#bad + 1] = k .. "=" .. tostring(w[k])
			end
		end
	end
	for _, list in pairs(out.days) do
		table.sort(list, function(x, y) return x.s < y.s end)
	end
	return out, (#bad > 0) and bad or nil
end

-- Whether the WLAN is on at minute `minute` (0..1439) of weekday `wday`
-- (1 = Sunday .. 7 = Saturday, os.date's numbering).
function M.is_on(sched, wday, minute)
	if type(sched) ~= "table" then return true end
	local blocks = sched.days and sched.days[M.DAYS[wday] or ""]
	local inside = false
	for _, b in ipairs(blocks or {}) do
		if minute >= b.s and minute < b.e then inside = true break end
	end
	if sched.invert then return not inside end
	return inside
end

-- The schedule as one UCI-safe string (the device keeps it on the WLAN's own
-- section, so it outlives a restart): "inv|sun=0000-0800,1700-2359|mon=..."
-- with "on|" in place of "inv|" for a plain one. Ends of the day are written
-- as 2359, as on the wire.
local function hhmm(v)
	if v >= 1440 then return "2359" end
	return string.format("%02d%02d", math.floor(v / 60), v % 60)
end

function M.encode(sched)
	if type(sched) ~= "table" then return nil end
	local parts = {sched.invert and "inv" or "on"}
	for _, d in ipairs(M.DAYS) do
		local blocks = sched.days and sched.days[d]
		if blocks and #blocks > 0 then
			local b = {}
			for _, x in ipairs(blocks) do b[#b + 1] = hhmm(x.s) .. "-" .. hhmm(x.e) end
			parts[#parts + 1] = d .. "=" .. table.concat(b, ",")
		end
	end
	return table.concat(parts, "|")
end

function M.decode(s)
	if type(s) ~= "string" then return nil end
	local mode = s:match("^(%a+)")
	if mode ~= "inv" and mode ~= "on" then return nil end
	local out = {invert = (mode == "inv"), days = {}}
	for d, list in s:gmatch("|(%a%a%a)=([%d%-,]+)") do
		if DAY_INDEX[d] then
			for v in list:gmatch("[^,]+") do
				local b = M.parse_block(v)
				if b then
					out.days[d] = out.days[d] or {}
					table.insert(out.days[d], b)
				end
			end
		end
	end
	return out
end

return M
