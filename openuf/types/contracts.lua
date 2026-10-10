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
-- UniFi -> OpenWrt:  wlan.parse() -> RadioIntent[], VapIntent[], BackhaulEntry[];
--                    mesh.parse() -> MeshIntent -> mesh.plan() -> BackhaulPlan;
--                    wlan.parse_bandsteering() -> BandSteeringIntent;
--                    ports.parse() -> PortsIntent;  network.parse() -> NetworkModel
--                    -> netmodel.plan() -> NetPlan;  system.parse() -> SystemSettings;
--                    hardening.parse() -> EbtablesRules -> hardening.spec_from() -> HardeningSpec;
--                    guest.parse() -> GuestRules -> guest.spec_from() -> GuestSpec

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
---@field led string?        the status LED Locate blinks (a /sys/class/leds name), or nil when the board has none usable
---@field config Config      the options (set by the entry points)
---@field hwassign string[]? the UCI radios reported, from local.lua; nil: all
---@field radio table<string, RadioPolicy>? per-band limits, from local.lua

---@class Dev                openwrt/board.lua's describe()
---@field conf DevConf
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
---@field max_sta integer|false  "Max Clients" for the whole radio; false: no limit
---@field acs_exclude integer[]? channels Auto must not pick (blklst), sorted; nil: none
---@field acs_dfs boolean?   Auto may pick DFS channels (acsdfs); nil: the push did not say

---@class VapIntent
---@field ssid string
---@field radio string
---@field security string    "open" | "owe" | "wpa2" | "wpa3" | "wpa2/wpa3", or Enterprise:
---                           "wpa2-eap" | "wpa3-eap" | "wpa2/wpa3-eap" | "wpa3-eap192"
---@field owe_transition boolean? Enhanced Open transition: one section, two BSSes
---@field pairwise string?   "ccmp" | "gcmp256" | ...
---@field x_passphrase string?
---@field wlanconf_id string
---@field devname string     the controller's VAP name ("ath0")
---@field br_devname string? the controller bridge it joins
---@field vlan_enabled boolean?
---@field vlan integer?
---@field ppsk PpskKey[]? private pre-shared keys, in wire order; nil when none
---@field radius RadiusIntent? Enterprise / RADIUS MAC authentication servers
---@field radius_mac_auth boolean? RADIUS MAC authentication (hostapd macaddr_acl=2)
---@field radius_psk boolean?  keys from RADIUS only (wpa.psk_radius=2): OpenWrt ppsk
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
---@field roam_assist_enabled boolean  Roaming Assistant (btm_disassoc); absent on the wire = false
---@field roam_assist_rssi integer?    its threshold, plain dBm
---@field mac_filter_policy string?
---@field mac_filter_list string[]?
---@field mac_filter_lock2ap string[]? the lock2ap subset: clients locked to another AP, lowercase
---@field bcfilt_enabled boolean?
---@field bcfilt_macs string[]?
---@field minrate_data integer?
---@field minrate_cck boolean?
---@field minrate_below_disable boolean?
---@field beacon_rate integer?
---@field ratelimit_up_kbps integer?
---@field ratelimit_down_kbps integer?
---@field group_rekey integer?     aaa.<n>.wpa.group_rekey, seconds (0 = never)
---@field tdls_prohibit boolean?   aaa.<n>.tdls_prohibit
---@field country_beacon boolean?  aaa.<n>.country_beacon (802.11d; per radio in OpenWrt)
---@field rrm_enabled boolean?     aaa.<n>.11k.status (802.11k)
---@field uapsd boolean?           wireless.<n>.uapsd
---@field sae_groups string[]?     aaa.<n>.sae.groups.<i>.group, in wire order

---@class RadiusServer
---@field ip string
---@field port integer
---@field secret string

---@class RadiusIntent     unifi/wlan.lua parse_radius(): aaa.<n>.radius.* and friends
---@field auth RadiusServer[]   at least one
---@field acct RadiusServer[]?
---@field acct_interval integer? interim accounting interval, seconds
---@field nas_id string?
---@field dynamic_vlan integer  0 off, 1 optional, 2 required (RADIUS-assigned VLAN)
---@field auth_cache boolean?   PMKSA/opportunistic key caching (Enterprise only)

---@class PpskKey          one private pre-shared key (aaa.<n>.wpa.psk_file.<k>.*)
---@field key string        8-63 printable characters, or 64 hex digits
---@field vid integer?      its VLAN; nil: the VAP's own network (a VLAN-1 network)

---@class BandSteeringIntent unifi/wlan.lua's parse_bandsteering(): the AP's own setting
---@field enabled boolean    bandsteering.status; false is not "per-WLAN steering off"
---@field mode string?       "prefer_5g" | "equal" (Balance); nil when disabled

-- ─── The wireless uplink (mesh) ──────────────────────────────────────────────

---@class MeshIntent          unifi/mesh.lua's parse(): the push's mesh.* block
---@field status boolean       mesh.status=enabled
---@field essid string?        the site's backhaul ESSID (vwire-<16 hex>)
---@field psk string?          the site's backhaul PSK
---@field serial1 string?      the priority-1 parent's MAC, while one is set

---@class BackhaulEntry       one backhaul VAP unifi/wlan.lua hands over instead of provisioning it
---@field role "downlink"|"uplink"
---@field radio string         wireless.<n>.parent, the UCI radio
---@field ssid string          the mesh ESSID (downlink) or vport-<own MAC> (uplink)
---@field devname string?      the controller's devname (vwire3 / ath4)
---@field psk string?          aaa.<n>.wpa.psk (the downlink's)
---@field hidden boolean?

---@class BackhaulLink
---@field radio string
---@field ssid string          the ESSID beaconed (downlink) or joined (uplink)
---@field key string           WPA2 passphrase
---@field devname string?      reported back as the vap_table entry's name
---@field enabled boolean?     uplink only: the station is up (the device is on its wireless uplink)

---@class BackhaulPlan        unifi/mesh.lua's plan(): what ucihelper.backhaul_apply writes
---@field downlink BackhaulLink?
---@field uplink BackhaulLink?

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
---@field guest integer      GUESTIN/GUESTOUT fragments, left to unifi/guest.lua
---@field unknown string[]   rule shapes not recognised, verbatim

---@class HardeningSpec      unifi/hardening.lua's spec_from(); what l2guard enforces
---@field bpdu boolean
---@field tagdrop boolean
---@field ifnames string[]?

---@class GuestMatch         one ebtables rule's matches, neutral
---@field proto "ipv4"|"ipv6"|"arp"|"length"|integer|nil   integer = an ethertype
---@field pkttype "broadcast"|"multicast"|"host"|"other"|nil
---@field l4 "tcp"|"udp"|nil
---@field sport integer?
---@field dport integer?
---@field src string?        IPv4 address or CIDR
---@field dst string?
---@field arp_op "request"|"reply"|nil
---@field set string?        an ipset.* name
---@field set_dir "src"|"dst"|nil

---@class GuestRule
---@field match GuestMatch
---@field verdict "accept"|"drop"|"return"|"jump"
---@field jump string?       chain name, when verdict is "jump"

---@class GuestRules         unifi/guest.lua's parse()
---@field enabled boolean    ebtables.status
---@field ssids string[]     the guest WLANs (wireless.<n>.is_guest)
---@field conflicts string[] SSIDs a guest and a non-guest WLAN both carry
---@field guest_devnames string[]
---@field hooks {in: string[], out: string[]}   ath<n> hooked into GUESTIN/GUESTOUT
---@field chains table<string, {policy: string?, rules: table[]}>
---@field order string[]
---@field sets table<string, string[]>
---@field unknown string[]   guest-chain fragments not understood, verbatim
---@field unenforced string[] understood and not applied (wired guest networks)

---@class GuestSpec          unifi/guest.lua's spec_from(); what guestguard enforces
---@field enabled boolean
---@field portal boolean?    the controller has a captive portal on (not implemented)
---@field ssids string[]?
---@field chains table<string, {policy: string, rules: GuestRule[]}>?
---@field order string[]?
---@field sets table<string, string[]>?
---@field dropped string[]?  rules left out (the portal's), verbatim
---@field ifnames string[]?  the VAP netdevs, recorded for the startup rebuild

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
---@field guest_isolation boolean
---@field rrm_enrichment boolean
---@field rrm_request_interval integer
---@field roam_assist_diff_db integer
---@field wireless_uplink boolean  claim the mesh bits (wifi_caps 0x801)
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
