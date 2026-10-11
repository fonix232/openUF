-- Tests for src/unifi/guest.lua (the controller's guest restrictions) and
-- src/openwrt/guestguard.lua (their nft table).
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local guest = dofile("src/unifi/guest.lua")
local gg = dofile("src/openwrt/guestguard.lua")
local hardening = dofile("src/unifi/hardening.lua")
local ws = dofile("src/openwrt/wlansched.lua")

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

local function portal_lab()
	local f = assert(io.open("tests/fixtures/system_cfg_guest_portal_lab.txt"))
	local s = f:read("*a")
	f:close()
	return s
end

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
			assert_eq(#cmds, 2, "one transaction, then no portal NAT table")
			assert_contains(cmds[2], "nft delete table ip openuf_guest", "no portal: no NAT table")
			local s = cmds[1]
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
			assert_contains(cmds[1], "add set bridge openuf_guest guest_restricted { type ipv4_addr; flags interval; auto-merge; }", "set")
			assert_contains(cmds[1], "add element bridge openuf_guest guest_restricted { 224.0.0.0/4, 192.0.2.0/24 }", "elements")
		end
	},
	{
		name = "guestguard: nothing to enforce, or no VAP yet, only deletes; odd names are not spliced",
		fn = function()
			local cmds = with_exec(function() assert_false(gg.reconcile(nil), "nil") end)
			assert_eq(#cmds, 2, "delete only")
			assert_contains(cmds[1] .. cmds[2], "delete table bridge openuf_guest", "the guest table")
			assert_contains(cmds[1] .. cmds[2], "delete table ip openuf_guest", "and the portal's NAT table")
			cmds = with_exec(function() assert_false(gg.reconcile({enabled = false}, {"x"}), "off") end)
			assert_eq(#cmds, 2, "delete only")
			local spec = guest.spec_from(guest.parse(fixture()))
			local out = with_stderr(function()
				cmds = with_exec(function() assert_false(gg.reconcile(spec, {"bad name; rm", "x'y"}), "none sane") end)
			end)
			assert_eq(#cmds, 2, "delete only")
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
	{
		name = "guest: the authorization ledger is capped, oldest first; MACs are normalised",
		fn = function()
			local st = {guest_authorized = {}}
			for i = 1, guest.LEDGER_MAX do
				st.guest_authorized[("02:00:00:00:%02x:%02x"):format(math.floor(i / 256), i % 256)] = 1000 + i
			end
			assert_true(guest.authorize(st, " AA:BB:CC:DD:EE:01 ", true, 5000), "recorded")
			local n = 0
			for _ in pairs(st.guest_authorized) do n = n + 1 end
			assert_eq(n, guest.LEDGER_MAX, "held at the cap")
			assert_nil(st.guest_authorized["02:00:00:00:00:01"], "the oldest went")
			assert_eq(st.guest_authorized["aa:bb:cc:dd:ee:01"], 5000, "the new one stays, lowercased")
			assert_false(guest.authorize(st, "aa:bb:cc:dd:ee:01;x", false, 0), "malformed refused")
			assert_true(guest.authorize(st, "aa:bb:cc:dd:ee:01", false, 0), "unauthorize")
			assert_nil(st.guest_authorized["aa:bb:cc:dd:ee:01"], "dropped")
		end
	},
	{
		name = "guest: sta_authorized is the ledger's word on a portal WLAN only",
		fn = function()
			local st = {guest_wlans = {w1 = true}, guest_authorized = {["aa:bb:cc:dd:ee:01"] = 1}}
			assert_true(guest.sta_authorized(st, "w1", "AA:BB:CC:DD:EE:01"), "authorized")
			assert_false(guest.sta_authorized(st, "w1", "aa:bb:cc:dd:ee:02"), "not authorized")
			assert_true(guest.sta_authorized(st, "w2", "aa:bb:cc:dd:ee:02"), "not a portal WLAN")
			assert_true(guest.sta_authorized(st, nil, "aa:bb:cc:dd:ee:02"), "no wlanconf id")
			assert_true(guest.sta_authorized({}, "w1", "aa:bb:cc:dd:ee:02"), "no record at all")
		end
	},
	{
		name = "guest: the lab's portal push is enforced in wire order, default-deny and all",
		fn = function()
			local p = guest.parse(portal_lab())
			assert_eq(#p.unknown, 0, "every shape known: " .. table.concat(p.unknown, " | "))
			assert_eq(p.portal_url, "http://192.0.2.2:8880/guest/s/default/", "redirector.url")
			local spec = guest.spec_from(p)
			assert_true(spec.portal, "portal on")
			assert_eq(spec.portal_url, p.portal_url, "and enforced")
			assert_eq(spec.chains.GUESTIN.policy, "drop", "GUESTIN's default-deny kept")
			assert_eq(spec.chains.GUEST_DNS.policy, "drop", "GUEST_DNS's too")
			for _, c in ipairs({"AUTHORIZED_GUESTS", "REDIRECT_HTTP", "REDIRECT_HTTPS", "REDIRECT_DNS"}) do
				assert_eq(spec.chains[c].portal, c, c .. ": the device writes its body")
				assert_eq(#spec.chains[c].rules, 0, c .. ": nothing from the wire")
			end
			local g = bodies(spec, "GUESTIN")
			assert_eq(g[1], "ether type ip ip daddr 192.0.2.2 ip protocol tcp tcp dport 8881 accept", "last -I first")
			assert_eq(g[2], "ether type ip ip daddr 192.0.2.2 ip protocol tcp tcp dport 8882 jump redirect_http",
				"the 8882 intercept")
			local at = {}
			for i, b in ipairs(g) do at[b] = i end
			local auth = at["ether type ip meta pkttype other jump authorized_guests"]
			local http = at["ether type ip ip protocol tcp tcp dport 80 jump redirect_http"]
			local restricted = at["ether type ip ip daddr 10.0.0.0/8 drop"]
			assert_true(restricted and auth and http and restricted < auth and auth < http,
				"restricted subnets, then authorized guests, then the HTTP redirect")
			assert_true(guest.spec_from(guest.parse(portal_lab():gsub("redirector%.url=", "x=")))
				.chains.GUESTIN.policy == "accept", "no URL: not enforced, the old open fallback")
			p = guest.parse(portal_lab():gsub("redirector%.url=[^\n]*", "redirector.url=http://x/\r"))
			assert_nil(p.portal_url, "a URL with a control character is refused")
		end
	},
	{
		name = "guestguard: the portal's chains get the device's bodies, the NAT redirect its own transaction",
		fn = function()
			local spec = guest.spec_from(guest.parse(portal_lab()))
			local orig = gg._read_file
			gg._read_file = function(path)
				if path == "/sys/class/net/phy0-ap1/master/address" then return "02:00:00:00:00:AA\n" end
			end
			local ok, out, cmds
			out = with_stderr(function()
				cmds = with_exec(function()
					ok = gg.reconcile(spec, {"phy0-ap1", "phy1-ap1"}, {macs = {"02:00:00:00:00:01", "x;reboot"}})
				end)
			end)
			gg._read_file = orig
			assert_true(ok, "applied")
			assert_eq(#cmds, 2, "the guest table, then the NAT table")
			local s = cmds[1]
			local T = "add rule bridge openuf_guest "
			assert_contains(s, "add set bridge openuf_guest openuf_authorized { type ether_addr; }", "the set")
			assert_contains(s, "add element bridge openuf_guest openuf_authorized { 02:00:00:00:00:01 }", "the ledger")
			assert_true(not s:find("reboot", 1, true), "a malformed MAC is never spliced")
			assert_contains(s, T .. "authorized_guests ether saddr @openuf_authorized accept\n"
				.. T .. "authorized_guests jump selfrun\n", "AUTHORIZED_GUESTS")
			assert_contains(s, T .. "redirect_http meta mark set meta mark or 0x40000000\n"
				.. T .. 'redirect_http iifname "phy0-ap1" ether daddr set 02:00:00:00:00:aa meta pkttype set host accept\n'
				.. T .. "redirect_http drop\n", "REDIRECT_HTTP: to the bridge, where bridged")
			assert_contains(s, T .. "redirect_https drop\n", "HTTPS is dropped")
			assert_contains(s, T .. "redirect_dns accept\n", "DNS passes")
			assert_contains(s, T .. "guestin drop\n", "the default-deny as the last rule")
			assert_true(s:find("add chain bridge openuf_guest selfrun", 1, true)
				< s:find("jump selfrun", 1, true), "selfrun exists before the jump")
			assert_contains(cmds[2], "add chain ip openuf_guest pre { type nat hook prerouting priority -101; }", "NAT")
			assert_contains(cmds[2], "meta mark and 0xc0000000 == 0x40000000 meta l4proto tcp redirect to :8820",
				"the marked HTTP to the answer")
			assert_contains(out, "1 guest interface(s) not bridged", "the unbridged one is said")
		end
	},
	{
		name = "guestguard: selfrun lets every guest through authorized_guests, and only there",
		fn = function()
			local spec = guest.spec_from(guest.parse(portal_lab()))
			local on = gg.script(spec, {"phy0-ap1"}, {selfrun = true})
			local off = gg.script(spec, {"phy0-ap1"}, {})
			assert_contains(on, "add rule bridge openuf_guest selfrun accept\n", "pass: open")
			assert_true(not off:find("selfrun accept", 1, true), "otherwise empty")
		end
	},
	{
		name = "wlansched: set_bss takes one BSS off the air and puts it back with its beacon",
		fn = function()
			local cmds, cli, rc, beacon = {}, {}, 0, "OK\n"
			local orig = {run = ws._run_cmd, popen = ws._popen}
			ws._run_cmd = function(c) cmds[#cmds + 1] = c; return rc end
			ws._popen = function(c) cli[#cli + 1] = c; return c:find("update_beacon", 1, true) and beacon or "OK\n" end
			local ok, err = pcall(function()
				assert_true(ws.set_bss("phy0-ap1", false), "down")
				assert_eq(table.concat(cmds, " | "), "ip link set dev phy0-ap1 down 2>/dev/null", "the link only")
				assert_eq(#cli, 0, "no hostapd call going down")
				cmds = {}
				assert_true(ws.set_bss("phy0-ap1", true), "up")
				assert_eq(table.concat(cmds, " | "), "ip link set dev phy0-ap1 up 2>/dev/null", "the link")
				assert_eq(table.concat(cli, " | "), "hostapd_cli -i phy0-ap1 raw STOP_AP 2>/dev/null | "
					.. "hostapd_cli -i phy0-ap1 update_beacon 2>/dev/null", "then the beacon")
				cmds, cli, beacon = {}, {}, "FAIL\n"
				assert_false(ws.set_bss("phy0-ap1", true), "no beacon")
				assert_eq(cmds[#cmds], "ip link set dev phy0-ap1 down 2>/dev/null", "down again")
				cmds, cli, rc = {}, {}, 1
				assert_false(ws.set_bss("phy0-ap1", true), "the link refused")
				assert_eq(#cli, 0, "hostapd not asked")
				assert_false(ws.set_bss("phy0-ap1", false), "refused down")
				cmds, rc = {}, 0
				assert_false(ws.set_bss("x; reboot", true), "bad name")
				assert_false(ws.set_bss("x; reboot", false), "bad name")
				assert_eq(#cmds, 0, "never run")
			end)
			ws._run_cmd, ws._popen = orig.run, orig.popen
			if not ok then error(err, 0) end
		end
	},
}
