--[[
	UniFi inform protocol client.

	Sends encrypted JSON payloads to the controller via HTTP POST every 10
	seconds (the standard UniFi heartbeat interval).  Parses and dispatches
	the controller's response. The packet format is unifi/packet.lua's.
]]--

-- socket is lazy-loaded inside http_post/run so the module can be required
-- in test environments that do not have luasocket installed.
local cjson  = require("cjson")

local crypto    = require("unifi.crypto")
local state     = require("state")
local sysinfo   = require("openwrt.sysinfo")
local lldp      = require("openwrt.lldp")
local ucihelper = require("openwrt.ucihelper")
local led       = require("openwrt.led")
local netconfig = require("openwrt.netconfig")
local firewall  = require("openwrt.firewall")
local usteer    = require("openwrt.usteer")
local switchvlan = require("openwrt.switchvlan")
local rrmscan   = require("openwrt.rrmscan")
local roamassist = require("openwrt.roamassist")
local minrssi   = require("openwrt.minrssi")
local shaper    = require("openwrt.shaper")
local rrbguard  = require("openwrt.rrbguard")
local netmodel  = require("openwrt.netmodel")
local stun      = require("unifi.stun")
local upgrade   = require("openwrt.upgrade")
local unhandled = require("unifi.unhandled")
local sysconf   = require("openwrt.sysconf")
local l2guard   = require("openwrt.l2guard")
local guest     = require("unifi.guest")
local guestguard = require("openwrt.guestguard")
local guestportal = require("openwrt.guestportal")
local airtime   = require("openwrt.airtime")
local staevents = require("unifi.staevents")
local dnswatch  = require("openwrt.dnswatch")
local staphase  = require("openwrt.staphase")
local http      = require("unifi.http")
local wlan      = require("unifi.wlan")
local ports     = require("unifi.ports")
local payload   = require("unifi.payload")
local report    = require("openwrt.report")
local provision = require("openwrt.provision")
local idlescan  = require("openwrt.idlescan")
local backhaul  = require("openwrt.backhaul")
local recognized = require("unifi.recognized")
local wlansched = require("openwrt.wlansched")
local lockap    = require("openwrt.lockap")
local snmp_unifi = require("unifi.snmp")
local snmp_owrt = require("openwrt.snmp")

local M = {}

-- Injectable: expose internal modules so tests can inject fixtures
-- _crypto included: without the seam, a test file's own crypto instance (its
-- separate dofile) is stubbed while build_packet/parse_packet keep using this
-- private one -- which once made a fixed-IV stub silently ineffective and a
-- whole encryption assertion vacuous.
M._crypto    = crypto
M._state     = state
M._sysinfo   = sysinfo
M._ucihelper = ucihelper
M._lldp      = lldp
M._led       = led
M._netconfig = netconfig
M._firewall  = firewall
M._usteer    = usteer
M._switchvlan = switchvlan
M._rrmscan    = rrmscan
-- A beacon report's width is decided exactly as the scan cache's is.
rrmscan._channel_width = sysinfo.channel_width
M._idlescan   = idlescan
M._backhaul   = backhaul
M._roamassist = roamassist
M._minrssi    = minrssi
M._shaper     = shaper
M._rrbguard   = rrbguard
M._netmodel   = netmodel
-- netmodel stops a lease-releasing DHCP client before its reloads.
netmodel._stop_releasing_dhcp_client = ucihelper.stop_releasing_dhcp_client
M._stun       = stun
M._upgrade    = upgrade
M._unhandled  = unhandled
M._sysconf    = sysconf
M._l2guard    = l2guard
M._guest      = guest
M._guestguard = guestguard
M._guestportal = guestportal
M._airtime    = airtime
M._staevents  = staevents
M._dnswatch   = dnswatch
M._staphase   = staphase
M._wlansched  = wlansched
M._lockap     = lockap
M._report     = report
M._snmp_parse = snmp_unifi.parse
M._snmp       = snmp_owrt

-- In-memory only: 802.11k beacon-report neighbours, keyed by BSSID, plus the
-- flat list build_json merges from. Clients report asynchronously and only
-- some of them ever answer, so this is a best-effort side-channel that
-- supplements the passive scan cache -- see rrmscan.lua for the whole story.
M._rrm_cache        = {}
M._rrm_neighbours   = {}
M._rrm_next_request = 0
M._rrm_rr           = 0

-- Stations asked for a beacon report that have not answered, keyed by MAC:
-- {n = unanswered requests so far, at = when the last one went out}. A
-- station's RRM capability bits are not a promise -- a client can advertise
-- passive, active AND table measurement and still answer every variant with
-- report mode 0x02, "incapable". hostapd does not notify a bodiless refusal
-- over ubus, so from here such a station is simply one that never reports,
-- and asking it again every interval forever would only ever cost it an ack.
-- After RRM_MAX_UNANSWERED asks with nothing back it is left alone for
-- RRM_BENCH_SECONDS, then tried once more. Any report from it clears the count.
M._rrm_asked         = {}
M.RRM_MAX_UNANSWERED = 2
M.RRM_BENCH_SECONDS  = 6 * 3600

-- How often to ask ONE station for a sweep. An active beacon measurement takes
-- the client off-channel for roughly duration x channels (~1.3 s for a full
-- operating class at 50 TU), so this is deliberately slow: the point is to
-- keep the Environment tab honest, not to poll. Hourly, because hostapd writes
-- every report it receives to syslog as a hex line (~15 per answer, outside
-- openUF's control): at 600 s they took 72-78% of a 128 KB logread buffer
-- (upstream, live 2026-10-13). The controller keeps a reported neighbour ~24 h
-- (rogueap rows 22 h old still listed), so an hourly refresh loses no row.
M.RRM_REQUEST_INTERVAL = 3600

-- How often the background collector is checked for life. That check forks
-- `pgrep -f`, and ran on every 10-second heartbeat -- but the subscription
-- only dies when one of the hostapd objects it named goes away, which is a
-- config push, not a ten-second event. _tick re-arms it immediately after a
-- config IS applied (see M._rrm_collector_next), so recovery stays instant
-- exactly where it matters and the steady state costs nothing.
M.RRM_COLLECTOR_CHECK_INTERVAL = 60

-- How often, while the controller has the LEDs off, they are checked for
-- something having lit one again (led.lua reassert).
M.LED_CHECK_INTERVAL = 60
M._rrm_collector_next = 0


-- In-memory only (not persisted to state.json): per-radio spectrum-scan
-- results, keyed by radio name. Ephemeral live data, same category as
-- radio_stats()/sta_table() which are also recomputed rather than stored.
M._spectrum_cache = {}

-- In-memory only: a `quick-scan` the controller asked for (provision.lua),
-- {band = "ng"|"na"|"6e"|nil, reported = bool, queued = bool}, nil when none.
-- While set, every inform says `quickscan_scanning = true`; once one of those
-- has reached the controller (`reported`) the next tick queues the sweep
-- (`queued`), and it is cleared on the tick that runs the sweep's last chunk,
-- so that tick's inform says false and carries the results.
M._quickscan_pending = nil

-- Roam reports (staevents.lua) cannot wait for the heartbeat: the controller
-- pairs a departure with an arrival only within 10 s, and calls the roam
-- failed when the departure arrived more than a second ahead. While
-- connection events are on, _wait wakes this often to read the collector's
-- logs and sends any roam report at once (upstream ea0b5d6). _roam_fast,
-- _roam_st and _roam_cfg are set by each _tick; _roam_seq is the last
-- hostapd event read.
M.ROAM_POLL_S = 0.25
M._roam_fast  = false
M._roam_st    = nil
M._roam_cfg   = nil
M._roam_seq   = 0

-- In-memory only: the sweeps in progress, chunk by chunk (provision.lua's
-- spectrum_sweep / sweep_tick), and when the next chunk may run.
M._scan_jobs = {}
M._scan_next_chunk = 0
-- Blocking sleep between an Airtime Scan chunk's per-channel scans
-- (provision.SPECTRUM_HOME_S). Without luasocket it does not wait.
M._pause = function(seconds)
	local ok, socket = pcall(require, "socket")
	if ok then socket.select(nil, nil, seconds) end
end

-- In-memory only, keyed by client MAC: each station's WiFi Experience window
-- (`sat_window`: unifi/satisfaction.lua window()) and when it was last seen.
M._sta_stats_cache = {}
-- In-memory only, keyed by radio name: the in-use survey counters at the last
-- inform and the utilisation computed from them (unifi/payload.lua
-- windowed_cu).
M._cu_cache = {}
-- ...and how long an unseen station stays in it. See the sweep in build_json.
M.STA_STATS_FORGET_AFTER = 600

-- Injectable: override in tests to control elapsed time deterministically.
M._time = os.time

-- Injectable: override in tests to return fixture command output
M._run_cmd = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a")
	h:close()
	return s or ""
end

-- Injectable: sysfs reader for the per-netdev link attributes below.
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- Negotiated link speed in Mbit/s for a netdev, or nil when the kernel can't
-- report one (interface down, or a virtual device with no PHY -- reading
-- /sys/class/net/<if>/speed on a down interface returns an error, which
-- io.read surfaces as nil or an unparseable string, both handled here).
function M._link_speed(ifname)
	if not ifname then return nil end
	local n = tonumber((tostring(M._read_file(
		"/sys/class/net/" .. ifname .. "/speed") or ""):match("(-?%d+)") or ""))
	-- The kernel reports -1 for "unknown"; treat that as no reading.
	if n and n > 0 then return n end
	return nil
end

-- "full"/"half"/nil, from the same sysfs directory.
function M._link_duplex(ifname)
	if not ifname then return nil end
	local s = M._read_file("/sys/class/net/" .. ifname .. "/duplex")
	return s and s:match("^%s*(%a+)") or nil
end

-- Does the port have a link partner? Reads sysfs `carrier` (1/0), falling back
-- to `operstate` ("up"/"down"), and returns nil when neither is readable.
--
-- A port's mere existence in /proc/net/dev is NOT link state: an unused socket
-- is present, counted, and utterly idle. Reporting it as up was visible on a
-- real TL-WDR3500, whose eth1 (the unused WAN socket) went out as
-- "up, 1000 Mbps" while carrier was 0 and the kernel reported speed -1.
function M._link_up(ifname)
	if not ifname then return nil end
	local carrier = M._read_file("/sys/class/net/" .. ifname .. "/carrier")
	if carrier then
		local n = tonumber((carrier:match("(%d+)") or ""))
		if n then return n == 1 end
	end
	local state = M._read_file("/sys/class/net/" .. ifname .. "/operstate")
	if state then return state:match("^%s*(%a+)") == "up" end
	return nil
end

-- A token that changes whenever the state file changes, or nil when the file
-- cannot be read. Compared for equality only -- callers never interpret it --
-- so its type is free to vary.
--
-- The token is the file's own CONTENTS. This used to try `stat -c %Y` first
-- and keep the contents as a fallback, which cost a fork on the very first
-- line of every heartbeat and bought nothing:
--
--   * it cannot be relied on anyway. BusyBox gates `-c` behind
--     FEATURE_STAT_FORMAT and some builds omit the stat applet entirely
--     (confirmed on a real TL-WDR3500 with no stat at all), so on those boards
--     the fork was guaranteed to fail and this line ran regardless -- every
--     ten seconds, forever.
--   * the contents are the STRONGER test. mtime has one-second granularity,
--     so two writes inside the same second are indistinguishable by it.
--   * state.json is a few hundred bytes, and it is what M._state.load() is
--     about to read anyway.
--
-- So the fork bought strictly less correctness than the free path it fell back
-- to. The one thing lost with it is detecting a change to a file too large to
-- want to re-read; state.json is not that file, and never will be.
function M._state_mtime(path)
	return M._read_file(path)
end

-- Whether `user`'s password is locked, read off /etc/shadow (`passwd -l`
-- prefixes the hash with "!"). nil when the file or the user cannot be read,
-- which the caller treats as "unknown, act anyway".
M.SHADOW_FILE = "/etc/shadow"
function M._account_locked(user)
	local shadow = M._read_file(M.SHADOW_FILE)
	if not shadow then return nil end
	for line in shadow:gmatch("[^\n]+") do
		local name, hash = line:match("^([^:]+):([^:]*):")
		if name == user then return hash:sub(1, 1) == "!" end
	end
	return nil
end

-- Locks or unlocks the temporary SSH bootstrap account (option ssh_adopt,
-- config.lua's bootstrap_adopt_user, and USAGE.md's SSH prerequisite section) to match
-- the device's current adopted state. No-op if user is nil/false (feature
-- not enabled). Reads the current state first: BusyBox passwd is harmless on
-- an already-locked account but not silent -- it logs "password for <user>
-- is already locked" to auth.err, and this runs on every config push, so an
-- adopted AP's log filled with it. When the state cannot be read, passwd is
-- issued regardless.
-- The account's password is public, so TCP forwarding is off for as long as
-- it is usable (hook/ssh-forwarding.sh), in the same command as the unlock.
-- The hook runs every time, whatever passwd's state: it is silent and
-- idempotent, and openuf.init creates the account already unlocked without
-- it, so skipping it along with a redundant `passwd -u` would leave
-- forwarding on for a usable ubnt/ubnt login.
M.SSH_FORWARDING_HOOK = "/usr/share/openuf/hook/ssh-forwarding.sh"
function M._sync_bootstrap_account(adopted, user)
	if not user then return end
	local locked = M._account_locked(user)
	if adopted then
		local cmd = "sh " .. M.SSH_FORWARDING_HOOK .. " restore"
		if locked ~= true then cmd = "passwd -l '" .. user .. "'; " .. cmd end
		M._run_cmd(cmd)
	else
		local cmd = "sh " .. M.SSH_FORWARDING_HOOK .. " lock"
		if locked ~= false then cmd = cmd .. "; passwd -u '" .. user .. "'" end
		M._run_cmd(cmd)
	end
end

-- Injectable: override in tests to skip real HTTP
M._http_post = nil

-- The TNBU packet itself (unifi/packet.lua), with this module's crypto seam.
local packet = require("unifi.packet")
function M.build_packet(json_str, st) return packet.build(json_str, st, M._crypto) end
function M.parse_packet(raw, st) return packet.parse(raw, st, M._crypto) end

M._fix_empty_arrays = payload.fix_empty_arrays

-- IPv4 address of the inform URL's host (unifi/http.lua), cached for five
-- minutes so a heartbeat costs no DNS round trip.
M._inform_ip_cache = {}
function M._inform_ip(url)
	return http.inform_ip(url, M._time(), M._inform_ip_cache)
end

-- The payload (openwrt/report.lua), read through this module's seams.
function M.build_json(st, cfg, ufhw)
	return report.build(M, st, cfg, ufhw)
end

-- The controller's WiFi and per-port configuration (unifi/wlan.lua,
-- unifi/ports.lua), parsed with this device's capabilities.
function M._parse_wifi_system_cfg(sys_raw)
	local uci = M._ucihelper
	return wlan.parse(sys_raw, {best_phy = uci and uci.best_phy})
end
function M._parse_switch_system_cfg(sys_raw)
	return ports.parse(sys_raw)
end
function M._parse_bandsteering_system_cfg(sys_raw)
	return wlan.parse_bandsteering(sys_raw)
end

-- ─── Dropped-key visibility ──────────────────────────────────────────────────

-- Appends one line -- UTC timestamp, an optional direction tag, the text -- to
-- cfg.config.debug_dump_file. Responses are written with NO tag, the shape
-- every capture recipe expects; with debug_dump_requests set, what openUF
-- SENDS ("TX") and transport failures ("ERR") are written too, tagged so they
-- can be filtered. Append mode already positions at the end, so seek reports
-- the size -- no stat binding needed. Returns true when a line was written.
function M._debug_append(cfg, tag, text)
	local path = cfg and cfg.config and cfg.config.debug_dump_file
	if not path then return false end
	-- config.lua defaults it to 4 MiB; 0 disables the cap.
	local cap = cfg.config.debug_dump_max_bytes
	local f = io.open(path, "a")
	if not f then return false end
	local size = f:seek("end") or 0
	if cap and cap > 0 and size >= cap then
		f:close()
		f = io.open(path, "w")
		if not f then return false end
		f:write(("%s # openuf: dump passed %d bytes, restarted\n")
			:format(os.date("!%Y-%m-%dT%H:%M:%SZ"), cap))
	end
	f:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. (tag and (" " .. tag) or "")
		.. " " .. tostring(text) .. "\n")
	f:close()
	return true
end

-- The debug_caps / debug_payload_extra options make the device claim things
-- it does not implement, so the log says so at every start. Returns true when
-- it warned.
function M._warn_debug_overrides(cfg)
	local c = cfg and cfg.config
	if not c then return false end
	local caps  = type(c.debug_caps) == "table" and next(c.debug_caps) ~= nil
	local extra = type(c.debug_payload_extra) == "table" and next(c.debug_payload_extra) ~= nil
	if not (caps or extra) then return false end
	local parts = {}
	if caps then
		for _, k in ipairs({"fw_caps", "wifi_caps", "wifi_caps2"}) do
			if c.debug_caps[k] ~= nil then
				parts[#parts + 1] = string.format("%s=0x%x", k,
					math.floor(tonumber(c.debug_caps[k]) or 0))
			end
		end
	end
	if extra then
		local keys = {}
		for k in pairs(c.debug_payload_extra) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		parts[#parts + 1] = "extra payload fields: " .. table.concat(keys, ", ")
	end
	io.stderr:write(
		"openuf: DEBUG OVERRIDES ACTIVE (openuf.debug caps / local.json debug_payload_extra):\n" ..
		"openuf:   " .. table.concat(parts, "; ") .. "\n" ..
		"openuf: the controller is being told about capabilities this device does\n" ..
		"openuf: not implement. For protocol experiments only -- unset when done.\n")
	return true
end

-- Summarize the keys in a config blob that no pass recognized.
--
-- Emits key PREFIXES and counts only, never values: these blobs carry
-- aaa.<n>.wpa.psk and mgmt_cfg's authkey, and this goes to the log.
-- Numeric indices are collapsed to <n> so a four-VAP blob reports one line
-- per key shape rather than one per instance.
function M._report_dropped_keys(label, raw, recognized)
	if type(raw) ~= "string" then return end
	local counts, order, total, sample = {}, {}, 0, {}
	for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
		-- Skip blanks and the literal comment a radio-less blob carries
		-- ("# no wlan provisioned as no radio found").
		if line ~= "" and not line:match("^%s*#") then
			local k = line:match("^([^=]+)=")
			if k then
				local known = false
				for _, pat in ipairs(recognized) do
					if k:match(pat) then known = true break end
				end
				if not known then
					local prefix = k:gsub("%.%d+%.", ".<n>."):gsub("%.%d+$", ".<n>")
					if not counts[prefix] then
						counts[prefix] = 0
						order[#order + 1] = prefix
						sample[prefix] = {k, line:match("^[^=]+=(.*)$")}
					end
					counts[prefix] = counts[prefix] + 1
					total = total + 1
				end
			end
		end
	end
	if total == 0 then return end
	table.sort(order)
	-- The ledger (unhandled.lua) always gets one row per key shape, with the
	-- first key and its value redacted by name; the log line stays behind the
	-- debug gate and never carries values.
	for _, p in ipairs(order) do
		M._ledger(label, p, {
			sample      = sample[p][1],
			value       = M._unhandled and M._unhandled.redact(sample[p][2], sample[p][1]),
			occurrences = counts[p],
		})
	end
	if not M._debug_dropped_keys then return end
	local parts = {}
	for _, p in ipairs(order) do parts[#parts + 1] = p .. " x" .. counts[p] end
	io.stderr:write(("inform: %s: %d dropped key(s): %s\n")
		:format(label, total, table.concat(parts, ", ")))
end

-- ─── Unhandled-surface ledger ────────────────────────────────────────────────

-- A controller-supplied name as one short log token: no newline can forge a
-- second log line, and a huge string can't flood the log.
function M._log_token(name)
	return (tostring(name):sub(1, 48):gsub("[^%w%-_.]", "?"))
end

-- An unhandled cmd or _type is also logged by name with its ledger count, so
-- a new request shows up in logread without reading unhandled.json (before
-- this an unknown cmd left the same "cmd: X" line as a handled one; upstream
-- 20a8613). A response with no _type at all is ledgered but not logged.
local LOGGED_CATEGORIES = {cmd = "cmd", response = "_type"}

-- pcall'd: the ledger is a diagnostic and must never cost a heartbeat.
function M._ledger(category, key, payload)
	if not M._unhandled then return end
	local ok, e = pcall(M._unhandled.record, category, key, payload)
	if not ok then
		io.stderr:write("inform: unhandled ledger: " .. tostring(e) .. "\n")
		return
	end
	local kind = LOGGED_CATEGORIES[category]
	if kind and key ~= "nil" and type(e) == "table" then
		io.stderr:write(("inform: unhandled %s '%s' (%d seen) -- ignored\n")
			:format(kind, M._log_token(key), e.count or 0))
	end
end

function M._note_unknown_fields(resp)
	local known = type(resp) == "table" and recognized.KNOWN_TOP_FIELDS[resp._type]
	if not known then return end
	for k, v in pairs(resp) do
		if not known[k] then
			M._ledger("field", tostring(resp._type) .. "." .. tostring(k), {[tostring(k)] = v})
		end
	end
end

-- How many times a config push that failed to apply is asked for again.
M.CFG_RETRIES = 2

-- Judge a config push once every apply step has run.
--
-- The controller re-pushes only while the device reports a cfgversion other
-- than the one it expects -- cfgversion_effective is displayed, never acted
-- on -- and it deduplicates identical pushes for ten minutes. So a push that
-- errored reports the PREVIOUS cfgversion, and the controller sends it again
-- once that window has passed; after CFG_RETRIES such rounds the new version
-- is echoed anyway, so a config this device cannot apply stops cycling.
-- cfgversion_effective always names the last push that applied clean, which
-- is what the controller's last_config_applied_successfully is computed from.
-- The very first push (nothing ever applied) is never held back: adoption
-- must complete.
-- pushed: the cfgversion this push's mgmt_cfg carried. It is assigned here,
-- after the apply, and never before: a push that raises half-way must leave
-- the old version reported (and saved), so the controller sends it again.
function M._settle_cfgversion(st, cfg, cfg_before, ok, pushed)
	if pushed then st.cfgversion = pushed end
	local new = st.cfgversion
	if ok then
		st.cfgversion_effective = new
		st.cfg_retry = nil
		return true
	end
	local limit = tonumber(cfg and cfg.config and cfg.config.cfg_retries) or M.CFG_RETRIES
	local r = type(st.cfg_retry) == "table" and st.cfg_retry.v == new and st.cfg_retry or {v = new, n = 0}
	r.n = r.n + 1
	st.cfg_retry = r
	if st.cfgversion_effective == nil or cfg_before == nil or cfg_before == new or r.n > limit then
		io.stderr:write(("inform: config %s did not apply cleanly -- reporting it as received "
			.. "(cfgversion_effective stays %s)\n"):format(tostring(new), tostring(st.cfgversion_effective)))
		return false
	end
	st.cfgversion = cfg_before
	io.stderr:write(("inform: config %s did not apply cleanly -- still reporting %s so the "
		.. "controller sends it again (attempt %d of %d)\n"):format(tostring(new),
		tostring(cfg_before), r.n, limit))
	return false
end

-- ─── Response dispatcher ─────────────────────────────────────────────────────

-- Handle a parsed controller response JSON string.
-- st:  current state table
-- cfg: device configuration (config.lua; optional -- nil in tests, LED
--      control becomes a no-op without cfg.led)
-- Returns true if config was applied (caller should send follow-up inform).
-- The controller's answer, carried out (openwrt/provision.lua) through this
-- module's seams.
function M.handle_response(json_str, st, cfg)
	return provision.handle(M, json_str, st, cfg)
end

-- ─── HTTP POST ───────────────────────────────────────────────────────────────

-- The transport (unifi/http.lua), behind this module's _http_post test seam.
function M.http_post(url, body)
	if M._http_post then
		return M._http_post(url, body)
	end
	return http.post(url, body)
end

-- ─── Main loop ───────────────────────────────────────────────────────────────

-- Populate st.mac / st.ip using announce.lua's get_mac/get_ip helpers.
--
-- announce.lua is also a script: loading it runs its "script entry point"
-- block at the bottom, guarded by `if not OPENUF_TEST_MODE`. Outside of tests
-- that would spawn announce.lua's own *infinite* L2 broadcast loop nested
-- inside inform.lua's own M.run, or -- if the broadcast send errors, as it
-- does e.g. on a docker bridge network that disallows UDP broadcast -- call
-- os.exit(1) and kill the whole inform process before the actual inform loop
-- ever runs. Suppress it for the load (require caches, so there is only one).
function M._populate_net_info(st, cfg)
	local prev_test_mode = OPENUF_TEST_MODE
	OPENUF_TEST_MODE = true
	local ok_ann, announce = pcall(require, "announce")
	OPENUF_TEST_MODE = prev_test_mode
	if not ok_ann then return end

	local iface = cfg and cfg.net and cfg.net.lan_cpueth or "eth1"
	-- The identity MAC (board.lua: the MAC the network already knows the AP
	-- by, because some boards' socket MAC is random per boot). Everything
	-- else -- the bridge pin, LLDP, discovery -- follows it.
	local mac_tbl = announce.parse_mac(cfg and cfg.net and cfg.net.identity_mac)
		or announce.get_mac(iface)
	if mac_tbl then
		-- Format as "xx:xx:xx:xx:xx:xx"
		st.mac = string.format("%02x:%02x:%02x:%02x:%02x:%02x",
			mac_tbl[1], mac_tbl[2], mac_tbl[3],
			mac_tbl[4], mac_tbl[5], mac_tbl[6])
	end
	local ip_tbl = announce.get_ip(iface)
	if ip_tbl then
		st.ip = string.format("%d.%d.%d.%d",
			ip_tbl[1], ip_tbl[2], ip_tbl[3], ip_tbl[4])
	end
	-- Without this the payload's top-level hostname fell back to "openUF"
	-- for every device.
	local hostname = announce.get_hostname()
	if hostname then st.hostname = hostname end
	st.netmask = st.ip and M._netmask_of(st.ip) or nil
end

-- The dotted netmask of the interface holding `ip`, from `ip -4 -o addr`.
function M._netmask_of(ip)
	local out = M._run_cmd("ip -4 -o addr show 2>/dev/null") or ""
	local plen = nil
	for a, p in out:gmatch("inet (%d+%.%d+%.%d+%.%d+)/(%d+)") do
		if a == ip then plen = tonumber(p) break end
	end
	if not plen or plen < 0 or plen > 32 then return nil end
	local parts = {}
	for i = 1, 4 do
		local bits = math.max(0, math.min(8, plen - (i - 1) * 8))
		parts[i] = 256 - 2 ^ (8 - bits)
	end
	return string.format("%d.%d.%d.%d", parts[1], parts[2], parts[3], parts[4])
end

-- `uname -m` / `uname -r`, read once.
M._uname = nil
function M._uname_info()
	if M._uname == nil then
		local m = (M._run_cmd("uname -m 2>/dev/null") or ""):match("^%s*(%S+)")
		local r = (M._run_cmd("uname -r 2>/dev/null") or ""):match("^%s*(%S+)")
		M._uname = {machine = m, release = r}
	end
	return M._uname
end

-- What a controller left behind outside state.json, torn down when the
-- device stops being adopted -- a `setdefault` (controller "Forget") or an
-- out-of-process `syswrapper.sh reset-inform`. The l2guard table is kernel
-- state that st.l2guard no longer describes once the reset cleared it, and
-- the nightly 11k-scan cron job would keep asking clients for beacon reports
-- on behalf of a controller that no longer manages the device. Given the
-- loop's state, the controller's noop interval goes too: a failing inform
-- backs off up to that interval, which would slow re-adoption to one attempt
-- per interval. (A setdefault is itself an answer that is not a noop, so the
-- loop is back on the device's own cadence without it.) The pushed timezone
-- and NTP servers stay: they are sane settings for the board either way, and
-- their originals remain stamped in UCI (USAGE § 6).
--
-- UniFi firmware answers setdefault with a factory reset and reboot
-- (`syswrapper.sh restore-default`, firmware-confirmed for 4.0.15, upstream),
-- so a forgotten UAP comes back with no SSID and no VLAN. This reaches that end
-- state for the WiFi without the reboot: the WLANs, VLAN bridges and radio
-- extras (ucihelper.forget), the per-port VLANs, band steering and a
-- switched-off LED too. The controller-owned bridge stays (see
-- ucihelper.forget). prev is the state from BEFORE the reset: the per-port VLAN
-- ledger (dsa_brlan_ports) and led_enabled live only there.
function M._forget_controller(loop, prev, cfg)
	prev = prev or {}
	if loop and loop.base_interval then
		loop.interval = loop.base_interval
		loop.backoff  = loop.interval
	end
	if M._switchvlan then pcall(M._switchvlan.restore, prev, cfg) end
	if M._usteer then pcall(M._usteer.set_enabled, false, cfg, false) end
	if M._ucihelper and M._ucihelper.forget then
		pcall(M._ucihelper.forget)
		M._deny_reloaded()   -- forget ran `wifi reload`
	end
	if prev.led_enabled == false and M._led then pcall(M._led.set_enabled, true) end
	if M._l2guard then pcall(M._l2guard.reconcile, nil, {}) end
	if M._guestguard then pcall(M._guestguard.reconcile, nil) end
	if M._sysconf then pcall(M._sysconf.apply_cron, {enabled = false}) end
	-- A controller that switched Airtime Fairness off no longer does:
	-- mac80211's default (on) comes back.
	if M._airtime then pcall(M._airtime.set_enabled, true) end
end

-- Detects an out-of-process change to the on-disk state file -- written by
-- syswrapper.lua's set-adopt/reset-inform, invoked over SSH as a separate,
-- short-lived process -- and reloads it into the in-memory st table this
-- loop uses. Without this, a long-running inform.lua would never notice a
-- fresh SSH-driven adoption (or a manual reset-inform) and would keep
-- informing with stale credentials until restarted. Also keeps the SSH
-- bootstrap account (if enabled) locked/unlocked to match the reloaded
-- adopted state, and forgets the controller (_forget_controller, with the
-- loop's state `loop`) when the reload turns an adopted device unadopted.
-- Returns the current mtime (unchanged from last_mtime if the file didn't
-- change).
--
-- The daemon's own saves change the file too. Those are not external
-- changes: what this process last wrote (state.last_written) is skipped, so
-- an in-memory field is never replaced by a re-read of itself.
-- The identity fields (IDENTITY) are this run's live readings
-- (_populate_net_info); an external writer (syswrapper's reset-inform,
-- which writes defaults) may not carry them, so the live values stay.
M.IDENTITY = {"mac", "ip", "hostname", "netmask"}
function M._reload_if_changed(st, cfg, last_mtime, loop)
	local mtime = M._state_mtime(M._state._state_file)
	if mtime == nil or mtime == last_mtime then
		return last_mtime
	end
	if M._state.last_written ~= nil and mtime == M._state.last_written then
		return mtime
	end
	local was_adopted = st.adopted
	local prev = {}
	for k, v in pairs(st) do prev[k] = v end
	local live = {}
	for _, k in ipairs(M.IDENTITY) do live[k] = st[k] end
	local fresh = M._state.load()
	for k in pairs(st) do st[k] = nil end
	for k, v in pairs(fresh) do st[k] = v end
	for _, k in ipairs(M.IDENTITY) do
		if live[k] ~= nil then st[k] = live[k] end
	end
	M._sync_bootstrap_account(st.adopted, cfg and cfg.config and cfg.config.bootstrap_adopt_user)
	M._firewall.reconcile(st.blocked_stas)
	M._deny_pending = true
	if was_adopted and not st.adopted then M._forget_controller(loop, prev, cfg) end
	return mtime
end

-- dev.conf.net.lan_cpueth decides the device's IDENTITY, not just which port
-- carries VLANs: its MAC is what the controller keys the adopted device on.
-- Change it on an already-adopted device -- a different board layout, say -- and
-- every inform afterwards arrives under a MAC the controller has no adoption
-- for, so it rejects them (HTTP 400) while the old record sits there going
-- Offline. That is invisible from the device: the daemon is healthy, the
-- config is right, the radios are up, and the log just fills with anonymous
-- 400s. Observed for real when a board-specific model map moved lan_cpueth
-- from the (unused) WAN socket to the LAN trunk, which have different MACs.
-- Returns true when it warned, so this is testable without running the loop.
-- require("uci") comes from libuci-lua, which `lua` does not pull in and which
-- nothing installed until recently. Every ucihelper call is pcall-wrapped --
-- correctly, since a UCI error off-target must not take the inform loop down
-- -- so without the binding the daemon starts, adopts, reports its ethernet
-- ports and its statistics and looks completely healthy, while
-- get_radio_table() returns nothing and radio_table goes out EMPTY. The
-- controller then has no radio to provision a WLAN onto: the push arrives, is
-- accepted, and not one SSID is ever created. Nothing logs, nothing errors,
-- and the controller UI shows the device Connected.
--
-- Startup-only, and deliberately not fatal: a device with no UCI binding still
-- reports statistics usefully, and killing the daemon would lose that too.
-- Returns true when it warned, so this is testable without running the loop.
-- The symptom _warn_identity_change predicts, caught where it actually shows.
-- When dev.conf.net.lan_cpueth changes under an adopted device, every inform
-- afterwards arrives under a MAC the controller has no adoption for, so it
-- rejects them with HTTP 400 while the old record sits there going Offline.
-- That is invisible from the device -- the daemon is healthy, the config is
-- right, the radios are up -- and the log just fills with anonymous 400s.
-- _warn_identity_change needs the PREVIOUS MAC to compare against and fires at
-- startup; this one fires on the symptom itself, once per streak, so the log
-- names the likely cause. Returns true when it warned.
M._warned_400 = false
function M._warn_http_400(err, st, cfg)
	if M._warned_400 or not (st and st.adopted) then return false end
	if not (type(err) == "string" and err:match("^HTTP 400")) then return false end
	M._warned_400 = true
	io.stderr:write(string.format(
		"openuf: the controller rejects every inform with HTTP 400 although this\n" ..
		"openuf: device is adopted. That is what happens when the identity MAC\n" ..
		"openuf: changed underneath an adoption: this run informs as %s off\n" ..
		"openuf: dev.conf.net.lan_cpueth = %s. If the controller adopted a\n" ..
		"openuf: different MAC, Forget the device there and re-adopt, or point\n" ..
		"openuf: lan_cpueth back at the interface it was adopted under.\n",
		tostring(st.mac), tostring(cfg and cfg.net and cfg.net.lan_cpueth)))
	return true
end

function M._warn_missing_uci()
	if package.loaded["uci"] then return false end
	if pcall(require, "uci") then return false end
	io.stderr:write(
		"openuf: the Lua UCI binding is MISSING (require(\"uci\") failed).\n" ..
		"openuf: WiFi provisioning cannot work at all: every radio and WLAN\n" ..
		"openuf: read/write fails silently, the inform payload reports ZERO\n" ..
		"openuf: radios, and the controller has nothing to push a WLAN onto --\n" ..
		"openuf: adoption and statistics still work, so nothing else looks wrong.\n" ..
		"openuf: Fix it with:  apk add libuci-lua\n")
	return true
end

function M._warn_identity_change(prev_mac, st, cfg)
	if not (st and st.adopted and prev_mac and st.mac) then return false end
	if prev_mac == st.mac then return false end
	io.stderr:write(string.format(
		"openuf: IDENTITY MAC CHANGED %s -> %s (dev.conf.net.lan_cpueth = %s).\n" ..
		"openuf: this device was adopted as %s, so the controller will reject\n" ..
		"openuf: informs from %s with HTTP 400 and show the old record Offline.\n" ..
		"openuf: Forget the device in the controller and re-adopt it, or point\n" ..
		"openuf: lan_cpueth back at the interface whose MAC is %s.\n",
		prev_mac, st.mac, tostring(cfg and cfg.net and cfg.net.lan_cpueth),
		prev_mac, st.mac, prev_mac))
	return true
end

-- Make sure a controller-pushed static IP is in UCI at startup.
--
-- The address lives in /etc/config/network (netmodel.apply_addressing), so
-- a reboot keeps it; the controller does not re-push it (cfgversion
-- matches). This converges a device whose state.json says static but whose
-- UCI does not -- one upgraded from a build that applied the address with
-- `ip addr` only -- and is a no-op otherwise (nothing changed, no reload).
--
-- Only ip_mode == "static" acts. On "dhcp", and when IP Settings was never
-- pushed at all, the board's own config is already right.
function M._reapply_static_ip(st, cfg)
	if not st or st.ip_mode ~= "static" or not st.static_ip or not M._netmodel then return false end
	if not (cfg and cfg.net) then return false end
	local lan_if = cfg.net.lan_name or "lan"
	local ok, changed = pcall(M._netmodel.apply_addressing, st, cfg, lan_if,
		{static = {ip = st.static_ip, netmask = st.static_netmask, gateway = st.static_gateway,
			dns = st.static_dns}}, st.ip)
	if not ok then
		io.stderr:write("inform: IP Settings: " .. tostring(changed) .. "\n")
		return false
	end
	if changed then M._state.save(st) end
	return changed and true or false
end

-- Airtime Fairness is debugfs state (openwrt/airtime.lua), back at the
-- kernel's default (on) after every reboot, and the controller does not push
-- it again (cfgversion matches). Reapplied at startup from state.json; nil
-- means never pushed, and the board's default stays. Returns whether it wrote.
-- The LEDs at startup. Kernel state, not UCI: the controller pushes
-- led_enabled with mgmt_cfg and then only on a change, so without this the
-- LED switch forgot itself on every reboot while the controller went on
-- believing it took.
--  1. Hand back an LED the previous, single-LED scheme was holding (led.lua
--     restore_status_leds), once per device, before anything is snapshotted.
--  2. End a Locate: it does not survive a restart, and must not -- nobody is
--     still standing in front of the AP, and unset-locate only comes while
--     someone watches the controller. After a reboot there is nothing to end.
--  3. The switch as last pushed; nil (never pushed) leaves the board alone.
-- Netdev LEDs follow the bridge openUF owns, in UCI and on the running LEDs
-- (netmodel.lua reconcile_leds, led.lua repoint). Run at start, after a new
-- network plan, and after a rollback.
function M._follow_bridge_leds()
	if not M._netmodel then return end
	local ok, changes = pcall(M._netmodel.reconcile_leds)
	if not ok then
		io.stderr:write("inform: LEDs on the bridge: " .. tostring(changes) .. "\n")
		return
	end
	if type(changes) ~= "table" or #changes == 0 then return end
	pcall(M._led.repoint, changes)
	for _, c in ipairs(changes) do
		io.stderr:write(("inform: LED %s follows the bridge: %s -> %s\n")
			:format(tostring(c.sysfs), tostring(c.from), tostring(c.to)))
	end
end

function M._reapply_leds(st, cfg)
	local status_led = cfg and cfg.led
	local dirty = false
	if st.led_scheme ~= 2 then
		if st.led_enabled ~= nil and not M._led.load_baseline() then
			pcall(M._led.restore_status_leds)
		end
		st.led_scheme = 2
		dirty = true
	end
	if st.locating then
		pcall(M._led.locate_stop, status_led, st.led_enabled)
		st.locating = false
		dirty = true
	end
	if dirty then M._state.save(st) end
	if st.led_enabled ~= nil then
		pcall(M._led.set_enabled, st.led_enabled)
	end
end

function M._reapply_airtime(st)
	if not (st and st.atf_enabled ~= nil and M._airtime) then return false end
	pcall(M._airtime.set_enabled, st.atf_enabled)
	return true
end

-- One heartbeat's 802.11k work (openwrt/rrmscan.lua's tick), through this
-- module's seams and the caches it keeps across heartbeats.
function M._rrm_tick(cfg)
	return rrmscan.tick(M, cfg)
end

-- One heartbeat's off-channel scan of idle radios (openwrt/idlescan.lua).
M._idlescan_next = {}
function M._idlescan_tick(cfg)
	local conf = cfg and cfg.config or {}
	local now = M._time()
	local freqs = {}
	if tonumber(conf.sibling_scan_interval) and tonumber(conf.sibling_scan_interval) > 0 then
		local sib = require("openwrt.siblings")
		freqs = sib.decode_freqs(M._sysinfo._read_file(sib.FILE), now, require("cjson"))
	end
	return M._idlescan.tick(M._idlescan_next, now, tonumber(conf.idle_scan_interval),
		{sibling_interval = tonumber(conf.sibling_scan_interval), sibling_freqs = freqs})
end

-- WLAN Schedule (openwrt/wlansched.lua): at most once a minute, whatever the
-- inform interval. The schedule lives on the wifi-iface sections, so a fresh
-- start picks it up on its first heartbeat.
M._wlansched_next = 0
-- A WLAN brought back up has a new netdev: its speed limit (tc) and filters
-- went with the old one, and are rebuilt the way a fresh start does -- but
-- only once the netdev exists, which is some seconds after `wifi reload`
-- returns. Until then the sections wait here, checked every heartbeat; past
-- WLANSCHED_REAPPLY_WAIT the rebuild runs with whatever is up.
M.WLANSCHED_REAPPLY_WAIT = 300
M._wlansched_pending = nil
function M._wlansched_reapply(now)
	local p = M._wlansched_pending
	local u = M._ucihelper
	if not p or not (u and u.reapply_runtime_rules) then return false end
	local all = true
	for _, name in ipairs(p.names) do
		local ok, ifname = pcall(u.ifname_for_section, name)
		if not (ok and ifname) then all = false break end
	end
	if not all and now < p.deadline then return false end
	M._wlansched_pending = nil
	pcall(u.reapply_runtime_rules)
	return true
end

function M._wlansched_tick()
	local now = M._time()
	M._wlansched_reapply(now)
	if now < M._wlansched_next then return 0 end
	M._wlansched_next = now + 60
	local ok, n, up = pcall(M._wlansched.tick)
	if not ok then
		io.stderr:write("inform: WLAN schedule: " .. tostring(n) .. "\n")
		return 0
	end
	if type(up) == "table" and #up > 0 then
		M._wlansched_pending = {names = up, deadline = now + M.WLANSCHED_REAPPLY_WAIT}
	end
	return n
end

-- One heartbeat of the wireless uplink's policy (openwrt/backhaul.lua):
-- wired first, the WDS station only while the wired uplink has no link. A
-- no-op on a device whose push carried no uplink station.
function M._backhaul_tick(st, cfg)
	if not (M._backhaul and M._backhaul.tick) then return nil end
	return M._backhaul.tick(st, cfg, M._ucihelper, M._sysinfo, M._state)
end

-- One heartbeat's Roaming Assistant pass (openwrt/roamassist.lua) over the
-- stations the last build_json observed on vaps that have it on. Consumes
-- them, so a failed or skipped build never replays an old heartbeat's list.
-- Returns the number of actions taken.
function M._roamassist_tick(cfg)
	local obs = M._roam_obs
	M._roam_obs = nil
	if not (M._roamassist and obs and #obs > 0) then return 0 end
	return M._roamassist.tick(obs, M._time(),
		{diff_db = cfg and cfg.config and cfg.config.roam_assist_diff_db,
			locked = M._lockap.here})
end

-- Once a minute: is hostapd's 802.11r key-exchange socket still bound? See
-- openwrt/rrbguard.lua. The night repair window needs a plausible clock
-- (unifi/schedule.sane_clock); without one only the no-clients path repairs.
function M._rrbguard_tick()
	local g = M._rrbguard
	if not (g and g.tick) then return nil end
	local now = M._time()
	local hour = require("unifi.schedule").sane_clock(now) and os.date("*t", now).hour or nil
	return g.tick(now, hour)
end

-- A rate-update into st.sta_rates ({mac = {up = kbps, down = kbps}}), for
-- any client, as the firmware's update_sta_qosrate takes it: a limit of 0
-- or less, or none, is -1, which lifts that client's cap that way even on a
-- limited WLAN. Ignored for a MAC no netdev listed at the last heartbeat,
-- as the firmware ignores one with no association. Returns true when the
-- ledger changed.
function M._sta_rate(st, resp)
	local mac = type(resp.mac) == "string"
		and resp.mac:lower():match("^%s*(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s*$")
	if not mac then return false end
	local obs = M._shape_obs
	if obs and obs.complete and not obs.where[mac] then return false end
	local function kbps(v)
		v = tonumber(v)
		return v and v > 0 and math.floor(v) or -1
	end
	local up, down = kbps(resp.ul_max), kbps(resp.dl_max)
	st.sta_rates = st.sta_rates or {}
	local cur = st.sta_rates[mac]
	if cur and cur.up == up and cur.down == down then return false end
	st.sta_rates[mac] = {up = up, down = down}
	return true
end

-- WiFi Speed Limit (openwrt/shaper.lua), from what the last build_json saw
-- (M._shape_obs): each netdev's stations and its WLAN's limits, with
-- st.sta_rates on top. A rate-update lasts one association, as the
-- firmware's per-station class does: it goes when the client leaves, or when
-- its connected time drops (it reconnected between two heartbeats; the
-- controller sends a fresh one if the client still has a profile of its own).
M._sta_conn = {}
function M._shaper_resync(st)
	local obs = M._shape_obs
	if not (obs and M._shaper) then return false end
	local rates = st.sta_rates or {}
	local changed = false
	if obs.complete then
		for mac in pairs(rates) do
			local now_c, was_c = obs.conn[mac], M._sta_conn[mac]
			if not obs.where[mac] or (now_c and was_c and now_c < was_c) then
				rates[mac] = nil
				changed = true
			end
		end
		M._sta_conn = obs.conn
	end
	local desired = {}
	for ifname, o in pairs(obs.by_ifname) do
		local down = {default = o.down, stas = {}}
		local up = {default = o.up, stas = {}}
		for _, mac in ipairs(o.macs) do
			local r = rates[mac]
			local d, u = o.down, o.up
			-- An own limit replaces the WLAN's; -1 lifts it (0: uncapped).
			if r then
				d = r.down and r.down > 0 and r.down or 0
				u = r.up and r.up > 0 and r.up or 0
			end
			down.stas[mac], up.stas[mac] = d, u
		end
		local any = down.default or up.default
		for _, k in pairs(down.stas) do any = any or (k and k > 0) end
		for _, k in pairs(up.stas) do any = any or (k and k > 0) end
		if any then desired[ifname] = {down = down, up = up} end
	end
	if changed then
		st.sta_rates = next(rates) and rates or nil
		M._state.save(st)
	end
	M._shaper.sync(desired)
	return true
end

-- One heartbeat: build, send, dispatch. Returns the number of seconds the
-- caller should wait before the next one -- 0 means "again, now", the
-- config-applied case, where a real AP re-informs immediately. ctx carries the
-- loop's own state (base_interval, interval, backoff, last_mtime) so run() is
-- nothing but `while true do wait(_tick()) end`, and the error boundaries and
-- the backoff can be exercised without a socket.
--
-- Every stage is pcall-wrapped, and that is the point of the split. build_json
-- shells out to a dozen tools and does arithmetic on their output; one nil in
-- one field takes the whole daemon down, and procd's respawn turns that into a
-- crash loop every five seconds that reports no statistics and logs nothing
-- beyond a traceback. A bad cycle now costs one heartbeat and one log line,
-- and the next cycle gets another go.
-- Where `syswrapper.sh 11k-scan` -- the controller's nightly cron job, see
-- sysconf.lua -- leaves its dated request. Consumed by the next heartbeat;
-- ignored when older than SCAN_REQUEST_MAX_AGE, so a request a stopped daemon
-- never saw does not fire at the next boot, or when dated more than a minute
-- ahead (the clock was stepped back since, and its age is anyone's guess).
M.SCAN_REQUEST_FILE    = "/tmp/openuf-scan-request"
M.SCAN_REQUEST_MAX_AGE = 600

M.UPGRADE_REQUEST_FILE = "/tmp/openuf-upgrade-request"

function M._upgrade_requested()
	local f = io.open(M.UPGRADE_REQUEST_FILE, "r")
	if not f then return false end
	local raw = f:read("*a") or ""
	f:close()
	os.remove(M.UPGRADE_REQUEST_FILE)
	local at = tonumber(raw:match("%d+"))
	return at ~= nil and M._time() - at <= M.SCAN_REQUEST_MAX_AGE
end

function M._scan_requested()
	local f = io.open(M.SCAN_REQUEST_FILE, "r")
	if not f then return false end
	local raw = f:read("*a") or ""
	f:close()
	os.remove(M.SCAN_REQUEST_FILE)
	local at = tonumber(raw:match("%d+"))
	local age = at and (M._time() - at)
	if not age or age < -60 or age > M.SCAN_REQUEST_MAX_AGE then
		io.stderr:write("inform: ignoring a stale 11k-scan request\n")
		return false
	end
	return true
end

-- The loop's heartbeat for the outside world: a flat key=value file rewritten
-- atomically after every cycle. update.sh waits on it to decide whether a
-- freshly installed daemon is alive and talking to the controller before it
-- commits to the new version. tmpfs, so a reboot starts it clean.
M.STATUS_FILE = "/tmp/openuf-status"

-- The build stamp tools/dist.sh leaves next to the code, read once.
M._build = nil
local function build_stamp()
	if M._build == nil then
		local s
		for _, p in ipairs({"BUILD", "src/BUILD", "/usr/share/openuf/BUILD"}) do
			local f = io.open(p, "r")
			if f then s = f:read("*a"); f:close(); break end
		end
		M._build = s and s:match("^%s*(.-)%s*$") or "unknown"
	end
	return M._build
end

-- fields: {last_ok = epoch, last_type = "noop"} on success, or
-- {last_fail = epoch, last_fail_msg = "..."} on a transport failure; the other
-- side's last value is carried forward.
M._status = {}
function M._write_status(st, fields)
	for k, v in pairs(fields) do M._status[k] = v end
	local s = M._status
	local lines = {
		"last_ok="       .. tostring(s.last_ok or 0),
		"last_type="     .. tostring(s.last_type or ""),
		"last_fail="     .. tostring(s.last_fail or 0),
		"last_fail_msg=" .. (tostring(s.last_fail_msg or ""):gsub("[\r\n]", " ")),
		"adopted="       .. tostring(st and st.adopted or false),
		"cfgversion="    .. tostring(st and st.cfgversion or ""),
		"mac="           .. tostring(st and st.mac or ""),
		"inform_url="    .. tostring(st and st.inform_url or ""),
		"build="         .. build_stamp(),
	}
	local tmp = M.STATUS_FILE .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then return false end
	f:write(table.concat(lines, "\n"), "\n")
	f:close()
	return os.rename(tmp, M.STATUS_FILE) and true or false
end

function M._tick(st, cfg, ufhw, ctx)
	-- base_interval is the device's own cadence; interval is what the loop
	-- actually waits, which the controller's noop may have moved.
	ctx.base_interval = ctx.base_interval or ctx.interval or 10
	ctx.interval = ctx.interval or ctx.base_interval
	ctx.backoff  = ctx.backoff  or ctx.interval

	ctx.last_mtime = M._reload_if_changed(st, cfg, ctx.last_mtime, ctx)
	-- attended-sysupgrade update check (config.advertise_updates); never blocks.
	pcall(M._upgrade.tick, M._time(), cfg and cfg.config)
	-- The reported address was read once at startup; a DHCP renumbering or a
	-- controller-driven Management VLAN move changes it underneath. Cheap
	-- enough every five minutes (sysfs reads, no ubus).
	local now = M._time()
	if not ctx.next_netinfo then
		ctx.next_netinfo = now + 300
	elseif now >= ctx.next_netinfo then
		ctx.next_netinfo = now + 300
		pcall(M._populate_net_info, st, cfg)
		if M._netmodel and st.netmodel_applied then
			local ok_r, fixed = pcall(M._netmodel.repair_default_route,
				(cfg and cfg.net and cfg.net.lan_name) or "lan")
			if ok_r and fixed then pcall(M._sysinfo.forget_uplink_cache) end
		end
	end
	-- One ucihelper lookup pass for the resyncs below: several of them ask
	-- netifd for the VAP list on the same tick once a minute, and one
	-- `ubus call network.wireless status` does. begin_pass starts from empty
	-- caches, so a pass a throw left open is never joined, and it is closed
	-- before anything later in the tick can reload the WiFi (upstream
	-- a82fe73; build_json keeps its own pass).
	local ufuci = M._ucihelper
	local uci_pass = ufuci and ufuci.begin_pass and ufuci.end_pass
	if uci_pass then pcall(ufuci.begin_pass) end
	-- The L2 hardening and the guest restrictions follow the VAPs as they
	-- come and go.
	pcall(M._l2guard_resync, st, cfg)
	pcall(M._guest_resync, st, cfg)
	pcall(M._hairpin_resync)
	pcall(M._rrbguard_tick)
	pcall(M._block_resync, st)
	pcall(M._usteer_filter_resync)
	-- Lock to Access Point exemptions (openwrt/lockap.lua).
	pcall(M._lockap.resync, st and st.lock2ap, M._usteer)
	if uci_pass then pcall(ufuci.end_pass) end
	-- With the LED switch off, whatever relights an LED (LuCI saving the LED
	-- page restarts OpenWrt's led service) is undone within a minute. Sysfs
	-- reads only, no fork.
	if st.led_enabled == false and (not ctx.next_led_check or now >= ctx.next_led_check) then
		ctx.next_led_check = now + M.LED_CHECK_INTERVAL
		local ok_l, relit = pcall(M._led.reassert, st.locating and cfg and cfg.led or nil)
		if ok_l and relit > 0 then
			io.stderr:write("inform: " .. relit .. " LED(s) lit while the controller has LEDs off -- dark again\n")
		end
	end
	-- The controller's nightly `syswrapper.sh 11k-scan` (its cron job, see
	-- sysconf.lua): make the next 802.11k beacon request due now.
	if M._scan_requested() then
		io.stderr:write("inform: 11k-scan requested -- asking a client for a beacon report now\n")
		M._rrm_next_request = 0
	end
	-- `syswrapper.sh upgrade <url>` over SSH: the same hand-off as an inform
	-- `upgrade` (upgrade.lua) -- the URL itself is never fetched.
	if M._upgrade_requested() then
		local conf = cfg and cfg.config
		local ok_u, started, why = pcall(M._upgrade.start, conf)
		io.stderr:write("inform: SSH upgrade requested -- "
			.. ((ok_u and started) and "owut upgrade started"
				or ("not upgrading: " .. tostring(ok_u and why or started))) .. "\n")
	end
	-- Before build_json, so anything a client reported since the last cycle
	-- rides out on THIS inform rather than waiting for the next.
	pcall(M._rrm_tick, cfg)
	pcall(M._idlescan_tick, cfg)
	pcall(M._backhaul_tick, st, cfg)
	pcall(M._wlansched_tick)

	-- A quick-scan the controller has now seen in progress: queue its sweep.
	-- One chunk of whatever sweep is queued then runs before this payload is
	-- built, and the quick-scan is over on the tick that ran its last chunk:
	-- that inform carries the results and `quickscan_scanning` false -- the
	-- controller files the tables of exactly that inform.
	local qs_due = M._quickscan_pending
	if qs_due and qs_due.reported and not qs_due.queued then
		qs_due.queued = true
		local ok_s, err_s = pcall(provision.spectrum_sweep, M, "quick-scan", qs_due.band)
		if not ok_s then
			io.stderr:write("inform: quick-scan sweep failed: " .. tostring(err_s) .. "\n")
		end
	end
	local ok_c, err_c = pcall(provision.sweep_tick, M, M._time())
	if not ok_c then
		io.stderr:write("inform: sweep chunk failed: " .. tostring(err_c) .. "\n")
	end
	if qs_due and qs_due.queued and M._quickscan_pending == qs_due
		and not provision.sweep_active(M, "quick-scan") then
		M._quickscan_pending = nil
	end
	-- What this payload reports as quickscan_scanning (report.lua reads it).
	local qs_sent = M._quickscan_pending

	local ok_b, json_str = pcall(M.build_json, st, cfg, ufhw)
	-- build_json opens a ucihelper lookup pass and closes it on its normal
	-- return; an error skips that close, and a stale pass would then feed
	-- handle_response's own lookups pre-reload interface names.
	if M._ucihelper and M._ucihelper.end_pass then pcall(M._ucihelper.end_pass) end
	if M._sysinfo and M._sysinfo.end_pass then pcall(M._sysinfo.end_pass) end
	if not ok_b then
		io.stderr:write("inform: build_json failed: " .. tostring(json_str) .. "\n")
		-- No inform goes out on this path either: the rollback window is
		-- judged like any other tick, or a plan that broke the payload
		-- would never be rolled back.
		if M._netmodel_check(st, cfg, false) == "rolled_back" then return 5 end
		return ctx.interval
	end
	-- Roaming Assistant acts on the stations that payload just read.
	pcall(M._roamassist_tick, cfg)
	-- WiFi Speed Limit, on the stations that payload just listed.
	local ok_sh, err_sh = pcall(M._shaper_resync, st)
	if not ok_sh then io.stderr:write("inform: shaper: " .. tostring(err_sh) .. "\n") end

	-- Client connection events (staevents.lua): queue whatever changed since
	-- the last heartbeat; they go out after this inform succeeds. Roam
	-- reports come from hostapd's and the bridge's events (_roam_poll), and
	-- the heartbeat's stations tell them who is here.
	M._roam_fast = st.adopted == true and not (cfg and cfg.config and cfg.config.sta_events == false)
	M._roam_st, M._roam_cfg = st, cfg
	if M._roam_fast then
		pcall(M._staevents.roam_observe, M._last_here_obs or {},
			M._last_identity and M._last_identity.uptime)
		pcall(M._roam_poll)
	else
		-- Nobody reads the fdb log then: keep it from growing.
		pcall(M._staphase.drain_fdb)
	end
	if st.adopted and not (cfg and cfg.config and cfg.config.sta_events == false) then
		-- The DHCP/DNS timing table (dnswatch.lua), re-created every few
		-- minutes in case a reboot or a flush took it.
		local now = M._time()
		if M._dnswatch and now >= (M._dnswatch_next or 0) then
			M._dnswatch_next = now + 300
			pcall(M._dnswatch.ensure)
		end
		-- Each connection's timeline: hostapd's steps (the phases collector)
		-- and the first DHCP ACK and DNS answer.
		local ok_ph, phases = pcall(function()
			local doc = M._staphase.read()
			if not doc then return nil end
			return M._staphase.collect(doc, M._dnswatch.firsts(), M._last_vap_by_ifname)
		end)
		pcall(M._staevents.observe, M._last_sta_snapshot or {}, now,
			M._last_identity and M._last_identity.uptime, ok_ph and phases or nil)
	end

	local ok_p, pkt = pcall(M.build_packet, json_str, st)  -- use_gcm read from st.use_gcm
	if not ok_p then
		io.stderr:write("inform: build_packet failed: " .. tostring(pkt) .. "\n")
		-- No inform went out: the controller was not reached, and a network
		-- plan's rollback window is judged on this tick like any other.
		if M._netmodel_check(st, cfg, false) == "rolled_back" then return 5 end
		return ctx.interval
	end

	local dump_tx = cfg and cfg.config and cfg.config.debug_dump_requests
	if dump_tx then M._debug_append(cfg, "TX", json_str) end
	local body, err = M.http_post(st.inform_url, pkt)
	if not body then
		if dump_tx then M._debug_append(cfg, "ERR", tostring(err)) end
		if M._netmodel_check(st, cfg, false) == "rolled_back" then
			-- The previous network is back: try again shortly rather than
			-- sitting out the backoff the failed plan built up.
			ctx.backoff = ctx.interval
			return 5
		end
		-- A pending device is SUPPOSED to get 404: the controller files it as
		-- pending on the first inform and answers 404 until someone clicks
		-- Adopt. Backing off doubled the wait for the device to appear and for
		-- the adoption to complete, up to a minute each; real firmware keeps
		-- its normal cadence here.
		if not st.adopted and type(err) == "string" and err:match("^HTTP 404") then
			if not M._logged_pending then
				io.stderr:write("inform: pending adoption (HTTP 404 until adopted in the controller)\n")
				M._logged_pending = true
			end
			-- The controller answered: the daemon is alive and talking to it,
			-- which is what the status file's readers (tools/deploy.sh, LuCI) ask.
			pcall(M._write_status, st, {last_ok = M._time(), last_type = "pending"})
			-- At the device's own cadence: a controller answering 404 is not
			-- pacing it, and whatever one asked for before (an SSH
			-- reset-inform or set-inform lands here) no longer applies.
			ctx.interval = ctx.base_interval
			ctx.backoff = ctx.interval
			return ctx.interval
		end
		io.stderr:write("inform: POST failed: " .. tostring(err) .. "\n")
		pcall(M._write_status, st, {last_fail = M._time(), last_fail_msg = tostring(err)})
		pcall(M._guest_selfrun, st, cfg, false)
		M._warn_http_400(err, st, cfg)
		-- While a network plan's rollback window is open, keep the normal
		-- cadence: the window is judged on these ticks, and a 60 s backoff
		-- would stretch a stranded AP's outage by up to a minute.
		if st.netmodel_pending then
			ctx.backoff = ctx.interval
			return ctx.interval
		end
		-- Doubles from the CURRENT cadence, capped at 60 s -- or at the
		-- controller's own interval when that is longer, since a failure
		-- must never make the device poll faster than it was asked to.
		local cap = math.max(60, ctx.interval)
		if type(err) == "string" and err:match("^HTTP 503") then
			-- "Server is busy" (10.6), and 11.x's inform load shedding
			-- ("in-flight body budget exhausted"): the controller asks for
			-- relief, so straight to the longest wait, not a doubling ramp.
			ctx.backoff = cap
			return ctx.backoff
		end
		ctx.backoff = math.min(math.max(ctx.backoff, ctx.interval) * 2, cap)
		return ctx.backoff
	end
	ctx.backoff = ctx.interval
	M._warned_400 = false
	M._logged_pending = false
	pcall(M._guest_selfrun, st, cfg, true)
	-- The controller has seen this quick-scan in progress: sweep on the next
	-- tick. (A fresh quick-scan in this very answer replaces the table.)
	if qs_sent then qs_sent.reported = true end

	local parse_ok, json_body = pcall(M.parse_packet, body, st)
	if not parse_ok then
		io.stderr:write("inform: parse error: " .. tostring(json_body) .. "\n")
		-- An answer this device cannot decrypt does not prove the management
		-- path, so it must not hold a network plan's rollback off forever.
		if M._netmodel_check(st, cfg, false) == "rolled_back" then return 5 end
		return ctx.interval
	end
	-- The controller answered with something this device can decrypt: the
	-- management path works, which is exactly what confirms a network plan.
	M._netmodel_check(st, cfg, true)

	M._next_interval, M._immediate = nil, false
	local rtype = tostring(json_body):match('"_type"%s*:%s*"([%w_%-]+)"') or "?"
	local ok_h, applied = pcall(M.handle_response, json_body, st, cfg)
	-- Whatever handle_response recorded on the way -- including on the way
	-- to raising -- is written now if the ledger's own policy says so.
	if M._unhandled then pcall(M._unhandled.flush) end
	pcall(M._write_status, st, {last_ok = M._time(), last_type = rtype})
	if not ok_h then
		io.stderr:write("inform: handle_response failed: " .. tostring(applied) .. "\n")
		return ctx.interval
	end
	if st.adopted and M._staevents.pending() > 0 then pcall(M._send_sta_events, st, cfg) end
	-- The controller's own cadence for this device (noop `interval`, which it
	-- raises under load), or the device's own when this answer named none.
	-- The backoff was reset to the old cadence above, before this response
	-- could move it; follow it here too, or the first failure after a drop
	-- would double from the stale, longer value.
	ctx.interval = M._next_interval or ctx.base_interval
	ctx.backoff  = ctx.interval
	-- A due quick-scan sweep starts at once, not a heartbeat later.
	local qs_next = M._quickscan_pending
	if applied or M._immediate or (qs_next and qs_next.reported and not qs_next.queued) then
		-- A config push runs `wifi reload`, which takes every hostapd object
		-- the RRM collector subscribed to away with it and kills the
		-- subscription. That is the one moment the liveness check must not
		-- wait out its interval.
		if applied then M._rrm_collector_next = 0 end
		return 0
	end
	-- A sweep's next chunk comes after SWEEP_CHUNK_GAP, however long the
	-- controller's own interval: its 03:00 sweep waits only 120 s per band
	-- for every AP's flag to clear, and a 5 GHz band is six or seven chunks.
	if M._scan_jobs and #M._scan_jobs > 0 then
		return math.min(ctx.interval, provision.SWEEP_CHUNK_GAP)
	end
	return ctx.interval
end

-- Send queued connection events as notification informs, oldest first, a
-- bounded number per heartbeat. A failed POST keeps the event for the next
-- heartbeat; the controller's answer is a normal response and is handled as one.
function M._send_sta_events(st, cfg)
	local ev = M._staevents
	local sent = 0
	while ev.pending() > 0 and sent < ev.MAX_PER_TICK do
		local ok_j, js = pcall(function()
			return M._fix_empty_arrays(cjson.encode(ev.notif_payload(M._last_identity, ev.peek())))
		end)
		if not ok_j then
			ev.pop()
		else
			local ok_p, pkt = pcall(M.build_packet, js, st)
			if not ok_p then break end
			local body = M.http_post(st.inform_url, pkt)
			if not body then break end
			ev.pop()
			sent = sent + 1
			local ok_parse, jb = pcall(M.parse_packet, body, st)
			if ok_parse then pcall(M.handle_response, jb, st, cfg) end
		end
	end
	return sent
end

-- Feed the vlan_filtering backend's rollback window with the outcome of one
-- inform. A rollback rewrites /etc/config/network, so the cached uplink/bridge
-- lookups and the reported address are refreshed with it.
function M._netmodel_check(st, cfg, ok)
	if not (M._netmodel and st and st.netmodel_pending) then return nil end
	local before = type(st.netmodel_pending) == "table" and st.netmodel_pending.effective_before
	local ok_c, res = pcall(M._netmodel.check, st, ok)
	if not ok_c then
		io.stderr:write("inform: netmodel check: " .. tostring(res) .. "\n")
		return nil
	end
	if res then
		-- A rolled-back plan never took effect: the config it came with is not
		-- the one this device runs.
		if res == "rolled_back" then st.cfgversion_effective = before or nil end
		M._state.save(st)
		if res == "rolled_back" then
			pcall(M._sysinfo.forget_uplink_cache)
			M._follow_bridge_leds()
		end
		pcall(M._netmodel.repair_default_route, (cfg and cfg.net and cfg.net.lan_name) or "lan")
		-- Either way the management address may have moved (a Management
		-- VLAN is a new subnet), and `ip` in the payload is what the
		-- controller shows and connects to.
		pcall(M._populate_net_info, st, cfg)
	end
	return res
end

-- The AP-mode VAP netdevs l2guard protects; empty when wireless is not
-- answering.
function M._l2guard_live_ifnames()
	local ufuci = M._ucihelper
	if not (ufuci and ufuci.ap_ifnames) then return {} end
	local ok, names = pcall(ufuci.ap_ifnames)
	return (ok and type(names) == "table") and names or {}
end

local function same_names(a, b)
	if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

-- Once a minute: if the live VAP list no longer matches the one the l2guard
-- table was built for (an SSID added by a push whose `wifi reload` had not
-- finished, or wireless coming up after the daemon at boot), rebuild. An
-- empty live list is "not answering", never "no VAPs": it leaves the table
-- alone. Returns true when it rebuilt.
M.L2GUARD_RESYNC_INTERVAL = 60
M._l2guard_next = 0
function M._l2guard_resync(st, cfg)
	local g = st and st.l2guard
	if not (M._l2guard and type(g) == "table" and (g.bpdu or g.tagdrop)) then return false end
	if cfg and cfg.config and cfg.config.l2guard == false then return false end
	local now = M._time()
	if now < M._l2guard_next then return false end
	M._l2guard_next = now + M.L2GUARD_RESYNC_INTERVAL
	local names = M._l2guard_live_ifnames()
	if #names == 0 or same_names(names, g.ifnames) then return false end
	io.stderr:write("l2guard: AP interfaces changed (" .. table.concat(names, " ")
		.. ") -- rebuilding\n")
	g.ifnames = names
	M._state.save(st)
	M._l2guard.reconcile(g, names)
	return true
end

-- The live netdevs of the guest WLANs' VAPs, found by SSID; empty when
-- wireless is not answering or none is up yet.
function M._guest_live_ifnames(ssids)
	local ufuci = M._ucihelper
	if not (ufuci and ufuci.ap_ifnames_for_ssids) then return {} end
	local ok, names = pcall(ufuci.ap_ifnames_for_ssids, ssids)
	return (ok and type(names) == "table") and names or {}
end

-- Every hostapd BSS on the device, for a deauth or a deny-ACL entry that must
-- reach a station on whichever SSID it is on. A VLAN netdev folds into its
-- BSS (hostapd has no control socket on it).
function M._bss_ifnames()
	local ufuci = M._ucihelper
	if not (ufuci and ufuci.ap_ifnames) then return {} end
	local ok, names = pcall(ufuci.ap_ifnames)
	if not ok or type(names) ~= "table" then return {} end
	local out, seen = {}, {}
	for _, name in ipairs(names) do
		local bss = ufuci.bss_ifname and ufuci.bss_ifname(name) or name
		if not seen[bss] then
			seen[bss] = true
			out[#out + 1] = bss
		end
	end
	return out
end

-- A block's refusal in hostapd (firewall.deny_sync) is lost whenever hostapd
-- restarts or reloads a BSS. A sync forks a shell, one hostapd_cli per BSS
-- and a grep, so while anything is blocked it runs:
--   - every tick while _deny_pending: set at startup (entries from before a
--     restart get looked at), by a block change and a state reload, and kept
--     by a sync that did not settle (a BSS that did not answer, a change still
--     to read back), until a pass finds nothing left to clean;
--   - on any tick that finds a hostapd control socket replaced (a restart, a
--     BSS rebuilt: firewall.hostapd_sockets, a file read);
--   - every tick for DENY_SETTLE seconds after openUF's own `wifi reload`
--     (_deny_reloaded), which lands asynchronously and can reload a BSS in
--     place, keeping its socket;
--   - and otherwise every DENY_INTERVAL seconds, the bound on a reload in
--     place that openUF did not run (LuCI, a `wifi reload` by hand). Until
--     then the client can associate, and the nft drop still stops its traffic.
M._deny_pending = true
M.DENY_INTERVAL = 60
M.DENY_SETTLE   = 60
M._deny_at, M._deny_socks, M._deny_settle = nil, nil, nil
function M._deny_reloaded()
	M._deny_settle = M._time() + M.DENY_SETTLE
end
function M._block_resync(st)
	local list = st and st.blocked_stas or {}
	if #list == 0 and not M._deny_pending then return false end
	local now = M._time()
	local socks = M._firewall.hostapd_sockets and M._firewall.hostapd_sockets() or nil
	local since = M._deny_at and now - M._deny_at
	local settle = M._deny_settle and M._deny_settle - now
	local due = M._deny_pending or socks ~= M._deny_socks
		or not since or since < 0 or since >= M.DENY_INTERVAL
		-- A clock stepped back must not stretch the window.
		or (settle and settle > 0 and settle <= M.DENY_SETTLE)
	if not due then return false end
	M._deny_at, M._deny_socks = now, socks
	M._deny_pending = M._firewall.deny_sync(list, M._bss_ifnames())
	return true
end


-- Once a minute, as _l2guard_resync: a guest VAP that came up (or went
-- away) after the push rebuilds the guest table. An empty answer leaves it
-- alone. Returns true when it rebuilt.
M._guest_next = 0
function M._guest_resync(st, cfg)
	local g = st and st.guest
	if not (M._guestguard and type(g) == "table" and g.enabled) then return false end
	if cfg and cfg.config and cfg.config.guest_isolation == false then return false end
	local now = M._time()
	if now < M._guest_next then return false end
	M._guest_next = now + M.L2GUARD_RESYNC_INTERVAL
	local names = M._guest_live_ifnames(g.ssids)
	if #names == 0 or same_names(names, g.ifnames) then return false end
	io.stderr:write("guest: guest VAPs changed (" .. table.concat(names, " ") .. ") -- rebuilding\n")
	g.ifnames = names
	M._state.save(st)
	M._guestguard.reconcile(g, names, M._guest_live(st))
	return true
end

-- ─── Guest portal (LAB-VALIDATED UPSTREAM ONLY, unconfirmed on hardware) ────
--
-- guestguard.lua builds the portal into the guest table (st.guest.portal_url
-- set); this keeps the parts that live in the loop: the runtime state the
-- table is built with, and the listener guestportal.lua answers guests on.

-- The portal's runtime state for guestguard.reconcile.
function M._guest_live(st)
	return {macs = M._guest.authorized_macs(st),
		selfrun = M._guest_selfrun_on}
end

-- selfrun_guest_mode (mgmt_cfg, every push): what guests get while the AP
-- runs without its controller, as the UniFi firmware does it (mcad +
-- syswrapper.sh, BZ2 3.9.27-4.0.15, read upstream). Selfrun starts after
-- GUEST_SELFRUN_FAILS informs in a row went unanswered and ends with the
-- first answer; it only matters while the portal is enforced. "pass" (or
-- never told -- only "off" is off) lets every guest through (guestguard's
-- selfrun chain), since nobody could log in meanwhile. "off" takes the guest
-- WLANs off the air until the controller is back; the netdevs are kept in
-- st.guest_vaps_down, so a restart in between still brings them back.
-- Unlike the firmware, the authorized ledger is kept on return: the
-- controller re-authorizes the same guests anyway.
M.GUEST_SELFRUN_FAILS = 3
M._inform_fails = 0
M._guest_selfrun_on = false
M._guest_up_failed = ""
function M._guest_selfrun(st, cfg, contacted)
	M._inform_fails = contacted and 0 or M._inform_fails + 1
	local g = st.guest
	local enforced = type(g) == "table" and g.enabled and g.portal_url ~= nil
		and not (cfg and cfg.config and cfg.config.guest_isolation == false)
	-- WLANs left down before a restart stay down until an answer, rather
	-- than flapping up for the first failures of the new count.
	local selfrun = M._inform_fails >= M.GUEST_SELFRUN_FAILS
		or (st.guest_vaps_down ~= nil and not contacted)
	local mode
	if enforced and selfrun then mode = (st.guest_selfrun == "off") and "off" or "pass" end
	local changed = false
	if mode == "off" and not st.guest_vaps_down then
		local names = M._guest_live_ifnames(g.ssids)
		if #names == 0 then names = g.ifnames or {} end
		for _, n in ipairs(names) do pcall(M._wlansched.set_bss, n, false) end
		st.guest_vaps_down = names
		M._state.save(st)
		io.stderr:write("guestportal: " .. M._inform_fails .. " informs unanswered, "
			.. "selfrun_guest_mode=off -- guest WLANs down (" .. table.concat(names, " ") .. ")\n")
		changed = true
	elseif mode ~= "off" and st.guest_vaps_down then
		-- One whose beacon did not restart (wlansched.set_bss) stays in the
		-- ledger, down, and the next answered inform tries again.
		local up, failed = {}, {}
		for _, n in ipairs(st.guest_vaps_down) do
			-- Already up (a wifi reload recreated it) or gone: nothing to do.
			if M._wlansched.is_up(n) == false then
				local ok, res = pcall(M._wlansched.set_bss, n, true)
				if ok and res then up[#up + 1] = n else failed[#failed + 1] = n end
			end
		end
		if #up > 0 then
			io.stderr:write("guestportal: guest WLANs back up (" .. table.concat(up, " ") .. ")\n")
		end
		-- Said once per set of failures, not on every retry.
		local said = table.concat(failed, " ")
		if #failed > 0 and said ~= M._guest_up_failed then
			io.stderr:write("guestportal: could not put guest WLANs back on the air ("
				.. said .. ") -- retrying at every answer\n")
		end
		M._guest_up_failed = said
		st.guest_vaps_down = (#failed > 0) and failed or nil
		M._state.save(st)
		changed = true
	end
	local pass = mode == "pass"
	if pass ~= M._guest_selfrun_on then
		M._guest_selfrun_on = pass
		io.stderr:write(pass
			and ("guestportal: " .. M._inform_fails .. " informs unanswered, "
				.. "selfrun_guest_mode=pass -- letting guests through\n")
			or "guestportal: controller answered -- guest portal enforced again\n")
		pcall(M._guest_rebuild, st, cfg)
		changed = true
	end
	return changed
end

-- Rebuild the guest table with the current ledger (an authorize-guest).
-- One transaction that replaces the table: no gap.
function M._guest_rebuild(st, cfg)
	local g = st and st.guest
	if not (M._guestguard and type(g) == "table" and g.enabled and g.portal_url) then return false end
	if cfg and cfg.config and cfg.config.guest_isolation == false then return false end
	return M._guestguard.reconcile(g, g.ifnames or {}, M._guest_live(st))
end

-- The listening socket while the portal is enforced (served from _wait),
-- and the last bind error, said once.
M._guest_server = nil
M._guest_listen_err = nil
function M._guest_listen(st, cfg)
	local g = st and st.guest
	local want = type(g) == "table" and g.enabled and g.portal_url ~= nil
		and not (cfg and cfg.config and cfg.config.guest_isolation == false)
	if not want then
		if M._guest_server then M._guest_server:close() end
		M._guest_server, M._guest_listen_err = nil, nil
		return false
	end
	-- Reported as guest_token (report.lua): without one the controller
	-- refuses every portal login on this AP ("Missing Guest Token in
	-- AP[..] during guest authorization"). Its value would key the
	-- encrypted-cookie redirect, which openUF does not claim; the plain
	-- id=/ap= redirect only needs one to exist.
	if type(st.guest_token) ~= "string" then
		st.guest_token = (M._crypto.random_iv(16):gsub(".", function(c)
			return string.format("%02x", c:byte())
		end))
		M._state.save(st)
	end
	if not M._guest_server then
		local ok, server, err = pcall(M._guestportal.listen, require("socket"))
		if ok and server then
			M._guest_server, M._guest_listen_err = server, nil
		else
			local why = tostring(ok and err or server)
			if why ~= M._guest_listen_err then
				io.stderr:write("guestportal: cannot listen on port " .. M._guestportal.PORT .. ": "
					.. why .. " -- unauthorized guests are blocked but not shown the portal\n")
			end
			M._guest_listen_err = why
		end
	end
	return M._guest_server ~= nil
end

-- Whether a station is on one netdev (the portal's ssid= with more than one
-- guest SSID).
M._station_on = function(ifname, mac)
	local p = io.popen("iw dev " .. ifname .. " station get " .. mac .. " 2>/dev/null")
	if not p then return false end
	local out = p:read("*a") or ""
	p:close()
	return out:find("Station", 1, true) ~= nil
end

-- The guest's SSID for the portal's ssid=: the only one, or the one whose
-- VAP has the station.
function M._guest_ssid_for(ssids, mac)
	ssids = ssids or {}
	if #ssids <= 1 then return ssids[1] end
	for _, ssid in ipairs(ssids) do
		for _, n in ipairs(M._guest_live_ifnames({ssid})) do
			if n:match("^[%w%-%._]+$") and M._station_on(n, mac) then return ssid end
		end
	end
	return ssids[1]
end

-- The listener as an extra socket for _wait: {{sock, fn}} or nil.
function M._guest_also(st)
	local server, g = M._guest_server, st and st.guest
	if not (server and type(g) == "table" and g.portal_url) then return nil end
	local ctx = {
		url = g.portal_url, ap = st.mac, now = M._time,
		ssid_for = function(mac) return M._guest_ssid_for(g.ssids, mac) end,
		arp = function() return M._sysinfo._read_file("/proc/net/arp") or "" end,
	}
	return {{sock = server, fn = function()
		local ok, served = pcall(M._guestportal.serve_one, server, ctx)
		return ok and served
	end}}
end

-- Sleep for wait seconds, answering guests on the portal listener meanwhile.
function M._sleep(socket, wait, also)
	local deadline = socket.gettime() + wait
	while also and #also > 0 do
		local left = deadline - socket.gettime()
		if left <= 0 then return end
		local r = socket.select({also[1].sock}, nil, left)
		-- Readable but nothing to accept: do not spin on it.
		if r and r[1] and not also[1].fn() then break end
	end
	local left = deadline - socket.gettime()
	if left > 0 then socket.select(nil, nil, left) end
end

-- Once a minute, independent of the ebtables block: a force-isolated BSS
-- whose bridge port lost its hairpin flag (l2guard.reconcile_hairpin) cuts
-- its clients off from each other, and the reconfigure that causes it can
-- land at any time, not just after a push. Returns the number of flags fixed.
M.HAIRPIN_CHECK_INTERVAL = 60
M._hairpin_next = 0
function M._hairpin_resync()
	if not (M._l2guard and M._l2guard.reconcile_hairpin) then return 0 end
	local now = M._time()
	if now < M._hairpin_next then return 0 end
	M._hairpin_next = now + M.HAIRPIN_CHECK_INTERVAL
	return M._l2guard.reconcile_hairpin()
end

-- Once a minute: keep usteer's AP-to-AP broadcasts off the VAPs
-- (usteer.reconcile_filter) while openUF runs the daemon, rebuilding only when
-- that or the VAP list changed. An empty live list while wanted is "wireless
-- not answering yet" and leaves the table alone. Returns true when it rebuilt.
M.USTEER_FILTER_INTERVAL = 60
M._usteer_filter_next = 0
M._usteer_filter_built = nil
function M._usteer_filter_resync()
	local u = M._usteer
	if not (u and u.reconcile_filter and u.filter_wanted) then return false end
	local now = M._time()
	if now < M._usteer_filter_next then return false end
	M._usteer_filter_next = now + M.USTEER_FILTER_INTERVAL
	local names = {}
	if u.filter_wanted() then
		names = M._l2guard_live_ifnames()
		if #names == 0 then return false end
	end
	local key = table.concat(names, " ")
	if key == M._usteer_filter_built then return false end
	u.reconcile_filter(names)
	M._usteer_filter_built = key
	return true
end

-- A feature switched off in the config (a change reloads the daemon) takes its nft table or cron job with it at startup, instead
-- of leaving the last run's state in place until a reboot. The timezone and
-- NTP servers are the board's own settings and keep their last values.
function M._release_disabled(cfg)
	local c = cfg and cfg.config or {}
	if M._l2guard and c.l2guard == false then
		pcall(M._l2guard.reconcile, nil)
	end
	if M._guestguard and c.guest_isolation == false then
		pcall(M._guestguard.reconcile, nil)
	end
	if M._dnswatch and c.sta_events == false then
		pcall(M._dnswatch.remove)
	end
	if M._sysconf and not M._sysconf.enabled(c.controller_system, "cron") then
		pcall(M._sysconf.apply_cron, {enabled = false})
	end
end

-- The options that change what a controller push does on this device. The
-- controller only pushes when the device reports a cfgversion it does not
-- expect, so a changed setting would otherwise wait for the next unrelated
-- change in the controller: when one of these differs from the last run (a
-- settings change restarts the daemon), the cfgversion is forgotten and the
-- controller sends its whole configuration again. The first run only records.
M.PROVISION_OPTIONS = {"use_only_unifi_wlan", "own_config", "bridge_backend", "bridge_takeover",
	"bridge_name", "port_default", "country_override", "l2guard", "guest_isolation",
	"system_timezone", "system_ntp", "system_cron", "wireless_uplink"}
-- The same for this code: a release that changes what a push writes bumps it,
-- so an adopted device upgraded to that release has the controller send its
-- configuration again, rather than keeping the old output until an unrelated
-- change in the controller. A signature recorded before it existed differs too.
--   2: vendor_elements (the sibling-AP element) on every VAP
--   3: the upstream sync of 2026-09-27:
--      - Roaming Assistant (wifi_caps2 0x20 claimed: openuf_roam_assist
--        stamp, 802.11k/v forced on, usteer running); usteer
--        band_steering_interval replaces the inert band_steering_threshold,
--        and the AP's own Band Steering (wifi_caps 0xC) can turn it on
--      - radio_caps2 0x2 claimed: a WPA3-only WLAN's push now carries 802.11r
--      - radio_caps2 0x8 claimed: Enhanced Open WLANs are written
--        (encryption=owe, owe_transition=1)
--      - Airtime Fairness (atf.mode -> mac80211 airtime_flags, wifi_caps
--        0x20)
--      - Private Pre-Shared Keys (wifi_caps 0x100000 claimed: a wifi-station
--        per key, a wifi-vlan per key VLAN, dynamic_vlan=1)
M.PROVISION_GENERATION = 3
-- A value as a stable string: tables with their keys sorted, recursively.
local function stable(v)
	if type(v) ~= "table" then return tostring(v) end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local out = {}
	for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. ":" .. stable(v[k]) end
	return "{" .. table.concat(out, ",") .. "}"
end

-- Besides the options: the board's radio policy (dev.conf.radio: htmode cap
-- and floor, DFS, Auto's channel list -- what rf_config writes from) and the
-- radios it reports (hwassign). Changed in LuCI, either has to reach UCI,
-- and only a fresh push writes radios.
function M._provision_signature(cfg)
	local c = cfg and cfg.config or {}
	local parts = {"generation=" .. M.PROVISION_GENERATION}
	for _, k in ipairs(M.PROVISION_OPTIONS) do parts[#parts + 1] = k .. "=" .. tostring(c[k]) end
	parts[#parts + 1] = "radio=" .. stable(cfg and cfg.radio)
	parts[#parts + 1] = "hwassign=" .. stable(cfg and cfg.hwassign)
	return table.concat(parts, ";")
end
function M._reprovision_on_settings_change(st, cfg)
	local sig = M._provision_signature(cfg)
	if st.provision_sig == sig then return false end
	local changed = st.provision_sig ~= nil and st.adopted
	if changed then
		st.cfgversion = ""
		io.stderr:write("openuf: settings or provisioning changed; asking the controller for its configuration again\n")
	end
	st.provision_sig = sig
	M._state.save(st)
	return changed
end

function M.run(cfg, ufhw)
	local st = state.load()
	M._warn_debug_overrides(cfg)
	pcall(M._reprovision_on_settings_change, st, cfg)
	-- A network plan applied right before a restart gets a fresh rollback
	-- window measured from now.
	if M._netmodel then pcall(M._netmodel.on_start, st) end
	M._follow_bridge_leds()
	M._reapply_static_ip(st, cfg)
	-- The MAC persisted by the previous run, before _populate_net_info
	-- overwrites it with the live one read off dev.conf.net.lan_cpueth.
	local prev_mac = st.mac
	M._populate_net_info(st, cfg)
	M._warn_identity_change(prev_mac, st, cfg)
	M._warn_missing_uci()
	-- Identity and reported address must come off the same netdev. openUF takes
	-- the MAC from lan_cpueth and the IP from the bridge that port is enslaved
	-- to, which only agree when the two share a MAC -- true on every swconfig
	-- board, false on DSA, where the gateway then flags an IP conflict between
	-- the AP and itself. Reconciled once, here, before the first inform carries
	-- the mismatch. pcall'd for the same reason reapply_runtime_rules is: this
	-- reaches UCI and sysfs, and a board where either is missing must still
	-- start and report statistics.
	if M._ucihelper and M._ucihelper.ensure_bridge_identity then
		local ok_id, err_id = pcall(M._ucihelper.ensure_bridge_identity, cfg)
		if not ok_id then
			io.stderr:write("inform: could not reconcile bridge identity: "
				.. tostring(err_id) .. "\n")
		elseif err_id then
			-- It changed UCI; netifd has to be told, and nothing else at
			-- startup consumes _network_dirty (apply_config's reload only runs
			-- on a setparam, which may be many minutes away or never).
			M._ucihelper._network_dirty = false
			pcall(M._ucihelper.keep_dhcp_address,
				(cfg and cfg.net and cfg.net.lan_name) or "lan", st.ip)
			M._sysinfo._run_cmd("/etc/init.d/network reload 2>/dev/null")
			M._populate_net_info(st, cfg)  -- the address may have moved with it
		end
	end
	-- LLDP's chassis ID must be the identity MAC (ucihelper.ensure_lldp_identity).
	if M._ucihelper and M._ucihelper.ensure_lldp_identity then
		local ok_l, net_c, lldp_c = pcall(M._ucihelper.ensure_lldp_identity, cfg)
		if ok_l then
			if net_c then
				M._ucihelper._network_dirty = false
				pcall(M._ucihelper.keep_dhcp_address,
					(cfg and cfg.net and cfg.net.lan_name) or "lan", st.ip)
				M._sysinfo._run_cmd("/etc/init.d/network reload 2>/dev/null")
				M._populate_net_info(st, cfg)
			end
			if net_c or lldp_c then
				M._sysinfo._run_cmd("/etc/init.d/lldpd restart 2>/dev/null")
			end
		end
	end
	-- A default route netifd holds but the kernel lost (netmodel.lua).
	if M._netmodel and st.netmodel_applied then
		pcall(M._netmodel.repair_default_route, (cfg and cfg.net and cfg.net.lan_name) or "lan")
	end
	M._sync_bootstrap_account(st.adopted, cfg and cfg.config and cfg.config.bootstrap_adopt_user)
	-- Blocked-client nft rules are live kernel state, not persisted UCI --
	-- reapply from state.json on every fresh start (mirrors the bootstrap
	-- account reconciliation just above).
	M._firewall.reconcile(st.blocked_stas)
	M._deny_pending = true
	-- Same category, one level out: the "Multicast and Broadcast Blocker" is an
	-- nftables ruleset, so it dies with the reboot, and has no UCI option
	-- OpenWrt itself applies. It is only ever built inside apply_config, which
	-- runs on a setparam -- and after a reboot there is no setparam: cfgversion
	-- matches on the first inform and the controller replies noop, carrying no
	-- system_cfg at all. It therefore stayed off indefinitely while the UI
	-- showed it on. Rebuilt here from the openuf_bcfilt options wlan_add stamps
	-- onto each managed section. (The WiFi Speed Limit is rebuilt by every
	-- heartbeat's _shaper_resync from openuf_ratelimit_*.)
	--
	-- pcall'd because it reaches ubus for each VAP's live netdev name: no
	-- radios, no wifi up yet, no ubus at all are ordinary outcomes on a board
	-- openUF has never provisioned, and none of them may stop the daemon.
	if M._ucihelper and M._ucihelper.reapply_runtime_rules then
		local ok_rt, err_rt = pcall(M._ucihelper.reapply_runtime_rules)
		if not ok_rt then
			io.stderr:write("inform: could not reapply the blocker rules: "
				.. tostring(err_rt) .. "\n")
		end
	end
	M._reapply_leds(st, cfg)
	M._reapply_airtime(st)
	-- nftables state does not survive a reboot, so the per-socket MAC tap is
	-- reinstalled here from the UCI sections that record which sockets have
	-- learning off -- the same discipline _firewall.reconcile uses for the
	-- blocklist. A tap that is not reinstalled fails silently, as an empty
	-- mac_table, which is the bug it exists to fix.
	if M._switchvlan then pcall(M._switchvlan.reconcile_mac_taps) end
	-- Features switched off in the config drop what they installed.
	M._release_disabled(cfg)
	-- The controller's ebtables hardening (l2guard) is nft state as well:
	-- rebuilt on the live VAPs, or on the names recorded at the last push
	-- while wireless is not answering yet; _l2guard_resync corrects the list
	-- once it is.
	if M._l2guard and type(st.l2guard) == "table"
		and not (cfg and cfg.config and cfg.config.l2guard == false) then
		pcall(function()
			local names = M._l2guard_live_ifnames()
			if #names == 0 and type(st.l2guard.ifnames) == "table" then names = st.l2guard.ifnames end
			M._l2guard.reconcile(st.l2guard, names)
		end)
	end
	-- The guest restrictions likewise, on the guest VAPs live now or last.
	if M._guestguard and type(st.guest) == "table" and st.guest.enabled
		and not (cfg and cfg.config and cfg.config.guest_isolation == false) then
		pcall(function()
			local names = M._guest_live_ifnames(st.guest.ssids)
			if #names == 0 and type(st.guest.ifnames) == "table" then names = st.guest.ifnames end
			M._guestguard.reconcile(st.guest, names, M._guest_live(st))
		end)
	end
	-- The unhandled ledger carries its counts across restarts.
	if M._unhandled then
		local uf = cfg and cfg.config and cfg.config.unhandled_file
		if uf ~= nil then M._unhandled._file = uf end
		local ok_u, err_u = pcall(M._unhandled.load)
		if not ok_u then io.stderr:write("inform: unhandled ledger: " .. tostring(err_u) .. "\n") end
	end

	local ctx = {
		interval   = 10,
		backoff    = 10,
		last_mtime = M._state_mtime(M._state._state_file),
	}
	while true do M._cycle(st, cfg, ufhw, ctx) end
end

-- Injectable for tests.
M._collectgarbage = collectgarbage

-- One heartbeat, then a full collection, then the wait. Each tick builds a
-- payload, parses the controller's answer and reads most of /proc and the
-- driver's tables, then drops all of it. Left to the default pause the heap
-- doubles before a cycle runs, and the process keeps the pages it grew into.
-- Upstream measured collecting here on its two boards over 30 min each
-- (2026-10-17): inform's RssAnon 3068 -> 2378 kB and 3882 -> 3030 kB, the peak
-- about 1 MB lower, total CPU unchanged.
function M._cycle(st, cfg, ufhw, ctx)
	local wait = M._loop_once(st, cfg, ufhw, ctx)
	M._collectgarbage("collect")
	M._wait(st, cfg, wait)
end

-- One turn of the loop: the tick, or -- when it raises -- a logged error and
-- a backed-off wait. A raising tick must not end the process: procd would
-- restart it, and a restart forgets nothing on disk but restarts the clock
-- of everything kept in memory, the network plan's rollback check among
-- them (it is judged per tick against netmodel_pending's deadline).
M.TICK_ERROR_WAIT_MAX = 60
function M._loop_once(st, cfg, ufhw, ctx)
	local ok, wait = pcall(M._tick, st, cfg, ufhw, ctx)
	if ok and type(wait) == "number" then
		ctx.tick_errors = 0
		return wait
	end
	ctx.tick_errors = (ctx.tick_errors or 0) + 1
	io.stderr:write("inform: tick failed: " .. tostring(wait) .. "\n")
	-- The rollback deadline is still checked on a failed tick.
	pcall(M._netmodel_check, st, cfg, false)
	return math.min(M.TICK_ERROR_WAIT_MAX, 5 * 2 ^ math.min(ctx.tick_errors - 1, 4))
end

-- Sleep until the next inform is due -- or until the controller asks for one
-- over the STUN channel, whichever comes first. The client follows the
-- stun_url the controller last pushed; config.stun = false turns it off.
M._stun_client = nil
function M._wait(st, cfg, wait)
	local socket = require("socket")
	-- Until a mgmt_cfg has named it, the controller's STUN service is assumed
	-- where UniFi puts it: the inform host, port 3478. The pushed URL wins as
	-- soon as one arrives (a device upgraded in place would otherwise wait for
	-- the next config change to get its wake-up channel back).
	local url = st.stun_url
	if not url and type(st.inform_url) == "string" then
		local host = st.inform_url:match("^%a+://%[?([^%]/:]+)")
		if host then url = "stun://" .. host .. ":3478/" end
	end
	local want = st.adopted and url
		and not (cfg and cfg.config and cfg.config.stun == false) and M._stun or nil
	if M._stun_client and (not want or M._stun_client.url ~= url) then
		M._stun_client:close()
		M._stun_client = nil
	end
	if want and not M._stun_client then
		local port = tonumber(cfg and cfg.config and cfg.config.stun_local_port) or 3478
		local ok, c = pcall(M._stun.new, url, port)
		M._stun_client = ok and c or nil
	end
	pcall(M._guest_listen, st, cfg)
	if wait <= 0 then return false end
	-- The guest portal's listener (guestportal.lua) is answered inside the
	-- same wait.
	local also = M._guest_also(st)
	local function step(w)
		if not M._stun_client then
			M._sleep(socket, w, also)
			return false
		end
		local ok, woke = pcall(M._stun_client.wait, M._stun_client, w, socket.gettime, also)
		if not ok then
			io.stderr:write("inform: stun: " .. tostring(woke) .. "\n")
			M._stun_client:close()
			M._stun_client = nil
			return false
		end
		if woke then io.stderr:write("inform: stun: the controller asked for an inform\n") end
		return woke
	end
	if not M._roam_fast then return step(wait) end
	-- Roam reports: look at the collector every ROAM_POLL_S.
	local deadline = socket.gettime() + wait
	while true do
		local left = deadline - socket.gettime()
		if left <= 0 then return false end
		if step(math.min(left, M.ROAM_POLL_S)) then return true end
		pcall(M._roam_poll)
	end
end

-- The idle wait's look at the collector between heartbeats (staevents.lua
-- roam reports): anything new is ingested now, and a roam report it produced
-- is sent now. Returns how many reports were queued.
function M._roam_poll()
	local ev, ph = M._staevents, M._staphase
	local evs, top = ev.parse_roam_log(ph.read_roam(), M._roam_seq)
	M._roam_seq = top
	evs = ev.merge_events(evs, ev.parse_fdb_log(ph.drain_fdb()))
	if #evs == 0 then return 0 end
	local now = M._time()
	local n = ev.roam_ingest(evs, M._last_vap_by_ifname, function(mac)
		return M._lockap.departure_cause(mac, now, ev, M._roamassist)
	end)
	local st = M._roam_st
	if n > 0 and st and st.adopted and M._last_identity then
		pcall(M._send_sta_events, st, M._roam_cfg)
	end
	return n
end

-- ─── Script entry point ───────────────────────────────────────────────────────

if not OPENUF_TEST_MODE then
	local ok, err = pcall(function()
		-- Settings come from UCI (/etc/config/openuf; config.lua), the board
		-- from board.lua.
		local dev, config = require("config").load()
		-- state_file and inform_url: the paths every entry point agrees on.
		-- inform_url is only the DEFAULT: an adopted device keeps whatever the
		-- controller assigned it in state.json.
		if type(config.state_file) == "string" and config.state_file ~= "" then
			M._state._state_file = config.state_file
		end
		if type(config.inform_url) == "string" and config.inform_url ~= "" then
			M._state.DEFAULT_INFORM_URL = config.inform_url
		end
		local ufhw = {uap = dev.identity}
		-- The options travel under dev.conf.config: every consumer reads
		-- cfg.config.<option>.
		dev.conf.config = config
		M.run(dev.conf, ufhw)
	end)
	if not ok then
		io.stderr:write("inform: " .. tostring(err) .. "\n")
		os.exit(1)
	end
end

return M
