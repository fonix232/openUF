---@meta
-- The data contracts between openUF's two sides, for the Lua language server
-- (sumneko / LuaLS: the "Lua" VS Code extension). Annotations only: nothing
-- here runs, and this directory is not part of the package.
--
--   unifi/    the controller's side: parses what it pushes, builds what it
--             expects to hear. Pure: depends on nothing in openwrt/.
--   openwrt/  the device's side: describes the board, reads its state into
--             the payload (report.lua), applies the parsed pushes
--             (provision.lua, ucihelper.lua, netmodel.lua, ...).
--
-- OpenWrt -> UniFi:  board.describe() -> Dev;  report.build() -> payload JSON
-- UniFi -> OpenWrt:  wlan.parse() -> RadioIntent[], VapIntent[];
--                    ports.parse() -> PortsIntent;  network.parse() -> NetworkModel
--                    -> netmodel.plan() -> NetPlan;  system.parse() -> SystemSettings;
--                    hardening.parse() -> EbtablesRules -> hardening.spec_from() -> HardeningSpec

-- ─── The device ──────────────────────────────────────────────────────────────

---@class Port
---@field idx integer        UniFi port_idx (the controller keys per-port settings on it)
---@field ifname string      the socket's netdev ("lan1", "wan")

---@class DevNet
---@field lan_name string    the management UCI interface ("lan")
---@field lan_cpueth string  the uplink socket
---@field lan_vlanid integer
---@field wan_cpueth string
---@field identity_mac string the MAC the network knows the AP by
---@field ports Port[]

---@class DevConf
---@field net DevNet
---@field led string?        a /sys/class/leds name, or nil when the board has none usable
---@field config Config      the options (set by the entry points)
---@field uap DevUap         (set by the entry points)
---@field radio table<string, RadioPolicy>? per-band limits, from local.lua

---@class DevUap
---@field ufmodel string     always "auto"
---@field hwassign string[]  the UCI radios reported ("radio0", "radio1")

---@class Dev                openwrt/board.lua's describe()
---@field conf DevConf
---@field openuf {uap: DevUap}
---@field identity Identity

---@class RadioPolicy
---@field htmode_max string?     cap, e.g. "HE80"
---@field htmode_floor string?   floor, e.g. "HE20"
---@field acs_exclude_dfs boolean?
---@field channels string[]?     ACS candidates while the channel is Auto

-- ─── What the device presents as ────────────────────────────────────────────

---@class Firmware
---@field pre string         "U6IW."
---@field ver string         "6.8.2.15592" -- compared character for character
---@field buildtime string
---@field factoryver string

---@class Identity           unifi/identity.lua's choose() (modelmatch.identity)
---@field platform string
---@field model string       registry code ("U6IW")
---@field model_display string
---@field sysid integer      registry system id, resolved before `model`
---@field fw Firmware
---@field bootver string
---@field required_version string
---@field ports integer?     the model's socket count in the registry
---@field switch boolean?    a built-in switch: uplink on the last port
---@field uplink_idx integer

---@class Caps               what wlan.parse may ask of the hardware
---@field best_phy (fun(band: string): string?)? "HE" for "na"; nil when unknown

-- ─── The controller's WiFi (unifi/wlan.lua) ─────────────────────────────────

---@class RadioIntent
---@field name string        UCI radio ("radio0")
---@field country string?    ISO alpha-2, from the controller's numeric code
---@field channel string?    "auto" or a number
---@field tx_power string?
---@field htmode string?     "HE80"
---@field disabled boolean?  nil: the push did not say (leave UCI alone)

---@class VapIntent
---@field ssid string
---@field radio string
---@field security string    "open" | "wpa2" | "sae" | "sae-mixed" | ...
---@field pairwise string?   "ccmp" | "gcmp256" | ...
---@field x_passphrase string?
---@field wlanconf_id string
---@field devname string     the controller's VAP name ("ath0")
---@field br_devname string? the controller bridge it joins
---@field vlan_enabled boolean?
---@field vlan integer?
---@field disabled boolean?
---@field hide_ssid boolean?
---@field fast_roaming_enabled boolean?
---@field wpa3_fast_roaming_enabled boolean?
---@field bss_transition boolean?
---@field pmf_status string?
---@field pmf_mode string?
---@field sae_anti_clogging integer?
---@field sae_sync integer?
---@field l2_isolation boolean?
---@field proxy_arp boolean?
---@field mcast_enhance boolean?
---@field dtim_period integer?
---@field iot boolean?
---@field qbssload boolean?
---@field no2ghz_oui boolean? band steering
---@field advertise_ap_name boolean?
---@field mac_filter_policy string?
---@field mac_filter_list string[]?
---@field bcfilt_enabled boolean?
---@field bcfilt_macs string[]?
---@field minrate_data integer?
---@field minrate_cck boolean?
---@field minrate_below_disable boolean?
---@field beacon_rate integer?
---@field ratelimit_up_kbps integer?
---@field ratelimit_down_kbps integer?

-- ─── The controller's wired side ─────────────────────────────────────────────

---@class PortOverride
---@field pvid integer?
---@field vlans table<integer, "tagged"|"untagged">

---@class PortsIntent        unifi/ports.lua's parse()
---@field enabled boolean    both Port VLAN gates on
---@field vlans table<integer, {mode: string, enabled: boolean}>
---@field ports table<integer, PortOverride> keyed by port_idx; only overridden ports

---@class StaticAddress
---@field ip string
---@field netmask string?
---@field gateway string?
---@field dns string[]?

---@class NetworkModel       unifi/network.lua's parse(): the controller's L2
---@field uplink string      the controller's name for the uplink ("eth0")
---@field vids table<integer, true>
---@field bridges {devname: string, ports: string[]}[]
---@field bridge_vid table<string, integer> devname -> 0 (untagged) | VID
---@field mgmt_bridge string?
---@field mgmt_vid integer?  0 (untagged) | VID
---@field dhcp boolean?
---@field static StaticAddress?

---@class NetPlan            openwrt/netmodel.lua's plan(): the UCI it writes
---@field bridge {name: string, ports: string[], macaddr: string?}
---@field uplink string
---@field vlans table<integer, {ports: string[]}> bridge-vlan port lists ("lan1:t")
---@field mgmt {iface: string, device: string, proto: "dhcp"|"static"|nil, ipaddr: string?, netmask: string?, gateway: string?, dns: string[]?}
---@field vlan_ifaces table<integer, string>
---@field net_for_bridge table<string, string> controller bridge -> UCI interface

---@alias ConvergeOutcome "applied"|"unchanged"|"declined"|"rejected"|"failed"

-- ─── System settings and hardening ───────────────────────────────────────────

---@class CronJob
---@field schedule string    five crontab fields
---@field cmd string         a command this build provides (sysconf.CRON_COMMANDS)
---@field user string?
---@field enabled boolean

---@class SystemSettings     unifi/system.lua's parse(); a nil part was not pushed
---@field timezone string?   POSIX TZ string
---@field ntp {enabled: boolean, servers: string[]}?
---@field cron {enabled: boolean, jobs: CronJob[]}?

---@class EbtablesRules      unifi/hardening.lua's parse()
---@field enabled boolean
---@field bpdu_in string[]
---@field bpdu_out string[]
---@field tag_in string[]
---@field tag_vids integer[]
---@field unknown string[]   rule shapes not recognised, verbatim

---@class HardeningSpec      unifi/hardening.lua's spec_from(); what l2guard enforces
---@field bpdu boolean
---@field tagdrop boolean
---@field ifnames string[]?

-- ─── Settings ────────────────────────────────────────────────────────────────

---@class Config             config.lua's options (UCI openuf.main), typed
---@field inform_url string
---@field l2_announce boolean
---@field ssh_adopt boolean
---@field stun boolean
---@field stun_local_port integer
---@field cfg_retries integer
---@field use_only_unifi_wlan boolean
---@field own_config boolean
---@field bridge_backend "auto"|"vlan_filtering"|"bridges"
---@field bridge_takeover boolean
---@field bridge_rollback_timeout integer
---@field bridge_name string
---@field port_default "all"|"none"
---@field country_override string?
---@field sta_events boolean
---@field system_timezone boolean
---@field system_ntp boolean
---@field system_cron boolean
---@field controller_system boolean|{timezone: boolean, ntp: boolean, cron: boolean}
---@field l2guard boolean
---@field rrm_enrichment boolean
---@field rrm_request_interval integer
---@field upgrade_mode "owut"?
---@field advertise_updates boolean
---@field advertise_interval integer
---@field version_scheme string?
---@field state_file string
---@field unhandled_file string|false
---@field debug_dump_file string?
---@field debug_dump_requests boolean
---@field debug_dump_max_bytes integer
---@field bootstrap_adopt_user string?
---@field debug_caps table?          research only, from local.lua
---@field debug_payload_extra table? research only, from local.lua
