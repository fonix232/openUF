--[[
	openUF main configuration.

	Select the modelmap that matches your hardware (see openuf/modelmap/).
	Known-working modelmap files:
	  archer-c5-v1.lua        — TP-Link Archer C5 v1 (dual-band, board-specific)
	  tl-wdr3500-v1.lua       — TP-Link TL-WDR3500 v1 (dual-band, board-specific)
	  xiaomi-ax3000t.lua      — Xiaomi Mi Router AX3000T (802.11ax, DSA)
	  generic-dualband-ap.lua — any other dual-band board
	  generic-singleband-ap.lua — any other single-band (2.4 GHz) board
	  auto.lua                — derived from /etc/board.json at startup
	  tl-wr1043ndv2.lua       — TP-Link WR1043ND v2 (single-band)

	Prefer a board-specific map where one exists: the generic profile cannot
	know the board's LED name or which of its ports is the uplink, and gets
	both wrong on an Archer C5.

	The modelmap drives:
	  • dev.conf.net.*          network interface assignments
	  • dev.openuf.uap.ufmodel  which ufmodel/* to load (e.g. "u6iw")
	  • dev.openuf.uap.hwassign radio names to include in the inform payload

	The ufmodel controls the device identity presented to the controller:
	  u6iw.lua  — presents as U6-InWall (U6IW)  ← default for AP emulation
	  uapg1.lua — presents as UAP Gen1
	  uapg2-ac-lr.lua — presents as UAP-AC-LR

	openUF emulates a UniFi AP only. Gateway (USG) and switch (USW) emulation
	are not implemented and are not planned.
]]--

-- Select your hardware model map here:
dev = dofile("modelmap/generic-dualband-ap.lua")

config = {
	-- When true, any wifi-iface sections NOT prefixed with "openuf_" are disabled
	-- during WiFi provisioning, so the radios carry only what the controller
	-- pushed.  Set false to keep hand-configured SSIDs broadcasting; openUF
	-- stamps each SSID it disables, so switching back to false re-enables
	-- exactly those and leaves ones you disabled yourself alone.
	use_only_unifi_wlan = true,

	-- The controller owns the AP's config outright: with use_only_unifi_wlan
	-- the board's own SSIDs are DELETED rather than disabled, and when the
	-- controller takes the bridge over (bridge_backend "vlan_filtering") every
	-- other interface on it -- and any L3 interface left on a socket, like a
	-- stock wan/wan6 -- is deleted rather than kept. The originals are saved
	-- once to /etc/openuf/network.pre-openuf and wireless.pre-openuf;
	-- `syswrapper.sh netmodel-restore` puts both back. false keeps the old
	-- behaviour (SSIDs disabled and stamped, interfaces re-pointed).
	own_config = true,

	-- URL the inform loop posts to.  Overwritten at runtime when the controller
	-- sends a new URL or when syswrapper.sh set-inform is called.
	-- The value here is used only when state.json carries no URL of its own --
	-- a first boot, or the state after a factory reset.  install.sh also reads
	-- it, to decide whether an https:// controller needs luasec installed.
	inform_url = "http://unifi:8080/inform",

	-- Path for persistent state (authkey, adopted flag, cfgversion, inform_url).
	state_file = "/etc/openuf/state.json",

	-- Client-assisted RF environment enrichment (802.11k beacon reports), the
	-- same mechanism Ubiquiti's Channel AI describes as "neighbor reports and
	-- automated RRM scans".
	--
	-- The Environment tab is otherwise built from the kernel's PASSIVE scan
	-- cache, which only ever holds neighbours on the channel a radio is already
	-- serving -- 6 BSSes on a 2.4 GHz radio and 1 on a 5 GHz one, measured. With
	-- this on, openUF periodically asks ONE 802.11k-capable client to sweep and
	-- report back; the client goes off-channel, the AP never does. A single
	-- answer returned 15 BSSes across both bands.
	--
	-- Costs the AP nothing. Costs a participating client roughly a second
	-- off-channel, once per rrm_request_interval, and only clients that
	-- advertise active/passive beacon measurement are ever asked -- which in
	-- practice is a minority of them. Set false to never send a beacon request.
	rrm_enrichment = true,

	-- Seconds between beacon requests, across all radios and clients combined
	-- (they are asked one at a time, round-robin). Deliberately slow: the point
	-- is to keep the Environment tab honest, not to poll.
	rrm_request_interval = 600,

	-- L2 discovery broadcasts (announce.lua, UDP port 10001). On by default:
	-- it is how the device shows up in UniFi Discover without any set-inform.
	--
	-- Set false to adopt over L3 only. This is not just noise reduction: a
	-- controller that discovers a device via L2 adopts it by SSHing in and
	-- running `syswrapper.sh set-adopt`, and if that login cannot succeed
	-- (no password auth, no bootstrap account -- see install.sh's
	-- --bootstrap-adopt) adoption fails with "Connection Interrupted" no
	-- matter how healthy the inform loop is. With broadcasts off the
	-- controller treats the device as L3-discovered instead and delivers the
	-- adoption key over the inform channel, needing no SSH at all.
	-- Takes effect on service restart (the init script reads it).
	l2_announce = true,

	-- Opt-in: when set, every decrypted controller inform response is appended
	-- verbatim (with a UTC timestamp) to this file, before dispatch. Off by
	-- default. Used to capture ground-truth payload shapes when validating
	-- against a real UniFi controller -- see PROTOCOL-VALIDATION.md.
	debug_dump_file = nil,

	-- With debug_dump_file set: also record what openUF SENDS (a "TX" line per
	-- inform) and transport failures ("ERR" lines, e.g. "HTTP 400"). Response
	-- lines keep their untagged shape; filter with grep ' TX '.
	debug_dump_requests = false,

	-- RESEARCH ONLY. Override the capability bitmasks the payload claims:
	--   debug_caps = {fw_caps = 0x110, wifi_caps = 0x0, wifi_caps2 = 0x40},
	-- and/or merge extra top-level fields into every payload verbatim:
	--   debug_payload_extra = {uplink = {type = "wireless"}},
	-- A claimed bit makes the controller push config and show UI for a feature
	-- this device does not implement; the daemon says so at every start.
	debug_caps          = nil,
	debug_payload_extra = nil,

	-- Regulatory domain override: an ISO 3166-1 alpha-2 code programmed into
	-- the driver INSTEAD of the one the controller pushes (nil = off). For a
	-- driver that cannot run DFS, where the site's regdomain leaves no usable
	-- wide channel. The controller is still told its OWN value. This programs
	-- a regulatory domain the device may not physically be in -- channel use
	-- and TX power are legal constraints, so it is off unless set on purpose.
	country_override = nil,

	-- Ceiling for that dump, in bytes (default 4 MiB). The inform loop appends
	-- to it every few seconds, and its usual home is /tmp -- a RAM disk on
	-- these boards -- so an unbounded dump eventually starves state.json
	-- writes and apk. Past the cap the file restarts, with a marker line
	-- saying so; a capture is read from its tail anyway. 0 = no cap.
	debug_dump_max_bytes = 4 * 1024 * 1024,

	-- Set (by install.sh's --bootstrap-adopt, not by hand) to the name of a
	-- temporary, non-root SSH bootstrap account matching real Ubiquiti
	-- hardware's factory-default "ubnt" login -- lets first adoption succeed
	-- without presetting a root password. nil unless that install flag was
	-- used. When set, inform.lua locks the account once the device becomes
	-- adopted and re-enables it on factory reset -- see USAGE.md's SSH
	-- prerequisite section.
	bootstrap_adopt_user = nil,

	-- Who builds the AP's layer 2 from the controller's push (netmodel.lua):
	--   "bridges"        per-VLAN bridges holding <uplink>.<vid> sub-devices
	--                    (the original design; Native VLAN per port only)
	--   "vlan_filtering" ONE vlan-filtering bridge carrying every network the
	--                    controller describes -- Management VLAN, WLAN VLANs,
	--                    tagged/trunk ports -- with the switch doing the VLAN
	--                    work in hardware. DSA boards only.
	--   "auto"           vlan_filtering when the uplink socket is already in a
	--                    vlan-filtering bridge (where "bridges" cannot work at
	--                    all), bridges otherwise.
	bridge_backend = "auto",

	-- vlan_filtering only: replace any bridge that holds this board's sockets
	-- ("the controller fully manages the bridge"). Interfaces that used it are
	-- re-pointed, the VLANs they need are kept, and the board's own config is
	-- saved once to /etc/openuf/network.pre-openuf
	-- (`syswrapper.sh netmodel-restore` puts it back). false: leave the network
	-- alone whenever another bridge claims the sockets.
	bridge_takeover = true,

	-- vlan_filtering only: every network change is rolled back unless an
	-- inform succeeds within this many seconds; a rolled-back plan is not
	-- applied again until the controller sends a different one
	-- (`syswrapper.sh netmodel-retry` overrides).
	bridge_rollback_timeout = 180,

	-- vlan_filtering only: the bridge's name, and what a downstream socket
	-- carries while Port VLAN is off in the controller -- "all" (native VLAN
	-- untagged, every other VLAN tagged: UniFi's "Allow All") or "native".
	bridge_name  = "br-lan",
	port_default = "all",

	-- The controller's STUN wake-up channel (stun.lua): lets it make this AP
	-- inform at once -- used on 10.6 for upgrades and missed-heartbeat
	-- recovery. stun_local_port is kept stable so a restart keeps the address
	-- the controller has on file. false disables.
	stun            = true,
	stun_local_port = 3478,

	-- OpenWrt upgrades through UniFi's upgrade flow (upgrade.lua), all opt-in:
	--   upgrade_mode = "owut"      a controller upgrade (button, schedule,
	--                              Custom Upgrade) runs `owut upgrade`; needs
	--                              the contrib/asu bootstrap. nil: store only.
	--   advertise_updates = true   show UniFi's "Upgrade available" badge while
	--                              `owut check` finds a newer build
	--   version_scheme = "openwrt" OpenWrt revision in the firmware column
	--                              (causes a permanent Upgrade badge)
	upgrade_mode       = nil,
	advertise_updates  = false,
	advertise_interval = 6 * 3600,
	version_scheme     = nil,

	-- Client connection events (staevents.lua): associations and departures
	-- reported the way UniFi APs do, as notification informs, which is what
	-- the controller builds client connection and roaming history from.
	sta_events = true,

	-- The controller's system settings (sysconf.lua): its timezone, its NTP
	-- servers (the ubnt pool) and its nightly `syswrapper.sh 11k-scan` cron
	-- job. true applies all three, false none, or pick, e.g.
	-- {timezone = true, ntp = false, cron = true} for a site with its own NTP.
	controller_system = true,

	-- The controller's ebtables hardening (l2guard.lua): no STP BPDUs and no
	-- VLAN-tagged frames from Wi-Fi clients, as an nftables bridge table on
	-- the VAPs. Needs kmod-nft-bridge. false leaves it off.
	l2guard = true,

	-- Every response type, command and config key openUF did not act on is
	-- kept (redacted, bounded) in this file -- how a new controller verb gets
	-- noticed. false keeps the ledger in memory only.
	unhandled_file = "/etc/openuf/unhandled.json",
}
