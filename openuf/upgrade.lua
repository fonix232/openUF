--[[
	OpenWrt upgrades through UniFi's own upgrade flow, via attended sysupgrade.

	All of it is opt-in (conf.lua):

	  config.upgrade_mode = "owut"
	      A controller `upgrade` -- the Upgrade button, a scheduled auto-upgrade,
	      or Devices -> Custom Upgrade with any URL -- runs `owut upgrade` in the
	      background instead of being stored and ignored. owut builds an image
	      for this exact board on the ASU server with everything installed kept,
	      verifies it and sysupgrades. The UniFi firmware URL itself is never
	      fetched: it is Ubiquiti firmware and would brick the board.
	      Refused unless /etc/init.d/openuf-bootstrap exists (contrib/asu): a
	      sysupgrade keeps openUF's state and conf.lua but not its code, and
	      without the bootstrap the new image would come up without openUF.

	  config.advertise_updates = true
	      Every advertise_interval seconds (default 6 h) run `owut check`, and
	      while it reports a newer build that is safe to install, report a
	      version just below the catalogue's (6.8.1.x for 6.8.2.x). The
	      controller shows its normal "Upgrade available" badge; Upgrade -- or
	      its own auto-upgrade schedule -- then runs owut, and the device comes
	      back reporting the catalogue version again, which the controller logs
	      as an "Upgraded" event.

	  config.version_scheme = "openwrt"   (cosmetic)
	      Put the OpenWrt revision in the build field (6.8.2.36162 for r36162)
	      so the firmware column follows the real build -- at the price of a
	      permanent Upgrade badge (below).

	Why version games are needed at all: on 10.6 the controller marks a device
	upgradable whenever its `version` differs, character for character, from
	the catalogue's current version for the model. So by default the exact
	catalogue string is reported -- and LEARNED from the controller's own
	`upgrade` commands (their `version` field), so a new Ubiquiti release stops
	leaving every openUF AP permanently "outdated" after one upgrade round.
]]--

local M = {}

M.CHECK_FILE   = "/tmp/openuf-owut-check.txt"
M.LOG_FILE     = "/tmp/openuf-owut.log"
M.BOOTSTRAP    = "/etc/init.d/openuf-bootstrap"
M.RELEASE_FILE = "/etc/openwrt_release"
M.DEFAULT_ADVERTISE_INTERVAL = 6 * 3600

M.update_available = false
M._next_check = 0
M._check_started = nil

M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end
M._exists = function(path)
	local f = io.open(path, "r")
	if f then f:close() return true end
	return false
end
M._exec = function(cmd) return os.execute(cmd) end
M._running = function()
	local h = io.popen("pgrep -f '^/usr/bin/ucode.*owut|owut (check|upgrade)' 2>/dev/null")
	local s = h and h:read("*a") or ""
	if h then h:close() end
	return s:match("%d") ~= nil
end

-- The OpenWrt revision number (r36162-... -> 36162), or nil.
function M.revision()
	local s = M._read_file(M.RELEASE_FILE) or ""
	return tonumber(s:match("DISTRIB_REVISION=['\"]?r(%d+)"))
end

-- "M.m.p.b" -> {M, m, p}
local function head3(ver)
	local a, b, c = tostring(ver or ""):match("^(%d+)%.(%d+)%.(%d+)")
	if not a then return nil end
	return {tonumber(a), tonumber(b), tonumber(c)}
end

-- The version string for the payload. `learned` is the catalogue version the
-- controller last asked this device to upgrade to (st.fw_version); it wins
-- over the ufmodel's built-in one.
function M.version(ufver, conf, learned)
	conf = conf or {}
	local base = type(learned) == "string" and learned:match("^%d+%.%d+%.%d+%.%d+$") and learned
		or ufver
	local h = head3(base)
	if not h then return base end
	local build = tostring(base):match("^%d+%.%d+%.%d+%.(%d+)$") or "0"
	local rev = M.revision()
	if conf.advertise_updates and M.update_available then
		-- Anything but the catalogue's exact string raises the badge; one step
		-- below it also reads as "older" to a human.
		if h[3] > 0 then h[3] = h[3] - 1
		elseif h[2] > 0 then h[2], h[3] = h[2] - 1, 99
		elseif h[1] > 0 then h[1], h[2], h[3] = h[1] - 1, 99, 99 end
		return string.format("%d.%d.%d.%s", h[1], h[2], h[3], tostring(rev or build))
	end
	if conf.version_scheme == "openwrt" and rev then
		return string.format("%d.%d.%d.%d", h[1], h[2], h[3], rev)
	end
	return base
end

-- Parse `owut check` output: is there a newer build that is safe to install?
function M.parse_check(out)
	if type(out) ~= "string" then return false end
	local from = tonumber(out:match("Version%-from%s+%S+%s+r(%d+)"))
	local to   = tonumber(out:match("Version%-to%s+%S+%s+r(%d+)"))
	local vfrom = out:match("Version%-from%s+(%S+)")
	local vto   = out:match("Version%-to%s+(%S+)")
	local safe  = out:find("safe to proceed", 1, true) ~= nil
	if not (safe and vfrom and vto) then return false end
	if vfrom ~= vto then return true end          -- a new release/branch
	return (from and to and to > from) or false  -- a newer build of the same one
end

-- Called every heartbeat when advertise_updates is on. Never blocks: the
-- check runs detached and its output is read on a later tick.
function M.tick(now, conf)
	if not (conf and conf.advertise_updates) then return end
	if M._check_started then
		local out = M._read_file(M.CHECK_FILE)
		if out and out:find("\n__done__", 1, true) then
			M.update_available = M.parse_check(out)
			M._check_started = nil
		elseif now - M._check_started > 900 then
			M._check_started = nil               -- stuck; try again next time
		end
		return
	end
	if now < M._next_check or M._running() then return end
	M._next_check = now + (tonumber(conf.advertise_interval) or M.DEFAULT_ADVERTISE_INTERVAL)
	M._check_started = now
	M._exec("( owut check > " .. M.CHECK_FILE .. " 2>&1; echo __done__ >> "
		.. M.CHECK_FILE .. " ) </dev/null >/dev/null 2>&1 &")
end

-- Start an upgrade. Returns true when one was started, false and a reason
-- otherwise.
function M.start(conf)
	if not (conf and conf.upgrade_mode == "owut") then return false, "upgrade_mode is not owut" end
	if not M._exists("/usr/bin/owut") then return false, "owut is not installed" end
	if not M._exists(M.BOOTSTRAP) then
		return false, "no " .. M.BOOTSTRAP .. ": the new image would come up without openUF"
			.. " (install it with contrib/asu/openuf-firstboot.sh)"
	end
	if M._running() then return false, "owut is already running" end
	M._exec("( sleep 2; owut upgrade > " .. M.LOG_FILE .. " 2>&1 ) </dev/null >/dev/null 2>&1 &")
	return true
end

return M
