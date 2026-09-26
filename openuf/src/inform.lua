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
local netmodel  = require("openwrt.netmodel")
local stun      = require("unifi.stun")
local upgrade   = require("openwrt.upgrade")
local unhandled = require("unifi.unhandled")
local sysconf   = require("openwrt.sysconf")
local l2guard   = require("openwrt.l2guard")
local staevents = require("unifi.staevents")
local dnswatch  = require("openwrt.dnswatch")
local http      = require("unifi.http")
local wire      = require("unifi.wire")
local wlan      = require("unifi.wlan")
local ports     = require("unifi.ports")
local country   = require("unifi.country")
local payload   = require("unifi.payload")
local report    = require("openwrt.report")

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
M._netmodel   = netmodel
-- netmodel stops a lease-releasing DHCP client before its reloads.
netmodel._stop_releasing_dhcp_client = ucihelper.stop_releasing_dhcp_client
M._stun       = stun
M._upgrade    = upgrade
M._unhandled  = unhandled
M._sysconf    = sysconf
M._l2guard    = l2guard
M._staevents  = staevents
M._dnswatch   = dnswatch

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
-- keep the Environment tab honest, not to poll.
M.RRM_REQUEST_INTERVAL = 600

-- How often the background collector is checked for life. That check forks
-- `pgrep -f`, and ran on every 10-second heartbeat -- but the subscription
-- only dies when one of the hostapd objects it named goes away, which is a
-- config push, not a ten-second event. _tick re-arms it immediately after a
-- config IS applied (see M._rrm_collector_next), so recovery stays instant
-- exactly where it matters and the steady state costs nothing.
M.RRM_COLLECTOR_CHECK_INTERVAL = 60
M._rrm_collector_next = 0

-- Matches rrmscan.merge_into's own cutoff, which exists because the
-- controller's rogue-AP ingestion silently drops any entry with age >= 30.
local RRM_MAX_AGE = 30

-- In-memory only (not persisted to state.json): per-radio spectrum-scan
-- results, keyed by radio name. Ephemeral live data, same category as
-- radio_stats()/sta_table() which are also recomputed rather than stored.
M._spectrum_cache = {}

-- In-memory only: previous {rx_bytes, tx_bytes, time} sample per client MAC,
-- used to delta-sample a throughput estimate the same way M._sysinfo's
-- cpu_percent() delta-samples /proc/stat between calls (first sample for a
-- given MAC has no prior delta, so throughput is reported as 0 that time).
M._sta_stats_cache = {}
-- ...and how long an unseen station stays in it. See the sweep in build_json.
M.STA_STATS_FORGET_AFTER = 600

-- Injectable: override in tests to control elapsed time deterministically
-- (used by the sta_table throughput delta-sample below).
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

-- Locks or unlocks the temporary SSH bootstrap account (option ssh_adopt,
-- config.lua's bootstrap_adopt_user, and USAGE.md's SSH prerequisite section) to match
-- the device's current adopted state. No-op if user is nil/false (feature
-- not enabled). Idempotent -- locking an already-locked account (or
-- unlocking an already-unlocked one) is a harmless no-op on BusyBox/shadow
-- passwd, so callers never need to track prior state themselves.
-- The account's password is public, so TCP forwarding is off for as long as
-- it is usable (hook/ssh-forwarding.sh), in the same command as the unlock.
M.SSH_FORWARDING_HOOK = "/usr/share/openuf/hook/ssh-forwarding.sh"
function M._sync_bootstrap_account(adopted, user)
	if not user then return end
	if adopted then
		M._run_cmd("passwd -l '" .. user .. "'; sh " .. M.SSH_FORWARDING_HOOK .. " restore")
	else
		M._run_cmd("sh " .. M.SSH_FORWARDING_HOOK .. " lock; passwd -u '" .. user .. "'")
	end
end

-- Injectable: override in tests to skip real HTTP
M._http_post = nil

-- The TNBU packet itself (unifi/packet.lua), with this module's crypto seam.
local packet = require("unifi.packet")
local is_mac, is_hex32 = wire.is_mac, wire.is_hex32
function M.build_packet(json_str, st) return packet.build(json_str, st, M._crypto) end
function M.parse_packet(raw, st) return packet.parse(raw, st, M._crypto) end

M._fix_empty_arrays = payload.fix_empty_arrays

-- IPv4 address of the inform URL's host (unifi/http.lua), cached for five
-- minutes so a heartbeat costs no DNS round trip.
M._inform_ip_cache = {}
function M._inform_ip(url)
	return http.inform_ip(url, M._time(), M._inform_ip_cache)
end

-- The sys_stats block (unifi/payload.lua).
M._sys_stats = payload.sys_stats

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

-- ─── Dropped-key visibility ──────────────────────────────────────────────────

-- Key shapes some pass in openUF actually reads. Everything else in a config
-- blob is dropped on the floor.
--
-- Until 2026-07-18 that included macacl.* and qos.vap.* -- two whole features
-- sitting in every capture, unnoticed for months, because no tokenizer here
-- has an `else` branch and nothing ever counted what fell through. This list
-- plus _report_dropped_keys() is the missing feedback loop.
--
-- The keys openUF drops ON PURPOSE (switch.*, qos.if.*, qos.ebt.*, vlan.*,
-- bridge.*, mcastrate, cwm.mode, pmf.cipher, mac_acl.* and the other decoys)
-- are deliberately NOT listed here: they show up in the report, which is the
-- honest picture of what is ignored. Each one's reasoning is in
-- PROTOCOL-VALIDATION.md's `system_cfg` section.
local RECOGNIZED_SYSTEM_CFG = {
	"^aaa%.%d+%.",       -- per-SSID security
	"^wireless%.%d+%.",  -- per-SSID radio binding and behavior
	"^radio%.%d+%.",     -- per-radio config
	"^stamgr%.%d+%.",    -- Minimum RSSI
	"^macacl%.%d+%.",    -- MAC Address Filter
	"^qos%.vap%.%d+%.",  -- WiFi Speed Limit
	"^netconf%.1%.",     -- IP Settings
	"^route%.1%.gateway$",
	"^dhcpc%.1%.",
	"^resolv%.nameserver%.%d+%.ip$",
	"^resolv%.host%.1%.name$",
	-- Per-port VLAN. Deliberately narrow: switch.dot1x.status and
	-- switch.jumboframes are in every capture and openUF implements neither,
	-- so they stay in the dropped-key report rather than being whitelisted
	-- along with the block they share a prefix with.
	"^switch%.status$",
	"^switch%.vlan%.status$",
	"^switch%.vlan%.%d+%.",
	"^switch%.port%.%d+%.",
	-- The L2 model the vlan_filtering backend renders (netmodel.lua).
	"^bridge%.",
	"^vlan%.%d+%.",
	"^netconf%.%d+%.",
	"^dhcpc%.%d+%.",
	-- Controller-managed system settings (sysconf.lua). cron.<n>.user is
	-- deliberately NOT here: the pushed account does not exist and the jobs
	-- run as root, so the key stays in the ledger as ignored.
	"^system%.timezone$",
	"^locale%.timezone$",
	"^ntpclient%.status$",
	"^ntpclient%.%d+%.",
	"^cron%.status$",
	"^cron%.%d+%.status$",
	"^cron%.%d+%.job%.%d+%.",
	-- The ebtables hardening block (l2guard.lua).
	"^ebtables%.status$",
	"^ebtables%.%d+%.cmd$",
}

local RECOGNIZED_MGMT_CFG = {
	"^inform_url$", "^use_aes_gcm$", "^cfgversion$", "^led_enabled$", "^authkey$",
	"^stun_url$",
}

-- Set from handle_response when cfg.config.debug_dump_file is on -- the
-- dropped-key report is a diagnostic for exactly the same workflow (diffing
-- full captures against what openUF acts on), so it shares that gate rather
-- than adding a second knob.
M._debug_dropped_keys = false

-- Ceiling for that dump. It is append-only and the inform loop writes to it
-- every few seconds, so left on it grows without bound -- and its usual home
-- is /tmp, which on these boards is a RAM disk. Measured on an Archer C5 after
-- five weeks: 31.7 MB, 55% of a 59 MB tmpfs, on course to starve state.json
-- writes and apk alike. Past the cap the file RESTARTS rather than rotating:
-- keeping a second generation would double the peak footprint on exactly the
-- boards least able to afford it, and a capture is read from its tail anyway.
-- Override per device with config.debug_dump_max_bytes; 0 disables the cap.
M.DEBUG_DUMP_MAX_BYTES = 4 * 1024 * 1024

-- Appends one line -- UTC timestamp, an optional direction tag, the text -- to
-- cfg.config.debug_dump_file. Responses are written with NO tag, the shape
-- every capture recipe expects; with debug_dump_requests set, what openUF
-- SENDS ("TX") and transport failures ("ERR") are written too, tagged so they
-- can be filtered. Append mode already positions at the end, so seek reports
-- the size -- no stat binding needed. Returns true when a line was written.
function M._debug_append(cfg, tag, text)
	local path = cfg and cfg.config and cfg.config.debug_dump_file
	if not path then return false end
	local cap = cfg.config.debug_dump_max_bytes
	if cap == nil then cap = M.DEBUG_DUMP_MAX_BYTES end
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
		"openuf: DEBUG OVERRIDES ACTIVE (local.lua debug_caps / debug_payload_extra):\n" ..
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

-- Every response _type the controller sends and the top-level fields openUF
-- reads on the ones that carry any. Anything else goes to unhandled.lua's
-- ledger (/etc/openuf/unhandled.json) with its body, always -- that file is
-- how a new controller verb gets noticed.
local KNOWN_TYPES = {
	noop = true, setparam = true, cmd = true, upgrade = true, reboot = true,
	setdefault = true,
}
local KNOWN_TOP_FIELDS = {
	noop     = {_type = true, interval = true, immediate = true, server_time_in_utc = true,
	            live_update = true, include_blocks = true, exclude_blocks = true,
	            fingerprint = true},
	setparam = {_type = true, mgmt_cfg = true, system_cfg = true, cfgversion = true,
	            server_time_in_utc = true, blocked_sta = true, include_blocks = true},
}
-- Commands with a handler below; everything else is ledgered with its body.
local KNOWN_CMDS = {
	["set-locate"] = true, ["unset-locate"] = true, ["block-sta"] = true,
	["unblock-sta"] = true, ["kick-sta"] = true, ["spectrum-scan"] = true,
	["quick-scan"] = true,
}

-- pcall'd: the ledger is a diagnostic and must never cost a heartbeat.
function M._ledger(category, key, payload)
	if not M._unhandled then return end
	local ok, err = pcall(M._unhandled.record, category, key, payload)
	if not ok then
		io.stderr:write("inform: unhandled ledger: " .. tostring(err) .. "\n")
	end
end

function M._note_unknown_fields(resp)
	local known = type(resp) == "table" and KNOWN_TOP_FIELDS[resp._type]
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
function M._settle_cfgversion(st, cfg, cfg_before, ok)
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
function M.handle_response(json_str, st, cfg)
	-- Tracks the config rather than latching on: a caller that stops passing
	-- debug_dump_file stops getting dropped-key reports too.
	M._debug_dropped_keys = not not (cfg and cfg.config and cfg.config.debug_dump_file)

	-- Untagged: the line shape every documented grep recipe expects.
	M._debug_append(cfg, nil, json_str)

	local ok, resp = pcall(cjson.decode, json_str)
	if not ok or type(resp) ~= "table" then
		return false
	end

	local _type = resp._type
	if not KNOWN_TYPES[_type] then
		M._ledger("response", tostring(_type), resp)
	end
	M._note_unknown_fields(resp)

	if _type == "noop" then
		-- The controller's next-inform interval for this device and its "come
		-- back now" flag. Bounded: a garbled value must not park the daemon.
		local iv = tonumber(resp.interval)
		if iv and iv >= 1 and iv <= 300 then M._next_interval = iv end
		if resp.immediate == true then M._immediate = true end
		return false
	end

	if _type == "setparam" then
		-- mgmt_cfg is a newline-delimited key=value string (real controller format,
		-- confirmed by amd989/unifi-gateway _parse_mgmt_cfg).
		local mgmt_raw = resp.mgmt_cfg
		local newly_adopted = false
		-- What this push is judged on (M._settle_cfgversion): the version we
		-- reported before it, and whether every apply step ran clean.
		local cfg_before = st.cfgversion
		local apply_ok = true
		if type(mgmt_raw) == "string" then
			for line in (mgmt_raw .. "\n"):gmatch("([^\n]*)\n") do
				local k, v = line:match("^([^=]+)=(.*)$")
				if k and v then
					if k == "inform_url" then
						-- NOT "mgmt_url" -- confirmed live against a real controller
						-- (2026-07-14) that mgmt_url is the web UI deep link
						-- (https://host:8443/manage/site/default), a completely
						-- different endpoint from the actual inform target.
						-- Aliasing the two here previously made the device
						-- overwrite its own working inform_url with the UI link on
						-- the very next routine setparam cycle after adoption,
						-- breaking the inform loop for good (http-only builds have
						-- no luasec, so switching to that https URL is fatal).
						if v ~= "" then st.inform_url = v end
					elseif k == "stun_url" then
						-- The controller's STUN service, where the device keeps the
						-- binding the controller wakes it through (stun.lua).
						if v ~= "" then st.stun_url = v end
					elseif k == "use_aes_gcm" then
						st.use_gcm = (v == "true")
					elseif k == "cfgversion" then
						if v ~= "" then st.cfgversion = v end
					elseif k == "led_enabled" then
						local enabled = (v == "true")
						st.led_enabled = enabled
						M._led.set_enabled(cfg and cfg.led, enabled)
					elseif k == "authkey" then
						-- Only trusted pre-adoption. Real L3 adoption has no SSH
						-- step at all (controller logs "skip SSH adoption" for
						-- L3-discovered devices) and delivers the new key this
						-- way instead -- confirmed against amd989/unifi-gateway's
						-- _parse_mgmt_cfg (which does exactly this, no SSH
						-- anywhere in that codebase) and live testing against a
						-- real controller. See PROTOCOL-VALIDATION.md. Restricted
						-- to the unadopted case: while unadopted the device is
						-- still using the well-known DEFAULT_KEY, so this
						-- exchange carries no less confidentiality than the rest
						-- of L3 provisioning already assumes. Once adopted, only
						-- SSH set-adopt may rotate the key (matches real L2
						-- hardware behavior).
						if not st.adopted and is_hex32(v) then
							st.authkey = v
							st.adopted = true
							newly_adopted = true
						elseif st.adopted and is_hex32(v) and v ~= st.authkey
							and st.authkey ~= M._state.DEFAULT_KEY then
							-- A rotation. This setparam decrypted under the
							-- current, secret key, so it is authenticated in a
							-- way the default-key adoption exchange is not; the
							-- controller pushes a new key whenever the one an
							-- inform arrived under differs from its x_authkey,
							-- and refusing it leaves the device on a key the
							-- controller may stop trying.
							st.authkey = v
							newly_adopted = true   -- re-inform now, under the new key
						end
					end
				end
			end
		end

		-- IP Settings (DHCP vs Static, in the real controller UI) arrive via
		-- system_cfg, not mgmt_cfg -- a separate flat OpenWrt-UCI-style
		-- key=value blob, confirmed live against a real controller (see
		-- PROTOCOL-VALIDATION.md). Only present when the controller is
		-- actually pushing a network-config change, not on every inform.
		M._report_dropped_keys("mgmt_cfg", mgmt_raw, RECOGNIZED_MGMT_CFG)

		-- blocked_sta: the site's COMPLETE blocked-client list, newline-joined,
		-- carried by the provisioning push on every (re)connect and by every
		-- full config. It is authoritative -- block-sta/unblock-sta are only
		-- the live deltas -- so a block or unblock issued while this AP was
		-- offline, or lost with state.json, converges here. Absent means
		-- "not part of this push", never "unblock everyone".
		if type(resp.blocked_sta) == "string" then
			local list, seen = {}, {}
			for mac in resp.blocked_sta:gmatch("[^%s,]+") do
				mac = mac:lower()
				if is_mac(mac) and not seen[mac] then
					seen[mac] = true
					list[#list + 1] = mac
				end
			end
			table.sort(list)
			local before = {}
			for _, m in ipairs(st.blocked_stas or {}) do before[tostring(m):lower()] = true end
			local same = true
			for _, m in ipairs(list) do if not before[m] then same = false end end
			local n_before = 0
			for _ in pairs(before) do n_before = n_before + 1 end
			if n_before ~= #list then same = false end
			if not same then
				st.blocked_stas = list
				M._state.save(st)
				M._firewall.reconcile(list)
				local ufuci = M._ucihelper
				for _, m in ipairs(list) do
					if not before[m] and ufuci and ufuci.disconnect_station then
						pcall(ufuci.disconnect_station, m)
					end
				end
			end
		end

		local sys_raw = resp.system_cfg
		if type(sys_raw) == "string" then
			M._report_dropped_keys("system_cfg", sys_raw, RECOGNIZED_SYSTEM_CFG)

			local ip, netmask, gateway
			local dhcp = false
			local device_name
			-- DNS servers, keyed by their wire index so the controller's
			-- ordering (primary/secondary) survives -- resolv.conf's order is
			-- the resolver's preference order, so it is load-bearing. Same
			-- index-keyed-then-sorted treatment as macacl's acl.<k> list.
			local dns_by_idx = {}
			for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
				local k, v = line:match("^([^=]+)=(.*)$")
				if k and v then
					local dns_idx = k:match("^resolv%.nameserver%.(%d+)%.ip$")
					if dns_idx then
						if v ~= "" then dns_by_idx[tonumber(dns_idx)] = v end
					elseif k == "netconf.1.ip" then ip = v
					elseif k == "netconf.1.netmask" then netmask = v
					elseif k == "route.1.gateway" then gateway = v
					elseif k == "dhcpc.1.status" then
						-- Only an enabled-ish value means DHCP. The key's
						-- presence alone used to set dhcp=true, so a
						-- hypothetical dhcpc.1.status=disabled alongside a
						-- netconf.1.ip would have misread a static push as
						-- DHCP and flushed the working static address. Every
						-- capture so far carries =enabled; this is defensive
						-- for the static-mode shape that hasn't been
						-- captured yet.
						dhcp = wire.bool(v) == true
					elseif k == "resolv.host.1.name" then
						-- The controller's own idea of this device's name
						-- (its local network hostname) -- already present
						-- in every capture (e.g. "U6IW" when never
						-- renamed). Reused as the WPS Device Name value
						-- when advertise_ap_name is on, since it's the
						-- only controller-assigned "AP name" string
						-- available on this wire protocol.
						if v ~= "" then device_name = v end
					end
				end
			end
			-- Flatten the index-keyed DNS table into controller order.
			local dns = {}
			do
				local idxs = {}
				for i in pairs(dns_by_idx) do idxs[#idxs + 1] = i end
				table.sort(idxs)
				for _, i in ipairs(idxs) do dns[#dns + 1] = dns_by_idx[i] end
			end

			-- Shape check BEFORE anything is recorded or run. These three
			-- values are interpolated into `ip addr` / `ip route` command
			-- lines by netconfig.lua (which refuses them again itself), and
			-- this is what keeps a malformed push out of state.json as well:
			-- with the record written first, a refused apply would still leave
			-- ip_mode=static and a bogus static_ip behind for the DHCP-revert
			-- logic to act on. Feature-detected, so a test double standing in
			-- for netconfig need not carry the validator.
			local ipv4 = M._netconfig.is_ipv4
			if ip and ipv4 and not (ipv4(ip)
					and (netmask == nil or netmask == "" or ipv4(netmask))
					and (gateway == nil or gateway == "" or ipv4(gateway))) then
				io.stderr:write(("inform: ignoring IP Settings push with a malformed "
					.. "address (ip=%q netmask=%q gateway=%q)\n"):format(
					tostring(ip), tostring(netmask), tostring(gateway)))
				ip = nil
			end

			-- The vlan_filtering backend (netmodel.lua): the controller's whole L2
			-- model -- bridges, VLANs, Management VLAN, port matrix, management
			-- addressing -- rendered as UCI on one filtering bridge, taking over
			-- whatever bridge held the sockets before. When it produces a plan
			-- the legacy IP-settings, per-VLAN-bridge and switchvlan passes below
			-- stand aside: they describe a different layout of the same ports.
			local netplan = nil
			-- Set when the controller's network could not be applied: every
			-- pass below that assumes a layout (addressing, the WiFi pass that
			-- attaches VAPs, per-port VLANs) stays out of it, and the push is
			-- not reported as applied.
			local net_blocked = false
			local nm = M._netmodel
			if nm and nm.backend(cfg) == "vlan_filtering" then
				local model = nm.parse(sys_raw)
				if model then
					local s = model.static
					if s and ipv4 and not (ipv4(s.ip or "")
							and (s.netmask == nil or s.netmask == "" or ipv4(s.netmask))
							and (s.gateway == nil or s.gateway == "" or ipv4(s.gateway))) then
						io.stderr:write("inform: netmodel: ignoring a malformed static address\n")
						model.static = nil
					end
					local lan = cfg and cfg.net and cfg.net.lan_cpueth
					local ok_br, br = pcall(M._sysinfo.bridge_of, lan)
					local up = nil
					if ok_br and br then
						local ok_up, u = pcall(M._sysinfo.uplink_bridge_port, br)
						if ok_up then up = u end
					end
					local ok_nm, changed, plan, outcome = pcall(nm.converge, model,
						M._parse_switch_system_cfg(sys_raw), cfg, st,
						{uplink_ifname = up, identity_mac = st.mac, current_ip = st.ip})
					if not ok_nm then
						io.stderr:write("inform: netmodel: " .. tostring(changed) .. "\n")
						apply_ok, net_blocked = false, true
					elseif outcome == "rejected" or outcome == "failed" then
						apply_ok, net_blocked = false, true
					elseif plan then
						netplan = plan
						-- The per-VLAN-bridge ledgers describe a layout that no
						-- longer exists; their restore paths must never run on it.
						st.dsa_brlan_ports, st.swvlan_backup = nil, nil
						st.ip_mode, st.static_ip, st.static_netmask = nil, nil, nil
						st.static_gateway, st.static_dns = nil, nil
						ip = nil   -- addressing is part of the plan, as UCI
						if changed then
							M._sysinfo.forget_uplink_cache()
							-- A new plan is only proven once its rollback window
							-- closes (M._netmodel_check).
							if type(st.netmodel_pending) == "table" then
								st.netmodel_pending.effective_before = st.cfgversion_effective
							end
							M._state.save(st)
						end
					end
				end
			end

			if net_blocked then
				io.stderr:write("inform: the controller's network was not applied; its"
					.. " addressing, WiFi and port settings wait for the next push\n")
				ip = nil
			end

			if ip then
				local iface = cfg and cfg.net and cfg.net.lan_cpueth
				if dhcp then
					-- Only genuinely ACT when reverting our own prior static
					-- config -- a fresh device's first-ever system_cfg (and
					-- every steady-state reaffirmation) also carries
					-- dhcpc.1.status=enabled, but real hardware already runs
					-- its own DHCP client continuously; flushing+re-leasing
					-- on every "still DHCP" push is needless and, worse,
					-- destructive wherever no DHCP server actually exists to
					-- grant a new lease (confirmed live: this validation
					-- container's Docker bridge has none -- udhcpc timed out
					-- and left the interface with no address at all).
					if st.ip_mode == "static" then
						M._netconfig.apply_dhcp(iface)
						M._populate_net_info(st, cfg)  -- re-read the freshly-leased address
					end
					st.ip_mode = "dhcp"
					st.static_ip, st.static_netmask, st.static_gateway = nil, nil, nil
					-- DNS is deliberately NOT touched here: the lease supplies
					-- it, and rewriting resolv.conf on every steady-state "still
					-- DHCP" push would fight the DHCP client for ownership --
					-- the same hazard as the flush+re-lease guarded above.
					st.static_dns = nil
				else
					st.ip_mode = "static"
					st.static_ip, st.static_netmask, st.static_gateway = ip, netmask, gateway
					st.static_dns = (#dns > 0) and dns or nil
					if M._netconfig.apply_static(iface, ip, netmask, gateway, dns) then
						st.ip = ip  -- known directly, no need to re-read the interface
					end
				end
				-- Persisted HERE, not at the end of handle_response.
				--
				-- The interface has already been reconfigured by this point,
				-- and state.json is the only record that it was: M.run's
				-- startup reapply is what puts a static address back after a
				-- reboot, and it reads exactly these fields. Everything
				-- between here and the save at the end of this function --
				-- the WiFi pass, switchvlan, usteer, bcfilter, shaper -- shells
				-- out or reaches into UCI and can raise, and _tick pcalls this
				-- whole function by design, so an error there costs one log
				-- line and nothing else. Leaving the write until the end meant
				-- any such error left the kernel reconfigured and the record
				-- lost, which is precisely the state the reapply cannot
				-- recover from.
				--
				-- Observed exactly that in the validation lab on 2026-09-10:
				-- usteer raised midway, the AP moved to its pushed static
				-- address, and state.json never learned about it.
				M._state.save(st)
			end

			-- Parsed once, out here: the switch pass below needs the vap_table
			-- too (for the VLANs tagged SSIDs sit on), and scoping it inside
			-- the wifi branch left that consumer reading a nil table -- an
			-- empty trunk list that fails silently.
			local radio_table, vap_table = M._parse_wifi_system_cfg(sys_raw)

			-- VLANs that a WIRED port is assigned to. Computed before the
			-- WiFi pass because their L2 is the same bridge a tagged SSID
			-- uses, and apply_config prunes any bridge no WLAN wants --
			-- which would delete the one a per-port assignment is about to
			-- need, on every push, then have switchvlan rebuild it. DSA
			-- only: on swconfig a port VLAN is a switch table entry, not a
			-- bridge. Safe when nothing is pushed (an empty set).
			local port_vlans = {}
			if not netplan and not net_blocked and M._switchvlan and M._switchvlan.dsa_members
				and not (cfg and cfg.vlan and cfg.vlan.ports) then
				local br = M._sysinfo.bridge_of(cfg and cfg.net and cfg.net.lan_cpueth)
				local up = br and M._sysinfo.uplink_bridge_port(br) or nil
				local ok_pv, m = pcall(M._switchvlan.dsa_members,
					M._parse_switch_system_cfg(sys_raw), cfg, up)
				if ok_pv then
					for vid in pairs(m or {}) do port_vlans[vid] = true end
				end
			end

			local ufuci = M._ucihelper
			if ufuci and ufuci.apply_config and not net_blocked then
				if #radio_table > 0 or #vap_table > 0 then
					-- Band Steering (wireless.<n>.no2ghz_oui) is confirmed
					-- live to be a per-WLAN wire field, not a per-device
					-- one -- but usteer (the daemon that actually
					-- implements steering on OpenWrt) is a single
					-- device-wide config, so band steering is treated as
					-- active for the whole device whenever ANY WLAN has it
					-- enabled.
					local steering_active = false
					for _, vap in ipairs(vap_table) do
						if vap.no2ghz_oui then steering_active = true end
					end
					M._usteer.set_enabled(steering_active, cfg)
					local ok_ac, err_ac = pcall(ufuci.apply_config,
						{radio_table = radio_table, vap_table = vap_table, network_table = {}},
						cfg, {band_steering_active = steering_active,
							device_name = device_name, keep_vlans = port_vlans,
							netmodel = netplan})
					if not ok_ac then
						io.stderr:write("inform: WiFi config failed: " .. tostring(err_ac) .. "\n")
						apply_ok = false
					end
				end
			end

			-- Per-port VLAN, after the WiFi pass so that any VLAN interface
			-- ensure_vlan_network() creates for a tagged SSID already exists
			-- before a switch port is put on the same VLAN.
			if M._switchvlan and not netplan and not net_blocked then
				local ok_sv, err_sv = pcall(function()
					-- Every VLAN a tagged SSID lands on. The switch drops
					-- frames for a VID it has no entry for, so these need
					-- trunking whether or not per-port VLAN is in use.
					local wireless_vlans, seen = {}, {}
					for _, vap in ipairs(vap_table or {}) do
						if vap.vlan_enabled and vap.vlan and not seen[vap.vlan] then
							seen[vap.vlan] = true
							wireless_vlans[#wireless_vlans + 1] = vap.vlan
						end
					end
					-- Which socket the uplink cable is in, so a pushed port
					-- VLAN can never be applied to it (see physical_port).
					-- Asked of whichever source this board has: the switch's
					-- ARL table on swconfig, the bridge FDB on DSA.
					local uplink_phys, uplink_ifname = nil, nil
					if cfg and cfg.vlan and cfg.vlan.ports then
						local swst = M._sysinfo.switch_status(cfg.vlan.device)
						uplink_phys = M._sysinfo.uplink_phys_port(swst.arl)
					else
						local br = M._sysinfo.bridge_of(cfg and cfg.net and cfg.net.lan_cpueth)
						if br then uplink_ifname = M._sysinfo.uplink_bridge_port(br) end
					end
					local sw = M._parse_switch_system_cfg(sys_raw)
					-- Turning Port VLAN off does not always announce itself.
					-- The gates were once observed staying on the wire at
					-- =disabled, but a device that has HAD the feature on and
					-- then has it unticked gets a full system_cfg with no
					-- switch.* keys at all -- confirmed live on the AX3000T,
					-- where the teardown therefore never ran and br-lan kept
					-- openUF's port list forever.
					--
					-- So absence counts as off too, but only when openUF holds
					-- a reversibility ledger: that is proof it applied
					-- something, which in turn is proof the controller was
					-- sending switch.* until now. With no ledger there is
					-- nothing to undo and this is a no-op anyway. Safe on a
					-- partial push -- the worst case is a restore to stock
					-- that the next full push re-applies -- and it cannot
					-- flap, since restore() spends the ledger. Reachable only
					-- inside `type(sys_raw) == "string"`, never on a noop.
					local had_applied = st.swvlan_backup ~= nil
						or st.dsa_brlan_ports ~= nil
					if (sw and not sw.enabled) or (sw == nil and had_applied) then
						-- Explicit disable: unticking the device-level "Port
						-- VLAN" box keeps the switch.* block on the wire with
						-- both gates at =disabled (confirmed live -- the
						-- baseline capture carries them that way). Tear our
						-- sections down and put the stock port strings back,
						-- or the switch stays segmented forever after the
						-- user turns the feature off. A blob with no switch.*
						-- lines at all (sw == nil: older controller, partial
						-- push) still leaves everything alone -- restore only
						-- ever runs on an affirmative off signal, and its own
						-- empty-ledger no-op keeps steady-state disabled
						-- pushes free of switch reloads.
						-- ...unless a tagged SSID still needs its VLAN
						-- trunked. restore() puts the stock port strings
						-- back and drops every openuf section, which would
						-- take the wireless trunk with it and silently kill
						-- the IoT WLAN's uplink. apply() reconciles both
						-- concerns in one pass.
						--
						-- That hazard is SWCONFIG-ONLY, and gating on the
						-- wireless VLANs alone got it wrong on DSA: there the
						-- tagged SSID needs no trunk at all and its bridge
						-- belongs to ucihelper, so restore() cannot harm it --
						-- it only hands br-lan its original port list back.
						-- Skipping restore there meant the reversibility
						-- ledger was never spent and br-lan kept the port
						-- ORDER openUF had left it in, so unticking Port VLAN
						-- looked like it had done nothing.
						if (cfg and cfg.vlan and cfg.vlan.ports)
							and #wireless_vlans > 0 then
							M._switchvlan.apply(sw, cfg, st, wireless_vlans,
								uplink_phys, uplink_ifname)
						else
							M._switchvlan.restore(st, cfg)
						end
					else
						M._switchvlan.apply(sw, cfg, st, wireless_vlans,
							uplink_phys, uplink_ifname)
					end
					-- Either branch may have moved a socket into or out of a
					-- VLAN bridge, which is the one thing bridge_of's 300 s TTL
					-- cannot notice on its own.
					M._sysinfo.forget_uplink_cache()
				end)
				if not ok_sv then
					io.stderr:write("inform: per-port VLAN failed: " .. tostring(err_sv) .. "\n")
					apply_ok = false
				end
			end

			-- Controller-managed system settings: timezone, NTP servers and
			-- the nightly `syswrapper.sh 11k-scan` cron job (sysconf.lua),
			-- gated by the system_timezone / system_ntp / system_cron options.
			local gate = cfg and cfg.config and cfg.config.controller_system
			if M._sysconf and gate ~= false then
				local ok_sc, err_sc = pcall(function()
					local sc = M._sysconf.parse(sys_raw)
					if sc then M._sysconf.apply(sc, gate) end
				end)
				if not ok_sc then
					io.stderr:write("inform: system settings failed: " .. tostring(err_sc) .. "\n")
					apply_ok = false
				end
			end

			-- The ebtables.* hardening block (l2guard.lua): BPDU and VLAN-tag
			-- drop on every AP VAP. Kernel state, so the intent and the VAP
			-- names go to state.json for the startup rebuild. After the WiFi
			-- pass on purpose: a VAP the push just added has its netdev by now.
			if M._l2guard and not (cfg and cfg.config and cfg.config.l2guard == false) then
				local ok_l2, err_l2 = pcall(function()
					local eb = M._l2guard.parse(sys_raw)
					if not eb then return end
					for _, u in ipairs(eb.unknown or {}) do
						io.stderr:write("l2guard: unrecognised ebtables rule shape, not applied: "
							.. ("%q"):format(u) .. "\n")
					end
					local spec = M._l2guard.spec_from(eb)
					local names = (M._ucihelper and M._ucihelper.all_vap_ifnames)
						and M._ucihelper.all_vap_ifnames() or {}
					if #names == 0 and st.l2guard and type(st.l2guard.ifnames) == "table" then
						names = st.l2guard.ifnames   -- wireless not answering yet: last known
					end
					spec.ifnames = names
					st.l2guard = spec
					M._l2guard.reconcile(spec, names)
					-- A push lands mid `wifi reload`, before the VAPs exist: try
					-- again on a later heartbeat instead of waiting for the
					-- next push, which may be days away.
					M._l2guard_retry = (#names == 0) and (spec.bpdu or spec.tagdrop) or nil
				end)
				if not ok_l2 then
					io.stderr:write("inform: L2 hardening failed: " .. tostring(err_l2) .. "\n")
					apply_ok = false
				end
			end
		end

		if type(sys_raw) == "string" then
			M._settle_cfgversion(st, cfg, cfg_before, apply_ok)
		end
		M._state.save(st)
		-- Re-inform at once after adopting (new key) and after applying a
		-- config push: the controller holds the device in PROVISIONING until it
		-- sees its cfgversion echoed, and real firmware reports straight back.
		return newly_adopted or type(sys_raw) == "string"
	end

	if _type == "setdefault" then
		-- Controller requested factory reset.  Reset state on disk and in-memory.
		io.stderr:write("inform: controller requested factory reset\n")
		-- mac/ip/hostname are populated once at M.run() startup by
		-- _populate_net_info and never persisted to state.json -- preserve them
		-- across the reset rather than losing the device's identity mid-run.
		local mac, ip, hostname = st.mac, st.ip, st.hostname
		local fresh = M._state.reset()
		for k in pairs(st) do st[k] = nil end
		for k, v in pairs(fresh) do st[k] = v end
		st.mac, st.ip, st.hostname = mac, ip, hostname
		M._sync_bootstrap_account(false, cfg and cfg.config and cfg.config.bootstrap_adopt_user)
		M._firewall.reconcile(st.blocked_stas)
		return false
	end

	if _type == "reboot" then
		io.stderr:write("inform: controller requested reboot\n")
		os.execute("reboot")
		os.exit(0)
	end

	if _type == "upgrade" then
		-- Store only -- never download/verify/flash/reboot. A real controller's
		-- upgrade URL targets genuine Ubiquiti firmware; applying it to this
		-- (non-Ubiquiti) hardware would brick it. See amd989/unifi-gateway,
		-- which handles this identically (log + store, no real upgrade path).
		st.upgrade_requested_version = tostring(resp.version or "")
		st.upgrade_requested_url     = tostring(resp.url or "")
		-- The catalogue version the controller wants this model on, reported
		-- from now on: the controller calls a device upgradable whenever its
		-- version differs from the catalogue's by so much as a character, so a
		-- stale built-in version meant a permanent Upgrade badge (upgrade.lua).
		local wanted = type(resp.version) == "string" and resp.version:match("^%d+%.%d+%.%d+%.%d+$")
		if wanted then st.fw_version = wanted end
		-- config.upgrade_mode = "owut": the controller's upgrade becomes an
		-- attended sysupgrade of THIS board's OpenWrt (upgrade.lua). The UniFi
		-- URL itself is never fetched.
		local conf = cfg and cfg.config
		if conf and conf.upgrade_mode == "owut" then
			local ok_u, started, why = pcall(M._upgrade.start, conf)
			io.stderr:write("inform: upgrade requested -- "
				.. ((ok_u and started) and ("owut upgrade started, log in " .. M._upgrade.LOG_FILE)
					or ("not upgrading: " .. tostring(ok_u and why or started))) .. "\n")
		else
			io.stderr:write("inform: upgrade requested (version=" .. st.upgrade_requested_version
				.. ") -- stored only, not applying\n")
		end
		M._state.save(st)
		return false
	end

	if _type == "cmd" then
		local cmd = resp.cmd or ""
		io.stderr:write("inform: cmd: " .. tostring(cmd) .. "\n")
		if not KNOWN_CMDS[cmd] then M._ledger("cmd", tostring(cmd), resp) end

		if cmd == "set-locate" or cmd == "unset-locate" then
			local led_path = cfg and cfg.led
			if cmd == "set-locate" then
				-- The trigger the LED was on is persisted, not just held in
				-- memory: the controller sends set-locate and unset-locate as
				-- two independent commands with nothing bounding the gap, so
				-- a restart can easily land between them, and only this copy
				-- then knows what to put back. See M.run's startup handling.
				local _, prev = M._led.locate_start(led_path)
				st.locate_prev_trigger = prev
			else
				M._led.locate_stop(led_path, st.locate_prev_trigger)
				st.locate_prev_trigger = nil
				-- Restoring the TRIGGER is not the whole idle state. An LED
				-- whose normal look is "trigger none, brightness on" -- which
				-- is exactly what set_enabled leaves behind, and what a
				-- dedicated status LED like blue:status or green:system sits
				-- at -- comes back from a Locate on trigger none and
				-- brightness 0, i.e. dark. So re-assert the steady state the
				-- operator actually chose, the same way M.run does at
				-- startup. nil means never pushed: leave the board alone.
				if st.led_enabled ~= nil then
					M._led.set_enabled(led_path, st.led_enabled)
				end
			end
			st.locating = (cmd == "set-locate")
			M._state.save(st)
		elseif cmd == "block-sta" or cmd == "unblock-sta" then
			-- One-shot command, confirmed live: block/unblock never appears
			-- as a persistent field on any inform response (a candidate
			-- top-level `include_blocks` list stays empty even while a
			-- client is genuinely blocked) -- the device itself is expected
			-- to remember the block, the same way real hardware would.
			-- Persisted in state.blocked_stas and re-applied at M.run()
			-- startup (M._firewall.reconcile), so it survives a restart.
			local mac = resp.mac
			if type(mac) == "string" then
				st.blocked_stas = st.blocked_stas or {}
				if cmd == "block-sta" then
					local already = false
					for _, m in ipairs(st.blocked_stas) do
						if m == mac then already = true break end
					end
					if not already then
						st.blocked_stas[#st.blocked_stas + 1] = mac
					end
				else
					local kept = {}
					for _, m in ipairs(st.blocked_stas) do
						if m ~= mac then kept[#kept + 1] = m end
					end
					st.blocked_stas = kept
				end
				M._state.save(st)
				M._firewall.reconcile(st.blocked_stas)
				if cmd == "block-sta" then
					-- Kick it immediately if it's currently associated --
					-- the nft drop rule alone stops future traffic, but
					-- doesn't tear down an existing association.
					local ufuci = M._ucihelper
					if ufuci and ufuci.get_radio_table then
						local ok_r, radios = pcall(ufuci.get_radio_table)
						if ok_r then
							local ifnames = {}
							for _, radio in ipairs(radios) do
								local ok_if, ifname = pcall(ufuci.get_ifname_for_radio, radio.name)
								if ok_if and ifname then ifnames[#ifnames + 1] = ifname end
							end
							M._firewall.deauth(mac, ifnames)
						end
					end
				end
			end
		elseif cmd == "kick-sta" then
			-- "Reconnect Client": drop the association, allow it straight back.
			local mac = type(resp.mac) == "string" and resp.mac:lower() or nil
			local ufuci = M._ucihelper
			if is_mac(mac) and ufuci and ufuci.disconnect_station then
				pcall(ufuci.disconnect_station, mac)
			end
		elseif cmd == "spectrum-scan" or cmd == "quick-scan" then
			-- quick-scan is the RF Environment view's own "Scan"; openUF runs
			-- the same sweep for both.
			-- Trigger a scan per radio (sweeps every channel), then read back
			-- per-channel survey data and build a spectrum_table entry per
			-- radio, cached for the next build_json() call.
			--
			-- Field names (spectrum_table/spectrum_table_time/
			-- spectrum_scan_timestamp/channel/center_freq/width/utilization/
			-- interference) are confirmed against the real UniFi Network
			-- Application's own Java bytecode (10.4.57's ace.jar/
			-- internal-dependencies.jar constant pool -- see
			-- PROTOCOL-VALIDATION.md's radio_table_stats reference), not
			-- guessed. The exact numeric semantics of `width` and
			-- `interference` are still a best-effort approximation (radio's
			-- configured htmode, and raw noise-floor dBm, respectively) --
			-- verify against a live controller capture before trusting the
			-- values, not just the key names.
			local ufuci = M._ucihelper
			if ufuci and ufuci.get_radio_table then
				local ok_r, radios = pcall(ufuci.get_radio_table)
				if ok_r then
					local now = os.time()
					for _, radio in ipairs(radios) do
						local ok_if, ifname = pcall(ufuci.get_ifname_for_radio, radio.name)
						if ok_if and ifname then
							-- Survey counters are cumulative and exist
							-- independently of the sweep, so sample them BEFORE
							-- it as well: immediately after a scan the radio has
							-- just come back from off-channel and the OPERATING
							-- channel's noise reads as 0 -- confirmed on real
							-- hardware, where the same channel reports 0 right
							-- after the sweep and -106 dBm moments later. 0 dBm
							-- is not a plausible noise floor, and this value is
							-- reported to the controller as `interference`.
							local pre_noise = {}
							local ok_pre, pre_stats = pcall(M._sysinfo.radio_stats, ifname)
							if ok_pre then
								for _, s in ipairs(pre_stats) do
									if s.freq and s.noise and s.noise ~= 0 then
										pre_noise[s.freq] = s.noise
									end
								end
							end
							ufuci._popen("iw dev " .. ifname .. " scan")
							local ok_rs, stats = pcall(M._sysinfo.radio_stats, ifname)
							if ok_rs then
								local width = wlan.width_from_htmode(radio.ht)
								local table_entries = {}
								for _, s in ipairs(stats) do
									local total = s.channel_time or 0
									local busy  = s.channel_time_busy or 0
									table_entries[#table_entries + 1] = {
										channel     = M._sysinfo.channel_from_freq(s.freq),
										center_freq = s.freq,
										width       = width,
										utilization = total > 0 and math.floor(busy * 100 / total) or 0,
										-- Post-sweep 0 falls back to the
										-- pre-sweep reading for that frequency.
										interference = (s.noise ~= 0 and s.noise)
											or pre_noise[s.freq] or 0,
									}
								end
								M._spectrum_cache[radio.name] = {
									table          = table_entries,
									table_time     = now,
									scan_timestamp = now,
								}
							end
						end
					end
				end
			end
		end
		-- other cmd values (e.g. mfi-output, restart): no-op
		--
		-- Per fxkr/unifi-protocol-reverse-engineering's documented inform
		-- semantics: "Upon receiving a command message, an AP will execute a
		-- command and then send another inform immediately" -- regardless of
		-- which cmd it was, including ones we treat as a no-op. Matches the
		-- cfgversion branch below, which already does this correctly.
		return true
	end

	-- Config update: check cfgversion. WiFi config itself is applied from
	-- system_cfg above, not here -- a real controller never sends the
	-- resp.vap_table/radio_table/network_table JSON this branch used to gate
	-- on, so all that is left to do is record the version we have caught up to.
	if type(resp.cfgversion) == "string" and resp.cfgversion ~= st.cfgversion then
		st.cfgversion = resp.cfgversion
		M._state.save(st)
		return true  -- signal: send follow-up inform immediately
	end

	return false
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
	-- A map may pin the identity MAC (modelmap/auto.lua: the MAC the network
	-- already knows the AP by, because some boards' socket MAC is random per
	-- boot). Everything else -- the bridge pin, LLDP, discovery -- follows it.
	local mac_tbl = (announce.parse_mac and announce.parse_mac(cfg and cfg.net and cfg.net.identity_mac))
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
	-- for every device (the doc comments always claimed hostname was
	-- populated here, but only mac/ip ever were). Feature-detected so an
	-- older announce module without get_hostname degrades to the fallback.
	local hostname = announce.get_hostname and announce.get_hostname()
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

-- Detects an out-of-process change to the on-disk state file -- written by
-- syswrapper.lua's set-adopt/reset-inform, invoked over SSH as a separate,
-- short-lived process -- and reloads it into the in-memory st table this
-- loop uses. Without this, a long-running inform.lua would never notice a
-- fresh SSH-driven adoption (or a manual reset-inform) and would keep
-- informing with stale credentials until restarted. Also keeps the SSH
-- bootstrap account (if enabled) locked/unlocked to match the reloaded
-- adopted state. Returns the current mtime (unchanged from last_mtime if
-- the file didn't change).
function M._reload_if_changed(st, cfg, last_mtime)
	local mtime = M._state_mtime(M._state._state_file)
	if mtime == nil or mtime == last_mtime then
		return last_mtime
	end
	-- mac/ip/hostname are populated once at M.run() startup and never
	-- persisted to state.json -- preserve them across the reload.
	local mac, ip, hostname = st.mac, st.ip, st.hostname
	local fresh = M._state.load()
	for k in pairs(st) do st[k] = nil end
	for k, v in pairs(fresh) do st[k] = v end
	st.mac, st.ip, st.hostname = mac, ip, hostname
	M._sync_bootstrap_account(st.adopted, cfg and cfg.config and cfg.config.bootstrap_adopt_user)
	M._firewall.reconcile(st.blocked_stas)
	return mtime
end

-- dev.conf.net.lan_cpueth decides the device's IDENTITY, not just which port
-- carries VLANs: its MAC is what the controller keys the adopted device on.
-- Change it on an already-adopted device -- switching modelmaps, say -- and
-- every inform afterwards arrives under a MAC the controller has no adoption
-- for, so it rejects them (HTTP 400) while the old record sits there going
-- Offline. That is invisible from the device: the daemon is healthy, the
-- config is right, the radios are up, and the log just fills with anonymous
-- 400s. Observed for real when a board-specific modelmap moved lan_cpueth
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

-- Reapply a controller-pushed static IP at startup.
--
-- A static IP is live kernel state, not UCI: netconfig.apply_static() is
-- `ip addr`/`ip route` only, so the address is gone after a reboot and netifd
-- brings the interface back up on whatever the board's own config says. The
-- controller does not re-push it either -- cfgversion is persisted, so it
-- matches on the first inform and the reply is a noop carrying no system_cfg
-- at all. Without this the device silently returns to DHCP (or to no address)
-- while the controller's IP Settings page goes on showing the static one it
-- assigned. Mirrors the blocked-client and LED reconciliation in M.run.
--
-- Only ip_mode == "static" acts. On "dhcp", and when IP Settings was never
-- pushed at all, the board's own boot config is already right, and flushing
-- the interface to re-lease would be exactly the destructive no-op that the
-- steady-state DHCP push is guarded against (see handle_response).
function M._reapply_static_ip(st, cfg)
	if not st or st.ip_mode ~= "static" or not st.static_ip then return false end
	local iface = cfg and cfg.net and cfg.net.lan_cpueth
	return M._netconfig.apply_static(iface, st.static_ip, st.static_netmask,
		st.static_gateway, st.static_dns) and true or false
end

-- Start the inform heartbeat loop (blocks forever).
-- cfg, ufhw: passed through to build_json()
-- One cycle of the client-assisted enrichment: keep the notification
-- collector alive, fold in whatever clients have reported since last time,
-- expire what the controller would discard anyway, and -- at most every
-- RRM_REQUEST_INTERVAL -- ask one more station to go and look.
--
-- Everything here is pcall-wrapped and best-effort: no hostapd, no ubus, no
-- capable client and no answer are all ordinary outcomes, and none of them may
-- interrupt an inform.
function M._rrm_tick(cfg)
	local rrm = M._rrmscan
	if not rrm then return false end
	if not (cfg and cfg.config and cfg.config.rrm_enrichment) then
		-- Enrichment is off, but a collector from an earlier run with it ON may
		-- still be alive: it is a detached `ubus subscribe` child reparented to
		-- init, so it outlives both the config change and the daemon. Nothing
		-- below this line runs any more, and harvest() is the ONLY thing that
		-- truncates the notification file -- so left alone the child appends to
		-- /tmp/openuf-rrm.jsonl forever with no reader and no cap. /tmp is a
		-- RAM disk on these boards; the debug-dump cap above exists because
		-- 31.7 MB there was measured starving state.json writes and apk.
		--
		-- Rate-limited on the collector's own liveness clock rather than run
		-- every tick: this is a pgrep, and there is nothing to catch between
		-- checks once the child is gone.
		local now = M._time()
		if now >= M._rrm_collector_next then
			M._rrm_collector_next = now + M.RRM_COLLECTOR_CHECK_INTERVAL
			local ok_r, running = pcall(rrm.collector_running)
			if ok_r and running then pcall(rrm.collector_stop) end
		end
		return false
	end

	-- On M._time(), the seam the rest of the timed paths use, so the gate below
	-- is testable. Note this is also the clock the age-out compares against,
	-- and n.seen_at comes from rrmscan's own M._now -- a test that stubs one
	-- must stub the other, or "freshness" is measured between two clocks.
	local now = M._time()
	if now >= M._rrm_collector_next then
		M._rrm_collector_next = now + M.RRM_COLLECTOR_CHECK_INTERVAL
		pcall(rrm.collector_ensure)
	end

	local ok, fresh, reporters = pcall(rrm.harvest)
	if ok then
		-- A station that answered is off the bench, whatever it reported.
		for mac in pairs(reporters or {}) do M._rrm_asked[mac] = nil end
		for _, n in ipairs(fresh or {}) do
			-- Keyed by BSSID so a neighbour two clients both saw is carried
			-- once, at whichever sighting is freshest.
			local prev = M._rrm_cache[n.bssid]
			if not prev or n.seen_at >= prev.seen_at then
				M._rrm_cache[n.bssid] = n
			end
		end
	end

	local live = {}
	for bssid, n in pairs(M._rrm_cache) do
		if now - n.seen_at < RRM_MAX_AGE then
			live[#live + 1] = n
		else
			M._rrm_cache[bssid] = nil
		end
	end
	table.sort(live, function(a, b) return a.bssid < b.bssid end)
	M._rrm_neighbours = live

	if now < M._rrm_next_request then return true end
	M._rrm_next_request = now +
		(tonumber(cfg.config.rrm_request_interval) or M.RRM_REQUEST_INTERVAL)

	-- Round-robin across every capable station on every BSS, one per
	-- interval. Asking them all at once would take every 802.11k-capable
	-- client in the house off-channel simultaneously.
	local cands = {}
	local ok_o, objs = pcall(rrm.hostapd_objects)
	for _, obj in ipairs(ok_o and objs or {}) do
		local ifname = obj:match("^hostapd%.(.+)$")
		local ok_s, stas = pcall(rrm.capable_stations, ifname)
		for _, sta in ipairs(ok_s and stas or {}) do
			local key   = tostring(sta):lower()
			local asked = M._rrm_asked[key]
			local spent = asked and asked.n >= M.RRM_MAX_UNANSWERED
			if spent and (now - asked.at) >= M.RRM_BENCH_SECONDS then
				M._rrm_asked[key] = nil   -- bench over: one more try, clean count
				spent = false
			end
			if not spent then
				cands[#cands + 1] = {ifname = ifname, sta = sta}
			end
		end
	end
	if #cands == 0 then return true end
	M._rrm_rr = (M._rrm_rr % #cands) + 1
	local c = cands[M._rrm_rr]
	local key = tostring(c.sta):lower()
	local asked = M._rrm_asked[key] or {n = 0}
	asked.n, asked.at = asked.n + 1, now
	M._rrm_asked[key] = asked
	if asked.n == M.RRM_MAX_UNANSWERED then
		io.stderr:write(string.format(
			"openuf: rrm: %s on %s advertises beacon measurement but has answered none "
			.. "of %d requests -- not asking again for %d h\n",
			c.sta, c.ifname, asked.n - 1, math.floor(M.RRM_BENCH_SECONDS / 3600)))
	end
	-- The operating class has to be one the CLIENT can measure. Asking every
	-- station for class 115 (5 GHz U-NII-1) works for a dual-band client --
	-- they ignore the band restriction and answer for 2.4 GHz too -- but a
	-- 2.4 GHz-only station answers it with report mode 0x02, "incapable", and
	-- an all-zero BSSID, which is nothing at all. So a station on a 2.4 GHz
	-- BSS is asked for class 81 (2.4 GHz, channels 1-13) instead; the band
	-- comes from that BSS's live channel.
	local op_class = 115
	local ok_c, caps = pcall(M._sysinfo.radio_caps, c.ifname)
	if ok_c and type(caps) == "table" and caps.channel and caps.channel <= 14 then
		op_class = 81
	end
	pcall(rrm.request, c.ifname, c.sta, {op_class = op_class})
	return true
end

-- One heartbeat: build, send, dispatch. Returns the number of seconds the
-- caller should wait before the next one -- 0 means "again, now", the
-- config-applied case, where a real AP re-informs immediately. ctx carries the
-- loop's own state (interval, backoff, last_mtime) so run() is nothing but
-- `while true do wait(_tick()) end`, and the error boundaries and the backoff
-- can be exercised without a socket.
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
-- never saw does not fire at the next boot.
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
	if not at or M._time() - at > M.SCAN_REQUEST_MAX_AGE then
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
	ctx.interval = ctx.interval or 10
	ctx.backoff  = ctx.backoff  or ctx.interval

	ctx.last_mtime = M._reload_if_changed(st, cfg, ctx.last_mtime)
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
	-- The L2 hardening a push could not apply because the VAPs were not up yet.
	if M._l2guard_retry and type(st.l2guard) == "table" then
		pcall(function()
			local names = M._ucihelper.all_vap_ifnames()
			if #names > 0 then
				st.l2guard.ifnames = names
				M._l2guard.reconcile(st.l2guard, names)
				M._state.save(st)
				M._l2guard_retry = nil
			end
		end)
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

	local ok_b, json_str = pcall(M.build_json, st, cfg, ufhw)
	-- build_json opens a ucihelper lookup pass and closes it on its normal
	-- return; an error skips that close, and a stale pass would then feed
	-- handle_response's own lookups pre-reload interface names.
	if M._ucihelper and M._ucihelper.end_pass then pcall(M._ucihelper.end_pass) end
	if M._sysinfo and M._sysinfo.end_pass then pcall(M._sysinfo.end_pass) end
	if not ok_b then
		io.stderr:write("inform: build_json failed: " .. tostring(json_str) .. "\n")
		return ctx.interval
	end

	-- Client connection events (staevents.lua): queue whatever changed since
	-- the last heartbeat; they go out after this inform succeeds.
	if st.adopted and not (cfg and cfg.config and cfg.config.sta_events == false) then
		-- The DNS-answer table (dnswatch.lua), re-created every few minutes
		-- in case a reboot or a flush took it.
		local now = M._time()
		if M._dnswatch and now >= (M._dnswatch_next or 0) then
			M._dnswatch_next = now + 300
			pcall(M._dnswatch.ensure)
		end
		local ok_d, dns = false, nil
		if M._dnswatch then ok_d, dns = pcall(M._dnswatch.seen) end
		pcall(M._staevents.observe, M._last_sta_snapshot or {}, now,
			M._last_identity and M._last_identity.uptime, ok_d and dns or nil)
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
			ctx.backoff = ctx.interval
			return ctx.interval
		end
		io.stderr:write("inform: POST failed: " .. tostring(err) .. "\n")
		pcall(M._write_status, st, {last_fail = M._time(), last_fail_msg = tostring(err)})
		M._warn_http_400(err, st, cfg)
		-- While a network plan's rollback window is open, keep the normal
		-- cadence: the window is judged on these ticks, and a 60 s backoff
		-- would stretch a stranded AP's outage by up to a minute.
		if st.netmodel_pending then
			ctx.backoff = ctx.interval
			return ctx.interval
		end
		ctx.backoff = math.min(ctx.backoff * 2, 60)
		return ctx.backoff
	end
	ctx.backoff = ctx.interval
	M._warned_400 = false
	M._logged_pending = false

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
	if applied or M._immediate then
		-- A config push runs `wifi reload`, which takes every hostapd object
		-- the RRM collector subscribed to away with it and kills the
		-- subscription. That is the one moment the liveness check must not
		-- wait out its interval.
		if applied then M._rrm_collector_next = 0 end
		return 0
	end
	-- The controller's own cadence for this device (noop `interval`), which it
	-- raises under load; ctx.interval only when it named none.
	return M._next_interval or ctx.interval
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
		if res == "rolled_back" then pcall(M._sysinfo.forget_uplink_cache) end
		pcall(M._netmodel.repair_default_route, (cfg and cfg.net and cfg.net.lan_name) or "lan")
		-- Either way the management address may have moved (a Management
		-- VLAN is a new subnet), and `ip` in the payload is what the
		-- controller shows and connects to.
		pcall(M._populate_net_info, st, cfg)
	end
	return res
end

-- A feature switched off in the config (a change reloads the daemon) takes its nft table or cron job with it at startup, instead
-- of leaving the last run's state in place until a reboot. The timezone and
-- NTP servers are the board's own settings and keep their last values.
function M._release_disabled(cfg)
	local c = cfg and cfg.config or {}
	if M._l2guard and c.l2guard == false then
		pcall(M._l2guard.reconcile, nil)
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
	"bridge_name", "port_default", "country_override", "l2guard",
	"system_timezone", "system_ntp", "system_cron"}
function M._provision_signature(cfg)
	local c = cfg and cfg.config or {}
	local parts = {}
	for _, k in ipairs(M.PROVISION_OPTIONS) do parts[#parts + 1] = k .. "=" .. tostring(c[k]) end
	return table.concat(parts, ";")
end
function M._reprovision_on_settings_change(st, cfg)
	local sig = M._provision_signature(cfg)
	if st.provision_sig == sig then return false end
	local changed = st.provision_sig ~= nil and st.adopted
	if changed then
		st.cfgversion = ""
		io.stderr:write("openuf: settings changed; asking the controller for its configuration again\n")
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
	-- Same category, one level out: the "Multicast and Broadcast Blocker" is an
	-- nftables ruleset and the "WiFi Speed Limit" is a tc qdisc, so both die
	-- with the reboot, and neither has a UCI option OpenWrt itself applies.
	-- They are only ever built inside apply_config, which runs on a setparam --
	-- and after a reboot there is no setparam: cfgversion matches on the first
	-- inform and the controller replies noop, carrying no system_cfg at all.
	-- Both controls therefore stayed off indefinitely while the UI showed them
	-- on. Rebuilt here from the openuf_bcfilt/openuf_ratelimit_* options
	-- wlan_add stamps onto each managed section.
	--
	-- pcall'd because it reaches ubus for each VAP's live netdev name: no
	-- radios, no wifi up yet, no ubus at all are ordinary outcomes on a board
	-- openUF has never provisioned, and none of them may stop the daemon.
	if M._ucihelper and M._ucihelper.reapply_runtime_rules then
		local ok_rt, err_rt = pcall(M._ucihelper.reapply_runtime_rules)
		if not ok_rt then
			io.stderr:write("inform: could not reapply blocker/speed-limit rules: "
				.. tostring(err_rt) .. "\n")
		end
	end
	-- A Locate does NOT survive a restart, and must not: it is a transient
	-- "which box is it" blink, nobody is still standing in front of the AP,
	-- and unset-locate only ever arrives while someone is watching the
	-- controller. Left alone the device comes back still blinking with no
	-- snapshot of what the LED was on, and the next unset-locate -- if one
	-- ever comes -- restores nothing. Worse, a second set-locate would
	-- snapshot the blink itself as the thing to restore. Observed exactly
	-- that on an AX3000T, whose radio LED stayed on the identify blink
	-- across three Locate cycles.
	if st.locating then
		-- Only when the LED is really still blinking: a device that REBOOTED
		-- mid-Locate comes back with the kernel's own default trigger already
		-- restored, and "stopping" that would write none over it.
		if M._led.locate_active(cfg and cfg.led) then
			M._led.locate_stop(cfg and cfg.led, st.locate_prev_trigger)
		end
		st.locating = false
		st.locate_prev_trigger = nil
		M._state.save(st)
	end
	-- LED brightness is live kernel state too, not UCI -- the same reason the
	-- blocked-client rules are reapplied above. The controller pushes
	-- led_enabled once, in mgmt_cfg, and never again, so without this the
	-- Manage > LED toggle silently forgets itself on every reboot while the
	-- controller goes on believing it took. Applied AFTER the locate teardown:
	-- if both have something to say, the steady state the operator chose wins
	-- over whatever trigger the blink displaced. nil means it was never
	-- pushed, which must leave the board's own default alone rather than
	-- deciding for it.
	if st.led_enabled ~= nil then
		M._led.set_enabled(cfg and cfg.led, st.led_enabled)
	end
	-- Per-port byte counters are a switch-driver setting that some boards ship
	-- switched off; without it every socket reports 0 B in the Ports view.
	if M._switchvlan then pcall(M._switchvlan.enable_mib_polling, cfg) end
	-- nftables state does not survive a reboot, so the per-socket MAC tap is
	-- reinstalled here from the UCI sections that record which sockets have
	-- learning off -- the same discipline _firewall.reconcile uses for the
	-- blocklist. A tap that is not reinstalled fails silently, as an empty
	-- mac_table, which is the bug it exists to fix.
	if M._switchvlan then pcall(M._switchvlan.reconcile_mac_taps) end
	-- Features switched off in the config drop what they installed.
	M._release_disabled(cfg)
	-- The controller's ebtables hardening (l2guard) is nft state as well.
	if M._l2guard and type(st.l2guard) == "table"
		and not (cfg and cfg.config and cfg.config.l2guard == false) then
		pcall(function()
			local names = M._ucihelper.all_vap_ifnames()
			if #names == 0 and type(st.l2guard.ifnames) == "table" then names = st.l2guard.ifnames end
			M._l2guard.reconcile(st.l2guard, names)
		end)
	end
	-- The unhandled ledger carries its counts across restarts.
	if M._unhandled then
		local uf = cfg and cfg.config and cfg.config.unhandled_file
		if uf ~= nil then M._unhandled._file = uf end
		local ok_u, err_u = pcall(M._unhandled.load)
		if not ok_u then io.stderr:write("inform: unhandled ledger: " .. tostring(err_u) .. "\n") end
	end

	local socket = require("socket")
	local ctx = {
		interval   = 10,
		backoff    = 10,
		last_mtime = M._state_mtime(M._state._state_file),
	}
	while true do
		local wait = M._tick(st, cfg, ufhw, ctx)
		M._wait(st, cfg, wait)
	end
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
	if wait <= 0 then return false end
	if not M._stun_client then
		socket.select(nil, nil, wait)
		return false
	end
	local ok, woke = pcall(M._stun_client.wait, M._stun_client, wait, socket.gettime)
	if not ok then
		io.stderr:write("inform: stun: " .. tostring(woke) .. "\n")
		M._stun_client:close()
		M._stun_client = nil
		return false
	end
	if woke then io.stderr:write("inform: stun: the controller asked for an inform\n") end
	return woke
end

-- ─── Script entry point ───────────────────────────────────────────────────────

if not OPENUF_TEST_MODE then
	local ok, err = pcall(function()
		if not ufpkt then require("loader").run("lib.lib") end
		-- Settings come from UCI (/etc/config/openuf; config.lua), with the
		-- model map it names.
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
		-- Same treatment for the modelmap's UniFi block (dev.openuf.uap): only
		-- dev.conf is passed down, so hwassign is otherwise unreachable from
		-- build_json.
		dev.conf.uap = dev.openuf and dev.openuf.uap
		M.run(dev.conf, ufhw)
	end)
	if not ok then
		io.stderr:write("inform: " .. tostring(err) .. "\n")
		os.exit(1)
	end
end

return M
