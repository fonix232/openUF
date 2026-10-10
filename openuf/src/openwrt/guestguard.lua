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

local function exec_ok(status)
	return status == true or status == 0
end

M.NFT_TABLE = "bridge openuf_guest"

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

-- The whole table as one nft script, or nil + reason.
function M.script(spec, ifnames)
	local T = M.NFT_TABLE
	local L = {"add table " .. T, "delete table " .. T, "add table " .. T}
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

-- Rebuild the table for spec on these VAP netdevs. Returns true when the
-- restrictions are in force, false when there is nothing to enforce, nothing
-- to enforce it on yet, or nft refused (the table is deleted in every case
-- but the first).
---@param spec GuestSpec?
---@param ifnames string[]?
function M.reconcile(spec, ifnames)
	M._exec("nft delete table " .. M.NFT_TABLE .. " 2>/dev/null")
	if type(spec) ~= "table" or not spec.enabled then return false end
	local names = {}
	for _, n in ipairs(ifnames or {}) do
		if valid_ifname(n) then
			names[#names + 1] = n
		else
			io.stderr:write("guestguard: ignoring odd interface name " .. ("%q"):format(tostring(n)) .. "\n")
		end
	end
	if #names == 0 then
		io.stderr:write("guestguard: no guest VAP up yet (" .. table.concat(spec.ssids or {}, ", ")
			.. ") -- restrictions deferred\n")
		return false
	end
	local script, why = M.script(spec, names)
	if not script then
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
		M._exec("nft delete table " .. M.NFT_TABLE .. " 2>/dev/null")
		return false
	end
	return true
end

return M
