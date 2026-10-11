--[[
	"Multicast and Broadcast Blocker" enforcement (Settings -> WiFi -> [WLAN]).

	The controller pushes this per WLAN as wireless.<n>.bcfilt.status plus a
	bcfilt.<k>.mac allow-list -- see inform.lua's parser for the live wire
	evidence. Unlike every other WLAN setting openUF carries, there is no
	hostapd or OpenWrt option for it: hostapd can suppress group-addressed
	frames wholesale (ap_isolate, disable_dgaf) but has no notion of an
	allow-list, so this is enforced with nftables instead.

	WHAT IT DOES, and why that is deliberately destructive:

	Per Ubiquiti's own documentation this blocks LAN->WLAN multicast and
	broadcast traffic except from the listed source MACs. That genuinely breaks
	DHCP for wireless clients unless the DHCP server's MAC is on the list --
	Ubiquiti documents exactly that, and instructs admins to add it. So the
	filter here is faithful to the controller's intent and deliberately does
	NOT carve out DHCP/ARP exemptions of its own: an admin who enabled this
	control and curated an allow-list would find a silent "helpful" exemption
	harder to debug than the documented behavior.

	The match is on SOURCE MAC in the to-wireless direction: a group-addressed
	frame heading out a managed VAP is dropped unless its sender is
	allow-listed. (Group destinations are not per-station addresses, so a
	destination match could not express an allow-list at all.)

	Mechanism mirrors firewall.lua: a dedicated `bridge` table rebuilt from
	scratch on every reconcile rather than diffed, so it is idempotent and
	self-healing. It uses its OWN table, separate from firewall.lua's `bridge
	openuf` -- that module deletes and recreates its whole table on each
	block/unblock, which would otherwise wipe these rules.

	REQUIRES kmod-nft-bridge. The rule below is the only place openUF uses a
	`meta` expression in the bridge family, and that expression lives in
	nft_meta_bridge.ko -- a module OpenWrt ships in kmod-nft-bridge, which is
	not pulled in by nftables and is absent from a default filogic or ath79
	image. Without it the kernel rejects the rule with a bare
	"Error: Could not process rule: No such file or directory", nft's caret
	pointing at `oifname`. Everything either side of it still succeeds: the
	table, the chain and the per-VAP allow set are all created and populated,
	so the control looks enabled in the controller and on the device while
	filtering nothing at all. That is why a failed rule add warns loudly
	below rather than being left to the reader of a syslog. `ether saddr`
	needs no module, which is why firewall.lua's block-sta table works on the
	same image and hid this for so long.

	VERIFIED on real hardware (AX3000T, mediatek/filogic, nftables 1.1.6,
	kernel 6.12): with the sender not allow-listed, 14 of 14 broadcast frames
	entering the VLAN bridge from the uplink and heading out the IoT VAP
	matched and were dropped; with the same sender allow-listed, 0 of 15
	matched. Both halves of the control do what the controller advertises.
]]--

local M = {}

-- Injectable: shell command runner, for real `nft` invocations.
M._exec = function(cmd) return os.execute(cmd) end

-- os.execute's contract differs across the Lua versions this module runs on:
-- 5.1 (the target) returns the raw exit status, so SUCCESS is the number 0 and
-- failure is a non-zero number -- both truthy. 5.4+ returns ok, "exit", code.
-- A bare `if M._exec(...) then` therefore reports success for every failure on
-- the very interpreter the APs use, which is how the missing module above went
-- unnoticed. Normalise before deciding anything.
local util = require("openwrt.util")

local NFT_TABLE = "bridge openuf_bcfilt"

-- Exactly "aa:bb:cc:dd:ee:ff": every allow-list entry is spliced into an nft
-- command line, so the shape is enforced here as well as at the parser.
local function is_mac(s)
	return type(s) == "string" and s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

-- Multicast Suppressor (wlanconf multicast_suppressor_mode), on top of the
-- blocker's table:
--
--   Aggressive arrives as the blocker itself plus bcfilt.bypass_types
--   ("ARP|NSNA|DHCPV4|DHCPV6", 10.6.106 ubntconf.EYFcHmSpOqr) and an allowlist
--   the controller fills with the site's device MACs. The UI's own words:
--   "Aggressive blocks all except DHCP and ARP, unless a device is
--   allowlisted". So each bypass type gets an accept ahead of the drop.
--
--   Conservative arrives as wireless.<n>.multicast.suppressor=enabled and
--   nothing else ("Conservative prevents storms"). The decompiled controller
--   says no more than that, and UniFi firmware's threshold is not on the
--   wire, so openUF's reading is storm control: group-addressed frames to
--   the VAP beyond STORM_PPS per second (burst STORM_BURST) are dropped, and
--   everything under it passes. A best-effort reading, not a replica.
--
-- Order in the chain, per VAP: the bypass accepts (DHCP, ARP, ND: never
-- rate-limited, a storm of other traffic must not starve them), then the
-- storm limiter, then the blocker's allow-list drop.
--
-- Every rule names the VAP (oifname), so nothing here touches a frame
-- between wired ports: UniFi's own AP-to-AP group (239.254.127.63, UDP
-- 48000, unifi.mcip) still crosses an openUF AP between two real UniFi APs
-- on its wired side.
M.STORM_PPS   = 200
M.STORM_BURST = 400

-- The frames each bypass type lets through, as nft matches. In the bridge
-- family the kernel sets the network header for IPv4/IPv6 frames
-- (nft_do_chain_bridge); the explicit ether type keeps a DHCPv4 match from
-- ever reading an IPv6 frame's ports and the other way round.
M.BYPASS = {
	ARP    = "ether type arp",
	NSNA   = "ether type ip6 icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert }",
	DHCPV4 = "ether type ip udp dport { 67, 68 }",
	DHCPV6 = "ether type ip6 udp dport { 546, 547 }",
}

-- Rebuild the filter to exactly match rules, a list of per-VAP entries:
--   {ifname = "wlan0", macs = {"aa:bb:..", ...}}       the blocker
--   + bypass = {"ARP", "NSNA", ...}                    Aggressive's exemptions
--   + block = false                                    no blocker (Conservative
--                                                      alone)
--   + storm = true                                     Conservative's limiter
-- A VAP with an empty allow-list still belongs here: that is "block all
-- group-addressed traffic to this SSID", which is a meaningful (if
-- aggressive) setting rather than a no-op.
--
-- Safe with an empty/nil list (leaves an empty table in place, blocking
-- nothing) and safe to call repeatedly.
-- One nft transaction (util.nft_apply): the old table goes in the commit
-- that builds the new one, so group traffic never meets a moment without the
-- blocker. If nft rejects the batch the statements are re-run one by one, and
-- each rejected rule is named. (upstream b6dd8cf)
function M.reconcile(rules)
	local T = NFT_TABLE
	local stmts = {"add chain " .. T .. " bcfilt { type filter hook forward priority 0; }"}
	local what = {}   -- stmts index -> {ifname, expr, label} for the rules
	for _, rule in ipairs(rules or {}) do
		if rule.ifname and not util.valid_ifname(rule.ifname) then
			-- The name is spliced into a script line.
			io.stderr:write(("bcfilter: ignoring odd interface name %q\n"):format(tostring(rule.ifname)))
		elseif rule.ifname then
			-- Matches frames leaving via this VAP (the LAN->WLAN direction)
			-- that are group-addressed.
			--
			-- oifname, not oif: `oif` resolves the interface to an index when
			-- the rule is added and so fails outright if it does not exist
			-- yet -- fatal here, since these rules are (re)built around a
			-- `wifi reload` that tears the wireless netdevs down and back up.
			-- oifname matches on the name and tolerates its absence. Both were
			-- checked against nftables 1.0.9: `oif wlan0` errors with
			-- "Interface does not exist", `oifname "wlan0"` accepts.
			--
			-- meta pkttype names broadcast and multicast explicitly; an
			-- earlier draft used `ether daddr type multicast`, which is not
			-- valid nft syntax at all (it parses as far as `type` and stops).
			--
			-- `meta pkttype` is the expression that needs kmod-nft-bridge (see
			-- the header): when that module is missing every rule add fails
			-- while the table and set still exist, leaving a table that looks
			-- built and filters nothing. Say so, with the package name.
			local match = "add rule " .. T .. " bcfilt oifname \"" .. rule.ifname
				.. "\" meta pkttype { broadcast, multicast }"
			local function add(expr, label)
				stmts[#stmts + 1] = match .. " " .. expr
				what[#stmts] = {rule.ifname, expr, label}
			end
			-- The exemptions first: never rate-limited, never dropped.
			if rule.block ~= false then
				for _, b in ipairs(rule.bypass or {}) do
					if M.BYPASS[b] then add(M.BYPASS[b] .. " accept", "Multicast Suppressor") end
				end
			end
			-- Storm control next, so a storm of allow-listed frames is cut too.
			if rule.storm then
				add(("limit rate over %d/second burst %d packets drop")
					:format(M.STORM_PPS, M.STORM_BURST), "Multicast Suppressor")
			end
			if rule.block ~= false then
				-- One set per interface, so each SSID keeps its own allow-list.
				local set = "allow_" .. rule.ifname:gsub("[^%w]", "_")
				stmts[#stmts + 1] = "add set " .. T .. " " .. set .. " { type ether_addr; }"
				for _, mac in ipairs(rule.macs or {}) do
					if is_mac(mac) then
						stmts[#stmts + 1] = "add element " .. T .. " " .. set .. " { " .. mac .. " }"
					else
						io.stderr:write(("bcfilter: ignoring malformed MAC %q\n")
							:format(tostring(mac)))
					end
				end
				add("ether saddr != @" .. set .. " drop", "Multicast/Broadcast Blocker")
			end
		end
	end
	local _, failed = util.nft_apply(T, stmts, M._exec)
	local ok = true
	for i = 1, #stmts do
		local w = what[i]
		if w and failed[i] then
			ok = false
			io.stderr:write(string.format(
				"openuf: %s: nft rejected a rule for %s (%s); this WLAN is not filtered as\n" ..
				"openuf: the controller asks. If every rule fails, kmod-nft-bridge (nft_meta_bridge)\n" ..
				"openuf: is the usual cause.\n",
				w[3], tostring(w[1]), w[2]))
		end
	end
	return ok
end

return M
