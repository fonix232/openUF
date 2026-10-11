--[[
	report.lua -- the device, as UniFi wants to hear about it: reads OpenWrt
	(system, radios, SSIDs, stations, ports, neighbours, topology) and fills
	the inform payload the controller expects.

	build(ctx, ...) takes inform.lua's module table as ctx: the platform
	modules it reads through (ctx._sysinfo, ctx._ucihelper, ...), which tests
	replace, and the caches that live across heartbeats.
]]--

local cjson   = require("cjson")
local ufp     = require("unifi.payload")   -- the payload TABLE is `payload` below
local country = require("unifi.country")
local mesh    = require("unifi.mesh")
local loadbalance = require("unifi.loadbalance")
local guest   = require("unifi.guest")
local wlan    = require("unifi.wlan")
local satisfaction = require("unifi.satisfaction")

local M = {}

local RRM_MAX_AGE = require("openwrt.rrmscan").MAX_AGE

-- sta_table[].chwidth codes by channel width in MHz (the controller's width
-- enum, 10.6.106 com.ubnt.i.g.a.b). A width not listed sends no chwidth.
M.CHWIDTH_CODE = {[20] = 0, [40] = 1, [80] = 2, [160] = 3, [240] = 4, [320] = 5}

-- sta_table[].state bit the controller reads as the client's power save
-- (10.6.106 devmgr MwArZjlvuVhguZnuxGE: powersave_enabled =
-- (getInt("state") & 0x10) != 0). It is the only bit of state read.
M.STA_STATE_PS = 16

-- Per-client flags on one sta_table entry, each set only from a source that
-- has it and left out otherwise (the controller defaults both to false):
--   is_11r  the station negotiated a Fast BSS Transition AKM (hostapd
--           all_sta's AKMSuiteSelector, read once per BSS: hapd);
--   state   M.STA_STATE_PS while mac80211 holds the station in power save,
--           else 0 (sysinfo.sta_powersave, debugfs; bss first, then the
--           netdev iw listed it on).
-- Not sent, with no faithful source: 1x_identity (no 802.1X WLAN is ever provisioned), ack_rssi
-- (iw's ack signal read a flat -95 dBm on hardware), ccq,
-- satisfaction_real, dhcpend_time, tx_retry_burst_count. See
-- PROTOCOL-VALIDATION.md, sta_table[].
function M.sta_flags(ctx, entry, sta, bss, hapd)
	if type(entry) ~= "table" or type(sta) ~= "table" then return end
	-- Only when true, as the firmware sends it (upstream 074b070).
	if type(hapd) == "table" and hapd.is_11r then
		entry.is_11r = true
	end
	local ps_fn = ctx and ctx._sysinfo and ctx._sysinfo.sta_powersave
	if ps_fn then
		local devs = {bss}
		if sta.dev and sta.dev ~= bss then devs[#devs + 1] = sta.dev end
		local ok, ps = pcall(ps_fn, devs, sta.mac)
		if ok and ps ~= nil then entry.state = ps and M.STA_STATE_PS or 0 end
	end
end

-- Build the inform JSON payload.
-- st: current state table
-- cfg: device configuration (config.lua)
-- ufhw: the UniFi identity (dev.identity)

-- A capability mask as the controller stores it: a Java int. Bit 31 makes the
-- value negative there, and the ingest DTO's setter takes an `int`
-- (com.ubnt.i.b.l.XtugNwLHsUnnZrF setFirmwareCapabilities(int)), which Jackson
-- refuses to fill from 2147483648 or more ("out of range of int"). So a mask
-- with bit 31 goes out as its signed 32-bit value; every other ingest path
-- (ZMUWuPFvCIO.getInt: Number.intValue()) reads that back bit for bit.
function M.signed32(v)
	if v >= 2147483648 then return v - 4294967296 end
	return v
end

-- Whether a sibling-sighting scan runs at all (idlescan.lua): the source of
-- the neighbour entries wifi_caps2 0x200 promises. The sibling-channel scan
-- listens on the frequencies the sibling exchange announced, so with
-- sibling_exchange off it never runs and does not count; an idle sweep scans
-- every channel and finds siblings by their beacon element on its own.
function M.neighbour_scan_enabled(cfg)
	local c = cfg and cfg.config or {}
	local sibling_scans = c.sibling_exchange ~= false and (tonumber(c.sibling_scan_interval) or 0) > 0
	return sibling_scans or (tonumber(c.idle_scan_interval) or 0) > 0
end

-- fw_caps: each bit gates one controller feature and is claimed only where
-- this device carries it out (PROTOCOL-VALIDATION.md, Capability bitmasks).
-- A capability probe's answer: true only when it ran and said true. A probe
-- that is missing or raises claims nothing -- and never takes the payload
-- down with it.
local function probe(fn)
	if type(fn) ~= "function" then return false end
	local ok, v = pcall(fn)
	return ok and v == true
end
M.probe = probe

function M.fw_caps(ctx, cfg)
	local si = ctx._sysinfo or {}
	local caps = 0x100110
		-- 0x1000 supportMultiBlockWlanSchedule + 0x400000 supportWlanScheduleInvert:
		-- every block of a day as schedule_<day>.<i>, and the blackout blocks
		-- as they are with schedule_invert. unifi/schedule.lua parses both,
		-- openwrt/wlansched.lua takes the SSID down and up. (The schedule keys
		-- themselves come regardless of these bits.)
		+ 0x1000 + 0x400000
		-- 0x20000000 supportsRadiusFilter: aaa.<n>.filter_id on an Enterprise
		-- WLAN while the gateway runs the RADIUS server; ucihelper puts it in
		-- every Access-Request as Filter-Id (radius_auth_req_attr 11).
		+ 0x20000000
	-- 0x800000 supportHotspot2: without it a Hotspot 2.0 (or OSEN) WLAN is
	-- dropped from the push. Only where hostapd has CONFIG_HS20.
	if probe(si.hs20_supported) then caps = caps + 0x800000 end
	-- 0x4000 supportsSNMPv3: snmp.user.1.* is sent only with it. Only where
	-- the ssl build of snmpd is installed (openwrt/snmp.lua); v1/v2c needs no
	-- bit and is applied wherever snmpd is.
	local snmp = ctx._snmp
	if snmp and probe(snmp.v3_capable) then caps = caps + 0x4000 end
	-- 0x80000000 supportsMacBasedVlans: aaa.<n>.accept_mac.* (per-client
	-- network override; the site feature needs every AP and switch with
	-- clients to claim it). hostapd's accept_mac_file VLAN ids land on
	-- wifi-vlan sections: the same VLAN machinery Private Pre-Shared Keys
	-- need, so the same probe.
	if probe(si.ppsk_supported) then caps = caps + 0x80000000 end
	return M.signed32(caps)
end

function M.build(ctx, st, cfg, ufhw)
	local function loadavg()
		local ok, la = pcall(ctx._sysinfo.loadavg)
		return ok and la or nil
	end
	local uap = ufhw and ufhw.uap or {}

	-- Opened before the first sysinfo call, not partway down: this payload's
	-- very first question -- the uptime -- is one scan_table asks again per
	-- radio, and measuring a real heartbeat on hardware showed it still being
	-- read twice because the pass started below it. Nothing in here may
	-- outlive the payload; _tick closes it again even if this function throws.
	if ctx._sysinfo.begin_pass then ctx._sysinfo.begin_pass() end

	-- Collect sysinfo
	local uptime     = ctx._sysinfo.uptime()
	local meminfo    = ctx._sysinfo.meminfo()
	local cpu_pct    = ctx._sysinfo.cpu_percent()
	-- "Used" is total minus what the kernel says is available (page cache is
	-- reclaimable, not used); MemFree is the fallback on kernels without it.
	local mem_used_kb = meminfo.total_kb - (meminfo.available_kb or meminfo.free_kb)
	local mem_pct    = meminfo.total_kb > 0
	                    and math.floor(mem_used_kb * 100 / meminfo.total_kb + 0.5)
	                    or 0
	local ifaces    = ctx._sysinfo.interfaces()
	local lldp_nbrs = ctx._lldp.neighbors()

	-- Build if_table
	local if_table = {}
	for _, iface in ipairs(ifaces) do
		if_table[#if_table + 1] = {
			name        = iface.name,
			mac         = iface.mac,
			rx_bytes    = iface.rx_bytes,
			tx_bytes    = iface.tx_bytes,
			rx_packets  = iface.rx_packets,
			tx_packets  = iface.tx_packets,
			rx_errors   = iface.rx_errors,
			tx_errors   = iface.tx_errors,
		}
	end

	-- radio_table and vap_table require UCI (not available in test context)
	local radio_table       = {}
	local radio_table_stats = {}
	local vap_table         = {}
	local scan_radio_table  = {}
	local derived_country   = nil  -- from the radios' UCI regdomain, below

	local mac_str = st.mac or "00:00:00:00:00:00"

	-- Wireless station MACs, collected below while building vap_table --
	-- subtracted from port_table's mac_table entries further down so a
	-- wireless client bridged into br-lan (and thus also visible in the
	-- bridge FDB) is never double-reported as a wired client too.
	local station_macs = {}
	-- mac -> {vap, signal, uptime, idle}: what staevents.lua diffs between
	-- heartbeats into the controller's connection events.
	local sta_snapshot = {}
	-- Every client station, a roamed-away one included, for the roam
	-- reports' view of who is here (staevents.roam_observe).
	local here_obs = {}
	-- hostapd interface -> vap_table name: connection failures arrive from
	-- hostapd by interface, and the controller knows the VAP by name.
	local vap_by_ifname = {}
	-- Roaming Assistant: one observation per station on a vap that has it on,
	-- for inform.lua's loop to hand to openwrt/roamassist.lua after the build.
	local roam_obs = {}
	-- Minimum RSSI: one observation per station below its radio's threshold,
	-- decided after the station loop (openwrt/minrssi.lua kicks only one that
	-- stayed below for minrssi.HOLD seconds).
	local minrssi_obs = {}
	-- Load balance: every station on a radio that has it on.
	local lb_obs = {}
	-- WiFi Speed Limit: what each netdev lists and its WLAN's limits, for
	-- inform's _shaper_resync after this payload is built. complete = false
	-- when some netdev could not be read, so nothing is dropped on a guess.
	local shape_obs = {complete = true, by_ifname = {}, where = {}, conn = {}}
	-- WiFi Experience tallies (unifi/satisfaction.lua), one per VAP, filled
	-- by the per-VAP station loop further down: the client VAPs' for the
	-- device's score, and per radio for that radio's. A backhaul VAP's
	-- "stations" are other APs, so it feeds neither.
	local sat_tallies, sat_tallies_by_radio = {}, {}
	-- A station's ip/hostname/ipv6_addresses, from sysinfo's MAC-keyed maps:
	-- the ARP cache, the DHCP lease file (both shared with the wired hosts'
	-- mac_table) and the IPv6 neighbour cache. The pass opened above reads
	-- each once per payload, and only once a station asks, so a payload with
	-- no wireless client costs no `ip -6 neigh` fork.
	local function sta_addr(fn, mac)
		if not fn then return nil end
		local ok, by_mac = pcall(fn)
		return ok and type(by_mac) == "table" and by_mac[mac:lower()] or nil
	end
	-- The device's own MACs (its netdevs) -- excluded from port_table's
	-- mac_table for the same reason: without this, the AP would report
	-- itself as a wired client of its own switch.
	local self_macs = {[mac_str] = true}
	for _, iface in ipairs(ifaces) do
		if iface.mac and iface.mac ~= "" then self_macs[iface.mac] = true end
	end

	-- ufuci: VAP/radio info (require("uci") calls inside it can legitimately
	-- fail off-target, so individual calls are still pcall-wrapped below)
	local ufuci = ctx._ucihelper
	if ufuci and ufuci.get_vap_table then
		-- One `ubus call network.wireless status` for the whole payload: every
		-- get_ifname_for_radio/vap below (one per VAP in get_vap_table, one
		-- per radio, one per VAP again) otherwise re-runs it for the same
		-- answer -- ten identical forks per heartbeat on a two-radio,
		-- four-SSID box. Feature-detected: test doubles inject a ucihelper
		-- without it. _tick() ends the pass even when this function throws.
		if ufuci.begin_pass then ufuci.begin_pass() end
		local ok_v, rv = pcall(ufuci.get_vap_table)
		if ok_v then vap_table = rv end
		-- dev.conf.hwassign (UCI openuf.board.hwassign) restricts which radios are reported;
		-- absent, every wifi-device in UCI is (see get_radio_table).
		local hwassign = cfg and cfg.hwassign
		local ok_r, rr = pcall(ufuci.get_radio_table, hwassign)
		if ok_r then radio_table = rr end

		-- Regulatory domain for the payload's country_code, off the first
		-- radio that declares one (UCI sets the same country on every
		-- wifi-device). Was hardcoded 840 (US) for every deployment.
		for _, r in ipairs(radio_table) do
			if r.country then
				derived_country = country.NUMERIC[tostring(r.country):upper()]
				break
			end
		end

		-- Live per-radio channel utilization, parallel to radio_table (matches
		-- real UniFi's split of static config vs. live stats). Also kept in
		-- radio_cu_stats, keyed by radio name, so each vap_table entry on
		-- that radio can carry the same cu_* figures -- confirmed via
		-- decompile (com.ubnt.service.system.XrjNIQhefUEBuL's archived-field
		-- schema registry) that cu_interf/cu_self_tx/cu_self_rx live in the
		-- same per-VAP schema group as avg_client_signal, not solely in
		-- radio_table_stats: live-tested against a real controller, adding
		-- them only to radio_table_stats left the archiver's client_signal_avg
		-- populating every cycle while cu_interf/cu_total never appeared at
		-- all despite being sent correctly.
		local radio_cu_stats = {}
		-- radio_table_stats entries, keyed by UCI radio name, so the VAP loop
		-- can attach per-radio TX counters after summing them per station.
		local radio_stats_by_name = {}
		-- Minimum RSSI enforcement data, keyed by radio name (e.g. "radio0"),
		-- consumed by the per-station loop below -- kept as absolute dBm
		-- thresholds (converted from the wire's fixed encoding in this same
		-- loop) so the enforcement check further down is a plain
		-- sta.signal comparison.
		local minrssi_threshold_by_radio = {}
		-- Load balance's client cap, keyed by radio name; only radios that
		-- have it on.
		local maxsta_by_radio = {}
		-- Live noise floor per radio, for satisfaction and sta_table.noise.
		local noise_by_radio = {}
		-- Live secondary-channel side per radio, for each vap's extchannel.
		local extchan_by_radio = {}
		-- sysinfo.sibling_bssids(), read once per payload on first use.
		local siblings_by_bssid, sibling_models
		-- 802.11k merge inputs, built on first use; see the scan_table merge.
		local rrm_skip, rrm_site
		for _, radio in ipairs(radio_table) do
			local ok_if, ifname = pcall(ufuci.get_ifname_for_radio, radio.name)
			if ok_if and ifname then
				-- Hardware capability fields the controller's radio_table
				-- ingestion expects independently of everything else here
				-- (is_11ac/is_11ax/is_11be/has_dfs/has_fccdfs/has_ht160/
				-- has_eht240/has_eht320/nss) -- see sysinfo.radio_caps()
				-- for the decompile citation. Missing these is why the
				-- Radios tab excluded the device entirely.
				local ok_caps, caps = pcall(ctx._sysinfo.radio_caps, ifname)
				if ok_caps and caps then
					extchan_by_radio[radio.name] = caps.extchannel
					caps.extchannel = nil
					for k, v in pairs(caps) do radio[k] = v end
					-- The live negotiated channel is band-authoritative once
					-- ACS has picked one: UCI's config value may be the
					-- literal "auto", for which get_radio_table's config-first
					-- derivation can still misreport the band when the
					-- section carries neither `band` nor `hwmode`. Re-derive
					-- here so every downstream consumer of radio.radio in
					-- this loop (scan_radio_table band, athstats bucketing)
					-- inherits the correction. Feature-detected: test mocks
					-- inject a ucihelper without band_for_channel.
					if caps.channel and ufuci.band_for_channel then
						radio.radio = ufuci.band_for_channel(caps.channel)
					end
					-- radio_caps: a genuine SEPARATE integer field on
					-- radio_table (confirmed via decompile,
					-- com.ubnt.service.devmgr.PGOcbDWlbnYQdFW/
					-- tFhABnrHYJqvjaoEa: `uCthhvfQNZ2.put("radio_caps",
					-- uCthhvfQNZ3.getInt("radio_caps", 0))` -- an int, not the
					-- flattened is_11ac/nss/etc. booleans above, and distinct
					-- from radio_caps2) -- confirmed 2026-07-14 from the
					-- controller's own React bundle (swai chunk) that the
					-- Radios tab's MIMO column/filter computes
					-- `mimo: e7(radio.radio_caps)` from exactly this field.
					-- The controller's Java side only ever passes this int
					-- through verbatim (no server-side bit-decode found in
					-- the decompile); the decode into "1x1".."4x4" happens
					-- client-side only. openUF previously always sent 0 (the
					-- field was never populated), which is why every radio's
					-- MIMO column stayed blank and the 1x1-4x4 filter
					-- checkboxes excluded every radio outright rather than
					-- just filtering incorrectly. The exact bit layout isn't
					-- simply "value == nss" (confirmed live: radio_caps=2
					-- still showed blank/excluded) -- it's a bitmask, reverse
					-- engineered by calling the controller's own live e7()
					-- decoder directly (via its webpack module cache) with a
					-- sweep of single-bit values: bit 3 (0x8) -> "1x1", bit 4
					-- (0x10) -> "2x2", bit 5 (0x20) -> "3x3", bit 26
					-- (0x4000000) -> "4x4", checked in that highest-first
					-- priority order when multiple bits are set (all
					-- confirmed against the live decoder, not guessed).
					local RADIO_CAPS_MIMO_BIT = {
						[1] = 0x8,
						[2] = 0x10,
						[3] = 0x20,
						[4] = 0x4000000,
					}
					radio.radio_caps = RADIO_CAPS_MIMO_BIT[caps.nss or 1] or RADIO_CAPS_MIMO_BIT[1]
					-- wpa3_supported: reported only when hostapd can really
					-- do SAE, so we never claim what the radio cannot run.
					-- Truthful -- but the controller does NOT read it, and it
					-- does NOT unlock WPA3.
					--
					-- Confirmed live on 10.4.57 by reading back the persisted
					-- device: radio_caps survives the round trip verbatim
					-- (nss=3 -> 0x20 comes back as radio_caps=32), while
					-- wpa3_supported and owe_supported come back UNDEFINED --
					-- the controller drops them on ingestion entirely.
					--
					-- Decompiling the only class that mentions wpa3_supported
					-- (com.ubnt.net.k.aI.jRsSex, a record of wpa3Supported/
					-- band6GHzSupported/oweSupported) shows it is CONSTRUCTED,
					-- never parsed: its single caller builds it from an
					-- injected com.ubnt.service.wifi.AcrQJeJCScLn service and
					-- takes the device object as a parameter it then ignores.
					-- It is an outbound/API description of what the site
					-- supports, not an inform ingestion path.
					--
					-- An earlier commit here claimed setting this field flipped
					-- a push from WPA-PSK to SAE. That was a coincidental
					-- config regeneration: it has never reproduced, including
					-- across a clean re-adoption with the field present from
					-- the first inform.
					--
					-- Kept because it is accurate (these radios really do have
					-- SAE) and harmless, and another controller version may yet
					-- read it -- but nothing here unlocks WPA3 on 10.4.57. See
					-- PROTOCOL-VALIDATION.md's WPA3 section.
					if ctx._sysinfo.sae_supported and ctx._sysinfo.sae_supported() then
						radio.wpa3_supported = true
					else
						radio.wpa3_supported = false
					end
					-- Same truth as radio_caps2 bit 0x8 below, and just as
					-- unread by the controller.
					radio.owe_supported = (ctx._sysinfo.owe_supported
						and ctx._sysinfo.owe_supported()) and true or false
					-- radio_caps2 bit 0x1: THE WPA3 GATE. Traced end to
					-- end through the 10.4.57 bytecode:
					--
					--   config gen (QSAkfnbfInKJ) calls radio.CVir()
					--   CVir()  = (1 & ZPjpXpgFhJSgqk().orElse(0)) == 1
					--   ZPjpXpgFhJSgqk() -> impl field iBjnA
					--   iBjnA <- builder field SuUD
					--   SuUD  <- setter rMxwXnPhhdotvjERKoA(int)
					--   which the radio parser feeds from "radio_caps2"
					--
					-- radio_caps goes to a DIFFERENT field (builder kJeOrfqt
					-- -> impl DbisCuTqoItCGd -> accessor FJaWnIAautY), which
					-- is the MIMO column and nothing else. So the capability
					-- that decides WPA3 lives in the one radio field openUF
					-- never sent -- it arrived as 0 on every inform, and 0
					-- fails the bit test, so every WPA3 WLAN was downgraded.
					-- Gated on real SAE support for the same reason as
					-- wpa3_supported: never claim what hostapd cannot run.
					--
					-- Bit 0x2 is FT with WPA3 (10.6.101: radio DTO
					-- ytajcagDggPuTaL(), tested in the per-radio security
					-- filter plVcFpIybmrpXclX). Without it the controller
					-- forces wpa3_fast_roaming off on every SAE WLAN, and on
					-- a WPA3-only one fast_roaming_enabled too, so no 802.11r
					-- goes out. hostapd runs FT-SAE wherever it runs SAE.
					if ctx._sysinfo.sae_supported and ctx._sysinfo.sae_supported() then
						radio.radio_caps2 = 0x3
					else
						radio.radio_caps2 = 0
					end
					-- Bit 0x8 is Enhanced Open (radio DTO NoFWvUa(), same
					-- filter). Without it an OWE WLAN is not provisioned at
					-- all and an OWE transition WLAN goes out as plain open.
					-- Probed separately: hostapd can have SAE without OWE.
					if ctx._sysinfo.owe_supported and ctx._sysinfo.owe_supported() then
						radio.radio_caps2 = radio.radio_caps2 + 0x8
					end
				end
				local ok_rs, stats = pcall(ctx._sysinfo.radio_stats, ifname)
				local in_use = ok_rs and ufp.in_use_survey(stats) or nil
				noise_by_radio[radio.name] = in_use and in_use.noise
				-- min_rssi (outbound field, confirmed via decompile alongside
				-- radio_caps/tx_power/athstats in the same DTO) converts
				-- rf_config()'s stored raw wire units back to dBm with the
				-- SAME FIXED offset the controller encoded them with:
				-- confirmed live, UI "-80 dBm" <-> wire "15" and UI "-85 dBm"
				-- <-> wire "10", i.e. raw = dbm + 95 exactly.
				--
				-- This used to add the LIVE noise floor instead, on the reading
				-- that the value is "dB above noise". It is not, and cannot be:
				-- the controller never learns a radio's noise floor, so it has
				-- nothing but a constant to encode with -- which is why both
				-- data points land on one. Live noise also broke the round
				-- trip, reporting a min_rssi the UI would render as a number
				-- the operator never chose.
				--
				-- It looked right only because it was written against a radio
				-- whose noise floor happens to be exactly -95 (an Archer C5's
				-- ath10k 5GHz). Every other radio to hand disagreed, in both
				-- directions: the same board's ath9k 2.4GHz reads -107, turning
				-- a requested -80 into -92 and barely kicking anyone, while an
				-- AX3000T's mt76 radios read -90/-92 and turned it into -75,
				-- kicking clients the operator meant to keep. A threshold that
				-- drifts 12 dB with the driver is worse than no threshold.
				local MINRSSI_WIRE_OFFSET = 95
				-- min_rssi_raw can legitimately be missing with the flag set
				-- (inconsistent UCI, e.g. a hand-edit or interrupted write) --
				-- without the guard this was arithmetic on nil, killing the
				-- whole inform build.
				if radio.min_rssi_enabled and radio.min_rssi_raw then
					radio.min_rssi = radio.min_rssi_raw - MINRSSI_WIRE_OFFSET
					minrssi_threshold_by_radio[radio.name] = radio.min_rssi
				end
				if in_use then
					-- in_use: the channel the radio is actually on, over the
					-- time since the last inform (ufp.windowed_cu).
					local cu_state, cu_total, cu_self_rx, cu_self_tx =
						ufp.windowed_cu(ctx._cu_cache[radio.name], in_use)
					ctx._cu_cache[radio.name] = cu_state
					local entry = {
						name        = radio.name,
						channel     = radio.channel,
						cu_total    = cu_total,
						cu_self_rx  = cu_self_rx,
						cu_self_tx  = cu_self_tx,
						-- cu_interf: airtime busy for reasons other than this
						-- radio's own tx/rx (other-BSS/non-WiFi interference).
						-- The stat archiver (com.ubnt.service.system.
						-- QDcGUYAmLvJwylXw, confirmed via decompile) reads
						-- this as a sibling of cu_total/cu_self_rx/cu_self_tx
						-- and silently drops the whole per-band bucket without
						-- it -- this is why "Avg. Interference" stayed blank
						-- even though cu_total was already being sent.
						cu_interf   = math.max(0, cu_total - cu_self_rx - cu_self_tx),
					}
					radio_cu_stats[radio.name] = {
						cu_total   = entry.cu_total,
						cu_self_rx = entry.cu_self_rx,
						cu_self_tx = entry.cu_self_tx,
						cu_interf  = entry.cu_interf,
					}
					-- athstats: the ACTUAL source the stat archiver reads for
					-- these four fields, confirmed via decompiling
					-- com.ubnt.service.system.x.htDMji -- it iterates
					-- radio_table (not radio_table_stats, not vap_table) and
					-- SKIPS a radio entirely if it lacks this nested
					-- "athstats" sub-object (`if
					-- (!uCthhvfQNZ.containsField("athstats")) continue;`),
					-- then reads cu_total/cu_self_rx/cu_self_tx/satisfaction/
					-- cu_interf off it (named after the legacy Atheros ath9k/
					-- ath10k driver stats struct UniFi firmware historically
					-- exposed under this name, kept for newer radios too).
					-- radio_table_stats/vap_table's copies of these same
					-- fields are real and used by other code paths (the live
					-- wifi-stats/radios REST API, per-VAP display) but this
					-- nested copy is what the periodic archiver needs --
					-- omitting it is why "Avg. Interference"/"Avg. Airtime"
					-- stayed blank even with correct data everywhere else.
					--
					-- satisfaction is added after the VAP loop, once the
					-- radio's clients are scored. ast_be_xmit (beacons sent)
					-- is not sent: mac80211 does not count it.
					radio.athstats = {
						cu_total   = cu_total,
						cu_self_rx = cu_self_rx,
						cu_self_tx = cu_self_tx,
						cu_interf  = entry.cu_interf,
					}
					-- Hardware tx and carrier-sense timeouts, raw counts as
					-- the firmware sends them (upstream fafe47f). The
					-- controller diffs them per inform and logs "Possible
					-- interference" when either rises faster than 10/s (at
					-- most every 5 min per radio). ath9k only; elsewhere
					-- absent, as on a radio that never times out.
					if ctx._sysinfo.radio_timeouts then
						local ok_to, txto, cst = pcall(ctx._sysinfo.radio_timeouts, ifname)
						if ok_to and txto then
							radio.athstats.ast_txto = txto
							radio.athstats.ast_cst = cst
						end
					end
					-- Cached spectrum-scan result. On the radio_table entry,
					-- beside athstats: the controller builds its own
					-- radio_table_stats from the inform's radio_table and
					-- reads spectrum_table from there (devmgr
					-- PGOcbDWlbnYQdFW); sent in radio_table_stats it was
					-- dropped (upstream a684980, real scan on 10.4.57).
					-- spectrum_table_time is the scan's AGE in seconds: the
					-- controller stores now - value and the UI shows that as
					-- the scan's epoch, so an epoch here reads as 1970.
					local sscan = ctx._spectrum_cache[radio.name]
					if sscan then
						radio.spectrum_table = ufp.spectrum_table(sscan.table, radio.radio,
							wlan.width_from_htmode(radio.ht))
						radio.spectrum_table_time = math.max(0, ctx._time() - sscan.table_time)
					end
					-- Exactly one entry per radio name: UniFi 11.x collapses
					-- duplicates ("Collapsed {} duplicate radio_table_stats
					-- entries") and drops entries past a limit, so a radio
					-- listed twice must not report twice.
					if not radio_stats_by_name[radio.name] then
						radio_table_stats[#radio_table_stats + 1] = entry
					end
					-- Keep the entry addressable so the VAP/station loop below
					-- can attach this radio's TX counters once it has summed
					-- them -- see radio_tx_stats.
					radio_stats_by_name[radio.name] = radio_stats_by_name[radio.name] or entry
				end
				-- Neighboring wireless networks visible to this radio --
				-- confirmed real field names via the decompiled controller's
				-- ingestion DTO (com.ubnt.service.aO.bLwwMKkr, literally
				-- named "PeerScan"): a top-level scan_radio_table, one entry
				-- per radio, each carrying that radio's own scan_table list.
				-- Feeds the controller's Insights -> AirView -> Environment
				-- view (backed by stat/rogueap) -- a different, previously
				-- unimplemented feature from the RF/spectrum-scan cmd above,
				-- which only ever reported channel utilization, never which
				-- neighboring SSIDs/BSSIDs were actually detected. See
				-- PROTOCOL-VALIDATION.md for the full derivation.
				local ok_sc, nets = pcall(ctx._sysinfo.scan_table, ifname)
				if ok_sc and nets then
					local scan_table = {}
					for _, net in ipairs(nets) do
						scan_table[#scan_table + 1] = {
							mac        = net.bssid,
							bssid      = net.bssid,
							radio      = radio.radio,
							radio_name = radio.name,
							-- Confirmed from the controller's own React bundle
							-- (2026-07-14, react-app-wrapper chunk): the
							-- Environment tab's list is fed through an
							-- unconditional filter keyed on `band` (a field
							-- distinct from `radio`, but taking the exact same
							-- enum values -- "ng"/"na"/"6e", confirmed from the
							-- bundle's own enum definition) -- any entry
							-- missing `band` fails that filter silently, with
							-- no error and no visible UI cause, regardless of
							-- every visible sidebar filter's state.
							band       = radio.radio,
							channel    = net.channel,
							freq       = net.freq,
							rssi       = net.signal,
							signal     = net.signal,
							-- The Environment tab's "Ch. Width" column reads
							-- this directly and renders nothing at all when
							-- it's falsy/missing (confirmed live 2026-07-14).
							bw         = net.bw or 20,
							-- NOT last_seen: the controller derives the
							-- absolute last_seen itself from report_time -
							-- age, and its rogue-AP detection silently
							-- drops any entry with age >= 30 as stale
							-- (confirmed live 2026-07-14, see
							-- PROTOCOL-VALIDATION.md) -- age must be
							-- seconds actually elapsed, not omitted.
							age        = net.age or 0,
							security   = net.security,
							essid      = net.essid,
						}
						-- A sibling openUF or UniFi AP, identified by the IE it
						-- beacons (sysinfo.peer_ie_hex, peer_match_ucode). is_unifi + serialno is what
						-- the controller resolves to an adopted device; without
						-- them every BSS of ours carrying a site SSID was
						-- listed as an impersonating third-party AP.
						if net.peer_mac then
							local e = scan_table[#scan_table]
							e.is_unifi = true
							e.serialno = net.peer_mac
						end
					end
					-- 802.11k enrichment: BSSes a CLIENT went off-channel
					-- and saw, which this radio never could from its own
					-- passive cache. Merged on the reported channel's BAND,
					-- not on the interface the request went out of, because a
					-- client sitting on 5 GHz routinely reports 2.4 GHz too --
					-- so one report fills both radios' lists. Anything the
					-- passive cache already knows wins, since a beacon report
					-- carries no SSID, security or width. See rrmscan.lua.
					-- A sibling seen without its vendor element (any 802.11k
					-- entry), recognised from the BSSIDs siblings announce on
					-- the LAN.
					if siblings_by_bssid == nil then
						local ok_sb, sb, sm = pcall(ctx._sysinfo.sibling_bssids)
						siblings_by_bssid = ok_sb and sb or {}
						sibling_models = ok_sb and sm or {}
					end
					-- Clients report this AP too: its own BSSIDs are skipped,
					-- and the site's SSIDs are withheld from any reported BSS
					-- that is not a known sibling. Built once per payload.
					if ctx._rrmscan and #ctx._rrm_neighbours > 0 then
						if not rrm_skip then
							rrm_skip, rrm_site = {}, {}
							for _, v in ipairs(vap_table) do
								if type(v.bssid) == "string" and v.bssid ~= "" then
									rrm_skip[v.bssid:lower()] = true
								end
								if v.essid then rrm_site[v.essid] = true end
							end
						end
						pcall(ctx._rrmscan.merge_into, scan_table,
							ctx._rrm_neighbours, {
								band       = radio.radio,
								radio      = radio.radio,
								radio_name = radio.name,
								max_age    = RRM_MAX_AGE,
								skip       = rrm_skip,
								siblings   = siblings_by_bssid,
								site_ssids = rrm_site,
							})
					end
					for _, e in ipairs(scan_table) do
						local sib = not e.is_unifi and e.bssid
							and siblings_by_bssid[e.bssid:lower()]
						if sib then
							e.is_unifi = true
							e.serialno = sib
						end
						-- The sibling's model, which the controller copies into
						-- the sighting for WiFiman's neighbour list (siblings.lua).
						local m = e.is_unifi and e.serialno and sibling_models[e.serialno:lower()]
						if m then
							e.model = m.model
							e.model_display = m.model_display
						end
					end
					scan_radio_table[#scan_radio_table + 1] = {
						radio      = radio.radio,
						name       = radio.name,
						scan_table = ufp.arr(scan_table),
					}
				end
			end
			-- Internal fields, never payload members. Cleared out here (not
			-- inside the ifname branch above) so they can't leak into the
			-- serialized radio_table when ifname resolution fails.
			radio.min_rssi_raw = nil
			maxsta_by_radio[radio.name] = radio.loadbalance_maxsta
			radio.loadbalance_maxsta = nil
			radio.country      = nil  -- consumed into country_code above
		end

		-- Live connected-client counts, nested per-vap as sta_table -- matches
		-- the real controller's vap-stats DTO, which nests connected clients
		-- inside each vap_table entry rather than a flat top-level table
		-- (confirmed against unifi-network-application:10.4.57's own
		-- bytecode; see PROTOCOL-VALIDATION.md's outbound payload
		-- field reference).
		-- Live-corrected per-radio entries, keyed by UCI device name, for the
		-- vap loop below. The radio loop above overwrote each entry's channel
		-- with the live negotiated iw value and re-derived its band from it;
		-- vap_table's own channel/radio are still UCI config echoes (possibly
		-- the literal "auto", and stringly-typed), which left vap_table/
		-- sta_table disagreeing with radio_table inside one payload.
		local radio_live_by_name = {}
		for _, radio in ipairs(radio_table) do
			radio_live_by_name[radio.name] = radio
		end
		local now = ctx._time()
		for _, vap in ipairs(vap_table) do
			local live = radio_live_by_name[vap.radio_name]
			if live then
				if live.channel then vap.channel = live.channel end
				if live.radio then vap.radio = live.radio end
				-- Same UCI-echo problem as channel: get_vap_table reads the
				-- `txpower` option, which does not exist while Transmit Power
				-- is Auto, so the vap's copy stayed nil even after the radio
				-- entry picked up the driver's real value.
				if live.tx_power then vap.tx_power = live.tx_power end
			end
			-- Resolve THIS vap's netdev, not the radio's first one.
			-- get_ifname_for_radio() returns whichever interface netifd
			-- lists first, which is the same thing only on a single-SSID
			-- radio. With two WLANs on one radio every secondary vap
			-- inherited the first vap's station dump: a brand-new IoT SSID
			-- with nobody on it reported nine connected clients, all of them
			-- the other WLAN's, complete with the other network's IP
			-- addresses. Every per-vap figure derived from `stas` below --
			-- num_sta, the traffic and retry counters, satisfaction -- was
			-- wrong the same way, and the device-level aggregates
			-- double-counted those stations once per vap on the radio.
			--
			-- get_ifnames_for_vap() matches on SSID within the radio's
			-- interface list and needs no extra data (same ubus call, same
			-- cjson dependency). When it cannot resolve -- no cjson, an
			-- older netifd that omits config.ssid, a radio with several
			-- interfaces and no match -- the vap reports NO clients rather
			-- than someone else's: an empty sta_table understates, a
			-- borrowed one invents associations that never happened.
			-- `essid` is what get_vap_table() calls it -- the vap has no
			-- `ssid` field, and passing one silently resolves to nil, which
			-- would empty every sta_table instead of fixing anything.
			--
			-- An Enhanced Open transition VAP is two BSSes, the hidden OWE
			-- one and the open one, and a VAP with private pre-shared keys
			-- has one more netdev per key VLAN (<vap>-<vid>). Each lists only
			-- its own stations, and the VAP's clients are the union of them all.
			--
			-- A wireless-uplink VAP names its own netdevs (ucihelper's
			-- backhaul_vap): the downlink shares its SSID with the uplink
			-- station on the same radio, so a lookup by SSID could land on
			-- either.
			local ok_if, ifnames
			local is_backhaul_vap = (vap.usage == "uplink" or vap.usage == "downlink")
			if type(vap._ifnames) == "table" then
				ok_if, ifnames = true, vap._ifnames
			else
				ok_if, ifnames = pcall(ufuci.get_ifnames_for_vap,
					vap.radio_name, vap.essid)
			end
			vap._ifnames = nil
			if not ok_if then shape_obs.complete = false end
			-- sta_ifname[i] is the hostapd BSS stas[i] is on, for the Minimum
			-- RSSI kick and Roaming Assistant below. A key VLAN's netdev lists
			-- its own stations but has no hostapd of its own, so those go to
			-- the VAP's.
			local stas, sta_ifname, hapd_read = {}, {}, {}
			-- sta_dev[i]: the netdev stas[i] was dumped from -- for a mesh
			-- downlink the child's own WDS netdev, which is what the bridge
			-- learnt that child's addresses behind.
			local sta_dev = {}
			-- sta_hapd: hostapd's all_sta per-station flags (is_11r), read
			-- once per BSS (a key VLAN netdev's stations are its BSS's).
			local sta_hapd = {}
			for _, ifname in ipairs(ok_if and type(ifnames) == "table" and ifnames or {}) do
				local bss = ufuci.bss_ifname and ufuci.bss_ifname(ifname) or ifname
				if not is_backhaul_vap then vap_by_ifname[bss] = vap.name end
				local ok_sta, rv2 = pcall(ctx._sysinfo.sta_table, ifname)
				if ok_sta and type(rv2) == "table" and not is_backhaul_vap then
					-- Stations are shaped on the netdev that lists them: a
					-- private pre-shared key's VLAN netdev carries its
					-- stations' frames, not the VAP's.
					local so = {down = vap.ratelimit_down, up = vap.ratelimit_up, macs = {}}
					shape_obs.by_ifname[ifname] = so
					for _, sta in ipairs(rv2) do
						if type(sta.mac) == "string" then
							local m = sta.mac:lower()
							so.macs[#so.macs + 1] = m
							shape_obs.where[m] = ifname
							shape_obs.conn[m] = tonumber(sta.connected_sec)
						end
					end
				elseif not is_backhaul_vap then
					shape_obs.complete = false
				end
				if ok_sta and type(rv2) == "table" then
					-- At most one hostapd_cli per BSS per heartbeat, and none for
					-- stations whose association it already answered for; a key
					-- VLAN netdev's stations not yet covered ask the cache too.
					local uncovered = false
					for _, s in ipairs(rv2) do
						if type(s.mac) == "string" and not sta_hapd[s.mac:lower()] then uncovered = true end
					end
					local get = ctx._sysinfo.hostapd_sta_flags_cached
					if uncovered and get then
						hapd_read[bss] = true
						local ok_c, hf = pcall(get, bss, rv2)
						if ok_c and type(hf) == "table" then
							for mac, v in pairs(hf) do sta_hapd[mac] = v end
						end
					elseif uncovered and not hapd_read[bss] and ctx._sysinfo.hostapd_sta_flags then
						hapd_read[bss] = true
						local ok_c, hf = pcall(ctx._sysinfo.hostapd_sta_flags, bss)
						if ok_c and type(hf) == "table" then
							for mac, v in pairs(hf) do sta_hapd[mac] = v end
						end
					end
					for _, sta in ipairs(rv2) do
						if not is_backhaul_vap then
							here_obs[#here_obs + 1] = {mac = sta.mac, ifname = bss,
								signal = sta.signal_avg or sta.signal, inactive_ms = sta.inactive_ms}
						end
						-- Behind another AP since its sta_roam; hostapd just
						-- has not noticed yet (staevents.roamed_away). Listed,
						-- 10.6's roam fallback records the move a second
						-- time, without tags (upstream ea0b5d6).
						if is_backhaul_vap or not (ctx._staevents
							and ctx._staevents.roamed_away(sta.mac, uptime, sta.inactive_ms)) then
							stas[#stas + 1] = sta
							sta_ifname[#stas] = bss
							sta_dev[#stas] = ifname
						end
					end
				end
			end
			vap.num_sta = #stas
			-- The wireless uplink's links, named the way the controller resolves
			-- them to devices: by each station's `serialno` (its fallbacks need
			-- a Ubiquiti OUI or a vwire-<MAC> ESSID, which an OpenWrt board
			-- has neither of -- PROTOCOL-VALIDATION.md § Wireless uplink). The
			-- uplink VAP's one "station" is the parent's downlink BSS; a
			-- downlink's stations are its children.
			if is_backhaul_vap and ctx._backhaul then
				local siblings
				for i, sta in ipairs(stas) do
					if vap.usage == "uplink" then
						local ok_p, parent = pcall(ctx._backhaul.parent_for_bssid, st,
							sta.mac, sta_dev[i], ctx._sysinfo)
						if ok_p and parent then sta.serialno = parent end
					else
						if siblings == nil then
							-- Every site AP this one knows: the scan entries the
							-- sibling element or the sibling exchange tagged.
							siblings = {}
							for _, r in ipairs(scan_radio_table) do
								for _, e in ipairs(type(r) == "table" and r.scan_table or {}) do
									if type(e) == "table" and e.is_unifi and type(e.serialno) == "string" then
										siblings[e.serialno:lower()] = true
									end
								end
							end
							local ok_sb, sb = pcall(ctx._sysinfo.sibling_bssids, true)
							for _, m in pairs(ok_sb and type(sb) == "table" and sb or {}) do
								if type(m) == "string" then siblings[m:lower()] = true end
							end
						end
						local ok_c, child = pcall(ctx._backhaul.child_serialno, sta_dev[i],
							siblings, cfg, ctx._sysinfo)
						if ok_c and child then sta.serialno = child end
					end
				end
			end
			-- Per-VAP traffic/retry counters ("Air Stats" in the controller
			-- UI) -- confirmed real field names via the decompiled vap-stats
			-- DTO (cVbZoFIZsWYaVCquTr$QCtdvLKOBb): rx_bytes/rx_packets/
			-- tx_bytes/tx_packets/tx_retries/tx_dropped, aggregated here by
			-- summing each connected station's own counters (iw(8) doesn't
			-- expose a single already-aggregated per-radio/per-VAP counter,
			-- only per-station ones). rx_dropped/rx_errors/tx_errors/
			-- satisfaction have no source data anywhere in iw's output (ARQ
			-- retry/failure counters are inherently TX-side only) -- left
			-- unset rather than invented.
			local vap_rx_bytes, vap_tx_bytes = 0, 0
			local vap_rx_packets, vap_tx_packets = 0, 0
			local vap_tx_retries, vap_tx_dropped = 0, 0
			local signal_sum, signal_count = 0, 0
			-- This VAP's WiFi Experience tally (see sat_tallies above).
			local tally = satisfaction.tally()
			if not is_backhaul_vap then
				sat_tallies[#sat_tallies + 1] = tally
				sat_tallies_by_radio[vap.radio_name] = sat_tallies_by_radio[vap.radio_name] or {}
				table.insert(sat_tallies_by_radio[vap.radio_name], tally)
			end
			-- tx failed counts dropped frames on most drivers but failed
			-- attempts on mt76 (satisfaction.failed_is_dropped/dropped).
			local first_if = ok_if and type(ifnames) == "table" and ifnames[1] or nil
			local ok_drv, driver = false, nil
			if ctx._sysinfo.wifi_driver then ok_drv, driver = pcall(ctx._sysinfo.wifi_driver, first_if) end
			local failed_is_dropped = satisfaction.failed_is_dropped(ok_drv and driver or nil)
			local sta_table = {}
			for sta_i, sta in ipairs(stas) do
				local ifname = sta_ifname[sta_i]
				station_macs[sta.mac] = true
				-- A backhaul link's peer is another AP, never a client: no
				-- connection events for it (staevents.lua).
				if not is_backhaul_vap then
					sta_snapshot[sta.mac] = {vap = vap.name, signal = sta.signal,
						uptime = sta.connected_sec,
						idle = sta.inactive_ms and math.floor(sta.inactive_ms / 1000) or nil}
				end
				vap_rx_bytes    = vap_rx_bytes    + (sta.rx_bytes or 0)
				vap_tx_bytes    = vap_tx_bytes    + (sta.tx_bytes or 0)
				vap_rx_packets  = vap_rx_packets  + (sta.rx_packets or 0)
				vap_tx_packets  = vap_tx_packets  + (sta.tx_packets or 0)
				vap_tx_retries  = vap_tx_retries  + (sta.tx_retries or 0)
				local sta_dropped = satisfaction.dropped(failed_is_dropped, sta.tx_failed, sta.tx_retries)
				vap_tx_dropped  = vap_tx_dropped  + (sta_dropped or 0)
				if sta.signal then
					signal_sum   = signal_sum + sta.signal
					signal_count = signal_count + 1
				end
				-- "Minimum RSSI": a real per-radio (not per-vap) setting --
				-- vap.radio_name is the shared UCI radio device name, so every
				-- vap/SSID broadcasting on this same physical radio enforces
				-- the identical threshold. One-shot deauth only (see
				-- ucihelper.kick_station) -- no block, client can reassociate
				-- immediately.
				local minrssi_threshold = minrssi_threshold_by_radio[vap.radio_name]
				-- Never on a backhaul VAP: the uplink's "station" is the parent
				-- itself and a downlink's stations are mesh children, so neither
				-- Minimum RSSI nor Roaming Assistant may touch them.
				if not is_backhaul_vap and maxsta_by_radio[vap.radio_name] then
					lb_obs[#lb_obs + 1] = {radio = vap.radio_name, ifname = ifname,
						mac = sta.mac, inactive_ms = sta.inactive_ms}
				end
				if is_backhaul_vap then
					-- counters only
				elseif minrssi_threshold and sta.signal and sta.signal < minrssi_threshold then
					-- Below Minimum RSSI: its business, not Roaming Assistant's.
					-- A client locked to this AP (Lock to Access Point) is
					-- denied everywhere else: kicking it would only make it
					-- come straight back, or drop off the network.
					if not (ctx._lockap and ctx._lockap.is_locked(sta.mac)) then
						minrssi_obs[#minrssi_obs + 1] = {ifname = ifname, mac = sta.mac,
							signal = sta.signal, threshold = minrssi_threshold}
					end
				elseif vap.roam_assist_rssi and sta.signal then
					roam_obs[#roam_obs + 1] = {
						ifname = ifname, ssid = vap.essid, mac = sta.mac,
						signal = sta.signal, connected_sec = sta.connected_sec,
						threshold = vap.roam_assist_rssi,
					}
				end
				local prev = ctx._sta_stats_cache[sta.mac]
				-- The client panel's "TX Retries": the controller diffs this
				-- station's tx_retries and wifi_tx_attempts (with the byte and
				-- packet counters) every inform, keeps the positive deltas and
				-- overwrites wifi_tx_retries_percentage with
				-- retries / (retries + attempts + dropped) of those deltas
				-- (devmgr TtZhv, wifi.k bLwwMKkr; upstream 70c6498). Every
				-- retry rate it computes has that denominator, and the session
				-- archive fills wifi_tx_attempts from wifi_tx_packets: attempts
				-- are the frames sent, retries not included. Without tx_retries
				-- here the delta was 0 and every client read 0.0 %. Lifetime
				-- values; WiFi Experience uses its own per-minute window.
				local wifi_tx_attempts = sta.tx_packets or 0
				local tries = wifi_tx_attempts + (sta.tx_retries or 0) + (sta_dropped or 0)
				local wifi_tx_retries_pct = 0
				if tries > 0 then
					wifi_tx_retries_pct = (sta.tx_retries or 0) * 100 / tries
				end
				-- WiFi Experience, the firmware's formula (unifi/
				-- satisfaction.lua): SNR from the averaged signal, the last
				-- tx/rx rates, and the retry term over the last completed
				-- minute.
				local win = satisfaction.window(prev and prev.sat_window, {
					packets = sta.tx_packets, retries = sta.tx_retries,
					dropped = sta_dropped or 0,
				}, now)
				ctx._sta_stats_cache[sta.mac] = {time = now, sat_window = win}
				local mov = win.mov or {}
				local satisfaction_now, satisfaction_reason, anomalies = satisfaction.score{
					snr = satisfaction.snr(sta.signal_avg or sta.signal, noise_by_radio[vap.radio_name]),
					tx_kbps = sta.tx_bitrate and math.floor(sta.tx_bitrate * 1000 + 0.5),
					rx_kbps = sta.rx_bitrate and math.floor(sta.rx_bitrate * 1000 + 0.5),
					tries = mov.tries, retries = mov.retries, dropped = mov.dropped,
				}
				if satisfaction_now then
					tally.add(satisfaction_now, satisfaction_reason, anomalies)
				end

				sta_table[#sta_table + 1] = {
					-- The device behind a backhaul link (the parent on an
					-- uplink VAP, a child on a downlink); nil everywhere else.
					serialno   = sta.serialno,
					active     = true,
					mac        = sta.mac,
					-- The guest portal's state (unifi/guest.lua sta_authorized).
					authorized = guest.sta_authorized(st, vap.id, sta.mac),
					ap_mac     = mac_str,
					channel    = vap.channel,
					radio      = vap.radio,
					signal     = sta.signal,
					-- rssi is the SNR in dB, as UniFi firmware sends it
					-- (fill_stainfo_json, firmware-confirmed for 3.9.27 to
					-- 4.0.15: signal = rssi + max(noise, -96)); the
					-- controller's readers test it against 5 (mesh) and
					-- convert it with -95 (upstream 074b070). It used to be
					-- the dBm signal.
					rssi       = satisfaction.snr(sta.signal, noise_by_radio[vap.radio_name] ~= 0
						and noise_by_radio[vap.radio_name] or nil),
					-- noise: the radio's live noise floor (dBm). The
					-- wireless-client model reads it as plain data and the
					-- console's WiFiman service (:8900/proxy/) passes it on;
					-- without it that reply says "noise":0. Left out, not
					-- 0, when the survey has no reading.
					noise      = noise_by_radio[vap.radio_name] ~= 0
						and noise_by_radio[vap.radio_name] or nil,
					-- chwidth: the client's channel width as a code (0/1/2/3/
					-- 4/5 = 20/40/80/160/240/320 MHz). The controller turns it
					-- into the client's channel_width (10.6.106: devmgr
					-- FrAskVY reads getOptionalInt("chwidth") through the
					-- com.ubnt.i.g.a.b width enum), which the WiFiman reply
					-- carries. The wider of the last tx/rx frame: one
					-- direction's last frame can be a 20 MHz management one.
					chwidth    = M.CHWIDTH_CODE[math.max(sta.tx_width or 20,
						sta.rx_width or 20)],
					-- No capacity/throughput/linkscore/multicast: UniFi
					-- firmware sends none of them (fill_stainfo_json,
					-- firmware-confirmed for 3.9.27 to 4.0.15), and the 10.x
					-- controller reads them only off a mesh uplink's entry
					-- (upstream e50bdc3). They were a tx-rate proxy, a byte
					-- rate and two zeros.
					-- Cumulative per-client counters -- confirmed real field
					-- names via the decompiled vapInformProcessor
					-- (com.ubnt.service.devmgr.c.KHUkYjHujLgFBD), which
					-- copies exactly these names off each incoming sta_table
					-- entry ("channel","radio","name","signal","rssi",
					-- "tx_rate","rx_rate","tx_packets","rx_packets",
					-- "tx_bytes","rx_bytes") and computes its own bytes-d/
					-- rate-d deltas between informs -- so these must be sent
					-- as raw cumulative counters, not pre-computed rates.
					rx_bytes   = sta.rx_bytes or 0,
					tx_bytes   = sta.tx_bytes or 0,
					rx_packets = sta.rx_packets or 0,
					tx_packets = sta.tx_packets or 0,
					-- tx_rate/rx_rate: controller's tx_rate/rx_rate are in
					-- Kbps (matches real-device captures, e.g. tx_rate:
					-- 39000 for a 39 Mbps MCS rate); iw reports Mbit/s.
					tx_rate    = sta.tx_bitrate and math.floor(sta.tx_bitrate * 1000) or 0,
					rx_rate    = sta.rx_bitrate and math.floor(sta.rx_bitrate * 1000) or 0,
					-- uptime/idletime: iw's "connected time"/"inactive time"
					-- are the same concepts: seconds associated, seconds
					-- since last activity. Only set uptime when iw actually
					-- reports connected time (older iw builds omit it).
					uptime     = sta.connected_sec,
					idletime   = sta.inactive_ms and math.floor(sta.inactive_ms / 1000) or nil,
					-- tx_mcs/rx_mcs: confirmed real field names (not
					-- "tx_mcs_index", which is only the ucore-message wire
					-- name) via the decompiled wireless-client model
					-- (com.ubnt.service.l.e.AQODNNoMmBlFpWXX) and unpoller/
					-- unifi's REST client struct. iw's bitrate lines already
					-- print this ("144.4 MBit/s MCS 15 short GI"); only set
					-- when iw actually reports an MCS-based rate (legacy
					-- pre-11n rates have none).
					tx_mcs     = sta.tx_mcs,
					rx_mcs     = sta.rx_mcs,
					-- radio_proto: still sent for the disconnect-time session
					-- archive (com.ubnt.service.devmgr.TtZhv reads this string
					-- directly when a client disconnects), but it is NOT what
					-- drives the live, still-connected display -- confirmed by
					-- decompiling the actual live-update path
					-- (com.ubnt.service.devmgr.HCKpgcBFPLu, a KrlpWXOulbN
					-- implementation) down to com.ubnt.g.s.jRsSex, whose
					-- generation logic ignores any "radio_proto" string
					-- entirely and instead derives it from boolean per-station
					-- capability flags -- is_11be/is_11ax/is_11ac/is_11n/
					-- is_11b -- falling through to the lowest ("g" on 2.4GHz,
					-- "a" on 5GHz) when none are set. That's why sending only
					-- radio_proto left every live client showing "g"/"a" and
					-- why nss (read directly, no derivation) worked
					-- immediately: these booleans were the missing piece.
					is_11n     = sta.tx_generation == "n",
					is_11ac    = sta.tx_generation == "ac",
					is_11ax    = sta.tx_generation == "ax",
					is_11be    = sta.tx_generation == "be",
					radio_proto = sta.tx_generation or (vap.radio == "na" and "a" or "g"),
					nss         = sta.tx_nss or 1,
					wifi_tx_attempts = wifi_tx_attempts,
					wifi_tx_retries_percentage = wifi_tx_retries_pct,
					tx_retries       = sta.tx_retries,
					wifi_tx_dropped  = sta_dropped,
					-- WiFi Experience (unifi/satisfaction.lua). The controller
					-- computes none of it: it stores what the AP sends.
					-- satisfaction_reason is the bit of the term that set the
					-- score, anomalies the bitmask of every weak term; both
					-- are on the controller's client model (getOptionalLong).
					satisfaction        = satisfaction_now,
					satisfaction_now    = satisfaction_now,
					satisfaction_reason = satisfaction_reason,
					anomalies           = anomalies,
					-- ip/hostname/ipv6_addresses: what the controller keeps
					-- as the client's last_ip, hostname and last_ipv6 (10.6.106
					-- devmgr URbVkSXx; its live `ip` only while no UniFi OS
					-- gateway is connected in the site -- PROTOCOL-VALIDATION.md
					-- § sta_table). Each left out when this device has no
					-- answer: absent is the controller's "keep what you had".
					ip               = sta_addr(ctx._sysinfo._ip_by_mac, sta.mac),
					hostname         = sta_addr(ctx._sysinfo._hostname_by_mac, sta.mac),
					ipv6_addresses   = sta_addr(ctx._sysinfo._ipv6_by_mac, sta.mac),
				}
				M.sta_flags(ctx, sta_table[#sta_table], sta, ifname,
					sta_hapd[sta.mac:lower()])
			end
			vap.sta_table  = ufp.arr(sta_table)
			vap.rx_bytes   = vap_rx_bytes
			vap.tx_bytes   = vap_tx_bytes
			vap.rx_packets = vap_rx_packets
			vap.tx_packets = vap_tx_packets
			vap.tx_retries = vap_tx_retries
			vap.tx_dropped = vap_tx_dropped
			-- Per-RADIO TX counters, accumulated across every VAP on it.
			--
			-- radio_table_stats carried only name/channel/cu_* -- no TX
			-- counters at all -- and the controller does not fill them from
			-- the vap_table copies it already has. Instead its stored entry
			-- ended up with tx_packets=243, tx_retries=0 and, from those,
			-- tx_retries_pct=100, which the Devices view renders as a
			-- permanent "TX Retries: High (100%)" on an AP whose real retry
			-- rate is a few percent. Confirmed against a live 10.4.57
			-- controller, on both APs.
			-- wifi_tx_attempts / wifi_tx_dropped: the pair the controller
			-- aggregates upward into stat.ap ("<band>-wifi_tx_attempts",
			-- "radio0-wifi_tx_attempts", "user-...-wifi_tx_attempts") and
			-- divides to get a retry/failure rate. openUF sent them per
			-- STATION only, so every aggregate sat at 0 and the division
			-- degenerated -- which is what pinned "TX Retries: High (100%)"
			-- on the Devices view even though the signal-bucketed attempt
			-- counters, derived from the same per-station data, were populated
			-- correctly. Attempts are the frames sent, retries not included,
			-- the same definition sta_table uses (the controller's rate is
			-- retries / (retries + attempts + dropped)); dropped is the
			-- driver's own drop count (satisfaction.dropped: tx_failed, less
			-- the retries that mt76 folds into it; upstream c0a2047).
			vap.wifi_tx_attempts = vap_tx_packets
			vap.wifi_tx_dropped  = vap_tx_dropped
			local rstat = radio_stats_by_name[vap.radio_name]
			if rstat then
				rstat.wifi_tx_attempts =
					(rstat.wifi_tx_attempts or 0) + vap.wifi_tx_attempts
				rstat.wifi_tx_dropped =
					(rstat.wifi_tx_dropped or 0) + vap.wifi_tx_dropped
				rstat.tx_packets = (rstat.tx_packets or 0) + vap_tx_packets
				rstat.tx_retries = (rstat.tx_retries or 0) + vap_tx_retries
				rstat.tx_dropped = (rstat.tx_dropped or 0) + vap_tx_dropped
				rstat.rx_packets = (rstat.rx_packets or 0) + vap_rx_packets
				rstat.tx_bytes   = (rstat.tx_bytes   or 0) + vap_tx_bytes
				rstat.rx_bytes   = (rstat.rx_bytes   or 0) + vap_rx_bytes
				-- Retries as a share of every try (sent + retried + dropped),
				-- the controller's own definition, which sta_table's
				-- wifi_tx_retries_percentage uses too. Left absent while
				-- nothing has been transmitted, rather than reported as 0% or
				-- 100% of nothing.
				local tries = rstat.tx_packets + rstat.tx_retries + (rstat.tx_dropped or 0)
				if tries > 0 then
					rstat.tx_retries_pct =
						math.floor(rstat.tx_retries * 100 / tries + 0.5)
				end
			end
			-- avg_client_signal: mean RSSI (dBm, negative) of currently
			-- associated clients on this VAP. The stat archiver (decompiled
			-- com.ubnt.service.system.QDcGUYAmLvJwylXw) reads this exact
			-- field name directly off each vap_table entry -- alongside the
			-- existing num_sta -- to compute the "Avg. Signal" column; it is
			-- NOT derived server-side from per-client signal the way
			-- "weakest_clients_signal_avg" is, so omitting it left that
			-- column permanently blank regardless of per-client signal
			-- already being sent correctly.
			if signal_count > 0 then
				vap.avg_client_signal = math.floor(signal_sum / signal_count)
			end
			-- satisfaction: the mean of this VAP's clients' own scores. The
			-- controller does NOT derive it from the per-client values it
			-- already has -- with this absent, the Devices list showed
			-- "No Clients" in the Experience column on an AP with eight
			-- connected clients, all of them individually scored (96, 82,
			-- 93 ...) in the Clients view.
			--
			-- Truncated, as the firmware does (calc_vap_satisfaction), and -1
			-- with no clients, as the firmware sends it: 0 would read as
			-- "terrible experience", and the controller's stat archiver
			-- skips -1. The two bar charts count this VAP's clients per
			-- anomaly and per limiting term (fill_wireless_info_full).
			vap.satisfaction = tally.mean()
			vap.anomalies_bar_chart = tally.chart(satisfaction.ANOMALY_KEYS)
			vap.reasons_bar_chart = tally.chart(satisfaction.REASON_KEYS)
			-- cu_total/cu_self_rx/cu_self_tx/cu_interf: same per-radio channel-
			-- utilization figures as radio_table_stats, duplicated onto each
			-- VAP on that radio -- see radio_cu_stats above for why.
			local cu = radio_cu_stats[vap.radio_name]
			if cu then
				vap.cu_total   = cu.cu_total
				vap.cu_self_rx = cu.cu_self_rx
				vap.cu_self_tx = cu.cu_self_tx
				vap.cu_interf  = cu.cu_interf
			end
			vap.roam_assist_rssi = nil  -- internal, consumed above
			-- Only when non-zero, as the firmware sends it. The controller
			-- copies it into radio_table_stats, where the UI centres a
			-- 2.4 GHz 40 MHz channel at channel + 2 * extchannel (upstream
			-- 8b0ed77).
			local ext = extchan_by_radio[vap.radio_name]
			vap.extchannel = ext ~= 0 and ext or nil
			vap.ratelimit_down, vap.ratelimit_up = nil, nil  -- shape_obs's
		end
		-- Minimum RSSI's kick: one-shot deauth (ucihelper.kick_station), no
		-- block; hostapd's rssi_reject_assoc_rssi, 3 dB higher, keeps the
		-- client from coming straight back.
		local kicked = {}
		if ctx._minrssi then
			local ok_mr, mr_kicks = pcall(ctx._minrssi.tick, minrssi_obs, now)
			for _, k in ipairs(ok_mr and mr_kicks or {}) do
				pcall(ufuci.kick_station, k.ifname, k.mac)
				kicked[k.mac] = true
				-- For the departure event's assoc_status (staevents.lua).
				if ctx._lockap then ctx._lockap.note_kick(k.mac, now) end
			end
		end
		-- Load balance's kick: the most idle stations above the radio's cap,
		-- not counting the ones Minimum RSSI just kicked (unifi/loadbalance.lua).
		if #lb_obs > 0 then
			local ok_lb, lb_kicks = pcall(loadbalance.kicks, lb_obs, maxsta_by_radio, kicked)
			for _, k in ipairs(ok_lb and lb_kicks or {}) do
				pcall(ufuci.kick_station, k.ifname, k.mac)
			end
		end
		-- athstats.satisfaction: the radio's VAP scores weighted by their
		-- client counts (calc_radio_satisfaction, unifi/satisfaction.lua). The controller (10.6.106, inform handler
		-- iceUMDuewFNFLMOqti) stores `athstats.getInt("satisfaction", -1)`
		-- as the radio's satisfaction, and the stat archiver
		-- (com.ubnt.service.system.v.fdwW) archives `<radio>-satisfaction`
		-- and `<band>-satisfaction` from it unless it is -1. Left out, the
		-- archiver's getInt() default is 0, so a radio with eight happy
		-- clients was archived at 0. -1 is the controller's own "no score"
		-- sentinel, so a radio without clients sends that, not a 0.
		for _, radio in ipairs(radio_table) do
			if radio.athstats then
				radio.athstats.satisfaction =
					satisfaction.rollup(sat_tallies_by_radio[radio.name] or {})
			end
		end
		-- Forget stations not seen for ten minutes. Each entry is tiny, but
		-- the table is keyed by CLIENT MAC and was never emptied, so on a
		-- daemon that runs for months in a place with transient clients it
		-- only ever grew. A station back after that long is a fresh
		-- association, whose WiFi Experience window starts afresh anyway.
		-- Assigning nil during pairs() is defined behaviour.
		for mac, prev in pairs(ctx._sta_stats_cache) do
			if now - prev.time > ctx.STA_STATS_FORGET_AFTER then
				ctx._sta_stats_cache[mac] = nil
			end
		end
	end

	-- port_table: the device's own ethernet ports plus, per non-uplink port,
	-- the wired hosts learned behind it. Confirmed via decompiled
	-- controller 10.4.57 (com.ubnt.service.devmgr.PGOcbDWlbnYQdFW /
	-- DyonYyyYJkiyv / TtZhv, see PROTOCOL-VALIDATION.md) that this is only
	-- processed at all when Device.isSwitch() is true for the reported
	-- model -- which it is for U6IW (registered in the controller's model
	-- registry with 5 ports and a switch feature flag), so this is not
	-- optional for that model: an empty/missing port_table means zero
	-- wired clients can ever appear, and the device's Ports view stays
	-- empty, regardless of what's actually bridged into br-lan.
	local ports = (cfg and cfg.net and cfg.net.ports) or {
		{idx = 1, ifname = (cfg and cfg.net and cfg.net.wan_cpueth) or "eth0", uplink = true},
		{idx = 2, ifname = (cfg and cfg.net and cfg.net.lan_cpueth) or "eth1"},
	}
	local iface_by_name = {}
	for _, iface in ipairs(ifaces) do iface_by_name[iface.name] = iface end

	-- Every socket is its own netdev, and the bridge they are all enslaved to
	-- knows which one the gateway is behind. Measured rather than declared: a
	-- board constant is wrong the moment someone moves the cable, and a socket
	-- wrongly treated as downstream reports the whole LAN segment as hosts
	-- plugged into it.
	--
	-- Only honoured when it names a socket this board actually reports.
	-- Otherwise no entry would be flagged at all and the uplink would publish
	-- a mac_table of the entire far side -- worse than the static fallback.
	local uplink_ifname = nil
	-- Kept in scope for the port loop: the FDB dump uplink_bridge_port already
	-- takes of this bridge carries the hosts of every socket ENSLAVED TO IT
	-- too, so those sockets are served from it rather than forking a
	-- `bridge fdb show dev <socket>` of its own.
	--
	-- "Enslaved to it" is the load-bearing half, and this was read as "every
	-- socket" -- which is true right up until openUF moves one. A socket the
	-- controller assigns to a port VLAN is moved out of the management bridge
	-- into br-openuf<vid> (switchvlan.dsa_apply), and asking the UPLINK
	-- bridge's FDB about it finds nothing, because it is not a port of that
	-- bridge any more. The socket then published an empty mac_table and the
	-- controller credited its client to whatever else had seen the MAC -- the
	-- gateway, which sees everything. Each socket is asked about its own
	-- bridge in the port loop below.
	local uplink_bridge = nil
	do
		local lan = cfg and cfg.net and cfg.net.lan_cpueth
		local ok_br, br = pcall(ctx._sysinfo.bridge_of, lan)
		if ok_br and br then
			uplink_bridge = br
			local ok_up, name = pcall(ctx._sysinfo.uplink_bridge_port, br)
			if ok_up and name then
				for _, p in ipairs(ports) do
					if p.ifname == name then uplink_ifname = name break end
				end
			end
		end
	end
	local mgmt_vlan = (cfg and cfg.net and cfg.net.lan_vlanid) or 1

	local port_table = {}
	for _, p in ipairs(ports) do
		-- Link state from the kernel, not from the netdev merely existing:
		-- an unused socket exists in /proc/net/dev and is idle, and
		-- reporting it as a live port misleads the Ports view. Falls back
		-- to existence only when sysfs cannot answer.
		local iface = iface_by_name[p.ifname]
		local link_up = ctx._link_up(p.ifname)
		if link_up == nil then link_up = (iface ~= nil) end
		local entry = {
			port_idx    = p.idx,
			name        = "Port " .. tostring(p.idx),
			media       = "GE",
			up          = link_up,
			enable      = true,
			-- Negotiated link speed/duplex, read from the netdev rather
			-- than asserted: these were hardcoded 1000/full, so the
			-- controller's Ports view showed "GbE" for every device on
			-- every board no matter what the link had actually negotiated.
			-- A port with no link has no negotiated speed: 0, not the
			-- fallback. The kernel reports -1 for a down interface, which
			-- _link_speed already discards, so without this the fallback
			-- claimed a gigabit link on a socket with nothing in it.
			speed       = (not link_up) and 0 or (ctx._link_speed(p.ifname) or 1000),
			full_duplex = link_up and (ctx._link_duplex(p.ifname) ~= "half") or false,
			-- Detected where the bridge could answer, declared otherwise.
			-- Never both: a board that detects an uplink has already
			-- agreed the flag is not board truth.
			is_uplink   = (uplink_ifname ~= nil and p.ifname == uplink_ifname)
				or (uplink_ifname == nil and p.uplink) or false,
			speed_caps  = 0,
			port_poe    = false,
			poe_caps    = 0,
			rx_bytes    = iface and iface.rx_bytes   or 0,
			tx_bytes    = iface and iface.tx_bytes   or 0,
			rx_packets  = iface and iface.rx_packets or 0,
			tx_packets  = iface and iface.tx_packets or 0,
			rx_errors   = iface and iface.rx_errors  or 0,
			tx_errors   = iface and iface.tx_errors  or 0,
		}
		-- Wired clients are only reported on downstream (non-uplink)
		-- ports -- the controller itself skips client creation on ports
		-- flagged is_uplink, since that port faces the controller's own
		-- network, not an end host.
		--
		-- Do NOT be tempted to report just the gateway here, however
		-- reasonable "the device on the other end of this cable" sounds,
		-- and however visibly a real UniFi gateway does it on its own
		-- uplink port. openUF knows which MAC that is -- finding it is how
		-- the uplink socket was identified in the first place -- and
		-- reporting it would populate the Ports view's Connection column.
		-- It would also invert the topology. The controller matches every
		-- MAC on a port against its adopted devices, and a port carrying
		-- exactly one known device files that device in this one's
		-- `downlink_table`; the guard that would stop it is
		--     bl9 = !is_uplink && isUplinkMac(neighbour)
		-- which disables itself on precisely the port where it is needed.
		-- The gateway would hang beneath every AP that reported it.
		--
		-- A real gateway gets away with it because its upstream is the
		-- ISP's router, which is not an adopted device and so never
		-- reaches that branch. openUF cannot tell the two cases apart
		-- from the device, and the failure mode is a wrong map of the
		-- network, so it reports nothing on the uplink at all.
		if not entry.is_uplink then
			-- This socket's bridge, which is the uplink's for every socket
			-- openUF has not moved. bridge_of is TTL-cached and
			-- bridge_fdb_ports is memoized per bridge NAME for the pass,
			-- so the common case resolves to the same string and reuses
			-- the dump already taken -- no extra fork. A socket in
			-- br-openuf<vid> costs one dump of that bridge instead.
			--
			-- nil (not a bridge port at all) is passed through rather than
			-- papered over with the uplink's: mac_table then forks
			-- `bridge fdb show dev <socket>`, which is the right answer
			-- for an unbridged socket and an empty one for a bridged
			-- socket looked up in the wrong bridge.
			local ok_sb, sock_bridge = pcall(ctx._sysinfo.bridge_of, p.ifname)
			if not ok_sb then sock_bridge = nil end
			-- A socket in a bridge that is not the uplink's is one openUF
			-- moved, which is the only case where MAC learning is off and
			-- the FDB has nothing to say -- so it is the only case allowed
			-- to fall back to switchvlan's nft tap. Every other board never
			-- forks `nft` at all.
			local allow_tap = (uplink_bridge ~= nil and sock_bridge ~= nil
				and sock_bridge ~= uplink_bridge)
			-- Which VLAN this socket carries, read off the bridge openUF
			-- moved it into rather than plumbed down from the push: that
			-- bridge IS the VLAN (ucihelper names it br-openuf<vid>), so
			-- the socket's own enslavement is the most direct statement of
			-- it available, and it cannot disagree with where the frames
			-- actually go. nil for a socket still in the management
			-- bridge, which is the same thing as VLAN 1.
			local port_vlan = sock_bridge
				and tonumber(sock_bridge:match("^br%-openuf(%d+)$")) or nil
			if port_vlan == mgmt_vlan then port_vlan = nil end
			-- A vlan-filtering bridge (netmodel's, or a hand-made one) is one
			-- bridge for every network: the host's own FDB entry says which.
			if port_vlan == nil and sock_bridge and ctx._sysinfo.bridge_filters_vlans
				and ctx._sysinfo.bridge_filters_vlans(sock_bridge) then
				local ok_v, map = pcall(ctx._sysinfo.bridge_fdb_vlans, sock_bridge)
				if ok_v and type(map) == "table" and next(map) then port_vlan = map end
			end
			entry.mac_table = ufp.arr(ufp.filter_hosts(
				ctx._sysinfo.mac_table, p.ifname, sock_bridge, allow_tap,
				port_vlan, self_macs, station_macs))
		end
		port_table[#port_table + 1] = entry
	end

	-- lldp_table (field names confirmed against the real controller's OXMua
	-- DTO -- see PROTOCOL-VALIDATION.md's outbound payload field
	-- reference)
	local lldp_table = {}
	for _, nbr in ipairs(lldp_nbrs) do
		lldp_table[#lldp_table + 1] = {
			chassis_descr   = nbr.system_desc,
			chassis_id      = nbr.chassis_id,
			local_port_name = nbr.port,
			local_port_idx  = nbr.local_port_idx,
			is_wired        = true,  -- LLDP is inherently a wired-link protocol
			port_id         = nbr.port_id,
			port_descr      = nbr.port_descr,
		}
	end

	-- (spectrum_scan_timestamp is not sent: the controller stamps it itself,
	-- in ms, from quick-scan results; upstream a684980.)
	local spectrum_scanning = false
	for _, job in ipairs(ctx._scan_jobs or {}) do
		if job.who == "spectrum-scan" then spectrum_scanning = true end
	end

	local payload = {
		_type            = "state",
		["default"]      = not st.adopted,
		["state"]        = st.adopted and 2 or 0,  -- 2=connected, 0=unadopted (per amd989)
		locating         = st.locating or false,
		mac              = mac_str,
		serial           = mac_str:gsub(":", ""),
		model            = uap.model or "U6IW",
		platform         = uap.platform or "U6IW",
		model_display    = uap.model_display,
		hostname         = st.hostname or "openUF",
		ip               = st.ip or "0.0.0.0",
		inform_url       = st.inform_url,
		cfgversion       = st.cfgversion,
		-- The last config this device applied without an error. The controller
		-- sets the device's last_config_applied_successfully from
		-- cfgversion_effective == cfgversion (see ctx._settle_cfgversion).
		cfgversion_effective = st.cfgversion_effective,
		-- Identity detail real firmware reports and the controller stores on
		-- the device record.
		--
		-- netmask only once adopted. The controller builds the device's subnet
		-- from ip + netmask, and when its own address falls inside it (an AP on
		-- the gateway's LAN) it adopts over SSH with the default ubnt/ubnt login
		-- instead of delivering the key over the inform channel -- which fails
		-- on OpenWrt ("SSH adopt failed ... loginfail", then ADOPT_FAILED and
		-- every inform rejected). Without a netmask the subnet is unknown and a
		-- device discovered by inform is adopted over L3. Confirmed on 10.6.106
		-- (devmgr XtugNwLHsUnnZrF, hyFnQ.getSubnetInfo).
		netmask          = st.adopted and st.netmask or nil,
		architecture     = ctx._uname_info().machine,
		kernel_version   = ctx._uname_info().release,
		uptime           = uptime,
		time             = os.time(),
		-- Bare firmware version string only -- NOT model-prefixed. The
		-- controller compares this against its firmware catalog's own
		-- "version" field (e.g. "6.8.2.15592") with a strict, unnormalized
		-- string equality check; a prefixed value like "U6IW.6.8.2.15592"
		-- never matches even when the numeric version is identical, so the
		-- device is permanently shown as needing an update. `fw.pre` (e.g.
		-- "U6IW.") is a separate, correct field used only by announce.lua's
		-- L2 discovery "firmware version verbose" TLV -- do not reuse it here.
		-- The catalogue version: built into the identity, or learned from the
		-- controller's own upgrade commands. 10.6 calls a device upgradable
		-- whenever this differs from the catalogue's by a character; the
		-- opt-in variants (advertising an OpenWrt update, the revision scheme)
		-- are in upgrade.lua.
		version          = ctx._upgrade.version(uap.fw and uap.fw.ver or "6.6.55",
			cfg and cfg.config, st.fw_version),
		required_version = uap.required_version or "6.0.0",
		bootrom_version  = uap.bootver or "",
		country_code     = st.country_code or derived_country or 840,
		mem_total        = meminfo.total_kb * 1024,
		mem_used         = mem_used_kb * 1024,
		-- The controller takes the inform's source for the device's management
		-- address from `inform_ip`; absent, it uses the HOST PART of inform_url
		-- verbatim -- no DNS -- and rejects anything that is not an IP literal
		-- ("invalid inform_ip unifi" -> HTTP 400, confirmed on 10.6.106). So a
		-- hostname inform URL, including the shipped default, could never
		-- complete an adoption without this.
		inform_ip        = ctx._inform_ip(st.inform_url),
		-- Subsystem id from the model registry (uidb `sysid`); the controller
		-- resolves the model from it first and only then from `model`.
		sysid            = uap.sysid,
		-- Where the controller's STUN service can reach this device to make it
		-- inform at once (stun.lua). Strings, as real devices send them.
		connect_request_ip   = ctx._stun_client and (ctx._stun_client:address(st.ip)) or nil,
		connect_request_port = ctx._stun_client
			and tostring(select(2, ctx._stun_client:address(st.ip))) or nil,
		-- Bit 0x10 (16): Device.hasQCASwitch() in the decompiled controller
		-- is exactly hasFirmwareCapability(16), and PGOcbDWlbnYQdFW gates the
		-- Ports view's projection of port_table into the device DTO on it.
		-- Wired-client ingestion itself is gated only on isSwitch() (a
		-- model-registry property, not this bit), so wired clients can
		-- appear without this -- but the Ports view needs it.
		-- Bit 0x100 (256): Device.hasOWRTSwitch() -- exactly
		-- hasFirmwareCapability(256), literally "OpenWrt switch" as opposed
		-- to a genuine QCA hardware switch ASIC (fitting, since that's
		-- exactly what this is). Without it, the REST API's per-port VLAN
		-- validator (com.ubnt.ace.api.e.VVyiC, only reachable once
		-- hasQCASwitch() above is true) unconditionally rejects any port
		-- whose forward mode resolves to the default "all" -- i.e. every
		-- port that has never had `forward` explicitly set -- with
		-- api.err.VlanTaggingUnsupportedByDevice, before ever touching
		-- vlan_caps or anything port-specific. Confirmed live: assigning a
		-- port's Native VLAN/Network failed with exactly that error at
		-- fw_caps=0x10, and succeeded once this bit was added (0x110) --
		-- reproduced directly against the REST endpoint, bypassing the UI,
		-- to rule out unrelated causes. See PROTOCOL-VALIDATION.md's
		-- "Capability bitmasks" for the full derivation (traced through
		-- an obfuscation-induced macOS case-folding extraction bug along
		-- the way).
		-- + 0x100000: the controller sends RADIUS Dynamic Authorization
		-- (aaa.radius.dad.*, aaa.<n>.radius.das.*) only to a device with it
		-- (10.6.106 VAZShipWTNxlo); openwrt/das.lua is the dispatcher.
		-- The rest are M.fw_caps' own comments.
		fw_caps          = M.fw_caps(ctx, cfg),
		-- wifi_caps: each bit gates one WiFi feature in the controller's config
		-- generator (decompiled from 10.6.101, PROTOCOL-VALIDATION.md,
		-- Capability bitmasks) and is claimed only where this device can
		-- carry the feature out. The bits not listed gate features openUF
		-- does not implement.
		wifi_caps        = 0
			-- 0x4, Device.supportBandsteering(): without it the controller
			-- never emits the device-level bandsteering.* block (the AP's
			-- own Band Steering setting, unifi/wlan.lua parse_bandsteering).
			-- Decompiled from 10.6.101, captured on 10.4.57 (upstream).
			+ 0x4
			-- 0x8, supportVapBasedBandsteering(): keeps that block enabled
			-- when some WLAN has no 2.4/5 GHz pair; without it one
			-- single-band WLAN switches the device's steering off.
			+ 0x8
			-- 0x10, supportSpectrumScan(): the controller refuses Airtime
			-- Scan ("Scan Now", the spectrum-scan cmd) without it, and
			-- stat/spectrum-scan leaves the AP out (upstream a684980). Every
			-- driver has the channel survey the sweep reads.
			+ 0x10
			-- 0x20: supportATFConfig() = hasWifiCapability(32). Without it no
			-- atf.* block (the AP's Airtime Fairness switch) is sent; claimed
			-- where mac80211's per-phy airtime_flags exists (airtime.lua).
			+ ((ctx._airtime and probe(ctx._airtime.supported)) and 0x20 or 0)
			-- 0x100000: supportWpaPpsk(). Without it a WLAN with Private
			-- Pre-Shared Keys is skipped entirely ("PPSK is not supported ...
			-- will be skipped"); claimed where hostapd can put each key on its
			-- own VLAN (sysinfo.ppsk_supported).
			+ (probe(ctx._sysinfo.ppsk_supported) and 0x100000 or 0)
			-- 0x1000: supportRadiusMacAuth(). No 10.6.106 config generator reads
			-- it: aaa.<n>.radius.macacl.* goes out whatever the bit, and
			-- unifi/wlan.lua + ucihelper apply it (macaddr_acl=2). Claimed so
			-- the device reports what it does.
			+ 0x1000
			-- 0x1000000: supportLockAp(). The site offers a client's "Lock to
			-- Access Point" only while every wireless device claims it (10.6.106
			-- site feature LOCK_AP). The lock itself reaches every OTHER AP as
			-- macacl entries of type lock2ap under policy deny, which unifi/
			-- wlan.lua parses like the user's MAC filter and hostapd enforces;
			-- the AP the client is locked to receives nothing for it.
			+ 0x1000000
			-- 0x1 (VWIRE) + 0x800 (MESHV3): the wireless uplink. Without 0x1
			-- the controller drops the device's mesh-connect flag; with both
			-- its push carries the mesh block, the hidden WDS downlink and the
			-- 4-address uplink station (unifi/mesh.lua, openwrt/backhaul.lua;
			-- bisected live by yesrab/openUF on 10.6.106). Only with the
			-- wireless_uplink option: unconfirmed on this project's hardware,
			-- and claiming it puts a hidden BSS on every AP's 5 GHz radio.
			+ ((cfg and cfg.config and cfg.config.wireless_uplink == true) and 0x801 or 0),
		-- Bit 0x40 (64): Device.supportAdvertisingDeviceNameInBeacon() in the
		-- decompiled controller is exactly hasWifiCapability2(64) -- i.e. bit
		-- 6 of a SECOND capability bitmask, wifi_caps2, entirely separate
		-- from fw_caps/wifi_caps above. Confirmed by decompiling
		-- com/ubnt/service/config's WLAN-config-generator method: it only
		-- emits wireless.<n>.advertise_ap_name into system_cfg at all when
		-- this bit is set -- otherwise the "Show Access Point Name in
		-- Beacon" WLAN toggle is silently dropped, which is exactly what a
		-- live capture showed (toggling it produced zero system_cfg/mgmt_cfg
		-- diff, and the controller didn't even bother re-pushing config on
		-- the next change) before this bit was added. A bit is claimed only
		-- where openUF implements its feature -- wifi_caps2 also gates
		-- several other real-hardware-only features (Mesh MLO parent/child,
		-- etc., see PROTOCOL-VALIDATION.md) that openUF does not implement
		-- and must not claim.
		wifi_caps2       = 0x40
			-- Bit 0x20 (32): Device.supportsAssistedRoaming(). Without it the
			-- controller never emits a WLAN's "Roaming Assistant"
			-- (wireless.<n>.btm_disassoc.*), which openwrt/roamassist.lua
			-- implements. Decompiled from controller 10.6.101.
			+ 0x20
			-- Bit 0x10 (16): Device.supportsAcsDfs(). Without it the
			-- controller never emits radio.<n>.blklst (the site's
			-- auto-channel exclusions) or radio.<n>.acsdfs (its 5 GHz DFS
			-- switch); both become UCI channels/acs_exclude_dfs in
			-- ucihelper.rf_config. Decompiled from controller 10.6.106.
			+ 0x10
			-- Bit 0x80 (128): Device.supportQuickScan(). Without it the
			-- controller never sends `quick-scan` (the RF view's Scan, the
			-- nightly 03:00 sweep while Radio AI is off, Radio AI's
			-- prescans); provision.lua runs it and quickscan_scanning reports
			-- its progress. Claiming it enrols the AP in those sweeps, each
			-- taking every radio of a band off-channel. Decompiled from 10.6.106.
			+ 0x80
			-- 0x400000: supportsMulticastSuppressor(). Without it no WLAN's
			-- wireless.<n>.multicast.suppressor (Conservative or Aggressive)
			-- is sent; bcfilter.lua enforces both. Decompiled from 10.6.106.
			+ 0x400000
			-- 0x200: supportNeighbourInScan(). Radio AI's neighbour isolation
			-- (site features RADIO_AI_NEIGHBOR_ISOLATION_NG/NA/6E) needs every
			-- AP on a band to claim it; an AP without it gets a `scan_band`
			-- command during a Radio AI run instead. The isolation matrix is
			-- built from the controller's peer-scan cache, which every inform's
			-- scan_radio_table fills from is_unifi entries (aS.qikih, kept an
			-- hour): openUF's sibling sightings (idlescan.lua's sweeps and
			-- sibling scans, every 30 min by default). Claimed only while one
			-- of those scans is configured. Decompiled from 10.6.106.
			+ (M.neighbour_scan_enabled(cfg) and 0x200 or 0)
			-- 0x2000: supportsRoamTopologyStats(). The controller then feeds
			-- `sta_roam` departures to its roaming detector and stops feeding
			-- it `success`, joining roams from `association` (auth_rssi)
			-- alone; staevents.lua sends both, with assoc_status. Only while
			-- connection events are on (sta_events). Decompiled from 10.6.106.
			+ ((cfg and cfg.config and cfg.config.sta_events == false) and 0 or 0x2000),
		-- Device-level (not per-radio -- see radio_table_stats above)
		-- Device-level Experience: the client VAPs' scores weighted by their
		-- client counts (calc_ap_satisfaction, unifi/satisfaction.lua). The
		-- controller does not aggregate the per-client scores it already
		-- holds, so without this the Devices list reads "No Clients" however
		-- many are connected. -1 with no clients, as the firmware sends it:
		-- the controller copies this field only when present, so leaving it
		-- out kept the last score on an AP whose clients had all left.
		satisfaction     = satisfaction.rollup(sat_tallies),
		-- True while a `spectrum-scan` sweep still has chunks to run
		-- (provision.lua's sweep jobs); its last chunk's inform says false.
		spectrum_scanning       = spectrum_scanning,
		-- Guest portal: the controller refuses to authorize a guest on an AP
		-- that reported no guest_token ("Missing Guest Token in AP[..]
		-- during guest authorization"). Only while the portal is enforced.
		guest_token = (type(st.guest) == "table" and st.guest.portal_url ~= nil)
			and st.guest_token or nil,
		-- A controller-issued quick-scan from its command until the inform
		-- that carries its results (inform.lua M._quickscan_pending).
		quickscan_scanning      = ctx._quickscan_pending ~= nil,
		-- Real devices report this under the hyphenated key "system-stats"
		-- with {cpu, mem, uptime} as percentage/uptime strings -- confirmed
		-- against a real captured USG inform payload (stephanlascar/
		-- unifi-gateway, poc/real_inform_payload_exemple.json). Previously
		-- sent as "sys_stats" (underscore) with raw loadavg_1/5/15 fields,
		-- which the controller would not have recognized at all.
		["system-stats"] = {
			cpu    = tostring(cpu_pct),
			mem    = tostring(mem_pct),
			uptime = tostring(uptime),
		},
		-- ...and sys_stats as well: 10.6 devices send both (the gateway's own
		-- inform does), and the controller stores this block verbatim as the
		-- device's load average and memory detail. It was `{}` on every openUF
		-- device.
		-- mem_used is the firmware's totalram - freeram (prepare_system_stats,
		-- firmware-confirmed for 3.9.27 to 4.0.15; upstream 8b0ed77), not the
		-- MemAvailable-based figure system-stats' percentage uses.
		sys_stats        = ufp.sys_stats(meminfo, meminfo.total_kb - meminfo.free_kb, loadavg()),
		if_table         = ufp.arr(if_table),
		radio_table      = ufp.arr(radio_table),
		radio_table_stats = ufp.arr(radio_table_stats),
		vap_table        = ufp.arr(vap_table),
		scan_radio_table = ufp.arr(scan_radio_table),
		port_table       = ufp.arr(port_table),
		lldp_table       = ufp.arr(lldp_table),
	}

	-- The wireless uplink, while the device is on it and associated: the
	-- `uplink` STRING naming the uplink VAP above (unifi/mesh.lua). Absent
	-- otherwise, so a wired uplink is read as before.
	if ctx._backhaul and ctx._backhaul.uplink_link and ufuci then
		local ok_up, link = pcall(ctx._backhaul.uplink_link, st, ufuci)
		local fields = ok_up and mesh.uplink_fields(link) or nil
		for k, v in pairs(fields or {}) do payload[k] = v end
	end

	-- Kept for staevents: this heartbeat's stations, and the identity fields a
	-- notification inform repeats.
	ctx._last_sta_snapshot = sta_snapshot
	ctx._last_here_obs = here_obs
	ctx._last_vap_by_ifname = vap_by_ifname
	ctx._roam_obs = roam_obs
	ctx._shape_obs = shape_obs
	ctx._last_identity = {}
	for _, k in ipairs(ctx._staevents.IDENTITY_FIELDS) do ctx._last_identity[k] = payload[k] end

	-- debug_caps (UCI section openuf.debug) / debug_payload_extra (local.json):
	-- RESEARCH ONLY. The rule
	-- everywhere else in this file is "never claim a bit openUF cannot honour";
	-- these are the deliberate, loudly logged exception (_warn_debug_overrides)
	-- so a go/no-go protocol experiment is a config edit and a restart. An
	-- extra key that already exists is overwritten on purpose.
	local conf = cfg and cfg.config
	if conf and type(conf.debug_caps) == "table" then
		for _, k in ipairs({"fw_caps", "wifi_caps", "wifi_caps2"}) do
			local v = tonumber(conf.debug_caps[k])
			-- As a Java int, like the masks openUF builds itself: bit 31
			-- unsigned would make the controller reject the whole inform.
			if v and v >= 0 and v < 4294967296 then payload[k] = M.signed32(v) end
		end
	end
	if conf and type(conf.debug_payload_extra) == "table" then
		for k, v in pairs(conf.debug_payload_extra) do payload[k] = v end
	end

	if ufuci and ufuci.end_pass then ufuci.end_pass() end
	if ctx._sysinfo.end_pass then ctx._sysinfo.end_pass() end
	return ufp.fix_empty_arrays(cjson.encode(payload))
end

return M
