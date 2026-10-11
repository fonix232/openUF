--[[
	Band Steering support via OpenWrt's usteer daemon.

	CONFIRMED live 2026-07-15 (toggled "Band Steering" in the controller's
	Behavior Controls panel, diffed system_cfg via debug_dump_file): real UniFi
	sends this as a per-WLAN wire field, wireless.<n>.no2ghz_oui ("enabled"/
	"disabled", only present on the WLAN's 2.4GHz/radio0 wireless.<n> entry --
	see inform.lua's _parse_wifi_system_cfg). It is a plain on/off toggle.
	The 3-state Device.BandsteeringMode (off/equal/prefer_5g) is a separate
	setting, the AP's own, and reaches the wire only as the device-level
	bandsteering.* block for a device claiming wifi_caps 0x4 (captured
	2026-09-27, upstream). provision.device_band_steering maps it: Prefer 5G
	turns steering on like the WLAN toggle does, Balance has no usteer
	equivalent. Both arrive here as the one `enabled` flag.

	OpenWrt/hostapd has no band-steering concept at all -- there is no UCI
	wireless option for it (no2ghz_oui is a madwifi/QCA driver-specific
	convention: omitting the AP's own OUI from 2.4GHz beacons/probe responses
	nudges dual-band-capable clients toward 5GHz -- mainline mac80211/hostapd
	on OpenWrt has no equivalent). Real steering on OpenWrt requires the
	separate ubus-based `usteer` daemon (/etc/config/usteer), which itself
	depends on 802.11k (neighbor reports) + BSS Transition being enabled on
	every wifi-iface -- see ucihelper.apply_config's opts.band_steering_active
	handling, which forces those on network-wide whenever steering is enabled.

	The on/off switch is band_steering_interval, read from usteer's source
	(band_steering.c): every interval, usteer sends each 2.4 GHz client that
	has a same-SSID 5 GHz interface to steer to a BSS Transition request, and
	0 disables it. The daemon default is non-zero, so a running usteer steers
	unless openUF writes 0 -- which matters because Roaming Assistant keeps
	the daemon running with Band Steering off. band_steering_threshold, which
	an earlier version toggled 5/0, only biases load balancing (policy.c
	below_assoc_threshold) and is inert while load_balancing_threshold is 0,
	the default: toggling it switched nothing.
	The /etc/init.d/usteer service name is the standard OpenWrt convention
	(package name == init script name).
]]--

local M = {}
local util = require("openwrt.util")

-- Injectable: UCI module and command runner, for tests.
M._uci     = nil
M._run_cmd = function(cmd) return os.execute(cmd) end

-- Options in usteer.local that openUF owns. Each is written when set_enabled
-- wants a value for it and deleted when it wants none, so the daemon falls
-- back to its own default. band_steering_threshold is listed only so that a
-- value an earlier openUF wrote gets removed.
M.OWNED_OPTIONS = {"band_steering_interval", "band_steering_threshold"}

-- List options of the device's own usteer sections that set_enabled copies
-- into usteer.local. /etc/init.d/usteer builds one set_config object from
-- every usteer section, and uci_option_to_json_string_array emits a list's
-- key even when the section has none; usteerd keeps the last occurrence of a
-- key, which is `local`'s. Without the copy, an ssid_list or event_log_types
-- set in the device's own section is silently replaced by an empty array.
-- aggressiveness_mac_list goes through the same copy (mac_list), merged
-- with the Lock to Access Point entries.
M.CARRIED_LISTS = {"ssid_list", "event_log_types"}

-- The clients locked to this AP, as set_locked last heard them (a set of
-- lowercase MACs); nil until it has been told once in this process.
M._locked = nil

local function get_uci()
	if M._uci then return M._uci end
	return require("uci")
end

local LOCK_SUFFIX = ",0"

-- A UCI list option as a table: a single value comes back as a string.
local function as_list(v)
	if type(v) == "string" then return {v} end
	return type(v) == "table" and v or {}
end

local function same_list(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

-- The entries of list option opt in every usteer section but openUF's
-- `local`, in section order.
local function other_entries(cursor, opt)
	local out = {}
	if not cursor.foreach then return out end
	cursor:foreach("usteer", "usteer", function(s)
		if s[".name"] ~= "local" then
			for _, e in ipairs(as_list(s[opt])) do out[#out + 1] = e end
		end
	end)
	return out
end

-- usteer.local's aggressiveness_mac_list as it should be: the entries of the
-- device's own usteer sections, always (usteerd keeps only `local`'s list,
-- so leaving it out would wipe theirs), with -- while openUF runs the
-- daemon -- each client locked here as "<mac>,0" in place of its own entry.
-- Before set_locked has been called in this process the locks already in
-- `local` stand.
local function mac_list(cursor, active)
	local others = other_entries(cursor, "aggressiveness_mac_list")
	local locked = M._locked
	if locked == nil then
		locked = {}
		local from_others = {}
		for _, e in ipairs(others) do from_others[tostring(e)] = true end
		for _, e in ipairs(as_list(cursor:get("usteer", "local", "aggressiveness_mac_list"))) do
			local m = tostring(e):match("^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x),0$")
			if m and not from_others[tostring(e)] then locked[m:lower()] = true end
		end
	end
	local want = {}
	for _, e in ipairs(others) do
		if not (active and locked[tostring(e):sub(1, 17):lower()]) then want[#want + 1] = e end
	end
	if active then
		local mine = {}
		for m in pairs(locked) do mine[#mine + 1] = m .. LOCK_SUFFIX end
		table.sort(mine)
		for _, e in ipairs(mine) do want[#want + 1] = e end
	end
	return want
end

-- Write a list option of usteer.local: set, or deleted when empty.
local function put_list(cursor, opt, list)
	if #list > 0 then
		cursor:set("usteer", "local", opt, list)
	elseif cursor:get("usteer", "local", opt) ~= nil then
		cursor:delete("usteer", "local", opt)
	end
end

-- Enable or disable band steering, and keep the daemon running for Roaming
-- Assistant. The one writer of usteer.local: the Lock to Access Point
-- exemptions (aggressiveness_mac_list) are part of the same compare, commit
-- and restart, so they are in place whenever this starts the daemon.
-- enabled:     boolean, Band Steering
-- cfg:         device configuration (from conf.lua); cfg.net.lan_name selects the
--              usteer network to bind to, defaulting to "lan" when absent.
-- roam_assist: boolean, Roaming Assistant (wireless.<n>.btm_disassoc). The
--              steering decision itself is openuf/roamassist.lua's, per WLAN;
--              it needs usteer only for its cross-AP table of which AP hears
--              which client how loudly. So Roaming Assistant alone runs the
--              daemon with band steering off (interval 0), and
--              usteer's own device-wide roam trigger (roam_trigger_snr,
--              signal_diff_threshold) is never set: it cannot be scoped to a
--              WLAN or a band, and its only scoping knob, ssid_list, switches
--              every usteer function off for the other SSIDs.
function M.set_enabled(enabled, cfg, roam_assist)
	local uci = get_uci()
	local cursor = uci.cursor()
	local network = (cfg and cfg.net and cfg.net.lan_name) or "lan"
	local run = (enabled or roam_assist) and "1" or "0"
	-- nil = delete: the daemon's own default interval is the one that
	-- steered a real client on hardware (PROTOCOL-VALIDATION.md, #25).
	local want = {band_steering_interval = (not enabled) and "0" or nil}
	local carried = {}
	for _, opt in ipairs(M.CARRIED_LISTS) do carried[opt] = other_entries(cursor, opt) end
	carried.aggressiveness_mac_list = mac_list(cursor, run == "1")

	-- No-op discipline (same hazard class as switchvlan's reload guard):
	-- this runs on EVERY WiFi setparam, and unconditionally committing +
	-- restarting bounced the steering daemon -- dropping its learned station
	-- table -- on every steady-state inform. Skip when UCI already matches.
	--
	-- openuf_active records whether openUF last ran or stopped the daemon.
	-- The options alone can't: with Band Steering on they are all unset,
	-- exactly as on a device openUF never touched. usteer's init script
	-- reads a fixed list of option names, so this stamp never reaches the
	-- daemon.
	local same = cursor:get("usteer", "local", "network") == network
		and cursor:get("usteer", "local", "openuf_active") == run
	for _, opt in ipairs(M.OWNED_OPTIONS) do
		if cursor:get("usteer", "local", opt) ~= want[opt] then same = false end
	end
	for opt, list in pairs(carried) do
		if not same_list(as_list(cursor:get("usteer", "local", opt)), list) then
			same = false
		end
	end
	if same then return true end

	cursor:set("usteer", "local", "usteer")
	cursor:set("usteer", "local", "network", network)
	for _, opt in ipairs(M.OWNED_OPTIONS) do
		if want[opt] ~= nil then
			cursor:set("usteer", "local", opt, want[opt])
		elseif cursor:get("usteer", "local", opt) ~= nil then
			cursor:delete("usteer", "local", opt)
		end
	end
	for opt, list in pairs(carried) do put_list(cursor, opt, list) end
	cursor:set("usteer", "local", "openuf_active", run)
	cursor:commit("usteer")

	if run == "1" then
		M._run_cmd("/etc/init.d/usteer enable 2>/dev/null")
		M._run_cmd("/etc/init.d/usteer restart 2>/dev/null")
	else
		M._run_cmd("/etc/init.d/usteer stop 2>/dev/null")
		M._run_cmd("/etc/init.d/usteer disable 2>/dev/null")
	end

	return true
end

-- ─── Lock to Access Point: never steer a client away from its AP ────────────
--
-- The controller enforces a lock by denying the client on every other AP
-- (macacl lock2ap). usteer, running here, does not know that: its roam
-- trigger (roam_trigger_snr) and band steering would still send the client
-- BSS Transition requests toward an AP that refuses it, and kick it after
-- roam_kick_delay, so it bounces. usteer's per-station override,
-- aggressiveness_mac_list ("<mac>,<0-4>", lowercase), set to 0 makes
-- usteer_policy_can_perform_roam() false for that client, which gates both
-- (usteer policy.c, band_steering.c). It does not cover min_snr kicks, load
-- kicks or assoc_steering, which openUF leaves at usteer's off defaults.
--
-- usteer reads a station's override only when it first creates the station
-- (sta.c usteer_sta_info_get), so a changed list needs a restart, not a
-- reload; set_locked restarts only on a change.
--
-- The init script turns every usteer section's list into the same JSON key,
-- and usteerd keeps the last one: openUF's `local` section, even when it
-- holds none. So the entries of the other sections (the device's own usteer
-- settings) are carried into `local`'s list, a locked client's own entry
-- replaced by the lock's.

-- macs: the clients locked to this AP (lowercase). Remembered for
-- set_enabled, and written into usteer.local's aggressiveness_mac_list now
-- when openUF runs usteerd (the device's own entries carried either way).
-- Returns true when it changed the list (and restarted the daemon).
function M.set_locked(macs)
	local locked = {}
	for _, m in ipairs(macs or {}) do
		if type(m) == "string" and m:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
			locked[m:lower()] = true
		end
	end
	M._locked = locked
	local cursor = get_uci().cursor()
	-- No section of openUF's yet: set_enabled writes the list when it makes one.
	local stamp = cursor:get("usteer", "local", "openuf_active")
	if stamp == nil then return false end
	local active = stamp == "1"
	local want = mac_list(cursor, active)
	if same_list(as_list(cursor:get("usteer", "local", "aggressiveness_mac_list")), want) then
		return false
	end
	put_list(cursor, "aggressiveness_mac_list", want)
	cursor:commit("usteer")
	if active then M._run_cmd("/etc/init.d/usteer restart 2>/dev/null") end
	return true
end

-- ─── Keep usteer's AP-to-AP sync off the air ────────────────────────────────
--
-- usteerd tells the other APs what it sees by broadcasting its whole station
-- table every remote_update_interval (1 s) to 255.255.255.255:16720 -- or
-- ff02::4150 with `ipv6` set -- plus a short update for every MAC it has not
-- seen before (usteer remote.c/sta.c). The table holds every device heard in
-- a probe request in the last local_sta_timeout (120 s), so passing phones
-- dominate it: live on 2026-10-07, 119 entries for 16 associated clients,
-- 7024 bytes per message, five IP fragments. The bridge floods each fragment
-- out of every VAP too, where Multicast Enhancement (multicast_to_unicast)
-- turns it into one unicast copy per station: ~16 KB and 10-15 frames a
-- second to every client of both APs, waking dozing phones and costing a weak
-- client ~1.5 % of the radio's airtime, for traffic only the other AP reads.
-- The peer AP is reached over the wired uplink, so dropping the sync where it
-- leaves through a VAP loses nothing.
--
-- Bridge postrouting sees both what this AP's usteerd sends and what the
-- peer's sends in over the uplink. The bridge does not reassemble, so only a
-- datagram's first fragment carries the UDP port; the later fragments are
-- matched as non-first fragments of a UDP broadcast. Nothing else sends a
-- fragmented UDP broadcast to clients (DHCP fits one frame, and a client that
-- missed the first fragment could not reassemble the rest anyway).
--
-- Own table, rebuilt from scratch like l2guard's; oifname, not oif, so a VAP
-- that a `wifi reload` is recreating does not fail the add. iifname/oifname in
-- the bridge family need kmod-nft-bridge.

M.NFT_TABLE = "bridge openuf_usteer"

M._exec = function(cmd) return os.execute(cmd) end

-- os.execute on the device's Lua 5.1 returns the raw exit status (0 =
-- success, non-zero = failure, both truthy); newer Lua returns true/nil.
local exec_ok = require("openwrt.util").exec_ok

local valid_ifname = util.valid_ifname

-- Whether openUF runs usteerd, i.e. whether the filter has anything to do.
function M.filter_wanted()
	local ok, v = pcall(function()
		return get_uci().cursor():get("usteer", "local", "openuf_active")
	end)
	return ok and v == "1"
end

-- Rebuild the table to drop usteer's sync on exactly these VAP netdevs; an
-- empty or nil list removes it. Returns the number of rules installed.
function M.reconcile_filter(ifnames)
	local T = M.NFT_TABLE
	local names = {}
	for _, n in ipairs(ifnames or {}) do
		if valid_ifname(n) then names[#names + 1] = '"' .. n .. '"' end
	end
	if #names == 0 then
		util.nft_apply(T, nil, M._exec)
		return 0
	end
	local set = "{ " .. table.concat(names, ", ") .. " }"
	local post = "add rule " .. T .. " post oifname " .. set
	local stmts = {
		"add chain " .. T .. " post { type filter hook postrouting priority 0; policy accept; }",
		post .. " ip daddr 255.255.255.255 udp dport 16720 drop",
		post .. " ip daddr 255.255.255.255 ip protocol udp ip frag-off & 0x1fff != 0 drop",
		-- usteer's own group: every fragment carries it, nothing else uses it.
		post .. " ip6 daddr ff02::4150 drop",
	}
	local _, failed = util.nft_apply(T, stmts, M._exec)
	local n = 0
	for i = 2, #stmts do
		if failed[i] then
			io.stderr:write("openuf: usteer: nft rejected a sync filter rule (needs "
				.. "kmod-nft-bridge); usteer's broadcasts still reach every client.\n")
		else
			n = n + 1
		end
	end
	return n
end

return M
