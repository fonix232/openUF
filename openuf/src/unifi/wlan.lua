--[[
	wlan.lua -- the controller's WiFi configuration: the flat system_cfg
	key=value blob (aaa.*, wireless.*, radio.*, stamgr.*, macacl.*, ...)
	turned into the {radio_table, vap_table} tables ucihelper applies.
	Pure: the one thing it asks of the hardware comes in as `caps`.
]]--

local wire = require("unifi.wire")
local country = require("unifi.country")

local M = {}

-- Maps an OpenWrt htmode ("HT20", "HT40+", "VHT80", "HE160", ...) to a
-- channel width in MHz. Falls back to 20 for unrecognized/missing modes.
function M.width_from_htmode(htmode)
	if type(htmode) ~= "string" then return 20 end
	local n = htmode:match("(%d+)")
	return n and tonumber(n) or 20
end

-- radio.<n>.ieee_mode: the controller's per-radio 802.11 mode + channel width,
-- as a single madwifi/Ubiquiti-style compound token -- "11" + band ("ng"/"na")
-- + PHY and width ("ht20", "ht40", "vht80", "he80", ...). CONFIRMED live
-- 2026-07-18: a stock dual-band AP sends radio.1.ieee_mode=11nght20 (2.4GHz)
-- and radio.2.ieee_mode=11naht40 (5GHz), and flipping the per-device radio
-- setting Devices -> [AP] -> Settings -> Radios -> "2.4 GHz Channel Width"
-- from 20 to 40 changes exactly this key to 11nght40 (alongside
-- radio.<n>.cwm.mode 0->1, a redundant "channel width management" flag the
-- same width is already encoded in). This is the only channel-width signal on
-- the wire -- an earlier version of openUF parsed no mode key at all, so
-- ucihelper.rf_config()'s htmode mapping was unreachable and channel width
-- silently never applied despite USAGE.md claiming it did.
--
-- Returns an OpenWrt htmode string ("HT20"/"HT40"/"VHT80"/"HE80"/...), or nil
-- for an absent or unrecognized token, which leaves htmode unchanged (same
-- "absent -> nil -> leave alone" convention as channel/txpower above).
-- Longest suffix first: "eht"/"vht" must win over the "ht" they end with.
local _IEEE_MODE_PHY = {
	{ "eht", "EHT" }, { "vht", "VHT" }, { "he", "HE" }, { "ht", "HT" },
}
local _IEEE_MODE_WIDTHS = { ["20"] = true, ["40"] = true, ["80"] = true,
	["160"] = true, ["320"] = true }

local function _htmode_from_ieee_mode(ieee_mode, caps)
	if type(ieee_mode) ~= "string" then return nil end
	local head, width = ieee_mode:match("^(11%a+)(%d+)$")
	if not (head and _IEEE_MODE_WIDTHS[width]) then return nil end

	-- The two letters after the "11" are the band ("ng"/"na"), the rest is
	-- the PHY token. The band is not used to pick a channel -- OpenWrt
	-- derives that from the channel, and the controller can send
	-- channel=auto while still naming a band here -- but it IS what says
	-- which radio's capabilities to read below.
	local band, token = head:match("^11(%a%a)(%a*)$")

	-- A plain "ht" is not a request for 802.11n. It is all this wire format
	-- has ever said: the vocabulary is Atheros-era (the same push calls the
	-- VAPs ath0/ath1/ath2), and a real controller sends "11naht40" to a real
	-- U6-InWall, which runs it as HE40. The token carries the BAND and the
	-- WIDTH; the PHY generation is the device's own business, and reading
	-- the "ht" literally pinned an 802.11ax radio to 802.11n forever --
	-- confirmed live on an AX3000T, whose 5GHz radio came up HT40 on
	-- hardware that does HE160.
	--
	-- So: honour an explicit vht/he/eht token if one ever arrives, and
	-- otherwise run the best PHY the band's hardware has. Unknown
	-- capabilities (no `iw`, unparseable output) fall back to the literal
	-- reading rather than guessing upward -- same contract as clamp_htmode,
	-- which still caps the result downward from here.
	if band and token == "ht" then
		local best = caps and caps.best_phy and caps.best_phy(band)
		if best then return best .. width end
	end

	for _, phy in ipairs(_IEEE_MODE_PHY) do
		local kind, prefix = phy[1], phy[2]
		if head:sub(-#kind) == kind then return prefix .. width end
	end
	return nil
end

-- WiFi/radio config (SSID, security, per-radio channel/TX power) arrives via
-- system_cfg as a flat, hostapd/OpenWrt-style key=value blob -- NOT as the
-- resp.vap_table/radio_table/network_table JSON that ucihelper.apply_config()
-- was originally built and unit-tested against. Confirmed live against a
-- real controller (10.4.57): creating a WiFi network produces keys like
-- "aaa.1.ssid", "aaa.1.wpa.psk", "aaa.1.wpa=2", "wireless.1.parent=radio0",
-- "radio.1.phyname=radio0", "radio.1.channel=auto" -- a real controller
-- never sends resp.vap_table/radio_table/network_table at all, which meant
-- apply_config() (gated on resp.network_table) never actually ran against
-- one. This translates the flat blob into the {radio_table, vap_table}
-- shape apply_config() expects, so its already-correct, already-tested
-- VLAN-join/fast-roaming/mobility-domain logic can be reused unchanged
-- rather than reimplemented against the raw wire format.
--
-- Security derivation reads the akm set from aaa.<n>.wpa.key.<k>.mgmt (not
-- just aaa.<n>.wpa, which is only the WPA protocol version and stays "2"
-- even for a WPA2/WPA3 transition WLAN): SAE present -> sae/sae-mixed,
-- else WPA2-PSK. Confirmed live for the WPA2-PSK case (wpa=2 +
-- wpa.key.1.mgmt=WPA-PSK -> "wpa2").
--
-- WPA3 is gated on the DEVICE claiming it: a radio_table entry must report
-- `wpa3_supported = true` (see build_json) or the controller silently
-- downgrades a WPA2/WPA3 WLAN to plain WPA2 for that device, before the
-- config is even generated. Confirmed live against a 10.4.57 gateway --
-- setting that one field flipped the very next push from
-- `wpa.key.1.mgmt=WPA-PSK` to `SAE`, and brought the whole
-- wpa3.support/wpa3.transition/wpa3.ft.status/sae.* block with it.
--
-- Once it does arrive, `SAE` comes as the ONLY akm -- there is no WPA-PSK
-- alongside it even in transition mode -- so the akm set alone cannot tell
-- transition from WPA3-only. wpa3.transition is what distinguishes them, and
-- is read below.
--
-- Two earlier readings recorded here were wrong: that the PMF keys carry the
-- WPA3-mixed signal (they do not -- PMF is just PMF), and that a radio_caps
-- capability bit gates it (neither radio_caps nor radio_caps2 bit 0x1 has any
-- effect; both were tested live).
--
-- caps.best_phy(band): the best PHY generation the hardware has on a band
-- ("HE"), for the "ht"-means-any-PHY reading above; nil runs it literally.
---@param sys_raw string  system_cfg
---@param caps Caps?
---@return RadioIntent[] radio_table
---@return VapIntent[] vap_table
function M.parse(sys_raw, caps)
	local aaa, wireless, radio, stamgr, macacl = {}, {}, {}, {}, {}
	local global_countrycode = nil
	local qos_vap = {}
	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		-- qos.vap.<m>: "WiFi Speed Limit". Needs its own pattern rather than
		-- the generic <section>.<idx>.<key> one below, since the index sits a
		-- level down (qos.vap.1.*, alongside qos.if.<n>.* and qos.ebt.<n>.*).
		local qidx, qkey, qv = line:match("^qos%.vap%.(%d+)%.(.+)=(.*)$")
		if qidx then
			qidx = tonumber(qidx)
			qos_vap[qidx] = qos_vap[qidx] or {}
			qos_vap[qidx][qkey] = qv
		end
		local section, idx, key, v = line:match("^(aaa)%.(%d+)%.(.+)=(.*)$")
		if not section then section, idx, key, v = line:match("^(wireless)%.(%d+)%.(.+)=(.*)$") end
		if not section then section, idx, key, v = line:match("^(radio)%.(%d+)%.(.+)=(.*)$") end
		-- stamgr.<n>: per-radio "Station Manager" block, indexed the same as
		-- radio.<n> -- confirmed live 2026-07-14 (Devices -> [AP] -> Radios ->
		-- "Minimum RSSI" checkbox+slider, NOT a WLAN-level setting): toggling
		-- it emits stamgr.<n>.radio (band, "ng"/"na"), stamgr.<n>.minrssi.status
		-- and stamgr.<n>.minrssi.rssi, alongside an unrelated
		-- stamgr.<n>.loadbalance.status sub-feature sharing the same block.
		-- The whole block is simply absent when disabled (no explicit
		-- status=false), same convention as every other optional section here.
		if not section then section, idx, key, v = line:match("^(stamgr)%.(%d+)%.(.+)=(.*)$") end
		-- macacl.<m>: the "MAC Address Filter". CONFIRMED live 2026-07-18 by
		-- enabling the control with one allow-listed MAC and diffing system_cfg
		-- -- this whole top-level section appeared at once, and it is keyed by
		-- devname (ath0/ath2), NOT by the wireless.<n> index: only the two ath
		-- devices belonging to the filtered WLAN got blocks, numbered 1 and 2
		-- while the WLAN is wireless.1/wireless.3. Hence the devname join below.
		--
		-- The obvious-looking wireless.<n>.mac_acl.status/.policy keys are NOT
		-- this feature: they sit at enabled/deny with the control off and did
		-- not move in the diff -- the same decoy shape as
		-- radio.<n>.bcmc_l2_filter.status was for the broadcast blocker.
		-- aaa.<n>.radius.macacl.status is the separate RADIUS MAC
		-- Authentication control.
		if not section then section, idx, key, v = line:match("^(macacl)%.(%d+)%.(.+)=(.*)$") end
		if section then
			local tbl = (section == "aaa" and aaa) or (section == "wireless" and wireless)
				or (section == "radio" and radio) or (section == "macacl" and macacl) or stamgr
			idx = tonumber(idx)
			tbl[idx] = tbl[idx] or {}
			tbl[idx][key] = v
		end
		-- The site's regulatory domain, as an ISO 3166-1 NUMERIC code. Sent
		-- both unindexed and per radio ("radio.countrycode=203",
		-- "radio.1.countrycode=203" for a Czechia site -- confirmed live on a
		-- real controller). The per-radio copy is captured by the indexed
		-- pattern above; this catches the unindexed one as a fallback, so a
		-- controller sending only the global still sets the regdomain.
		if not section then
			local cc = line:match("^radio%.countrycode=(%d+)$")
			if cc then global_countrycode = tonumber(cc) end
		end
	end

	local function sorted_indices(t)
		local keys = {}
		for k in pairs(t) do keys[#keys + 1] = k end
		table.sort(keys)
		return keys
	end

	local radio_table = {}
	for _, idx in ipairs(sorted_indices(radio)) do
		local r = radio[idx]
		if r.phyname then
			local entry = {
				name     = r.phyname,
				-- Regulatory domain, numeric on the wire -> UCI's alpha-2
				-- `country`. Nothing wrote this before, so a device kept
				-- whatever regdomain OpenWrt booted with (typically the
				-- unconfigured world domain) while REPORTING 840/US back --
				-- get_radio_table reads UCI `country` to derive country_code
				-- and falls back to US when it is unset. A site in Czechia
				-- therefore ran radios on US channel and power limits and saw
				-- "US" in the UI. An unmapped numeric leaves UCI alone rather
				-- than guessing a regdomain.
				country  = country.ALPHA[tonumber(r.countrycode) or global_countrycode or -1],
				-- "auto" passes through verbatim: UCI channel=auto is OpenWrt's
				-- ACS request (hostapd surveys the band at bring-up and picks
				-- the least-busy channel). Dropping it to nil instead would
				-- leave a previously pushed fixed channel in UCI, silently
				-- overriding the user's switch back to Auto. Absent/garbage
				-- still -> nil, leaving UCI alone.
				channel  = tonumber(r.channel) or (r.channel == "auto" and "auto" or nil),
				-- "auto" passes through as a sentinel like channel above, but
				-- lands differently: UCI has no auto txpower value (absent
				-- option = driver default/max), so rf_config DELETES the
				-- option for it. Dropping it to nil instead stranded the last
				-- fixed dBm in UCI, silently overriding the user's switch
				-- back to Auto. Absent/garbage still -> nil, leaving UCI alone.
				tx_power = tonumber(r.txpower) or (r.txpower == "auto" and "auto" or nil),
				-- nil for an absent/unrecognized token, leaving htmode alone.
				htmode   = _htmode_from_ieee_mode(r.ieee_mode, caps),
				-- Per-radio disable (Devices -> [AP] -> Radios -> Transmit
				-- Power -> Disabled). CONFIRMED live 2026-07-19: that control
				-- moves radio.<n>.status enabled->disabled together with
				-- txpower_mode=disabled, virtual.1.status and every
				-- wireless.<n>.status on the radio.
				--
				-- Deliberately tri-state: nil when the key is ABSENT, so a
				-- capture that never carries it cannot re-enable a radio the
				-- user disabled by hand in /etc/config/wireless. Only an
				-- explicit enabled/disabled writes anything.
				--
				-- Reading r.status (indexed) and never the unindexed
				-- radio.status is what keeps the radio-less
				-- "# no wlan provisioned as no radio found" blob -- which
				-- carries radio.status=disabled with no phyname anywhere --
				-- from disabling every radio on the device.
				--
				-- NB: written as a statement below rather than inline, because
				-- `(x ~= nil) and (x == "disabled") or nil` silently collapses
				-- the enabled case to nil in Lua's and/or.
				disabled = wire.status_disabled(r.status),
			}
			local sm = stamgr[idx]
			-- minrssi.rssi is NOT plain dBm -- confirmed live: UI "-80 dBm"
			-- wire-encoded as 15, UI "-85 dBm" as 10 (a madwifi-driver
			-- convention, offset from an assumed -95 dBm noise floor: raw =
			-- dbm + 95). Kept as raw wire units here; converted to dBm only
			-- where a live noise-floor reading is available (apply_config/
			-- enforcement), not at parse time.
			-- Explicit tri-state, never nil for a parsed radio: an absent
			-- stamgr block is the wire's disable convention (the whole block
			-- simply disappears when the checkbox is off), so it must produce
			-- an explicit `false` -> rf_config writes minrssi_enabled=0.
			-- Leaving it nil instead let a stale minrssi_enabled=1 from an
			-- earlier push survive in UCI -- and since build_json derives its
			-- enforcement thresholds from UCI (get_radio_table), openUF kept
			-- deauthing weak clients forever after the user turned the
			-- feature off. Writing the explicit off is safe here:
			-- minrssi_enabled/minrssi_rssi are openUF-invented options nothing
			-- else configures, and the radio-less "# no wlan provisioned" blob
			-- never reaches apply_config (gated on a nonempty radio_table).
			entry.min_rssi_enabled = (sm ~= nil and sm["minrssi.status"] == "true")
			if entry.min_rssi_enabled then
				entry.min_rssi = tonumber(sm["minrssi.rssi"])
			end
			radio_table[#radio_table + 1] = entry
		end
	end

	-- MAC Address Filter, keyed by the vap's wire devname (ath0/ath1/...).
	-- Wire shape, all confirmed live 2026-07-18:
	--   macacl.status=enabled            -- global gate
	--   macacl.<m>.devname=ath0          -- join key
	--   macacl.<m>.status=enabled
	--   macacl.<m>.acl.status=enabled
	--   macacl.<m>.acl.policy=allow      -- allow|deny (UI "Filter Type")
	--   macacl.<m>.acl.<k>.mac=02:11:22:33:44:55
	--   macacl.<m>.acl.<k>.status=enabled
	--   macacl.<m>.acl.<k>.type=user
	-- Like bcfilt, <k> is 1-based and carries no meaning beyond grouping, so
	-- the list is sorted for a stable, comparable result. Entries are taken
	-- only when both the block and the entry are enabled; type is "user" for
	-- hand-entered MACs (the only kind this UI produces).
	local mac_filter_by_dev = {}
	for _, e in pairs(macacl) do
		if e.devname and e.status == "enabled" and e["acl.status"] == "enabled" then
			local macs = {}
			for k, val in pairs(e) do
				local ki = k:match("^acl%.(%d+)%.mac$")
				if ki and e["acl." .. ki .. ".status"] == "enabled" then
					-- The list becomes a UCI maclist hostapd parses, where a
					-- malformed entry fails the whole BSS. The controller's UI
					-- cannot produce one, so dropping it -- loudly -- is the
					-- safe reading.
					if wire.is_mac(val) then
						macs[#macs + 1] = val
					else
						io.stderr:write(("inform: macacl: ignoring malformed MAC %q\n")
							:format(tostring(val)))
					end
				end
			end
			table.sort(macs)
			mac_filter_by_dev[e.devname] = {
				policy = e["acl.policy"],
				macs   = macs,
			}
		end
	end

	-- "WiFi Speed Limit", keyed by the vap's wire devname -- same join as the
	-- MAC filter above. Wire shape, confirmed live 2026-07-18 by creating a
	-- speed-limit profile (33 Mbps down / 17 Mbps up) and assigning it to a
	-- WLAN:
	--   qos.status=enabled
	--   qos.vap.<m>.devname=ath0
	--   qos.vap.<m>.dwnlink.maxspeed=33000     -- kbps (UI Mbps x 1000)
	--   qos.vap.<m>.dwnlink.minspeed=33000
	--   qos.vap.<m>.uplink.1.maxspeed=17000    -- kbps
	--
	-- The discriminator is the presence of *maxspeed*, not qos.status (which
	-- is global) and not the block itself: an UNLIMITED vap still gets a
	-- qos.vap.<m> block, carrying only minspeed set to that radio's raw
	-- devspeed (570 on 2.4 GHz, 2400 on 5 GHz in the capture). Reading the
	-- block's existence as "limited" would cap every WLAN at its own PHY rate.
	--
	-- This is a per-VAP aggregate cap, not a per-client one: the limit applies
	-- to the whole netdev, which is what makes a single tc qdisc sufficient.
	--
	-- The accompanying qos.ebt.<n>.cmd entries are literal ebtables fragments
	-- the stock firmware would replay to fwmark each VAP. openUF implements
	-- the intent with tc instead (see shaper.lua) rather than replaying them.
	local ratelimit_by_dev = {}
	for _, q in pairs(qos_vap) do
		local down = tonumber(q["dwnlink.maxspeed"])
		local up   = tonumber(q["uplink.1.maxspeed"])
		if q.devname and (down or up) then
			ratelimit_by_dev[q.devname] = {down = down, up = up}
		end
	end

	local vap_table = {}
	for _, idx in ipairs(sorted_indices(wireless)) do
		local w = wireless[idx]
		local a = aaa[idx] or {}

		-- Aggregate every aaa.<n>.wpa.key.<k>.mgmt entry (transition mode can
		-- list WPA-PSK and SAE either space-joined on one key or across
		-- separate keys). Hoisted out of the security branch below because the
		-- WPA-Enterprise check needs it before anything else is decided.
		local akm = ""
		for k, val in pairs(a) do
			if k:match("^wpa%.key%.%d+%.mgmt$") then akm = akm .. " " .. val end
		end

		-- WPA-Enterprise (802.1X, mgmt "WPA-EAP"). openUF cannot provision it:
		-- the wire carries no RADIUS server/port/secret -- aaa.<n>.wpa.psk is
		-- simply absent -- and wlan_add() writes no auth_server/auth_secret.
		-- Left to fall through, an Enterprise WLAN matched neither the SAE nor
		-- the PSK branch and landed on security="wpa2", producing a psk2
		-- section with a nil key: a VAP hostapd refuses to bring up, with
		-- nothing logged anywhere. Skipping it loudly is strictly better -- a
		-- missing WLAN an admin can diagnose beats a broken one that looks
		-- provisioned.
		local is_enterprise = akm:find("EAP", 1, true) ~= nil
		if is_enterprise and w.ssid then
			io.stderr:write(("inform: skipping WLAN %q -- WPA-Enterprise (%s) is not "
				.. "supported; openUF has no RADIUS configuration on this wire protocol\n")
				:format(w.ssid, (akm:gsub("^%s+", ""))))
		end

		if w.ssid and w.parent and not is_enterprise then
			local security = "open"
			if a.wpa == "2" or a.wpa == "3" then
				local has_sae = akm:find("SAE", 1, true) ~= nil
				local has_psk = akm:find("PSK", 1, true) ~= nil
				-- WPA3 rides on its OWN keys, and the akm set alone cannot
				-- tell transition from WPA3-only: a WPA2/WPA3 transition WLAN
				-- sends `wpa.key.1.mgmt=SAE` *by itself* -- no WPA-PSK
				-- alongside it -- and marks the transition separately with
				-- `wpa3.transition=enabled`. Reading only the akm would
				-- therefore provision a transition WLAN as pure WPA3 and drop
				-- every WPA2-only client on the network (IoT devices above
				-- all). These two keys are authoritative where present.
				local wpa3_support    = wire.bool(a["wpa3.support"])
				local wpa3_transition = wire.bool(a["wpa3.transition"])
				if wpa3_support and wpa3_transition then security = "wpa2/wpa3"
				elseif wpa3_support then security = "wpa3"
				elseif has_sae and has_psk then security = "wpa2/wpa3"
				elseif has_sae then security = "wpa3"
				elseif a.wpa == "3" then security = "wpa3"
				else security = "wpa2" end
			end
			-- VLAN-tagged SSIDs bridge onto a per-VLAN bridge device named
			-- "br0.<vlan>" (vs. plain "br0" for untagged) -- confirmed live:
			-- assigning a WiFi network to a VLAN-tagged network in the
			-- controller UI changes aaa.<n>.br.devname from "br0" to
			-- "br0.20" and adds companion vlan.*/bridge.*/netconf.* blocks
			-- declaring the VLAN subinterface and its bridge (which
			-- ucihelper.ensure_vlan_network() already creates on its own,
			-- so only the VLAN id itself needs extracting here).
			local vlan_id = tonumber((a["br.devname"] or ""):match("^br0%.(%d+)$"))

			-- "Multicast and Broadcast Blocker" (REST bc_filter_enabled /
			-- bc_filter_list). CONFIRMED live 2026-07-18 by REST-toggling it
			-- and diffing system_cfg -- the whole block appeared at once:
			--   wireless.<n>.bcfilt.status=enabled
			--   wireless.<n>.bcfilt.<k>.mac=01:00:5e:00:00:fb
			--   wireless.<n>.bcfilt.<k>.status=enabled
			-- on BOTH band entries of the WLAN. <k> is 1-based and does NOT
			-- follow the REST list's order (adding a second MAC renumbered the
			-- first), so the index carries no meaning beyond grouping and the
			-- list is sorted here for a stable, comparable result.
			--
			-- Two candidate keys that were already on the wire turned out NOT
			-- to be this feature -- radio.<n>.bcmc_l2_filter.status (sits at
			-- enabled with the control off) and wireless.<n>.multicast.inspect
			-- -- neither moved in the diff.
			--
			-- bcfilt.status is emitted whenever the control is on, including
			-- with an empty allow-list; the per-entry keys only appear once
			-- the list is non-empty.
			-- Tri-state on purpose: absent (nil) is not the same as
			-- "disabled" here -- see wpa3_fast_roaming_enabled below.
			local wpa3_ft
			if a["wpa3.ft.status"] ~= nil then
				wpa3_ft = (a["wpa3.ft.status"] == "enabled")
			end

			local bcfilt_macs
			for k, val in pairs(w) do
				local idx = k:match("^bcfilt%.(%d+)%.mac$")
				if idx and wire.bool(w["bcfilt." .. idx .. ".status"]) then
					-- These go into an `nft add element` command line
					-- (bcfilter.lua), so only a real MAC may pass.
					if wire.is_mac(val) then
						bcfilt_macs = bcfilt_macs or {}
						bcfilt_macs[#bcfilt_macs + 1] = val
					else
						io.stderr:write(("inform: bcfilt: ignoring malformed MAC %q\n")
							:format(tostring(val)))
					end
				end
			end
			if bcfilt_macs then table.sort(bcfilt_macs) end

			vap_table[#vap_table + 1] = {
				ssid                  = w.ssid,
				radio                 = w.parent,
				security              = security,
				-- aaa.<n>.id is the controller's wlanconf ObjectId; the
				-- controller only accepts a vap_table entry whose "id" echoes
				-- it back (vapInformProcessor drops usage=user vaps without
				-- one, taking the nested sta_table -- and thus every wireless
				-- client -- with them).
				wlanconf_id           = a.id,
				x_passphrase          = a["wpa.psk"],
				fast_roaming_enabled  = (a["ft.status"] == "enabled"),
				-- aaa.<n>.wpa3.ft.status: FT for the SAE akm specifically,
				-- a SEPARATE toggle from ft.status. Confirmed from the
				-- emitter (com.ubnt.service.config.ubntconf.OXMua, first
				-- key it writes): emitted unconditionally -- "enabled" or
				-- "disabled" -- whenever the WLAN goes out as SAE, from
				-- the wlanconf's isWpa3SaeFastRoamingEnabled(). nil when
				-- absent, which is every non-SAE push, so a plain WPA2
				-- WLAN is unaffected. See apply_wifi_config for why the
				-- two toggles are merged rather than honoured separately.
				wpa3_fast_roaming_enabled = wpa3_ft,
				vlan_enabled          = vlan_id ~= nil,
				vlan                  = vlan_id,
				-- The bridge the controller put this vap in, verbatim. The
				-- vlan_filtering backend (netmodel.lua) resolves the vap's
				-- network through the controller's bridge model instead of the
				-- "br0.<vid>" pattern above, which cannot express `br-trunk`
				-- (the untagged network once a Management VLAN is set).
				br_devname            = a["br.devname"],
				devname               = a.devname,
				-- aaa.<n>.bss_transition: CONFIRMED live 2026-07-15 (toggled
				-- "BSS Transition (802.11v)" in the Behavior Controls panel,
				-- diffed system_cfg via debug_dump_file) -- present on every
				-- aaa.<n> block for the WLAN, "enabled"/"disabled" string,
				-- flips independently of Fast Roaming/other toggles. Maps
				-- 1:1 onto hostapd/UCI's own current option name -- no
				-- translation needed, unlike the deprecated ieee80211v
				-- alias ucihelper used to (incorrectly) emit.
				bss_transition        = wire.bool(a.bss_transition),
					-- aaa.<n>.pmf.status / pmf.mode: 802.11w Protected
					-- Management Frames. CONFIRMED live 2026-07-18 (Humans+IoT
					-- validation, diffed system_cfg via debug_dump_file): the
					-- controller always emits these on the aaa.<n> block --
					-- status="enabled"/"disabled", mode=0|1|2 (0=disabled,
					-- 1=optional, 2=required, mapping 1:1 onto hostapd's
					-- ieee80211w). For a "WPA2/WPA3" mixed WLAN on this madwifi
					-- model the WPA3-transition intent is carried entirely by
					-- these fields (wpa stays =2, wpa.key.1.mgmt stays WPA-PSK),
					-- so dropping them silently collapsed mixed-mode to plain
					-- WPA2 -- the reason this WLAN got no PMF at all before.
					-- pmf.cipher (AES-128-CMAC) is not carried through:
					-- hostapd's default BIP group-mgmt cipher already is
					-- AES-128-CMAC, so there is nothing to translate.
					pmf_status            = a["pmf.status"],
					pmf_mode              = tonumber(a["pmf.mode"]),
					-- wireless.<n>.mcast.enhance: "Multicast Enhancement" /
					-- "Multicast to Unicast" -- CONFIRMED live 2026-07-18
					-- (Humans+IoT validation): the controller sends =1 on the
					-- toggled WLAN's wireless.<n> entries and =0 elsewhere;
					-- openUF read wireless.<n> but never this key, so no
					-- multicast_to_unicast reached hostapd. (It rides the same
					-- wireless.<n> block as dtim_period/no2ghz_oui -- an earlier
					-- draft misread the "\nwireless.<n>." dump text as a
					-- separate "nwireless" section; the leading n is just the
					-- escaped newline before the wireless key.) 0|1 on the
					-- wire, so _wire_bool handles it directly.
					mcast_enhance         = wire.bool(w["mcast.enhance"]),
				-- wireless.<n>.dtim_period: CONFIRMED live 2026-07-15 --
				-- always present as a plain integer regardless of the
				-- WLAN's Auto/Custom DTIM toggle (toggling "Auto 802.11
				-- DTIM Period" off and setting a custom 2.4/5GHz value only
				-- changed this same field's value; there is no separate
				-- dtim_mode/dtim_ng/dtim_na key on the wire at all -- an
				-- earlier version of this parser guessed such a scheme and
				-- was wrong). Maps 1:1 onto hostapd/UCI's own
				-- wifi-iface.dtim_period option.
				dtim_period           = tonumber(w.dtim_period),
				-- wireless.<n>.iot / wireless.<n>.qbssload: "Force WiFi 4
				-- Mode" (Settings -> WiFi -> [WLAN] -> IoT Optimization,
				-- REST field enhanced_iot). CONFIRMED live 2026-07-18 by
				-- diffing system_cfg across the toggle: both keys are
				-- absent entirely when it is off, and appear together as
				-- iot=enabled + qbssload=disabled on the WLAN's 2.4GHz
				-- wireless.<n> entry when it is on.
				--
				-- Most of what this feature *does* is encoded by the
				-- controller in keys openUF already applies -- the same
				-- diff showed the WLAN's 5GHz vap removed outright
				-- (wlan_bands forced to 2.4GHz-only), security pinned to
				-- WPA2, and bss_transition/proxy_arp/no2ghz_oui/PMF/
				-- advertise_ap_name all forced off. Notably the parent
				-- radio is NOT touched: radio.<n>.ieee_mode stayed at the
				-- site's configured width (verified by turning this on
				-- with the 2.4GHz radio at HT40 -- it stayed 11nght40), so
				-- this is a per-BSS flag only and must not be reflected
				-- back onto the shared radio.
				--
				-- That leaves qbssload as its one distinct on-air effect:
				-- suppress the QBSS Load information element in this
				-- BSS's beacons, which some legacy clients mis-parse.
				iot                   = wire.bool(w.iot),
				qbssload              = wire.bool(w.qbssload),
				-- wireless.<n>.no2ghz_oui: CONFIRMED live 2026-07-15 --
				-- this, not a per-device mgmt_cfg key, is Band Steering's
				-- real wire representation (toggled "Band Steering" in the
				-- Behavior Controls panel with nothing else changed; only
				-- this field flipped, and only on the WLAN's 2.4GHz/radio0
				-- wireless.<n> entry -- a madwifi/QCA driver convention:
				-- omitting the AP's OUI from 2.4GHz beacons/probe responses
				-- nudges dual-band-capable clients toward 5GHz). An
				-- earlier version of this parser guessed a per-device
				-- Device.BandsteeringMode-style mgmt_cfg field (per
				-- paultyng/go-unifi's REST model) that does not exist on
				-- this wire protocol at all -- see PROTOCOL-VALIDATION.md.
				no2ghz_oui            = wire.bool(w.no2ghz_oui),
				-- wireless.<n>.advertise_ap_name: "Show Access Point Name
				-- in Beacon". CONFIRMED via decompiling the controller's
				-- WLAN-config-generator method directly (not a live diff
				-- -- a live capture showed zero effect from this toggle
				-- until the wifi_caps2 capability bit above was added,
				-- since the controller only emits this key at all when
				-- Device.supportAdvertisingDeviceNameInBeacon() is true;
				-- see that field's comment in build_json for the full
				-- derivation). "enabled"/"disabled" string, same
				-- convention as bss_transition/no2ghz_oui.
				advertise_ap_name     = wire.bool(w.advertise_ap_name),
				-- aaa.<n>.sae.anti_clogging / aaa.<n>.sae.sync: "SAE
				-- Anti-clogging"/"SAE Sync Time" (WPA3-SAE tuning).
				-- CONFIRMED via decompiling the controller's WLAN-config-
				-- generator (a small SAE-specific helper class): both are
				-- plain integers, only emitted when > 0 (the controller's
				-- own admin-side default is 5 for each), and -- unlike
				-- every other field on this vap -- gated on the WLAN
				-- actually being in real WPA3/SAE mode (Wlan.isWpa3() --
				-- an admin-facing "wpa3_support" flag, NOT the same thing
				-- as the "WPA2/WPA3" mixed Security Protocol dropdown
				-- option -- or a 6GHz radio, not a device capability like
				-- advertise_ap_name above). Live-tested: a WPA2/WPA3
				-- mixed-mode WLAN never emits either key even with a
				-- non-default admin value saved server-side, confirming
				-- the gate. Could not live-confirm the emitting (pure
				-- WPA3) case end-to-end -- switching this validation
				-- environment's test WLAN to pure WPA3 tripped an
				-- unrelated, already-documented config-sync flakiness
				-- (see PROTOCOL-VALIDATION.md) where the controller
				-- stopped pushing the WLAN's aaa./wireless. blocks
				-- entirely, even across an inform.lua restart. High
				-- confidence from the decompiled method body alone
				-- (a simple getInt(key, -1) > 0 check, no ambiguity).
				-- Written through hostapd_bss_options (ucihelper), the one
				-- door both OpenWrt wifi stacks leave for raw hostapd keys.
				sae_anti_clogging     = tonumber(a["sae.anti_clogging"]),
				sae_sync              = tonumber(a["sae.sync"]),
				-- aaa.<n>.wpa.1.pairwise: the data cipher, on every WPA push.
				-- The controller's enum renders as "CCMP", "TKIP CCMP"
				-- (Auto on a WPA1-capable WLAN), "GCMP", "CCMP-256" or
				-- "GCMP-256". Written explicitly into `encryption` because
				-- OpenWrt's own default follows the board and htmode, not
				-- the controller.
				pairwise              = a["wpa.1.pairwise"],
					-- aaa.<n>.proxy_arp: "Proxy ARP". CONFIRMED live
					-- 2026-07-18 by REST-toggling wlanconf.proxy_arp and
					-- diffing system_cfg -- exactly aaa.<n>.proxy_arp flipped
					-- disabled->enabled, on both the 2.4GHz and 5GHz entries
					-- of the WLAN and nothing else. Always present on every
					-- aaa.<n> block (like bss_transition), never absent, so
					-- the "disabled" case is explicit rather than implied.
					-- Maps 1:1 onto hostapd/OpenWrt's own proxy_arp option.
					proxy_arp             = wire.bool(a.proxy_arp),
					-- wireless.<n>.l2_isolation: "Client Isolation" (blocks
					-- station-to-station traffic within the BSS). CONFIRMED
					-- live 2026-07-18 in the same diff as proxy_arp above --
					-- flipped disabled->enabled on both band entries, nothing
					-- else moved. Always present. Maps onto OpenWrt's
					-- "isolate" (hostapd ap_isolate).
					l2_isolation          = wire.bool(w.l2_isolation),
					-- wireless.<n>.hide_ssid: "Hide WiFi Name" -- suppress the
					-- SSID from beacons. CONFIRMED live 2026-07-18 by toggling
					-- the control in the UI and diffing system_cfg: exactly
					-- aaa.<n>.hide_ssid and wireless.<n>.hide_ssid flipped
					-- false->true, on both band entries of the WLAN, nothing
					-- else moved. The two keys are redundant duplicates; the
					-- wireless.<n> one is read here to keep this next to the
					-- other wireless.<n> booleans.
					--
					-- Note the value vocabulary is "true"/"false" here, not the
					-- "enabled"/"disabled" most of these keys use -- _wire_bool
					-- accepts both. Always present, so "off" is explicit and
					-- must be written back out as such. Maps onto OpenWrt's
					-- wifi-iface "hidden" (hostapd ignore_broadcast_ssid).
					hide_ssid             = wire.bool(w.hide_ssid),
					-- "MAC Address Filter", joined from the top-level macacl
					-- section on wireless.<n>.devname (see mac_filter_by_dev
					-- above for the wire shape and why the join is needed).
					-- Both are nil when the control is off for this vap, which
					-- the consumer turns into macfilter=disable.
					mac_filter_policy     = (mac_filter_by_dev[w.devname] or {}).policy,
					mac_filter_list       = (mac_filter_by_dev[w.devname] or {}).macs,
					-- "WiFi Speed Limit", in kbps, nil when unlimited.
					ratelimit_down_kbps   = (ratelimit_by_dev[w.devname] or {}).down,
					ratelimit_up_kbps     = (ratelimit_by_dev[w.devname] or {}).up,
					-- "Minimum Data Rate Control" (Settings -> WiFi -> [WLAN]).
					-- CONFIRMED live 2026-07-18 by REST-setting
					-- minrate_setting_preference=manual + minrate_ng_enabled +
					-- minrate_ng_data_rate_kbps=12000 and diffing system_cfg:
					--   minrate_data     1000 -> 12000   (kbps -- 12 Mbps)
					--   beacon_rate      1000 -> 12000
					--   mgmt_rate        1000 -> 12000
					--   minrate_cck_rates.status  true -> false
					--   pureg            0    -> 1
					-- i.e. beacon_rate/mgmt_rate simply mirror minrate_data, and
					-- the CCK/pureg pair are derived consequences (12 Mbps is an
					-- OFDM rate, so every CCK rate falls below the floor and
					-- 802.11b clients are excluded outright).
					--
					-- Per-band, and NOT band-gated: the 5 GHz entries carried
					-- none of these keys at first only because that band's
					-- minrate was disabled. Enabling minrate_na (24 Mbps) made
					-- minrate_data/beacon_rate/mgmt_rate appear on the radio1
					-- entries too, with no cck/pureg keys (2.4 GHz-only
					-- concepts). So the controller has already done the band
					-- math and this side needs no band awareness.
					--
					-- Nothing is emitted at all when that band's Minimum Data
					-- Rate is off, so absent -> nil -> leave the radio alone.
					minrate_data          = tonumber(w.minrate_data),
					minrate_cck           = wire.bool(w["minrate_cck_rates.status"]),
					beacon_rate           = tonumber(w.beacon_rate),
					-- wireless.<n>.minrate_below_disable: the "advertising
					-- rates" sub-toggle (REST minrate_<band>_advertising_rates).
					-- CONFIRMED live in its own diff -- turning it on added
					-- exactly this key (=true) to both band entries and changed
					-- nothing else. Distinguishes "make the floor a basic rate"
					-- (association still requires it) from "also stop
					-- advertising every rate below the floor".
					minrate_below_disable = wire.bool(w.minrate_below_disable),
					-- See the bcfilt derivation above the vap literal.
					bcfilt_enabled        = wire.bool(w["bcfilt.status"]),
					bcfilt_macs           = bcfilt_macs,
					-- Per-VAP disable. Moves with the parent radio's
					-- radio.<n>.status (disabling a radio disables every VAP
					-- on it), but is an independent key -- confirmed live
					-- 2026-07-19. The VAP is still provisioned when disabled,
					-- just with disabled=1, so its config survives a re-enable.
					disabled              = wire.status_disabled(w.status),
			}
		end
	end

	return radio_table, vap_table
end

return M
