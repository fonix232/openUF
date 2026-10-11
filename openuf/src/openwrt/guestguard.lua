--[[
	The controller's guest-network restrictions (unifi/guest.lua), enforced
	with nftables on the guest WLANs' VAPs.

	The stock firmware hooks each guest VAP into two ebtables nat chains,
	GUESTIN (frames from guests) and GUESTOUT (frames to them). Here the same
	chains become regular chains of a dedicated `bridge openuf_guest` table,
	entered from a prerouting base chain at -300 (where ebtables' nat
	PREROUTING sat) for `iifname` in the guest VAPs and from a postrouting one
	at 300 (nat POSTROUTING) for `oifname`. Every rule the controller sent is
	carried over in its wire order; ebtables' ACCEPT/DROP/RETURN and jumps map
	one to one onto nft's accept/drop/return/jump, and a user chain's policy
	becomes its last rule.

	The table is written as ONE nft transaction (`nft -f -`): it is all or
	nothing, so a rejected rule cannot leave half a guest policy -- a broadcast
	drop without the DHCP accept in front of it would take every guest
	offline. The leading `add table` + `delete table` make it idempotent.
	Success is then read back from the kernel (`nft list chain ... prerouting`
	must show the jump into GUESTIN), not inferred from the exit status alone.

	Same discipline as l2guard/bcfilter: its own table, rebuilt from scratch on
	every reconcile, kernel state that dies with a reboot and is rebuilt at
	startup from state.json's `guest` record. iifname/oifname and meta pkttype
	in the bridge family need kmod-nft-bridge; without it the transaction is
	refused and that is said by name.

	The VAPs are found by SSID (ucihelper.ap_ifnames_for_ssids): the controller
	names its own ath<n> devices, which do not exist here. inform.lua re-reads
	them once a minute (_guest_resync), because a `wifi reload` brings a new
	guest VAP up after the push that added it was handled.

	The captive portal (spec.portal_url; LAB-VALIDATED UPSTREAM ONLY, never
	run on hardware). unifi/guest.lua keeps the portal's chains and leaves
	their bodies to this module, the device's part of the firmware's
	ruleset:
	  authorized_guests  ether saddr in the `openuf_authorized` set (the
	                     authorize-guest ledger) -> accept; then `selfrun`,
	                     which accepts every guest while the controller is
	                     unreachable and selfrun_guest_mode=pass (the
	                     firmware's AUTHORIZED_GUESTS ACCEPT-all), and is
	                     empty otherwise
	  redirect_http      mark 0x40000000, then the firmware's ebtables
	                     `redirect`: `ether daddr set` to the bridge's MAC +
	                     `pkttype set host`, so the frame reaches the
	                     bridge's own IP stack; drop without a bridge MAC
	  redirect_https     drop (no certificate a guest would trust)
	  redirect_dns       accept (no local resolver: DNS passes for everyone)
	and a separate `ip openuf_guest` table NAT-redirects the marked HTTP to
	guestportal.PORT, where the inform loop answers with the portal's 302.
	A guest's own speed limit (rate-update) is not here: it is every
	client's per-client WiFi Speed Limit (shaper.lua).
	A rebuild is one transaction that replaces the table, so an
	authorize-guest refreshes the set without a moment of open access.
]]--

local M = {}

M._exec = function(cmd) return os.execute(cmd) end
M._read = function(cmd)
	local h = io.popen(cmd)
	if not h then return "" end
	local out = h:read("*a") or ""
	h:close()
	return out
end

local exec_ok = require("openwrt.util").exec_ok

M.NFT_TABLE = "bridge openuf_guest"
-- Where the NAT-redirected HTTP is answered (openwrt/guestportal.lua). Not
-- 80: uhttpd/LuCI may hold it.
M.PORTAL_PORT = 8820

local function valid_ifname(s)
	return type(s) == "string" and s:match("^[%w%-%._]+$") ~= nil and #s <= 15
end

-- unifi/guest.lua validated every name and address already; this re-checks
-- the shapes, since all of it is spliced into an nft script.
local function nft_chain(name)
	return type(name) == "string" and name:match("^[A-Z][A-Z0-9_]*$") and name:lower() or nil
end
local function cidr(s)
	return type(s) == "string" and s:match("^[%d%.]+/?%d*$") and s or nil
end
local function setname(s)
	return type(s) == "string" and s:match("^[%a_][%w_]*$") and s or nil
end

-- One rule of unifi/guest.lua's model as an nft rule body, or nil.
function M.rule_text(r)
	local m, p = r.match or {}, {}
	if m.proto == "ipv4" then p[#p + 1] = "ether type ip"
	elseif m.proto == "ipv6" then p[#p + 1] = "ether type ip6"
	elseif m.proto == "arp" then p[#p + 1] = "ether type arp"
	elseif m.proto == "length" then p[#p + 1] = "ether type < 0x0600"
	elseif type(m.proto) == "number" then p[#p + 1] = ("ether type 0x%04x"):format(m.proto)
	elseif m.proto ~= nil then return nil end
	if m.pkttype then
		if not ({broadcast = 1, multicast = 1, host = 1, other = 1})[m.pkttype] then return nil end
		p[#p + 1] = "meta pkttype " .. m.pkttype
	end
	if m.arp_op then
		if m.arp_op ~= "request" and m.arp_op ~= "reply" then return nil end
		p[#p + 1] = "arp operation " .. m.arp_op
	end
	if m.src then
		if not cidr(m.src) then return nil end
		p[#p + 1] = "ip saddr " .. m.src
	end
	if m.dst then
		if not cidr(m.dst) then return nil end
		p[#p + 1] = "ip daddr " .. m.dst
	end
	if m.set then
		if not setname(m.set) then return nil end
		p[#p + 1] = (m.set_dir == "src" and "ip saddr @" or "ip daddr @") .. m.set
	end
	if m.l4 then
		if m.l4 ~= "tcp" and m.l4 ~= "udp" then return nil end
		p[#p + 1] = "ip protocol " .. m.l4
		if m.sport then p[#p + 1] = m.l4 .. " sport " .. math.floor(m.sport) end
		if m.dport then p[#p + 1] = m.l4 .. " dport " .. math.floor(m.dport) end
	end
	if r.verdict == "jump" then
		local c = nft_chain(r.jump)
		if not c then return nil end
		p[#p + 1] = "jump " .. c
	elseif r.verdict == "accept" or r.verdict == "drop" or r.verdict == "return" then
		p[#p + 1] = r.verdict
	else
		return nil
	end
	return table.concat(p, " ")
end

M.NAT_TABLE = "ip openuf_guest"
-- The firmware's REDIRECT_HTTP mark; its iptables side matches it under
-- 0xc0000000.
M.MARK_HTTP = "0x40000000"

local function is_mac(s)
	return type(s) == "string" and s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

-- The device's body of one portal chain (see the header).
local function portal_body(name, ifnames, live)
	if name == "AUTHORIZED_GUESTS" then
		return {"ether saddr @openuf_authorized accept", "jump selfrun"}
	elseif name == "REDIRECT_HTTP" then
		local b = {"meta mark set meta mark or " .. M.MARK_HTTP}
		for _, n in ipairs(ifnames) do
			local mac = (live.bridge or {})[n]
			if is_mac(mac) then
				b[#b + 1] = ('iifname "%s" ether daddr set %s meta pkttype set host accept'):format(n, mac:lower())
			end
		end
		b[#b + 1] = "drop"
		return b
	elseif name == "REDIRECT_HTTPS" then
		return {"drop"}
	elseif name == "REDIRECT_DNS" then
		return {"accept"}
	end
	return {}
end

-- The whole table as one nft script, or nil + reason. live: the portal's
-- runtime state, {macs = {mac...},
-- selfrun = bool, bridge = {[ifname] = bridge MAC}}.
function M.script(spec, ifnames, live)
	live = live or {}
	local T = M.NFT_TABLE
	local L = {"add table " .. T, "delete table " .. T, "add table " .. T}
	if spec.portal_url then
		L[#L + 1] = ("add set %s openuf_authorized { type ether_addr; }"):format(T)
		local el = {}
		for _, m in ipairs(live.macs or {}) do if is_mac(m) then el[#el + 1] = m:lower() end end
		if #el > 0 then
			L[#L + 1] = ("add element %s openuf_authorized { %s }"):format(T, table.concat(el, ", "))
		end
		L[#L + 1] = ("add chain %s selfrun"):format(T)
		-- Jumped from authorized_guests only, so the restricted subnets and
		-- the AP itself stay behind the portal's rules.
		if live.selfrun then L[#L + 1] = ("add rule %s selfrun accept"):format(T) end
	end
	for name, entries in pairs(spec.sets or {}) do
		if not setname(name) then return nil, "odd set name" end
		-- auto-merge: the controller's subnets may overlap (203.0.113.0/24 and a
		-- 203.0.113.128/25 under it); auto-merge folds them
		-- (checked with OpenWrt 25.12's nft in a container).
		L[#L + 1] = ("add set %s %s { type ipv4_addr; flags interval; auto-merge; }"):format(T, name)
		local el = {}
		for _, e in ipairs(entries) do if cidr(e) then el[#el + 1] = e end end
		if #el > 0 then
			L[#L + 1] = ("add element %s %s { %s }"):format(T, name, table.concat(el, ", "))
		end
	end
	-- Every chain first, so a jump never names one not created yet.
	for _, name in ipairs(spec.order or {}) do
		local c = nft_chain(name)
		if not c then return nil, "odd chain name" end
		L[#L + 1] = ("add chain %s %s"):format(T, c)
	end
	for _, name in ipairs(spec.order or {}) do
		local c, ch = nft_chain(name), spec.chains[name]
		-- A rule identical to an earlier one in the same chain can never
		-- change the outcome (the controller repeats the EAPOL accept once
		-- per guest VAP, and here they all lose their interface).
		local seen = {}
		if ch.portal then
			for _, body in ipairs(portal_body(ch.portal, ifnames, live)) do
				L[#L + 1] = ("add rule %s %s %s"):format(T, c, body)
			end
		end
		for _, r in ipairs(ch.rules or {}) do
			local body = M.rule_text(r)
			if body and not seen[body] then
				seen[body] = true
				L[#L + 1] = ("add rule %s %s %s"):format(T, c, body)
			end
		end
		if ch.policy == "accept" or ch.policy == "drop" then
			L[#L + 1] = ("add rule %s %s %s"):format(T, c, ch.policy)
		end
	end
	local set = '{ "' .. table.concat(ifnames, '", "') .. '" }'
	L[#L + 1] = ("add chain %s prerouting { type filter hook prerouting priority -300; policy accept; }"):format(T)
	L[#L + 1] = ("add rule %s prerouting iifname %s jump guestin"):format(T, set)
	L[#L + 1] = ("add chain %s postrouting { type filter hook postrouting priority 300; policy accept; }"):format(T)
	L[#L + 1] = ("add rule %s postrouting oifname %s jump guestout"):format(T, set)
	return table.concat(L, "\n") .. "\n"
end

-- The portal's NAT redirect: the marked HTTP, now addressed to the bridge,
-- to port `port`. Its own transaction, so a missing kmod-nft-nat costs the
-- redirect and not the restrictions.
function M.nat_script(port)
	local T = M.NAT_TABLE
	return table.concat({"add table " .. T, "delete table " .. T, "add table " .. T,
		("add chain %s pre { type nat hook prerouting priority -101; }"):format(T),
		("add rule %s pre meta mark and 0xc0000000 == %s meta l4proto tcp redirect to :%d")
			:format(T, M.MARK_HTTP, math.floor(port)),
	}, "\n") .. "\n"
end

M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- The MAC of the bridge a VAP is enslaved to, or nil when it is not bridged.
function M.bridge_mac(ifname)
	if not valid_ifname(ifname) then return nil end
	local raw = M._read_file("/sys/class/net/" .. ifname .. "/master/address")
	local mac = raw and raw:match("^%s*(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
	return mac and mac:lower() or nil
end

local function drop_tables()
	M._exec("nft delete table " .. M.NFT_TABLE .. " 2>/dev/null")
	M._exec("nft delete table " .. M.NAT_TABLE .. " 2>/dev/null")
end

-- Rebuild the table for spec on these VAP netdevs (live: the portal's
-- state, see script; the bridge MACs are read here). Returns true when the
-- restrictions are in force, false when there is nothing to enforce, nothing
-- to enforce it on yet, or nft refused (the tables are deleted in every case
-- but the first). A rebuild replaces the table in one transaction, so it
-- never opens a gap.
---@param spec GuestSpec?
---@param ifnames string[]?
---@param live table?
function M.reconcile(spec, ifnames, live)
	if type(spec) ~= "table" or not spec.enabled then
		drop_tables()
		return false
	end
	local names = {}
	for _, n in ipairs(ifnames or {}) do
		if valid_ifname(n) then
			names[#names + 1] = n
		else
			io.stderr:write("guestguard: ignoring odd interface name " .. ("%q"):format(tostring(n)) .. "\n")
		end
	end
	if #names == 0 then
		drop_tables()
		io.stderr:write("guestguard: no guest VAP up yet (" .. table.concat(spec.ssids or {}, ", ")
			.. ") -- restrictions deferred\n")
		return false
	end
	local portal = spec.portal_url ~= nil
	local lv = {macs = live and live.macs,
		selfrun = live and live.selfrun, bridge = {}}
	local unbridged = 0
	if portal then
		for _, n in ipairs(names) do
			lv.bridge[n] = M.bridge_mac(n)
			if not lv.bridge[n] then unbridged = unbridged + 1 end
		end
	end
	local script, why = M.script(spec, names, lv)
	if not script then
		drop_tables()
		io.stderr:write("guestguard: not applied: " .. tostring(why) .. "\n")
		return false
	end
	local rc = M._exec("nft -f - <<'OPENUF_GUEST_EOF'\n" .. script .. "OPENUF_GUEST_EOF\n")
	local listed = exec_ok(rc) and M._read("nft list chain " .. M.NFT_TABLE .. " prerouting 2>/dev/null") or ""
	if not listed:find("jump guestin", 1, true) then
		io.stderr:write("openuf: guest network: nft refused the guest restrictions for "
			.. table.concat(names, " ") .. ". iifname/oifname and meta pkttype in the bridge "
			.. "family need kmod-nft-bridge (apk add kmod-nft-bridge); until then guests on "
			.. table.concat(spec.ssids or {}, ", ") .. " are NOT restricted.\n")
		drop_tables()
		return false
	end
	if not portal then
		M._exec("nft delete table " .. M.NAT_TABLE .. " 2>/dev/null")
		return true
	end
	if not exec_ok(M._exec("nft -f - <<'OPENUF_GUEST_EOF'\n" .. M.nat_script(M.PORTAL_PORT)
			.. "OPENUF_GUEST_EOF\n")) then
		io.stderr:write("openuf: guest portal: nft refused the NAT redirect (kmod-nft-nat?). "
			.. "Unauthorized guests stay blocked but are not shown the portal.\n")
	end
	if unbridged > 0 then
		io.stderr:write("openuf: guest portal: " .. unbridged .. " guest interface(s) not bridged; "
			.. "their unauthorized guests are blocked but not shown the portal\n")
	end
	return true
end

return M
