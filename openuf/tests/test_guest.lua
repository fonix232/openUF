-- Tests for src/unifi/guest.lua (the controller's guest restrictions) and
-- src/openwrt/guestguard.lua (their nft table).
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local guest = dofile("src/unifi/guest.lua")
local gg = dofile("src/openwrt/guestguard.lua")
local hardening = dofile("src/unifi/hardening.lua")

local function fixture()
	local f = assert(io.open("tests/fixtures/system_cfg_guest_synth.txt"))
	local s = f:read("*a")
	f:close()
	return s
end

-- The same WLAN with a captive portal (GUESTIN -P DROP), on a device with
-- fw_caps 0x40000 (ipset), as YcZSaTCMOYFEMGE / SrOQOGnuakVoL emit it.
local PORTAL_IPSET = table.concat({
	"wireless.1.devname=ath1", "wireless.1.is_guest=true", "wireless.1.ssid=Lobby",
	"ipset.status=enabled",
	"ipset.1.status=enabled", "ipset.1.name=guest_pre_allow", "ipset.1.type=hash:net",
	"ipset.1.entry.1.value=198.51.100.7",
	"ipset.2.status=enabled", "ipset.2.name=guest_restricted", "ipset.2.type=hash:net",
	"ipset.2.entry.1.value=224.0.0.0/4", "ipset.2.entry.2.value=192.0.2.0/24",
	"ipset.2.entry.3.value=not-an-address",
	"ipset.3.status=enabled", "ipset.3.name=guest_authorized_mac", "ipset.3.type=hash:mac",
	"ebtables.status=enabled",
	"ebtables.1.cmd=-t nat -N GUESTIN -P DROP",
	"ebtables.2.cmd=-t nat -N GUESTOUT -P ACCEPT",
	"ebtables.3.cmd=-t nat -A PREROUTING --in-interface ath1 -j GUESTIN",
	"ebtables.4.cmd=-t nat -A POSTROUTING --out-interface ath1 -j GUESTOUT",
	"ebtables.5.cmd=-t nat -A GUESTIN -p 0x800 --pkttype-type broadcast --ip-proto 17 --ip-sport 68 --ip-dport 67 -j ACCEPT",
	"ebtables.6.cmd=-t nat -A GUESTIN -p arp -j ACCEPT",
	"ebtables.7.cmd=-t nat -N GUEST_DNS -P DROP",
	"ebtables.8.cmd=-t nat -A GUESTIN -p 0x800 --ip-proto 17 --ip-dport 53 -j GUEST_DNS",
	"ebtables.9.cmd=-t nat -A GUESTIN -p 0x800 --set guest_pre_allow --set-flags dst --set-family inet -j ACCEPT",
	"ebtables.10.cmd=-t nat -A GUESTIN -p 0x86dd -j DROP",
	"ebtables.11.cmd=-t nat -A GUESTIN --pkttype-type broadcast -j DROP",
	"ebtables.12.cmd=-t nat -N CAPTIVE_PORTAL -P RETURN",
	"ebtables.13.cmd=-t nat -A GUESTIN -p 0x800 --ip-proto 6 --ip-dport 443 -j CAPTIVE_PORTAL",
	"ebtables.14.cmd=-t nat -A GUESTOUT -p 0x800 --set guest_pre_allow --set-flags dst --set-family inet -j ACCEPT",
	"ebtables.15.cmd=-t nat -A GUESTIN -p 0x800 --set guest_restricted --set-flags dst --set-family inet -j DROP",
	"ebtables.16.cmd=-t nat -N REDIRECT_HTTP",
	"ebtables.17.cmd=-t nat -A REDIRECT_HTTP -j mark --mark-or 0x1 --mark-target CONTINUE",
	"ebtables.18.cmd=-t nat -A REDIRECT_HTTP -j redirect",
	"ebtables.19.cmd=-t nat -N AUTHORIZED_GUESTS -P RETURN",
	"ebtables.20.cmd=-t nat -A AUTHORIZED_GUESTS --set guest_authorized_mac --set-flags src -j ACCEPT",
	"ebtables.21.cmd=-t nat -A GUESTIN -p 0x800 --pkttype-type otherhost -j AUTHORIZED_GUESTS",
	"ebtables.22.cmd=-t nat -A GUESTIN -p 0x800 --ip-proto 6 --ip-dport 80 -j REDIRECT_HTTP",
	"ebtables.23.cmd=-t nat -A GUEST_DNS -p 0x800 --ip-proto 17 --ip-dport 53 -j AUTHORIZED_GUESTS",
	"ebtables.24.cmd=-t nat -I GUESTIN -p 0x800 --ip-dst 192.0.2.1 --ip-proto 6 --ip-dport 8880 -j REDIRECT_HTTP",
	"ebtables.25.cmd=-t nat -I GUESTIN -p 0x800 --ip-dst 192.0.2.1 --ip-proto 6 --ip-dport 8843 -j ACCEPT",
}, "\n") .. "\n"

local function bodies(spec, chain)
	local out = {}
	for _, r in ipairs(spec.chains[chain].rules) do out[#out + 1] = gg.rule_text(r) end
	return out
end

local function with_exec(fn, opts)
	opts = opts or {}
	local cmds, oe, orr = {}, gg._exec, gg._read
	gg._exec = function(cmd)
		cmds[#cmds + 1] = cmd
		if opts.fail and cmd:find("nft -f", 1, true) then return 1 end
		return 0
	end
	gg._read = function() return opts.listed or "iifname { \"x\" } jump guestin" end
	local ok, err = pcall(fn)
	gg._exec, gg._read = oe, orr
	if not ok then error(err, 0) end
	return cmds
end

local function with_stderr(fn)
	local buf, real = {}, io.stderr
	io.stderr = {write = function(_, ...) for _, s in ipairs({...}) do buf[#buf + 1] = s end end}
	local ok, err = pcall(fn)
	io.stderr = real
	if not ok then error(err, 0) end
	return table.concat(buf)
end

return {
	{
		name = "guest: parse finds the guest WLAN by is_guest, and nothing unknown in the generator's rules",
		fn = function()
			local p = guest.parse(fixture())
			assert_true(p.enabled, "ebtables enabled")
			assert_eq(table.concat(p.ssids, ","), "Lobby", "only the guest SSID")
			assert_eq(table.concat(p.guest_devnames, ","), "ath1,ath3", "its two wire VAPs")
			assert_eq(table.concat(p.hooks["in"], ","), "ath1,ath3", "hooked into GUESTIN")
			assert_eq(table.concat(p.hooks.out, ","), "ath1,ath3", "and GUESTOUT")
			assert_eq(#p.unknown, 0, "every guest rule understood: " .. table.concat(p.unknown, " | "))
			assert_eq(table.concat(p.order, ","), "GUESTIN,GUESTOUT,GUEST_DNS,CAPTIVE_PORTAL,ALLOW_DNS_SERVERS",
				"chains in definition order")
		end
	},
	{
		name = "guest: -I lands at the head and -A at the tail, as ebtables replays them",
		fn = function()
			local spec = guest.spec_from(guest.parse(fixture()))
			assert_true(spec.enabled, "enabled")
			assert_false(spec.portal, "no portal")
			local b = bodies(spec, "GUESTIN")
			assert_eq(b[1], "ether type ip ip protocol tcp tcp dport 53 jump allow_dns_servers", "last -I first")
			assert_eq(b[2], "ether type ip ip protocol udp udp dport 53 jump allow_dns_servers", "restricted DNS on top")
			assert_eq(b[3], "ether type ip ip daddr 198.51.100.7 accept", "pre-authorization subnet before any drop")
			assert_eq(b[4], "ether type 0x888e accept", "EAPOL")
			assert_eq(b[6], "ether type ip meta pkttype broadcast ip protocol udp udp sport 68 udp dport 67 accept", "DHCP")
			assert_eq(b[7], "ether type arp arp operation request accept", "ARP requests")
			assert_eq(b[10], "ether type ip6 drop", "IPv6 dropped, as the controller asks")
			assert_eq(b[11], "meta pkttype broadcast drop", "other broadcasts dropped")
			assert_eq(b[13], "ether type ip ip daddr 224.0.0.0/4 drop", "multicast dropped")
			assert_eq(b[16], "ether type ip ip daddr 203.0.113.0/24 drop", "restricted subnets last")
			assert_eq(spec.chains.GUESTIN.policy, "accept", "policy ACCEPT")
			local o = bodies(spec, "GUESTOUT")
			assert_eq(o[1], "ether type ip ip saddr 198.51.100.7 accept", "pre-authorization source on top")
			assert_eq(o[#o], "ether type ip ip daddr 224.0.0.0/4 drop", "multicast to guests dropped")
			assert_eq(spec.chains.ALLOW_DNS_SERVERS.policy, "drop", "only the listed DNS servers")
			assert_eq(bodies(spec, "ALLOW_DNS_SERVERS")[1], "ether type ip ip daddr 192.0.2.53 accept", "the server")
			assert_eq(spec.chains.CAPTIVE_PORTAL.policy, "return", "an empty RETURN chain")
		end
	},
	{
		name = "guest: the portal's chains, jumps and default-deny are left out, the restrictions kept; ipsets resolved",
		fn = function()
			local p = guest.parse(PORTAL_IPSET)
			assert_eq(#p.unknown, 0, "all understood: " .. table.concat(p.unknown, " | "))
			local spec = guest.spec_from(p)
			assert_true(spec.portal, "portal noticed")
			assert_eq(spec.chains.GUESTIN.policy, "accept", "GUESTIN's DROP policy not applied")
			assert_eq(spec.chains.GUEST_DNS.policy, "accept", "nor GUEST_DNS's")
			assert_nil(spec.chains.REDIRECT_HTTP, "no redirect chain")
			assert_nil(spec.chains.AUTHORIZED_GUESTS, "no authorisation chain")
			local joined = table.concat(bodies(spec, "GUESTIN"), "\n") .. table.concat(bodies(spec, "GUEST_DNS"), "\n")
			assert_true(not joined:find("redirect"), "no jump to the redirect chain")
			assert_true(not joined:find("authorized"), "no jump to the authorisation chain")
			assert_contains(joined, "ip daddr @guest_restricted drop", "restricted set enforced")
			assert_contains(joined, "ip daddr @guest_pre_allow accept", "pre-allow set enforced")
			assert_contains(joined, "ether type arp accept", "all ARP, as with a portal")
			assert_eq(table.concat(spec.sets.guest_restricted, ","), "224.0.0.0/4,192.0.2.0/24", "valid entries only")
			assert_nil(spec.sets.guest_authorized_mac, "the portal's MAC set is not built")
			assert_true(#spec.dropped >= 4, "the dropped rules are listed for the log")
		end
	},
	{
		name = "guest: no guest WLAN, a disabled block, or a partial push",
		fn = function()
			local plain = "wireless.1.devname=ath0\nwireless.1.is_guest=false\nwireless.1.ssid=Home\n"
				.. "ebtables.status=enabled\nebtables.1.cmd=-t nat -A PREROUTING --in-interface ath0 -d BGA -j DROP\n"
			local p = guest.parse(plain)
			assert_true(p ~= nil, "a full push is read")
			assert_false(guest.spec_from(p).enabled, "no guest WLAN: nothing to enforce")
			assert_nil(guest.parse("wireless.1.is_guest=true\nwireless.1.ssid=Lobby\n"), "no ebtables block: partial")
			local off = fixture():gsub("ebtables%.status=enabled", "ebtables.status=disabled")
			assert_false(guest.spec_from(guest.parse(off)).enabled, "block disabled")
			assert_false(guest.spec_from(nil).enabled, "nil")
		end
	},
	{
		name = "guest: an SSID shared by a guest and a non-guest WLAN is refused, not guessed",
		fn = function()
			local raw = fixture() .. "wireless.5.devname=ath4\nwireless.5.is_guest=false\nwireless.5.ssid=Lobby\n"
			local p = guest.parse(raw)
			assert_eq(table.concat(p.conflicts, ","), "Lobby", "reported")
			assert_eq(#p.ssids, 0, "not a guest SSID")
			assert_false(guest.spec_from(p).enabled, "so nothing is enforced")
		end
	},
	{
		name = "guest: odd or unsupported fragments land in unknown, never in a chain",
		fn = function()
			local raw = "wireless.1.is_guest=true\nwireless.1.ssid=G\nebtables.status=enabled\n"
				.. "ebtables.1.cmd=-t nat -N GUESTIN -P ACCEPT\n"
				.. "ebtables.2.cmd=-t nat -N GUESTOUT -P ACCEPT\n"
				.. "ebtables.3.cmd=-t nat -A GUESTIN -p 0x800 --ip-dst 198.51.100.0/24; rm -rf / -j DROP\n"
				.. "ebtables.4.cmd=-t nat -A GUESTIN -p 0x800 --ip-dst 300.1.1.1 -j DROP\n"
				.. "ebtables.5.cmd=-t nat -A GUESTIN --ip-dst 192.0.2.0/24 -j DROP\n"
				.. "ebtables.6.cmd=-t nat -A GUESTIN -p 0x800 --ip-tos 4 -j DROP\n"
				.. "ebtables.7.cmd=-t nat -A NOSUCH -p arp -j ACCEPT\n"
				.. "ebtables.8.cmd=-t nat -A GUESTIN --in-interface ath1 -p 0x800 -j DROP\n"
				.. "ebtables.9.cmd=-t nat -A PREROUTING --logical-in br10 -j GUESTIN\n"
			local p = guest.parse(raw)
			assert_eq(#p.unknown, 6, "six refused: " .. table.concat(p.unknown, " | "))
			assert_eq(#p.chains.GUESTIN.rules, 0, "none of them in GUESTIN")
			assert_eq(#p.unenforced, 1, "the wired guest network is reported as not enforced")
		end
	},
	{
		name = "guest: hardening counts the guest rules instead of calling them unknown",
		fn = function()
			local h = hardening.parse(fixture())
			assert_eq(#h.unknown, 0, "nothing unknown to l2guard")
			assert_eq(h.guest, 32, "the 32 guest fragments counted")
			assert_eq(table.concat(h.bpdu_in, ","), "ath0,ath1,ath2,ath3", "BPDU rules still l2guard's")
			assert_eq(table.concat(h.tag_in, ","), "ath1,ath3", "and the guest VAPs' tag drop")
		end
	},
	{
		name = "ucihelper: ap_ifnames_for_ssids finds the guest SSID's AP VAPs on every radio, with their PPSK VLANs",
		fn = function()
			local ucihelper = dofile("src/openwrt/ucihelper.lua")
			ucihelper._popen = function()
				return '{"radio1":{"up":true,"interfaces":[{"section":"a","ifname":"phy1-ap1","config":{"mode":"ap","ssid":"Lobby"},'
					.. '"vlans":[{"ifname":"phy1-ap1-20"}]},'
					.. '{"section":"b","ifname":"phy1-ap0","config":{"mode":"ap","ssid":"Home"}},'
					.. '{"section":"s","ifname":"phy1-sta0","config":{"mode":"sta","ssid":"Lobby"}}]},'
					.. '"radio0":{"up":true,"interfaces":[{"section":"c","ifname":"phy0-ap1","config":{"ssid":"Lobby"}},'
					.. '{"section":"e","config":{"mode":"ap","ssid":"Lobby"}}]}}'
			end
			ucihelper.end_pass()
			local names = ucihelper.ap_ifnames_for_ssids({"Lobby"})
			assert_eq(table.concat(names, ","), "phy0-ap1,phy1-ap1,phy1-ap1-20",
				"guest VAPs and their VLAN netdev; not the other SSID, the station, or one not up yet")
			assert_eq(#ucihelper.ap_ifnames_for_ssids({}), 0, "no SSIDs, no VAPs")
			ucihelper._popen = function() return "" end
			ucihelper.end_pass()
			assert_eq(#ucihelper.ap_ifnames_for_ssids({"Lobby"}), 0, "no ubus answer -> empty")
		end
	},
	{
		name = "guestguard: one nft transaction, chains before rules, hooks on exactly the guest VAPs",
		fn = function()
			local spec = guest.spec_from(guest.parse(fixture()))
			local ok
			local cmds = with_exec(function() ok = gg.reconcile(spec, {"phy0-ap1", "phy1-ap1"}) end)
			assert_true(ok, "applied")
			assert_eq(#cmds, 2, "delete, then one transaction")
			assert_contains(cmds[1], "nft delete table bridge openuf_guest", "clears first")
			local s = cmds[2]
			assert_contains(s, "nft -f - <<'OPENUF_GUEST_EOF'", "atomic")
			assert_contains(s, "add table bridge openuf_guest\ndelete table bridge openuf_guest\n", "idempotent inside")
			local chain_at = s:find("add chain bridge openuf_guest allow_dns_servers", 1, true)
			local jump_at = s:find("jump allow_dns_servers", 1, true)
			assert_true(chain_at and jump_at and chain_at < jump_at, "a chain exists before the jump to it")
			assert_contains(s, "priority -300", "ebtables' nat PREROUTING")
			assert_contains(s, "priority 300", "ebtables' nat POSTROUTING")
			assert_contains(s, 'iifname { "phy0-ap1", "phy1-ap1" } jump guestin', "in hook")
			assert_contains(s, 'oifname { "phy0-ap1", "phy1-ap1" } jump guestout', "out hook")
			local _, eapol = s:gsub("ether type 0x888e accept", "")
			assert_eq(eapol, 1, "the repeated per-VAP EAPOL accept collapses to one")
			assert_contains(s, "add rule bridge openuf_guest guestin accept\n", "the policy as the last rule")
			assert_contains(s, "add rule bridge openuf_guest allow_dns_servers drop\n", "DROP policy too")
			assert_true(not s:find("add rule bridge openuf_guest captive_portal return"), "RETURN needs no rule")
		end
	},
	{
		name = "guestguard: ipsets become interval sets that tolerate overlap",
		fn = function()
			local spec = guest.spec_from(guest.parse(PORTAL_IPSET))
			local cmds = with_exec(function() gg.reconcile(spec, {"phy0-ap1"}) end)
			assert_contains(cmds[2], "add set bridge openuf_guest guest_restricted { type ipv4_addr; flags interval; auto-merge; }", "set")
			assert_contains(cmds[2], "add element bridge openuf_guest guest_restricted { 224.0.0.0/4, 192.0.2.0/24 }", "elements")
		end
	},
	{
		name = "guestguard: nothing to enforce, or no VAP yet, only deletes; odd names are not spliced",
		fn = function()
			local cmds = with_exec(function() assert_false(gg.reconcile(nil), "nil") end)
			assert_eq(#cmds, 1, "delete only")
			cmds = with_exec(function() assert_false(gg.reconcile({enabled = false}, {"x"}), "off") end)
			assert_eq(#cmds, 1, "delete only")
			local spec = guest.spec_from(guest.parse(fixture()))
			local out = with_stderr(function()
				cmds = with_exec(function() assert_false(gg.reconcile(spec, {"bad name; rm", "x'y"}), "none sane") end)
			end)
			assert_eq(#cmds, 1, "delete only")
			assert_contains(out, "ignoring odd interface name", "logged")
			assert_contains(out, "restrictions deferred", "and deferred")
		end
	},
	{
		name = "guestguard: a refused transaction, or one the kernel does not show, is said by name and cleaned up",
		fn = function()
			local spec = guest.spec_from(guest.parse(fixture()))
			local ok, cmds
			local out = with_stderr(function()
				cmds = with_exec(function() ok = gg.reconcile(spec, {"phy0-ap1"}) end, {fail = true})
			end)
			assert_false(ok, "not in force")
			assert_contains(out, "kmod-nft-bridge", "names the fix")
			assert_contains(out, "Lobby", "names the WLAN left unrestricted")
			assert_contains(cmds[#cmds], "nft delete table", "no half table left")
			out = with_stderr(function()
				with_exec(function() ok = gg.reconcile(spec, {"phy0-ap1"}) end, {listed = ""})
			end)
			assert_false(ok, "rc 0 but nothing listed is not success")
		end
	},
}
