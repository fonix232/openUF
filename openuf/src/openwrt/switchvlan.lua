--[[
	Per-port VLAN assignment, driven by the controller's `switch.*` push
	(parsed by unifi/ports.lua), for the per-VLAN-bridge backend: the layout
	openUF uses when it does not own the bridge (netmodel.lua's
	vlan_filtering backend does the same job inside its plan). Keyed by
	UniFi port_idx:
	    {enabled = true,
	     vlans = {[1] = {...}, [20] = {...}},
	     ports = {[2] = {pvid = 20, vlans = {[1]="exclude", [20]="untagged"}}}}

	On a DSA board every socket is its own netdev, so assigning a port to a
	VLAN is a bridge membership move: dsa_apply takes the socket out of br-lan
	and into that VLAN's bridge. `config bridge-vlan` is deliberately NOT used
	-- see PROTOCOL-VALIDATION.md for the netifd reasons. Verified on real
	hardware (a Xiaomi AX3000T against a UCG Ultra), including the
	one-address-table hazard that makes `learning '0'` mandatory and the nft
	tap that gives the reporting back.

	Reversibility: the sockets br-lan held are recorded (st.dsa_brlan_ports)
	before the first move, and restore() puts them back.
]]--

local M = {}

-- Injectable, matching netconfig.lua/shaper.lua's convention.
M._exec = function(cmd) return os.execute(cmd) end
-- Injectable stdout capture (nft listings). Same seam name and shape as
-- ucihelper's.
M._popen = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a")
	h:close()
	return s or ""
end
M._uci  = nil   -- set by callers/tests; falls back to require("uci")

local function get_uci()
	if M._uci then return M._uci end
	return require("uci")
end

-- Apply the controller's per-port VLANs. Returns whether anything changed.
function M.apply(sw, cfg, st, uplink_ifname)
	if not (sw and sw.enabled) or not cfg then return false end
	return M.dsa_apply(sw, cfg, st, uplink_ifname)
end

local OPENUF_BRDEV_PREFIX = "openuf_brdev"
local OPENUF_BRPORT_PREFIX = "openuf_brport"

-- Which netdev a UniFi port_idx is on a DSA board, or nil plus a reason.
--
-- The uplink socket is never reassignable (moving it strands the device),
-- and a board that cannot say which socket that is refuses every port rather
-- than taking a coin flip on it.
function M.dsa_ifname(cfg, port_idx, uplink_ifname)
	local net = cfg and cfg.net
	if not (net and net.ports) then return nil, "no dev.conf.net.ports" end
	for _, p in ipairs(net.ports) do
		if p.idx == port_idx then
			if not p.ifname then return nil, "no ifname for this port" end
			if p.uplink then return nil, "uplink" end
			if not uplink_ifname then return nil, "uplink port unknown" end
			if p.ifname == uplink_ifname then return nil, "uplink" end
			return p.ifname
		end
	end
	return nil, "no such port_idx"
end

-- Invert the controller's per-port matrix into {[vid] = {ifname, ...}}, the
-- sockets that should become untagged members of each VLAN's bridge.
--
-- Only "untagged" is honoured. A bridge gives a port exactly one untagged
-- home, which is precisely what a Native VLAN is, and that is the whole of
-- what an AP's downstream socket needs. "tagged" would mean carrying a VID
-- the attached device itself tags -- expressible as a <ifname>.<vid>
-- sub-device, but no UniFi AP port control emits it and it would ship
-- unverified, so it is refused out loud instead of half-done.
--
-- A port whose native VLAN is the management VLAN is deliberately absent from
-- the result: its home is br-lan, which is where it already is.
function M.dsa_members(sw, cfg, uplink_ifname)
	local out = {}
	if not (sw and sw.enabled and sw.ports) then return out end
	local mgmt = (cfg and cfg.net and cfg.net.lan_vlanid) or 1
	local idxs = {}
	for idx in pairs(sw.ports) do idxs[#idxs + 1] = idx end
	table.sort(idxs)
	for _, port_idx in ipairs(idxs) do
		local p = sw.ports[port_idx]
		local ifname, why = M.dsa_ifname(cfg, port_idx, uplink_ifname)
		if not ifname then
			io.stderr:write(("switchvlan: skipping port_idx %s (%s)\n")
				:format(tostring(port_idx), why or "unmappable"))
		else
			local native, tagged = nil, {}
			for vid, mode in pairs(p.vlans or {}) do
				local n = tonumber(vid)
				if n and mode == "untagged" and n ~= mgmt then
					native = n
				elseif n and mode == "tagged" and n ~= mgmt then
					tagged[#tagged + 1] = n
				end
			end
			if native then
				out[native] = out[native] or {}
				out[native][#out[native] + 1] = ifname
			elseif #tagged > 0 then
				-- Only worth saying when tagged membership is ALL the port was
				-- given. The controller's default Tagged VLAN Management is
				-- "Allow All", which marks every VLAN the port is not native
				-- to as tagged -- so warning per tagged VID logged a line per
				-- VLAN per inform about a default nobody chose. A port with a
				-- native VLAN got what it asked for; only one with nothing but
				-- tagged VLANs is actually being refused something.
				table.sort(tagged)
				io.stderr:write(("switchvlan: port %s is tagged-only (VLAN %s) "
					.. "-- not applied. DSA per-port VLAN implements the "
					.. "native/untagged assignment; set a Native VLAN on the "
					.. "port instead\n"):format(ifname, table.concat(tagged, ", ")))
			end
		end
	end
	for _, list in pairs(out) do table.sort(list) end
	return out
end

-- The bridge device section a VLAN's L2 lives in, matching the names
-- ucihelper.ensure_vlan_network writes.
local function brdev_section(vid) return OPENUF_BRDEV_PREFIX .. tostring(vid) end

-- The `config device` section carrying one moved SOCKET's bridge-port options.
--
-- Deliberately a different shape from ucihelper's `openuf_brport<vid>`, which
-- names the tagged UPLINK sub-device: that one is per-VLAN and there is exactly
-- one of it, this one is per-socket and there may be several in the same VLAN.
-- The `_` keeps the two apart under ucihelper's `^openuf_brport(%d+)$` sweep.
--
-- UCI section names accept only [A-Za-z0-9_], and libuci discards a section
-- with an invalid name while reporting success on both set() and commit() --
-- silently, which is how an SSID with a hyphen once provisioned nothing at all.
-- Socket netdevs here are `lan2`/`wan`-shaped, but sanitise rather than trust.
local function brport_section(vid, ifname)
	return OPENUF_BRPORT_PREFIX .. tostring(vid) .. "_"
		.. tostring(ifname):gsub("[^%w_]", "_")
end

-- Read a UCI list option that may come back as a bare string.
local function as_list(v)
	if type(v) == "table" then return v end
	if type(v) == "string" and v ~= "" then return {v} end
	return {}
end

-- The `config device` section that defines br-lan, and its port list. Found by
-- the bridge's NAME rather than by a section name, because it is the board's
-- own anonymous section (network.@device[0]) and openUF must not assume where
-- in the file it sits.
local function find_lan_bridge(cursor, br_name)
	local found
	cursor:foreach("network", "device", function(s)
		if s.name == br_name and s.type == "bridge" then found = s[".name"] end
	end)
	return found
end

-- Apply a parsed switch table on a DSA board.
--
-- Moves each assigned socket out of br-lan and into its VLAN's bridge, and
-- reconciles both directions: a socket the controller no longer assigns comes
-- back to br-lan, and a bridge left with no sockets keeps only its uplink.
--
-- st.dsa_brlan_ports is the reversibility ledger -- br-lan's port list exactly
-- as the board shipped it, snapshotted once before the first mutation. It is
-- the only record of what to put back, so it is written before anything else
-- changes and cleared only by dsa_restore.
--
-- Returns true when UCI changed and a reload was issued.
function M.dsa_apply(sw, cfg, st, uplink_ifname)
	local uci = get_uci()
	local cursor = uci.cursor()

	local lan_name = "br-" .. ((cfg and cfg.net and cfg.net.lan_name) or "lan")
	local lan_sec  = find_lan_bridge(cursor, lan_name)
	if not lan_sec then
		io.stderr:write(("switchvlan: no `config device` for %s -- per-port VLAN "
			.. "not applied (nothing to move sockets out of)\n"):format(lan_name))
		return false
	end

	local members = M.dsa_members(sw, cfg, uplink_ifname)

	-- Every socket openUF is entitled to move: the board's ports, minus the
	-- uplink and anything unmappable. Anything outside this set is the user's
	-- and is never added to or removed from br-lan.
	local managed = {}
	for _, p in ipairs((cfg and cfg.net and cfg.net.ports) or {}) do
		if M.dsa_ifname(cfg, p.idx, uplink_ifname) then managed[p.ifname] = true end
	end

	local assigned = {}   -- ifname -> vid
	for vid, list in pairs(members) do
		for _, ifname in ipairs(list) do assigned[ifname] = vid end
	end

	local changed = false

	-- br-lan: it keeps every port that is not assigned elsewhere. Ports
	-- outside `managed` pass through untouched whatever the push says.
	local lan_ports = as_list(cursor:get("network", lan_sec, "ports"))
	local keep, dropped = {}, false
	for _, ifname in ipairs(lan_ports) do
		if assigned[ifname] and managed[ifname] then
			dropped = true
		else
			keep[#keep + 1] = ifname
		end
	end
	-- ...and takes back any managed socket this push no longer assigns.
	for _, p in ipairs((cfg and cfg.net and cfg.net.ports) or {}) do
		local ifname = p.ifname
		if ifname and managed[ifname] and not assigned[ifname] then
			local present = false
			for _, k in ipairs(keep) do if k == ifname then present = true end end
			if not present then keep[#keep + 1] = ifname; dropped = true end
		end
	end
	if dropped or #keep ~= #lan_ports then
		-- Ledger first, always, and only ever the pristine list: taking the
		-- snapshot after a mutation would file openUF's own output as the
		-- board's original and make restore() a no-op that looks like a
		-- success.
		if st and st.dsa_brlan_ports == nil then st.dsa_brlan_ports = lan_ports end
		cursor:set("network", lan_sec, "ports", keep)
		changed = true
	end

	-- Each VLAN bridge: openUF's socket members, leaving the tagged uplink
	-- sub-device (ucihelper's) and anything else alone.
	local vids = {}
	cursor:foreach("network", "device", function(s)
		local vid = s[".name"] and s[".name"]:match("^" .. OPENUF_BRDEV_PREFIX .. "(%d+)$")
		if vid then vids[tonumber(vid)] = true end
	end)
	for vid in pairs(members) do vids[vid] = true end

	for vid in pairs(vids) do
		local sec = brdev_section(vid)
		if cursor:get("network", sec, "name") then
			local want = {}
			for _, ifname in ipairs(members[vid] or {}) do want[ifname] = true end
			local cur, out, diff = as_list(cursor:get("network", sec, "ports")), {}, false
			for _, ifname in ipairs(cur) do
				-- Drop only sockets openUF manages and this push dropped;
				-- the uplink sub-device and any hand-added member survive.
				if managed[ifname] and not want[ifname] then diff = true
				else out[#out + 1] = ifname; want[ifname] = nil end
			end
			for _, ifname in ipairs(members[vid] or {}) do
				if want[ifname] then out[#out + 1] = ifname; diff = true end
			end
			if diff then
				cursor:set("network", sec, "ports", out)
				changed = true
			end
		end
	end

	-- MAC learning OFF on every socket openUF moves into a VLAN bridge.
	--
	-- Same hardware fact as the tagged uplink's override in
	-- ucihelper.ensure_vlan_network, reached from the other side. On a DSA
	-- board br-openuf<vid> is a SOFTWARE bridge: `wan.10` is an 8021q device
	-- the switch knows nothing about, so the VLAN bridge exists only above the
	-- CPU port. The moved socket, though, is still a real port on the same
	-- ASIC as the uplink, and that ASIC has ONE address table. With learning
	-- on it files the attached device against `lan2`:
	--     00:00:5e:00:53:03 dev lan2 self
	-- A reply arriving VLAN-tagged on the physical uplink port then HITS that
	-- entry, and `lan2` is not in the uplink's bridge port matrix any more --
	-- so the switch resolves the frame in hardware and drops it instead of
	-- punting it to the CPU, where the software bridge would have delivered
	-- it. With no entry the same frame is unknown unicast, floods to the CPU,
	-- and arrives.
	--
	-- Measured on an AX3000T (2026-09-12) with an IKEA Trådfri hub on port 2,
	-- captured at all three points at once. Learning ON: four DHCP DISCOVERs
	-- leave `lan2`, reach `wan.10`, leave the uplink correctly tagged, and
	-- NOTHING comes back -- not even on the physical port, because a
	-- hardware-dropped frame never reaches the CPU to be captured. Learning
	-- OFF: DISCOVER -> OFFER -> REQUEST -> ACK in 2 ms. Outbound is perfect in
	-- both, which is what makes this so hard to see: every counter and every
	-- log line says the port move worked.
	--
	-- Cost: the socket's hosts stop appearing in `bridge fdb show dev <sock>`.
	-- That was priced here as "an attribution row" and it is not -- the bridge
	-- FDB is the ONLY wired-host source on a DSA board, so the port reports no
	-- clients at all and the controller credits them to the gateway. Paid for
	-- by M.reconcile_mac_taps below, which observes the socket where the FDB
	-- no longer can. Only assigned sockets need it.
	--
	-- NOTE a live reassignment still converges slowly: an entry learned while
	-- the socket was in br-lan is already in the ASIC, cannot be deleted
	-- (`bridge fdb del ... self` answers ENOENT, `bridge fdb flush` EOPNOTSUPP)
	-- and does not clear on a link bounce. It ages out on its own -- measured
	-- at ~140 s -- and the port works from that moment. Nothing to do but wait.
	for vid in pairs(vids) do
		for _, p in ipairs((cfg and cfg.net and cfg.net.ports) or {}) do
			local ifname = p.ifname
			if ifname and managed[ifname] then
				local sec = brport_section(vid, ifname)
				if assigned[ifname] == vid then
					if cursor:get("network", sec, "name") ~= ifname
						or tostring(cursor:get("network", sec, "learning") or "") ~= "0" then
						cursor:set("network", sec, "device")
						cursor:set("network", sec, "name", ifname)
						cursor:set("network", sec, "learning", "0")
						changed = true
					end
				elseif cursor:get("network", sec, "name") then
					-- Going home to br-lan, or to a different VLAN: the
					-- override must not outlive the assignment that needed
					-- it, or the socket returns with learning still off and
					-- silently stops reporting its hosts.
					cursor:delete("network", sec)
					changed = true
				end
			end
		end
	end

	if not changed then return false end
	cursor:commit("network")
	M._exec("/etc/init.d/network reload 2>/dev/null")
	-- After the commit, so tapped_sockets reads what was just written.
	M.reconcile_mac_taps(cursor)
	return true
end

-- === Getting the hosts back that `learning '0'` took away ==================
--
-- dsa_apply has to turn MAC learning off on every socket it moves into a VLAN
-- bridge, or the ASIC hardware-drops the replies (the measurement is in the
-- comment above). The bill for that arrives in the inform payload: the socket's
-- hosts vanish from `bridge fdb`, port_table publishes an empty mac_table, and
-- the controller credits the client to whoever else saw the MAC -- the gateway,
-- which sees everything. Seen in production: a wired IoT device on an assigned
-- socket listed under the gateway at the gateway's link speed.
--
-- There is no way to keep the software half of learning and drop the hardware
-- half. One BR_LEARNING flag per bridge port, mirrored into the driver by DSA;
-- the ASIC entry cannot be deleted (ENOENT) or flushed (EOPNOTSUPP) and is
-- re-learned on the client's next frame anyway. The switch-level fix is to make
-- the switch VLAN-aware (`vlan_filtering` + `config bridge-vlan`), which would
-- restore learning AND hardware offload -- PROTOCOL-VALIDATION.md records why
-- that is not what this does.
--
-- So openUF observes the socket somewhere the FDB is not: a bridge-family
-- prerouting rule that files each frame's source address into a dynamic set.
-- The socket is in a bridge whose other member is a software device, so it
-- cannot be hardware-offloaded and every one of its frames reaches the CPU --
-- which is the same fact that makes this tap see everything the FDB used to.
--
-- Two sets, one rule each, covering every tapped socket at once; a flat element
-- list beats one set per socket to parse, and sysinfo reads both in a single
-- `nft list table`. The 5m timeouts mirror the bridge's own FDB ageing so an
-- unplugged client expires the way it used to.
--
--   portmacs  ifname . ether_addr                WHO is behind the socket.
--   portips   ifname . ether_addr . ipv4_addr    and WHICH ADDRESS they have.
--
-- portips is not a nicety. The controller classifies a wired client into a
-- network by the IP the reporting device puts in `mac_table[].ip`, NOT by the
-- port's native VLAN -- verified against a live UCG Ultra, where every wired
-- client carrying a reported IP landed in that IP's subnet and the one without
-- fell back to the reporting AP's own network. An assigned socket is on a VLAN
-- the AP holds no address on, so /proc/net/arp can never answer for it and the
-- IP would be absent: the port would be right and the network label wrong.
--
-- Sources are ARP and IPv4 alike, because either one identifies the sender and
-- a device that only ever ARPs still has to be reported. 0.0.0.0 is excluded on
-- both: a DHCP DISCOVER and an ARP probe both carry it, and neither is an
-- address the host actually holds.
local NFT_LEARN_TABLE = "bridge openuf_learn"
local NFT_LEARN_CHAIN = "learn"
local NFT_LEARN_SET   = "portmacs"
local NFT_LEARN_IPSET = "portips"
local NFT_LEARN_TTL   = "5m"

-- Which sockets currently have learning off, read back from the `config device`
-- sections dsa_apply writes rather than from a second record of openUF's own.
-- Those sections ARE the record: they exist exactly while the override does, so
-- this is safe to call at startup with no state to consult.
function M.tapped_sockets(cursor)
	local out = {}
	cursor:foreach("network", "device", function(s)
		local sec = s[".name"]
		if sec and sec:match("^" .. OPENUF_BRPORT_PREFIX .. "%d+_")
			and tostring(s.learning or "") == "0"
			and type(s.name) == "string" and s.name ~= "" then
			out[#out + 1] = s.name
		end
	end)
	table.sort(out)
	return out
end

-- Rebuild the tap to exactly match the sockets that have learning off.
--
-- Same delete-and-recreate shape as firewall.reconcile: idempotent, and the
-- teardown path is this function with nothing to tap (the table goes and
-- nothing replaces it). Called after every dsa_apply/dsa_restore and once at
-- startup, because nftables state does not survive a reboot and a tap that is
-- not reinstalled fails silently -- as an empty mac_table, which is precisely
-- the bug it exists to fix.
--
-- Returns true when a tap is now installed.
function M.reconcile_mac_taps(cursor)
	local c = cursor or get_uci().cursor()
	local sockets = M.tapped_sockets(c)

	-- Leave a tap that already covers exactly these sockets alone. Everything
	-- the sets hold was learned from traffic that has already happened, so
	-- rebuilding empties them and the socket reports NO clients until each host
	-- next speaks -- and a host reported before its address is known is a host
	-- the controller files under the wrong network. openUF restarts far more
	-- often than an assignment changes, and the startup reconcile exists for
	-- the reboot case, where there is nothing to preserve anyway.
	local live = tostring(M._popen("nft list chain " .. NFT_LEARN_TABLE
		.. " " .. NFT_LEARN_CHAIN) or "")
	if #sockets > 0 and live:find("@" .. NFT_LEARN_SET, 1, true)
		and live:find("@" .. NFT_LEARN_IPSET, 1, true) then
		local have, n = {}, 0
		for line in live:gmatch("[^\n]+") do
			-- Each rule reads `iifname <selector> ... update @<set> {...}`, and
			-- nft prints the selector as a bare "lan2" for one socket or as
			-- { "lan2", "lan3" } for several. Taking the text before the first
			-- `update` covers both without caring which.
			local sel = line:match("^%s*iifname%s+(.-)%s+update")
			if sel then
				for ifn in sel:gmatch('"([^"]+)"') do
					if not have[ifn] then have[ifn] = true; n = n + 1 end
				end
			end
		end
		if n == #sockets then
			local same = true
			for _, ifn in ipairs(sockets) do
				if not have[ifn] then same = false break end
			end
			if same then return true end
		end
	end

	M._exec("nft delete table " .. NFT_LEARN_TABLE .. " 2>/dev/null")
	if #sockets == 0 then return false end

	-- Socket names reach here from board.json by way of UCI. They are
	-- `lan2`/`wan`-shaped and always have been, but they are interpolated into
	-- a shell command, so sanitise rather than trust -- the same discipline
	-- brport_section applies for libuci's sake.
	local quoted = {}
	for _, ifname in ipairs(sockets) do
		quoted[#quoted + 1] = '"' .. ifname:gsub("[^%w._-]", "_") .. '"'
	end

	local socket_set = "iifname { " .. table.concat(quoted, ", ") .. " }"

	M._exec("nft add table " .. NFT_LEARN_TABLE)
	M._exec("nft add set " .. NFT_LEARN_TABLE .. " " .. NFT_LEARN_SET
		.. " '{ type ifname . ether_addr; flags dynamic,timeout; timeout "
		.. NFT_LEARN_TTL .. "; }'")
	M._exec("nft add set " .. NFT_LEARN_TABLE .. " " .. NFT_LEARN_IPSET
		.. " '{ type ifname . ether_addr . ipv4_addr; flags dynamic,timeout;"
		.. " timeout " .. NFT_LEARN_TTL .. "; }'")
	-- priority -300 (dstnat) puts this ahead of anything else openUF hooks in
	-- the bridge family; policy accept and rules with no verdict mean it
	-- observes and never decides.
	M._exec("nft add chain " .. NFT_LEARN_TABLE .. " " .. NFT_LEARN_CHAIN
		.. " '{ type filter hook prerouting priority -300; policy accept; }'")
	M._exec("nft add rule " .. NFT_LEARN_TABLE .. " " .. NFT_LEARN_CHAIN
		.. " '" .. socket_set
		.. " update @" .. NFT_LEARN_SET .. " { iifname . ether saddr }'")
	M._exec("nft add rule " .. NFT_LEARN_TABLE .. " " .. NFT_LEARN_CHAIN
		.. " '" .. socket_set .. " arp saddr ip != 0.0.0.0"
		.. " update @" .. NFT_LEARN_IPSET
		.. " { iifname . ether saddr . arp saddr ip }'")
	M._exec("nft add rule " .. NFT_LEARN_TABLE .. " " .. NFT_LEARN_CHAIN
		.. " '" .. socket_set .. " ip saddr != 0.0.0.0"
		.. " update @" .. NFT_LEARN_IPSET
		.. " { iifname . ether saddr . ip saddr }'")
	return true
end

-- Undo dsa_apply: put br-lan's original port list back and drop openUF's
-- socket members from the VLAN bridges. The bridges themselves belong to
-- ucihelper (a tagged SSID may still need them) and are left standing.
function M.dsa_restore(st, cfg)
	if not (st and st.dsa_brlan_ports) then return false end
	local uci = get_uci()
	local cursor = uci.cursor()
	local orig = as_list(st.dsa_brlan_ports)

	local was = {}
	for _, ifname in ipairs(orig) do was[ifname] = true end

	local changed = false
	cursor:foreach("network", "device", function(s)
		local vid = s[".name"] and s[".name"]:match("^" .. OPENUF_BRDEV_PREFIX .. "(%d+)$")
		if not vid then return end
		local out, diff = {}, false
		for _, ifname in ipairs(as_list(s.ports)) do
			-- A socket that br-lan originally owned goes home; the tagged
			-- uplink sub-device (which br-lan never had) stays.
			if was[ifname] then diff = true else out[#out + 1] = ifname end
		end
		if diff then cursor:set("network", s[".name"], "ports", out); changed = true end
	end)

	-- The per-socket learning overrides go with the assignment that needed
	-- them. Collected first and deleted after the walk: deleting inside
	-- cursor:foreach mutates the list being iterated.
	local doomed = {}
	cursor:foreach("network", "device", function(s)
		local name = s[".name"]
		if name and name:match("^" .. OPENUF_BRPORT_PREFIX .. "%d+_") then
			doomed[#doomed + 1] = name
		end
	end)
	for _, name in ipairs(doomed) do
		cursor:delete("network", name)
		changed = true
	end

	-- Derived, not hardcoded: dsa_apply names this bridge from dev.conf.net,
	-- and a restore that looked for a different one would silently put nothing
	-- back while reporting success. Falls back to "lan" only when cfg is
	-- absent, which is what every board here uses anyway.
	local lan_name = "br-" .. ((cfg and cfg.net and cfg.net.lan_name) or "lan")
	local lan_sec  = find_lan_bridge(cursor, lan_name)
	if lan_sec then
		cursor:set("network", lan_sec, "ports", orig)
		changed = true
	end
	st.dsa_brlan_ports = nil

	if changed then
		cursor:commit("network")
		M._exec("/etc/init.d/network reload 2>/dev/null")
		-- The overrides are gone, so the tap has nothing left to watch and
		-- this tears the table down.
		M.reconcile_mac_taps(cursor)
	end
	return changed
end

-- Undo what apply() did: back to the sockets br-lan held before.
function M.restore(st, cfg)
	if st and st.dsa_brlan_ports then return M.dsa_restore(st, cfg) end
	return false
end

return M
