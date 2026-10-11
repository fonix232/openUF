--[[
	Ubiquiti L2 discovery broadcaster (UDP port 10001).

	Sends a TLV-encoded announce packet to 255.255.255.255 every 10 seconds.
	This makes the device visible in UniFi Discover / UBNT-Discovery before
	and after adoption.

	Can be loaded as a module (returns M) or run as a standalone script.
	When run as a script, call M.run(cfg) at the bottom of this file.
]]--

local bit = require("bit")

local M = {}

-- Discovery destination address and port
M.BROADCAST_ADDR = "255.255.255.255"
M.PORT = 10001

-- Appended to the firmware version strings in the discovery packet. One
-- definition: it used to be typed out twice, in build_packet and in the entry
-- point below, and the two could drift.
M.VERSION_SUFFIX = "-openUF-0.2"

-- TLV type codes for the Ubiquiti discovery protocol
local PKT = {
	HW_ADDR        = 0x01,
	IP_ADDR        = 0x02,
	FWVER_VERBOSE  = 0x03,
	UPTIME         = 0x0a,
	HOSTNAME       = 0x0b,
	PLATFORM       = 0x0c,
	INC_COUNTER    = 0x12,
	HW_ADDR2       = 0x13,
	PLATFORM2      = 0x15,
	FWVER_SHORT    = 0x16,
	FWVER_FACTORY  = 0x1b,
}

-- TLV writer: a record is {type, 0x00, len, value bytes...} built as a byte
-- table, then appended to the packet.
local tlv = {}

function tlv.init(kind)
	return {kind, 0x00, 0x00}
end

-- Append the elements of src to dst.
function tlv.cattbl(dst, src)
	for _, v in ipairs(src) do dst[#dst + 1] = v end
end

-- Append each byte of string src to dst.
function tlv.catstr(dst, src)
	for i = 1, #src do dst[#dst + 1] = src:byte(i) end
end

-- Fill in rec's length byte and append the whole record to dst.
function tlv.finish(rec, dst)
	rec[3] = #rec - 3
	tlv.cattbl(dst, rec)
end

-- A 32-bit value as four bytes, most significant first.
function tlv.gen4(n)
	return {
		bit.rshift(         n, 24),
		bit.band(bit.rshift(n, 16), 0xff),
		bit.band(bit.rshift(n,  8), 0xff),
		bit.band(           n,      0xff),
	}
end
M._tlv = tlv

-- Build TLV blob for types 0x17–0x1a.
-- 0x17 = IsDefault (1 = unadopted, 0 = adopted) — must reflect actual adoption state.
-- cfg.adopted controls the byte; defaults to unadopted (1) when not set.
local function make_blob_17_1a(adopted)
	return {
		0x17, 0x00, 0x01, adopted and 0x00 or 0x01,
		0x18, 0x00, 0x01, 0x00,
		0x19, 0x00, 0x01, 0x01,
		0x1a, 0x00, 0x01, 0x00,
	}
end

-- Build a complete announce packet as a Lua binary string.
--
-- cfg fields:
--   mac          {byte, ...}  6-element table of MAC bytes
--   ip           {byte, ...}  4-element table of IP bytes
--   hostname     string
--   platform     string       e.g. "U6IW"
--   fw_pre       string       e.g. "U6IW."
--   fw_ver       string       e.g. "6.6.55"
--   fw_buildtime string       e.g. "230801.1200"
--   fw_factoryver string      e.g. "6.5.28"
--   version_suffix string     appended after fw_ver in verbose/short strings
--   uptime       number       seconds since boot
--   counter      number       monotonically increasing send counter
--
-- reply: true builds the answer to a v1 probe instead of the periodic v2
-- announce. Only the header differs ({0x01, 0x00} for {0x02, 0x06}); a UCG
-- Fiber's v1 reply carries the same TLV numbering.
function M.build_packet(cfg, reply)
	-- Outer packet: 2-byte header + 2-byte length field (filled in at end)
	local packet = reply and {0x01, 0x00, 0x00, 0x00} or {0x02, 0x06, 0x00, 0x00}
	local w

	-- 0x02: IP address (MAC + IP concatenated)
	w = tlv.init(PKT.IP_ADDR)
	tlv.cattbl(w, cfg.mac)
	tlv.cattbl(w, cfg.ip)
	tlv.finish(w, packet)

	-- 0x01: Hardware address
	w = tlv.init(PKT.HW_ADDR)
	tlv.cattbl(w, cfg.mac)
	tlv.finish(w, packet)

	-- 0x0a: Uptime (32-bit big-endian seconds)
	w = tlv.init(PKT.UPTIME)
	tlv.cattbl(w, tlv.gen4(cfg.uptime or 0))
	tlv.finish(w, packet)

	-- 0x0b: Hostname
	w = tlv.init(PKT.HOSTNAME)
	tlv.catstr(w, cfg.hostname or "openUF")
	tlv.finish(w, packet)

	-- 0x0c: Platform string
	w = tlv.init(PKT.PLATFORM)
	tlv.catstr(w, cfg.platform)
	tlv.finish(w, packet)

	-- 0x03: Firmware version verbose
	local suffix = cfg.version_suffix or M.VERSION_SUFFIX
	w = tlv.init(PKT.FWVER_VERBOSE)
	tlv.catstr(w, cfg.fw_pre)
	tlv.catstr(w, cfg.fw_ver)
	tlv.catstr(w, suffix .. ".")
	tlv.catstr(w, cfg.fw_buildtime)
	tlv.finish(w, packet)

	-- 0x16: Firmware version short
	w = tlv.init(PKT.FWVER_SHORT)
	tlv.catstr(w, cfg.fw_ver)
	tlv.catstr(w, suffix)
	tlv.finish(w, packet)

	-- 0x15: Platform2 (same as platform)
	w = tlv.init(PKT.PLATFORM2)
	tlv.catstr(w, cfg.platform)
	tlv.finish(w, packet)

	-- Opaque blob 0x17–0x1a (IsDefault reflects adoption state)
	tlv.cattbl(packet, make_blob_17_1a(cfg.adopted))

	-- 0x13: Hardware address 2
	w = tlv.init(PKT.HW_ADDR2)
	tlv.cattbl(w, cfg.mac)
	tlv.finish(w, packet)

	-- 0x12: Incrementing counter (32-bit big-endian)
	w = tlv.init(PKT.INC_COUNTER)
	tlv.cattbl(w, tlv.gen4(cfg.counter or 0))
	tlv.finish(w, packet)

	-- 0x1b: Factory firmware version
	w = tlv.init(PKT.FWVER_FACTORY)
	tlv.catstr(w, cfg.fw_factoryver)
	tlv.finish(w, packet)

	-- Write full 16-bit packet length (big-endian) into bytes 3–4.
	-- BUG IN ORIGINAL: packet[4] = (len & 0xff) only wrote the low byte.
	-- FIX: write both bytes so packets >= 256 bytes are described correctly.
	local plen = #packet - 4
	packet[3] = bit.band(bit.rshift(plen, 8), 0xff)	-- high byte
	packet[4] = bit.band(plen, 0xff)					-- low byte

	-- Serialise byte table to binary string
	local out = {}
	for _, byte in ipairs(packet) do
		out[#out + 1] = string.char(byte)
	end
	return table.concat(out)
end

-- Read MAC address from sysfs for the given interface.
-- Returns a 6-element byte table or nil on failure.
-- "aa:bb:cc:dd:ee:ff" -> {0xaa, ...}, or nil.
function M.parse_mac(s)
	if type(s) ~= "string" then return nil end
	local out = {}
	for h in s:gmatch("%x%x") do out[#out + 1] = tonumber(h, 16) end
	if #out ~= 6 or not s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return nil end
	return out
end

function M.get_mac(iface)
	iface = iface or "eth0"
	local f = io.open("/sys/class/net/" .. iface .. "/address", "r")
	if not f then return nil end
	local line = f:read("*l"); f:close()
	if not line then return nil end
	local mac = {}
	for byte in line:gmatch("[0-9a-fA-F]+") do
		mac[#mac + 1] = tonumber(byte, 16)
	end
	return #mac == 6 and mac or nil
end

-- Primary IPv4 of one netdev, as a 4-element byte table, or nil if it has none.
local function ipv4_of(iface)
	local out = M._popen("ip -4 addr show dev " .. iface)
	if type(out) ~= "string" then return nil end
	local a, b, c, d = out:match("inet (%d+)%.(%d+)%.(%d+)%.(%d+)")
	if not a then return nil end
	return {tonumber(a), tonumber(b), tonumber(c), tonumber(d)}
end

-- Read primary IPv4 address for the given interface.
-- Returns a 4-element byte table or nil on failure.
--
-- The configured interface (dev.conf.net.lan_cpueth) names the LAN *port* --
-- which is what VLAN provisioning and the port_table need -- but on any AP
-- whose LAN port is enslaved to a bridge (the normal OpenWrt layout: eth1 in
-- br-lan) that port carries no address at all: the L3 address lives on the
-- bridge. Asking only the port yields nil, and the callers' fallbacks are
-- silent and wrong -- announce.run() broadcasts 192.168.1.1 and inform.lua's
-- build_json reports ip "0.0.0.0", which a controller cannot adopt.
-- So: try the port, then the bridge it is a member of, before giving up.
-- The bridge a netdev is enslaved to, or nil. /sys/class/net/<if>/master
-- symlinks to the enslaving device (e.g. "../../../../../virtual/net/br-lan").
local function master_of(iface)
	local m = M._popen("readlink /sys/class/net/" .. iface .. "/master")
	m = type(m) == "string" and m:match("([^/%s]+)%s*$") or nil
	if m and m ~= iface and m ~= "" then return m end
	return nil
end

local function walk(iface)
	local ip = ipv4_of(iface)
	if ip then return ip, iface end

	-- One hop: the port is a bridge member and the address is on the bridge.
	local master = master_of(iface)
	if master then
		ip = ipv4_of(master)
		if ip then return ip, master end
		-- ...or on one of the bridge's own VLAN sub-devices: a vlan-filtering
		-- bridge carries management on `<bridge>.<vid>` (br-lan.1, switch.1),
		-- never on the bridge itself. Without this hop every such board --
		-- netmodel's layout included -- reported 0.0.0.0.
		local kids = M._popen("ls -d /sys/class/net/" .. master .. ".* 2>/dev/null")
		for line in tostring(kids or ""):gmatch("[^\r\n]+") do
			local child = line:match("([^/%s]+)%s*$")
			if child and child ~= master then
				ip = ipv4_of(child)
				if ip then return ip, child end
			end
		end
	end

	-- Two hops: the port is a VLAN TRUNK, and it is the tagged sub-interface
	-- -- not the trunk itself -- that is enslaved to the bridge. That is the
	-- normal swconfig layout (eth0 -> eth0.1 -> br-lan), and lan_cpueth must
	-- name the trunk there so a pushed VLAN 20 becomes eth0.20 rather than
	-- eth0.1.20. Confirmed on a real TL-WDR3500, where naming the trunk made
	-- every inform report ip 0.0.0.0 until this hop existed.
	local children = M._popen("ls -d /sys/class/net/" .. iface .. ".* 2>/dev/null")
	for line in tostring(children or ""):gmatch("[^\r\n]+") do
		local child = line:match("([^/%s]+)%s*$")
		if child and child ~= iface then
			ip = ipv4_of(child)
			if ip then return ip, child end
			local cm = master_of(child)
			if cm then
				ip = ipv4_of(cm)
				if ip then return ip, cm end
			end
		end
	end
	return nil
end

-- Which netdev held the address, remembered for IP_HOLDER_TTL seconds so a
-- tick asks only that one (one `ip`) instead of walking port -> bridge ->
-- VLAN children (upstream d56f8aa). When it has no address any more, the
-- chain is walked again in the same call. Trade: a nearer netdev that gains
-- an address while the remembered one keeps its own is reported up to
-- IP_HOLDER_TTL late; a renewal on the same netdev is read live every tick.
M.IP_HOLDER_TTL = 300
M._now = os.time
M._ip_holder = nil   -- {port = iface, dev = netdev, until = s}
function M.get_ip(iface)
	iface = iface or "eth0"
	local h, now = M._ip_holder, M._now()
	if h and h.port == iface and now < h["until"] and now >= h["until"] - M.IP_HOLDER_TTL then
		local ip = ipv4_of(h.dev)
		if ip then return ip end
	end
	local ip, dev = walk(iface)
	M._ip_holder = ip and {port = iface, dev = dev, ["until"] = now + M.IP_HOLDER_TTL} or nil
	return ip
end

-- Injectable: command execution that captures stdout (same seam convention
-- as ucihelper._popen), so tests can feed get_hostname() without a shell.
M._popen = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a")
	h:close()
	return s or ""
end

-- Injectable: file reader, same seam convention as ucihelper._read_file.
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- The device's real system hostname, or nil when unavailable/empty.
-- Used by the L2-discovery entry point below and by inform.lua's
-- _populate_net_info (the inform payload's top-level "hostname" field --
-- without it every openUF device shows up in the controller as "openUF").
--
-- /proc/sys/kernel/hostname is read FIRST, and the `hostname` command is only
-- a fallback: OpenWrt builds do not necessarily ship a `hostname` applet at
-- all (confirmed on a real Archer C5 running 25.12.5 -- busybox there has no
-- such applet), so the command-only version silently reported every such
-- device to the controller as "openUF" instead of its actual hostname. The
-- proc file is always present on Linux and needs no process spawn.
function M.get_hostname()
	local function clean(s)
		if type(s) ~= "string" then return nil end
		local line = s:match("([^\r\n]+)")           -- first line
		line = line and line:match("^%s*(.-)%s*$")   -- trimmed
		if not line or line == "" then return nil end
		return line
	end
	return clean(M._read_file("/proc/sys/kernel/hostname"))
		or clean(M._popen("hostname"))
end

-- Lazily loaded state module (injectable), for the adopted flag below; nil
-- when state.lua cannot be loaded.
M._state = nil
local function state_module()
	if M._state then return M._state end
	local ok, mod = pcall(require, "state")
	if ok and type(mod) == "table" then
		M._state = mod
		return mod
	end
	return nil
end

-- Is the device adopted, per state.json? nil when that cannot be answered (no
-- state module, unreadable file), which callers treat as "leave the flag as it
-- is" -- and it starts out false, the value the packet always carried.
function M.adopted(state_file)
	-- `sm`, not `st`: the state MODULE, whose _state_file seam is being set
	-- here. A local called `st` would read as the state TABLE and trip
	-- test_state's "every field any module writes is registered" scan.
	local sm = state_module()
	if not sm then return nil end
	if state_file then sm._state_file = state_file end
	local ok, s = pcall(sm.load)
	if ok and type(s) == "table" then return s.adopted == true end
	return nil
end

-- The clients this AP denies for Lock to Access Point (st.lock2ap), which the
-- sibling exchange announces; {} when there are none or no state is readable.
function M.own_locks(state_file)
	local sm = state_module()
	if not sm then return {} end
	if state_file then sm._state_file = state_file end
	local ok, s = pcall(sm.load)
	return (ok and type(s) == "table" and type(s.lock2ap) == "table") and s.lock2ap or {}
end

-- The sibling packets to broadcast this tick: always the v3 packet every
-- openUF build understands; with the site's exchange key also the
-- authenticated v5 one, which alone carries the lock list
-- (openwrt/siblings.lua). Logs once when the lock list does not fit.
M._sib_logged = {}
local function log_once(key, msg)
	if M._sib_logged[key] then return end
	M._sib_logged[key] = true
	io.stderr:write("announce: " .. msg .. "\n")
end

function M.sibling_packets(sib, cfg, own, locks, key, now)
	local v3, v5, cut = sib.build(cfg.identity_mac, own,
		{model = cfg.model, model_display = cfg.model_display}, locks, key, now)
	if cut then
		log_once("locks", ("sibling exchange: %d Lock to Access Point clients, only the "
			.. "first %d are announced"):format(#locks, sib.MAX_LOCKS))
	end
	if #(locks or {}) > 0 and not key then
		log_once("nokey", "sibling exchange: no site key (unifi.key) yet, so this AP's "
			.. "Lock to Access Point list is not announced")
	end
	local out = {}
	if v3 then out[#out + 1] = v3 end
	if v5 then out[#out + 1] = v5 end
	return out
end

-- Fold one received sibling packet into the store, logging once per kind of
-- packet refused (an unknown version: a newer sibling during a rolling
-- upgrade; one that does not authenticate: another site, or a forgery) and
-- once when the store is full.
function M.sibling_receive(sib, store, data, self_mac, now, key)
	local ok, why = sib.record(store, data, self_mac, now, key)
	if why == "full" then
		log_once("full", ("sibling exchange: %d BSSIDs held, new ones are dropped until "
			.. "some expire"):format(sib.MAX_STORE))
	elseif not ok and why and why ~= "malformed" then
		log_once(why, "sibling exchange: packet ignored (" .. why .. ")")
	end
	return ok, why
end

-- Re-read, before each broadcast, the facts that change while the broadcaster
-- runs. The packet used to be built from startup values for the life of the
-- process:
--   • the IsDefault TLV said "unadopted" forever. run() was never handed
--     `adopted`, so the byte make_blob_17_1a's comment insists must reflect
--     adoption state never did;
--   • the IP was whatever the interface had at boot -- wrong after a DHCP
--     renewal or a controller-pushed static address;
--   • uptime counted seconds since the DAEMON started, not since boot.
-- Every read here is a proc file or one `ip` call.
--   cfg.iface       interface to read the IP from (optional)
--   cfg.state_file  state.json path for the adopted flag (optional)
-- A field whose source cannot be read keeps its previous value.
function M._refresh(cfg)
	if cfg.iface then
		local ip = M.get_ip(cfg.iface)
		if ip then cfg.ip = ip end
	end
	local hostname = M.get_hostname()
	if hostname then cfg.hostname = hostname end
	local up = M._read_file("/proc/uptime")
	local secs = up and tonumber(up:match("^(%S+)"))
	if secs then cfg.uptime = math.floor(secs) end
	local adopted = M.adopted(cfg.state_file)
	if adopted ~= nil then cfg.adopted = adopted end
	return cfg
end

-- Discovery probes. A client looking for UniFi devices (WiFiman, UniFi
-- Discover) sends the 4-byte v1 probe 01 00 00 00 and the v2 probe
-- 02 00 00 00, to 255.255.255.255:10001 and to M.MULTICAST_ADDR:10001, from
-- an ephemeral port, and listens there for answers. Seen 2026-10-03 from
-- WiFiman 2.13 on iOS: a UCG Fiber answered every v1 probe with a v1 packet,
-- unicast from port 10001 back to the probe's source address and port, and
-- answered no v2 probe. The periodic v2 broadcast goes to port 10001, which
-- such a client is not listening on, so without an answer it never sees us.
M.MULTICAST_ADDR = "233.89.188.1"

-- The reply to datagram data, or nil when it is not a v1 probe.
function M.probe_reply(cfg, data)
	if data ~= string.char(0x01, 0x00, 0x00, 0x00) then return nil end
	return M.build_packet(cfg, true)
end

-- A socket bound to port 10001 that receives probes, or nil (logged) when
-- the port cannot be had: announcing must not depend on it.
function M.open_listener(socket)
	local udp = socket.udp()
	local ok, err = udp:setsockname("*", M.PORT)
	if not ok then
		io.stderr:write("announce: cannot listen on udp/" .. M.PORT .. ": "
			.. tostring(err) .. "; probes go unanswered\n")
		udp:close()
		return nil
	end
	-- Multicast probes need the group joined; broadcast ones do not.
	local ok_m, err_m = udp:setoption("ip-add-membership",
		{multiaddr = M.MULTICAST_ADDR, interface = "*"})
	if not ok_m then
		io.stderr:write("announce: cannot join " .. M.MULTICAST_ADDR .. ": "
			.. tostring(err_m) .. "\n")
	end
	return udp
end

-- Wait up to timeout seconds, handing every datagram that arrives on one of
-- handlers' sockets to its function: handlers = {{sock = s, fn = f}, ...},
-- f(sock, data, ip, port).
function M.serve(socket, handlers, timeout)
	local deadline = socket.gettime() + timeout
	local socks, by_sock = {}, {}
	for _, h in ipairs(handlers) do
		socks[#socks + 1] = h.sock
		by_sock[h.sock] = h.fn
	end
	while true do
		local left = deadline - socket.gettime()
		if left <= 0 then return end
		if #socks == 0 then
			socket.select(nil, nil, left)
			return
		end
		local readable = socket.select(socks, nil, left)
		for _, s in ipairs(readable or {}) do
			local data, ip, port = s:receivefrom()
			if data then by_sock[s](s, data, ip, port) end
		end
	end
end

-- The handler answering v1 probes on the discovery listener.
function M.probe_handler(cfg)
	return function(sock, data, ip, port)
		local reply = M.probe_reply(cfg, data)
		if not reply then return end
		local ok, err = sock:sendto(reply, ip, port)
		if not ok then
			io.stderr:write("announce: reply to " .. tostring(ip)
				.. " failed: " .. tostring(err) .. "\n")
		end
	end
end

-- Whether to answer discovery probes: only with l2_announce on and
-- discovery_replies set (see run()).
function M.answers_probes(cfg)
	return cfg.l2_announce ~= false and cfg.discovery_replies == true
end

-- A broadcast-capable socket bound to port, or nil (logged).
local function open_bound(socket, port, what)
	local udp = socket.udp()
	local ok, err = udp:setsockname("*", port)
	if not ok then
		io.stderr:write("announce: cannot listen on udp/" .. port .. " (" .. what
			.. "): " .. tostring(err) .. "\n")
		udp:close()
		return nil
	end
	udp:setoption("broadcast", true)
	return udp
end

-- RADIUS Dynamic Authorization dispatcher (openwrt/das.lua): bound while
-- provisioning has left a plan, checked every tick. ds keeps the state
-- between ticks ({text, das, sock}); a plan that did not change does
-- nothing, one that appears opens UDP 3799 (open: the binder, a seam), one
-- that empties closes it. cfg.das_plan is the plan the handler answers from.
function M.das_tick(ds, cfg, socket, open)
	local text = M._read_file(cfg.das_file or "/etc/openuf/das.json")
	if ds.loaded and text == ds.text then return end
	ds.loaded, ds.text = true, text
	ds.das = ds.das or require("openwrt.das")
	local plan = ds.das.load(text)
	if #plan > 0 and not ds.sock then
		ds.sock = (open or open_bound)(socket, ds.das.PORT, "RADIUS DAS")
	elseif #plan == 0 and ds.sock then
		ds.sock:close()
		ds.sock = nil
	end
	cfg.das_plan = plan
end

-- Start the main announce loop (blocks forever).
-- cfg: same table as build_packet() requires, plus:
--   interval    number  seconds between sends (default 10)
--   iface       string  interface to re-read the IP from each tick
--   state_file  string  state.json path, for the adopted flag
--   l2_announce boolean the Ubiquiti discovery broadcast (default on)
--   discovery_replies boolean answer v1 discovery probes (default off; needs
--                       l2_announce). Off by default: with it, the UniFi app
--                       found the APs on the LAN, took them for standalone
--                       devices and asked for their own login (2026-10-03)
--                       (default on)
--   siblings    boolean the sibling BSSID exchange (openwrt/siblings.lua)
--   identity_mac string the MAC siblings know this device by
function M.run(cfg)
	local socket = require("socket")
	local l2 = cfg.l2_announce ~= false

	local udpb = socket.udp()
	-- luasocket creates the underlying OS socket lazily on first real use
	-- (bind/connect/send), not in socket.udp() itself. setoption() before
	-- that point silently no-ops against fd -1, so SO_BROADCAST never
	-- actually gets set and the later setpeername() to a broadcast address
	-- fails with EACCES. Force real socket creation first via a bind.
	udpb:setsockname("*", 0)
	udpb:setoption("broadcast", true)
	-- sendto on the unconnected socket, NOT setpeername + send. At boot this
	-- process comes up before br-lan has an address; setpeername to the
	-- broadcast address then fails with ENETUNREACH -- RETURNING nil rather
	-- than raising -- and the first send raised "calling 'send' on bad self
	-- (udp{connected} expected)", which took the process down. procd
	-- respawned it five seconds later so it healed itself, but every boot
	-- logged a crash. A failed sendto is logged and simply retried next tick.

	local counter  = cfg.counter or 0
	local interval = cfg.interval or 10
	local handlers = {}
	if M.answers_probes(cfg) then
		local listener = M.open_listener(socket)
		if listener then
			handlers[#handlers + 1] = {sock = listener, fn = M.probe_handler(cfg)}
		end
	end

	local sib, sib_sock, sib_store, own, own_locks = nil, nil, {}, {}, {}
	local sib_key
	if cfg.siblings then
		sib = require("openwrt.siblings")
		sib_key = sib.read_key()
		sib_sock = open_bound(socket, sib.PORT, "siblings")
		if sib_sock then
			handlers[#handlers + 1] = {sock = sib_sock, fn = function(_, data)
				M.sibling_receive(sib, sib_store, data, cfg.identity_mac, os.time(), sib_key)
			end}
		end
	end

	-- The RADIUS DAS dispatcher's state (M.das_tick).
	local ds = {}
	local relay

	while true do
		counter = counter + 1
		cfg.counter = counter
		pcall(M.das_tick, ds, cfg, socket)
		-- Counted as before, for the case where /proc/uptime is unreadable;
		-- _refresh replaces it with the real figure whenever it can.
		cfg.uptime = (cfg.uptime or 0) + interval
		M._refresh(cfg)

		if l2 then
			local ok, err = udpb:sendto(M.build_packet(cfg), M.BROADCAST_ADDR, M.PORT)
			if not ok then
				io.stderr:write("announce: send failed: " .. tostring(err) .. "\n")
			end
		end
		if sib_sock then
			-- The BSSIDs change only when the controller re-provisions WLANs;
			-- once a minute is plenty.
			if counter % 6 == 1 then own = sib.own_bssids(M._popen("iw dev")) end
			own_locks = M.own_locks(cfg.state_file)
			sib_key = sib.read_key()
			for _, pkt in ipairs(M.sibling_packets(sib, cfg, own, own_locks, sib_key, os.time())) do
				sib_sock:sendto(pkt, M.BROADCAST_ADDR, sib.PORT)
			end
			pcall(sib.save, sib.expire(sib_store, os.time()), sib.FILE,
				require("cjson"))
		end
		local tick_handlers = handlers
		local das, das_sock = ds.das, ds.sock
		if das_sock then
			relay = relay or das.udp_relay(socket)
			tick_handlers = {}
			for _, h in ipairs(handlers) do tick_handlers[#tick_handlers + 1] = h end
			tick_handlers[#tick_handlers + 1] = {sock = das_sock, fn = function(s, data, ip, port)
				local ok, answer = pcall(das.handle, cfg.das_plan, data, ip, relay)
				if ok and answer then s:sendto(answer, ip, port) end
			end}
		end
		M.serve(socket, tick_handlers, interval)
	end
end

-- ─── Script entry point ───────────────────────────────────────────────────────
-- When run directly (lua announce.lua from the install directory), load config
-- and start the main loop. When loaded as a module via dofile/require, the
-- caller drives execution.

if not OPENUF_TEST_MODE then
	local ok, err = pcall(function()
		local dev, config = require("config").load()

		local ufhw = {}
		ufhw.uap = dev.identity

		local iface = dev.conf.net.lan_cpueth or "eth1"
		-- The identity MAC (board.lua: the one the network knows the AP by,
		-- since some boards' socket MAC is random per boot); discovery must
		-- announce the same MAC the informs arrive under.
		local mac   = M.parse_mac(dev.conf.net.identity_mac)
			or M.get_mac(iface) or {0x24, 0xa4, 0x3c, 0x00, 0xd3, 0xad}
		local ip    = M.get_ip(iface)  or {192, 168, 1, 1}
		local hostname = M.get_hostname() or "openUF"
		-- The state_file option, honoured here the way inform.lua and
		-- hook/syswrapper.lua honour it, so all three agree on the file.
		local state_file = (type(config.state_file) == "string"
			and config.state_file ~= "") and config.state_file or nil

		M.run({
			mac           = mac,
			ip            = ip,
			hostname      = hostname,
			adopted       = M.adopted(state_file) or false,
			iface         = iface,
			state_file    = state_file,
			platform      = ufhw.uap.platform,
			fw_pre        = ufhw.uap.fw.pre,
			fw_ver        = ufhw.uap.fw.ver,
			fw_buildtime  = ufhw.uap.fw.buildtime,
			fw_factoryver = ufhw.uap.fw.factoryver,
			version_suffix = M.VERSION_SUFFIX,
			l2_announce   = config.l2_announce,
			model         = ufhw.uap.model,
			model_display = ufhw.uap.model_display,
			discovery_replies = config.discovery_replies,
			siblings      = config.sibling_exchange,
			identity_mac  = string.format("%02x:%02x:%02x:%02x:%02x:%02x",
				mac[1], mac[2], mac[3], mac[4], mac[5], mac[6]),
		})
	end)
	if not ok then
		io.stderr:write("announce: " .. tostring(err) .. "\n")
		os.exit(1)
	end
end

return M
