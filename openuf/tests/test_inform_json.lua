-- Integration test: inform.build_json() produces a well-formed payload.
-- Tests the full JSON structure without needing a real controller.
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true

local cjson  = require("cjson")
local state  = dofile("src/state.lua")
local inform = dofile("src/inform.lua")

local function fixture(name)
	local f = io.open("tests/fixtures/" .. name, "r")
	if not f then return "" end
	local s = f:read("*a"); f:close(); return s
end

-- Inject sysinfo fixtures via inform's exposed _sysinfo reference
-- (inform.lua loads its own sysinfo instance; M._sysinfo is that instance)
-- with_clients: when true, sta_table()/radio_stats() return real fixture data
-- (2 connected clients, one in-use channel survey entry) instead of empty.
-- with_wired: when true, mac_table()'s bridge fdb/arp/dhcp-lease sources
-- return real fixture data (2 wired hosts) instead of empty.
-- with_scan: when true, scan_table()'s `iw scan dump` source returns real
-- fixture data (2 neighboring networks) instead of empty; "peer" also has the
-- first one identified as a sibling openUF AP.
-- with_radio_caps: when true, radio_caps()'s `iw dev ... info` / `iw phy ...
-- info` sources return a real 5GHz (VHT+HE+DFS+160MHz) fixture instead of
-- empty.
-- The text sysinfo.sibling_bssids() reads (announce.lua's sibling table), or
-- nil for none. Set by a test, which resets it.
local siblings_json = nil

local function inject_sysinfo(with_clients, with_wired, with_scan, with_radio_caps)
	-- Caches whose whole point is to outlive a heartbeat: swapping the
	-- fixtures underneath them is exactly what they are not built for, so each
	-- payload starts from a clean one. (with_fixtures in test_sysinfo.lua does
	-- the same, on the way in and out.)
	inform._sysinfo._phy_info_cache = {}
	inform._sysinfo._uplink_cache   = {}
	inform._sysinfo._peer_cache     = {}
	inform._sysinfo.end_pass()
	-- Capability probes read the host otherwise (airtime lists debugfs); a
	-- test that wants a bit claimed says so.
	inform._airtime._supported_cache = false
	inform._sysinfo._ppsk_supported_cache = false
	inform._sysinfo._hs20_supported_cache = false
	inform._snmp._cache = {}
	inform._snmp._read_file = function() return nil end
	inform._sysinfo._read_file = function(path)
		if path:find("uptime")  then return fixture("proc_uptime.txt")  end
		if path:find("meminfo") then return fixture("proc_meminfo.txt") end
		if path:find("net/dev") then return fixture("proc_net_dev.txt") end
		if with_wired and path:find("net/arp")     then return fixture("proc_net_arp.txt") end
		if with_wired and path:find("dhcp.leases") then return fixture("dhcp_leases.txt")  end
		if siblings_json and path:find("openuf-siblings", 1, true) then return siblings_json end
		return ""
	end
	inform._sysinfo._run_cmd = function(cmd)
		-- Keyed on the interface, like the real `iw dev <if> station dump`.
		-- A blanket match would return the same stations for every netdev,
		-- which is precisely the failure mode this suite needs to be able to
		-- see: a second WLAN on a radio must come back empty, not with the
		-- first WLAN's clients.
		if with_clients and cmd:find("dev wlan0 station dump", 1, true) then
			return fixture("iw_station_dump.txt")
		end
		if cmd:find("station dump") then return "" end
		if with_clients and cmd:find("survey dump") then
			return fixture("iw_survey_dump.txt")
		end
		if with_wired and cmd:find("bridge fdb show") then
			return fixture("bridge_fdb_dump.txt")
		end
		if with_scan and cmd:find("scan dump") then
			return fixture("iw_scan_dump.txt")
		end
		if with_scan == "peer" and cmd:find("ucode -e", 1, true) then
			return "aa:bb:cc:dd:ee:01 00:00:5e:00:53:20\n"
		end
		if with_radio_caps and cmd:find("dev wlan0 info") then
			return fixture("iw_dev_info.txt")
		end
		if with_radio_caps and cmd:find("phy#0 info", 1, true) then
			return fixture("iw_phy_info_5g.txt")
		end
		return ""
	end
	-- Return empty neighbor list (no lldpd on dev machine). The neighbour list
	-- is TTL-cached for a minute, so a test that fed it a real lldpctl reply
	-- would otherwise keep answering for the tests after it.
	inform._lldp._run_cmd = function() return "" end
	inform._lldp._neighbours_cache = nil
	inform._lldp._port_idx_cache   = {}
end

-- Inject a mock ucihelper so build_json's radio/vap/stats wiring can be
-- exercised without a real UCI environment.
-- Set by a test to replace the per-VAP netdev resolution below for one build.
local ifnames_override

local function inject_ucihelper()
	inform._ucihelper = {
		get_radio_table = function()
			return {
				-- channel is numeric, mirroring the real get_radio_table's
				-- tonumber coercion (the literal "auto" is the only
				-- non-numeric value that passes through).
				{ name = "radio0", radio = "ng", channel = 6, ht = "HT20", tx_power = "20",
				  disabled = false, builtin_antenna = true, builtin_ant_gain = 3,
				  max_txpower = 20 },
			}
		end,
		get_vap_table = function()
			return {
				{ name = "openuf_test", essid = "test", radio = "ng", radio_name = "radio0",
				  encryption = "psk2", disabled = false, bssid = "aa:bb:cc:00:00:01",
				  channel = 6, tx_power = "20", usage = "user" },
			}
		end,
		-- Strict on purpose: real get_ifname_for_radio() resolves a UCI
		-- device name ("radio0"/"radio1"), not the band vap.radio reports
		-- ("ng"/"na") -- returning nil for anything else catches a caller
		-- that regresses back to passing vap.radio here (sta_table would
		-- silently stay empty on every real inform).
		get_ifname_for_radio = function(radio) if radio == "radio0" then return "wlan0" end return nil end,
		-- Per-VAP resolution, keyed on BOTH radio and ssid, the way the real
		-- one matches SSIDs inside a radio's interface list. Modelled per-SSID
		-- so a second WLAN on the same radio gets its own netdev -- a mock
		-- that ignored the ssid would happily pass a build that hands every
		-- vap on a radio the first vap's clients, which is the live bug this
		-- guards.
		get_ifnames_for_vap = function(radio, ssid)
			if ifnames_override then return ifnames_override(radio, ssid) end
			if radio ~= "radio0" then return {} end
			if ssid == "test" then return {"wlan0"} end
			if ssid == "guest" then return {"wlan0-1"} end
			return {}
		end,
	}
end

-- Minimal ufhw matching the u6iw model
local ufhw = {
	uap = {
		platform = "U6IW",
		model    = "U6IW",
		fw       = {pre="U6IW.", ver="6.6.55", buildtime="230801.1200", factoryver="6.5.28"},
		required_version = "6.0.0",
		bootver  = "",
	}
}

local function build(opts)
	inject_sysinfo(opts and opts.with_clients, opts and opts.with_wired, opts and opts.with_scan,
		opts and opts.with_radio_caps)
	local cfg = opts and opts.cfg or nil
	if opts and opts.with_uci then inject_ucihelper() end
	-- vap_id: the wlanconf id the fixture vap echoes (get_vap_table's `id`).
	if opts and opts.vap_id then
		local get = inform._ucihelper.get_vap_table
		inform._ucihelper.get_vap_table = function(...)
			local vaps = get(...)
			for _, v in ipairs(vaps) do v.id, v.wlanconf_id = opts.vap_id, opts.vap_id end
			return vaps
		end
	end
	-- vap_patch: edit the fixture vaps in place (bssid, essid, ...).
	if opts and opts.vap_patch then
		local get = inform._ucihelper.get_vap_table
		inform._ucihelper.get_vap_table = function(...)
			local vaps = get(...)
			opts.vap_patch(vaps)
			return vaps
		end
	end
	local st = {
		authkey    = state.DEFAULT_KEY,
		adopted    = opts and opts.adopted or false,
		cfgversion = opts and opts.cfgversion or "",
		inform_url = "http://10.0.0.1:8080/inform",
		mac        = "aa:bb:cc:dd:ee:ff",
		ip         = "192.168.1.100",
		hostname   = "testap",
		locating   = opts and opts.locating,
	}
	for k, v in pairs(opts and opts.st or {}) do st[k] = v end
	local json_str = inform.build_json(st, cfg, ufhw)
	return cjson.decode(json_str), st
end

-- A DSA board's port list: one netdev per socket, and no static uplink flag
-- -- the uplink is detected from the bridge FDB. Modelled on the Xiaomi AX3000T, whose four
-- sockets are wan/lan2/lan3/lan4 in br-lan.
local DSA_CFG = {
	net = {
		lan_cpueth = "wan", lan_vlanid = 1,
		ports = {
			{idx = 1, ifname = "wan"},
			{idx = 2, ifname = "lan2"},
			{idx = 3, ifname = "lan3"},
			{idx = 4, ifname = "lan4"},
		},
	},
}

-- build() for a DSA board: everything comes from sysfs per socket plus the
-- bridge FDB.
-- opts.fdb overrides the captured `bridge fdb show br br-lan`.
-- opts.master maps an ifname to the bridge it is enslaved to, for the one case
-- where they are not all in br-lan: a socket openUF has moved into a VLAN
-- bridge. opts.fdb_by_br gives that bridge its own FDB dump.
-- Commands the last build_dsa() run forked, by kind. Lets a test assert on the
-- COST of a payload, not only its content -- which is the only way to pin that
-- build_json actually threads the shared FDB dump down to the port loop.
local dsa_forks = {}

local function build_dsa(opts)
	opts = opts or {}
	dsa_forks = {fdb_br = 0, fdb_dev = 0, uptime = 0, fdb_br_names = {}}
	inject_sysinfo(false, false, false, false)
	local base_read = inform._sysinfo._read_file
	local base_cmd  = inform._sysinfo._run_cmd
	inform._sysinfo._read_file = function(path)
		if path:find("net/arp") then return fixture("proc_net_arp_dsa.txt") end
		if path == "/proc/uptime" then dsa_forks.uptime = dsa_forks.uptime + 1 end
		return base_read(path)
	end
	inform._sysinfo._run_cmd = function(cmd)
		if cmd:find("ip route") then
			return "default via 192.0.2.1 dev br-lan \n"
		end
		local rl = cmd:match("readlink /sys/class/net/(%S+)/master")
		if rl then
			local br = (opts.master or {})[rl] or "br-lan"
			return "../../../../../../../../virtual/net/" .. br .. "\n"
		end
		if cmd:find("readlink") then
			return "../../../../../../../../virtual/net/br-lan\n"
		end
		local fdb = opts.fdb or fixture("bridge_fdb_br_dsa.txt")
		local br = cmd:match("bridge fdb show br (%S+)")
		if br then
			dsa_forks.fdb_br = dsa_forks.fdb_br + 1
			dsa_forks.fdb_br_names[br] = (dsa_forks.fdb_br_names[br] or 0) + 1
			if br ~= "br-lan" then return (opts.fdb_by_br or {})[br] or "" end
			return fdb
		end
		-- `bridge fdb show dev <socket>`: on DSA each socket is its own
		-- bridge port, so the per-port FDB is the per-socket host list. Derived
		-- from the SAME dump rather than canned separately -- they are one
		-- kernel table, and a stub that let them disagree would hide exactly
		-- the substitution build_json now makes between them.
		local dev = cmd:match("bridge fdb show dev (%S+)")
		if dev then
			dsa_forks.fdb_dev = dsa_forks.fdb_dev + 1
			local lines = {}
			for line in fdb:gmatch("[^\n]+") do
				if line:match("dev%s+(%S+)") == dev then lines[#lines + 1] = line end
			end
			return table.concat(lines, "\n") .. "\n"
		end
		return base_cmd(cmd)
	end
	-- Per-socket sysfs: the uplink is up at gigabit, the rest are empty.
	local orig_rf = inform._read_file
	inform._read_file = function(path)
		local iface = path:match("/sys/class/net/([^/]+)/")
		if iface == (opts.live or "wan") then
			if path:find("speed")   then return "1000\n" end
			if path:find("duplex")  then return "full\n" end
			if path:find("carrier") then return "1\n"    end
		elseif iface then
			if path:find("speed")   then return "-1\n"   end
			if path:find("carrier") then return "0\n"    end
		end
		return nil
	end
	local st = {
		authkey = state.DEFAULT_KEY, adopted = true, cfgversion = "",
		inform_url = "http://192.0.2.1:8080/inform",
		mac = "00:00:5e:00:53:16", ip = "192.0.2.4", hostname = "testap",
	}
	local ok, out = pcall(function()
		return cjson.decode(inform.build_json(st, opts.cfg or DSA_CFG, ufhw))
	end)
	inform._read_file = orig_rf
	if not ok then error(out, 0) end
	return out
end

-- Index a payload's port_table by port_idx.
local function by_idx(port_table)
	local out = {}
	for _, p in ipairs(port_table) do out[p.port_idx] = p end
	return out
end

return {
	{
		name = "inform json: _type is 'state'",
		fn = function()
			local d = build()
			assert_eq(d._type, "state", "_type")
		end
	},
	{
		name = "inform json: required top-level fields present",
		fn = function()
			local d = build()
			for _, field in ipairs({"mac","serial","model","platform","hostname",
				"ip","version","uptime","time","mem_total","mem_used"}) do
				assert_not_nil(d[field], "field present: " .. field)
			end
		end
	},
	{
		name = "inform json: mac matches state",
		fn = function()
			local d = build()
			assert_eq(d.mac, "aa:bb:cc:dd:ee:ff", "mac")
		end
	},
	{
		name = "inform json: serial is mac without colons",
		fn = function()
			local d = build()
			assert_eq(d.serial, "aabbccddeeff", "serial")
		end
	},
	{
		name = "inform json: model and platform match u6iw",
		fn = function()
			local d = build()
			assert_eq(d.model,    "U6IW", "model")
			assert_eq(d.platform, "U6IW", "platform")
		end
	},
	{
		name = "inform json: version is the bare fw.ver, no model prefix",
		fn = function()
			-- Not model-prefixed: the controller compares this against its
			-- firmware catalog's own bare "version" field with strict string
			-- equality, so a "U6IW."-prefixed value never matches even when
			-- the numeric version is identical (see src/inform.lua).
			local d = build()
			assert_eq(d.version, "6.6.55", "version is bare fw.ver")
		end
	},
	{
		name = "inform json: default=true when not adopted",
		fn = function()
			local d = build({adopted = false})
			assert_true(d["default"], "default true when not adopted")
		end
	},
	{
		name = "inform json: default=false when adopted",
		fn = function()
			local d = build({adopted = true})
			assert_false(d["default"], "default false when adopted")
		end
	},
	{
		name = "inform json: uptime from fixture is 12345",
		fn = function()
			local d = build()
			assert_eq(d.uptime, 12345, "uptime from /proc/uptime fixture")
		end
	},
	{
		name = "inform json: mem_total and mem_used from fixture (bytes)",
		fn = function()
			local d = build()
			assert_eq(d.mem_total, 131072 * 1024, "mem_total bytes")
			assert_eq(d.mem_used, (131072 - 72000) * 1024, "mem_used = (total - available) bytes")
		end
	},
	{
		name = "inform json: debug_caps and debug_payload_extra override the payload, and warn",
		fn = function()
			local d = build({cfg = {config = {debug_caps = {wifi_caps = 0x40, fw_caps = 0x111},
				debug_payload_extra = {uplink = {type = "wireless"}}}}})
			assert_eq(d.wifi_caps, 0x40, "wifi_caps claimed only on request")
			assert_eq(d.fw_caps, 0x111, "fw_caps overridden")
			local plain = build()
			-- Against the shipped payload, not a literal: the claimed bits are
			-- pinned by the wifi_caps2 test below.
			assert_eq(d.wifi_caps2, plain.wifi_caps2, "unset masks keep their shipped value")
			assert_eq(d.uplink.type, "wireless", "extra field merged")
			assert_true(plain.wifi_caps ~= 0x40, "the override replaces the shipped wifi_caps")
			assert_eq(plain.wifi_caps, 0x100101C, "only what the device can do without the override")
			local said = ""
			local real = io.stderr
			io.stderr = {write = function(_, m) said = said .. m end}
			local warned = inform._warn_debug_overrides({config = {debug_caps = {wifi_caps = 0x40}}})
			io.stderr = real
			assert_true(warned, "warned")
			assert_true(said:find("wifi_caps=0x40", 1, true) ~= nil, "naming the override")
			assert_false(inform._warn_debug_overrides({config = {}}), "silent without")
		end
	},
	{
		name = "inform json: sys_stats carries load averages and memory (10.6 device shape)",
		fn = function()
			local d = build()
			local ss = d.sys_stats
			assert_not_nil(ss, "sys_stats present")
			assert_eq(ss.mem_total, 131072 * 1024, "mem_total bytes")
			-- total - MemFree, as the firmware's sysinfo() totalram - freeram
			-- gives it (not MemAvailable, which system-stats' percentage uses).
			assert_eq(ss.mem_used, (131072 - 65536) * 1024, "mem_used bytes")
			assert_eq(ss.mem_buffer, 2048 * 1024, "mem_buffer bytes")
		end
	},
	{
		-- The controller logs "Possible interference" when athstats.ast_txto
		-- or ast_cst rises faster than 10/s; it diffs the raw counts itself.
		name = "inform json: athstats carries ath9k's tx and carrier-sense timeout counts",
		fn = function()
			local orig = inform._sysinfo.radio_timeouts
			local asked
			inform._sysinfo.radio_timeouts = function(ifname) asked = ifname; return 312203, 263611 end
			local d = build({with_uci = true, with_clients = true})
			local radio = d.radio_table[1]
			assert_eq(asked, "wlan0", "read per radio netdev")
			assert_eq(radio.athstats.ast_txto, 312203, "ast_txto = GTT")
			assert_eq(radio.athstats.ast_cst, 263611, "ast_cst = CST")
			assert_nil(radio.athstats.ast_be_xmit, "no beacon count: no source")
			-- Not ath9k (or no debugfs): absent, never a made-up 0.
			inform._sysinfo.radio_timeouts = function() return nil end
			d = build({with_uci = true, with_clients = true})
			inform._sysinfo.radio_timeouts = orig
			assert_nil(d.radio_table[1].athstats.ast_txto, "no counter: no ast_txto")
			assert_nil(d.radio_table[1].athstats.ast_cst, "no counter: no ast_cst")
			assert_not_nil(d.radio_table[1].athstats.cu_total, "the rest of athstats unchanged")
		end
	},
	{
		name = "inform json: a 40 MHz vap reports its secondary channel side as extchannel",
		fn = function()
			local d = build({with_uci = true, with_radio_caps = true})
			assert_nil(d.vap_table[1].extchannel, "20 MHz: no secondary channel, and it is left out")
			assert_nil(d.radio_table[1].extchannel, "extchannel is a vap field only")
			-- HT40- on channel 11: the secondary 20 MHz is channel 7, below.
			-- The UI centres the channel at channel + 2 * extchannel = 9.
			inject_sysinfo(false, false, false, true)
			local run = inform._sysinfo._run_cmd
			inform._sysinfo._run_cmd = function(cmd)
				local out = run(cmd)
				if cmd:find("dev wlan0 info", 1, true) then
					out = (out:gsub("channel 6 %\(2437 MHz%\), width: 20 MHz, center1: 2437 MHz",
						"channel 11 (2462 MHz), width: 40 MHz, center1: 2452 MHz"))
				end
				return out
			end
			inject_ucihelper()
			local st = {authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://192.0.2.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.0.2.100", hostname = "testap"}
			local d2 = cjson.decode(inform.build_json(st, nil, ufhw))
			inform._sysinfo._run_cmd = run
			assert_eq(d2.vap_table[1].extchannel, -1, "secondary below the primary")
			assert_nil(d2.radio_table[1].extchannel, "not a radio_table field")
		end
	},
	{
		name = "inform json: inform_ip is the inform URL's literal host",
		fn = function()
			local d = build()
			-- build() adopts with a literal-IP URL or the default; either way a
			-- literal host must come back verbatim and a name is resolved.
			local inform = dofile("src/inform.lua")
			assert_eq(inform._inform_ip("http://192.0.2.10:8080/inform"), "192.0.2.10", "literal")
			assert_nil(inform._inform_ip("not a url"), "garbage")
			assert_true(d.inform_ip == nil or d.inform_ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil,
				"inform_ip is omitted or an IPv4 literal")
		end
	},
	{
		name = "inform json: if_table is a list",
		fn = function()
			local d = build()
			assert_not_nil(d.if_table, "if_table present")
			assert_true(type(d.if_table) == "table", "if_table is table")
			-- Fixture has lo, eth0, eth1
			assert_true(#d.if_table >= 3, "at least 3 interfaces")
		end
	},
	{
		name = "inform json: if_table entries have required fields",
		fn = function()
			local d = build()
			local eth0
			for _, iface in ipairs(d.if_table) do
				if iface.name == "eth0" then eth0 = iface end
			end
			assert_not_nil(eth0, "eth0 in if_table")
			assert_not_nil(eth0.rx_bytes,  "eth0 rx_bytes")
			assert_not_nil(eth0.tx_bytes,  "eth0 tx_bytes")
		end
	},
	{
		name = "inform json: cfgversion reflects state",
		fn = function()
			local d = build({cfgversion = "abc123"})
			assert_eq(d.cfgversion, "abc123", "cfgversion")
		end
	},
	{
		name = "inform json: inform_url present",
		fn = function()
			local d = build()
			assert_eq(d.inform_url, "http://10.0.0.1:8080/inform", "inform_url")
		end
	},
	{
		name = "inform json: lldp_table is a list (may be empty without lldpd)",
		fn = function()
			local d = build()
			assert_not_nil(d.lldp_table, "lldp_table present")
			assert_true(type(d.lldp_table) == "table", "lldp_table is table")
		end
	},
	{
		name = "inform json: lldp_table uses the real controller's field names",
		fn = function()
			-- Can't use build() here: inject_sysinfo() (which it always
			-- calls first) resets _lldp._run_cmd to return "" every time,
			-- so the lldpctl fixture override must be set after that and
			-- build_json() called directly.
			inject_sysinfo(false)
			inform._lldp._run_cmd = function(cmd)
				if cmd:find("lldpctl") then
					local f = io.open("tests/fixtures/lldpctl_output.json", "r")
					local s = f:read("*a"); f:close(); return s
				end
				return ""
			end
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap",
			}
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			local nbr = d.lldp_table[1]
			assert_eq(nbr.chassis_id, "aa:bb:cc:dd:ee:01", "chassis_id")
			assert_eq(nbr.port_id, "GigabitEthernet0/1", "port_id")
			assert_eq(nbr.local_port_name, "eth0", "local_port_name (was 'port')")
			assert_eq(nbr.port_descr, "Uplink port", "port_descr")
			assert_contains(nbr.chassis_descr, "UniFi Switch",
				"chassis_descr comes from the System Description TLV (chassis.descr), not chassis.name")
			assert_eq(nbr.is_wired, true, "is_wired always true for LLDP")
			assert_true(nbr.system_name == nil, "system_name is not a real wire field")
			assert_true(nbr.port == nil, "port is not a real wire field (renamed local_port_name)")
			inform._lldp._run_cmd = function() return "" end
		end
	},
	{
		name = "inform json: locating defaults to false",
		fn = function()
			local d = build()
			assert_false(d.locating, "locating false by default")
		end
	},
	{
		name = "inform json: locating reflects state.locating",
		fn = function()
			local d = build({locating = true})
			assert_true(d.locating, "locating true from state")
		end
	},
	{
		name = "inform json: system-stats present with cpu/mem/uptime (real capture key/shape)",
		fn = function()
			local d = build()
			-- Real devices report this under the hyphenated key "system-stats"
			-- (verified against a real captured USG payload) -- not "sys_stats".
			local stats = d["system-stats"]
			assert_not_nil(stats, "system-stats present")
			assert_not_nil(stats.cpu, "cpu field present")
			assert_not_nil(stats.uptime, "uptime field present")
			-- meminfo fixture: total=131072kB, available=72000kB -> 45% used
			-- (page cache is reclaimable: MemAvailable, not MemFree)
			assert_eq(stats.mem, "45", "mem percent computed from meminfo fixture")
		end
	},
	{
		name = "inform json: a second WLAN on the same radio does not inherit the first's clients",
		fn = function()
			-- The live bug: with "Home LAN" and a brand-new "Home IoT" both on
			-- radio1, the IoT WLAN reported nine connected clients -- every one
			-- of them the other WLAN's, showing the other network's IP
			-- addresses in the controller UI. sta_table was resolved per RADIO
			-- (get_ifname_for_radio returns whichever interface netifd lists
			-- first), so every secondary vap on a radio got the first vap's
			-- station dump, and with it the traffic counters, satisfaction and
			-- num_sta. The device-level aggregates double-counted too.
			inject_sysinfo(true)          -- fixture: 2 clients, on wlan0 only
			inject_ucihelper()
			local ufuci = inform._ucihelper
			local orig_vaps = ufuci.get_vap_table
			ufuci.get_vap_table = function()
				return {
					{name = "openuf_test", essid = "test", radio = "ng",
					 radio_name = "radio0", encryption = "psk2", disabled = false,
					 bssid = "aa:bb:cc:00:00:01", channel = 6, usage = "user"},
					-- Same radio, different SSID -- the IoT case.
					{name = "openuf_guest", essid = "guest", radio = "ng",
					 radio_name = "radio0", encryption = "psk2", disabled = false,
					 bssid = "aa:bb:cc:00:00:02", channel = 6, usage = "user"},
				}
			end
			local st = {authkey = state.DEFAULT_KEY, adopted = true, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap"}
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			ufuci.get_vap_table = orig_vaps

			local by_essid = {}
			for _, v in ipairs(d.vap_table) do by_essid[v.essid] = v end
			assert_eq(by_essid["test"].num_sta, 2,
				"the WLAN whose netdev has the stations reports them")
			assert_eq(by_essid["guest"].num_sta, 0,
				"the other WLAN on the same radio reports none of them")
			assert_eq(#by_essid["guest"].sta_table, 0,
				"and nests no borrowed sta_table entries")
		end
	},
	{
		name = "inform json: vap_table num_sta reflects connected clients",
		fn = function()
			local d = build({with_uci = true, with_clients = true})
			assert_eq(#d.vap_table, 1, "one vap")
			assert_eq(d.vap_table[1].num_sta, 2, "two clients from fixture")
		end
	},
	{
		name = "inform json: vap_table num_sta is 0 with no clients",
		fn = function()
			local d = build({with_uci = true, with_clients = false})
			assert_eq(d.vap_table[1].num_sta, 0, "no clients")
		end
	},
	{
		name = "inform json: vap_table avg_client_signal averages connected clients' signal",
		fn = function()
			local d = build({with_uci = true, with_clients = true})
			-- fixture clients: -62 dBm and -75 dBm -> floor(-137/2) = -69
			assert_eq(d.vap_table[1].avg_client_signal, -69, "mean of the two fixture clients' signal")
		end
	},
	{
		name = "inform json: vap_table avg_client_signal is omitted with no clients",
		fn = function()
			local d = build({with_uci = true, with_clients = false})
			assert_true(d.vap_table[1].avg_client_signal == nil,
				"no clients means no valid average to report")
		end
	},
	{
		name = "inform json: radio_table_stats carries per-radio TX counters and retry pct",
		fn = function()
			-- Without these the controller's own entry ended up
			-- tx_packets=243, tx_retries=0, tx_retries_pct=100 -- rendering a
			-- permanent "TX Retries: High (100%)" on an AP whose real rate is
			-- a few percent. It does not derive them from the vap_table copies
			-- it already holds.
			local d = build({with_uci = true, with_clients = true})
			local rs = d.radio_table_stats[1]
			local vap = d.vap_table[1]
			assert_eq(rs.tx_packets, vap.tx_packets, "radio sums its VAPs' packets")
			assert_eq(rs.tx_retries, vap.tx_retries, "and their retries")
			local attempts = rs.tx_packets + rs.tx_retries
			assert_eq(rs.tx_retries_pct, math.floor(rs.tx_retries * 100 / attempts + 0.5),
				"pct is retries over total attempts, matching sta_table's definition")
			assert_true(rs.tx_retries_pct >= 0 and rs.tx_retries_pct <= 100,
				"and is a percentage")
		end
	},
	{
		name = "inform json: wifi_tx_attempts/dropped are reported per VAP and per radio",
		fn = function()
			-- The controller aggregates this pair upward into stat.ap
			-- ("<band>-wifi_tx_attempts", "radio0-wifi_tx_attempts", ...) and
			-- divides them to get a rate. openUF sent them per STATION only,
			-- so every aggregate sat at 0 and the division degenerated into
			-- the permanent "TX Retries: High (100%)" on the Devices view.
			local d = build({with_uci = true, with_clients = true})
			local vap, rs = d.vap_table[1], d.radio_table_stats[1]
			assert_eq(vap.wifi_tx_attempts, vap.tx_packets,
				"attempts are the frames sent, retries not included, as sta_table defines them")
			assert_eq(vap.wifi_tx_dropped, vap.tx_dropped, "dropped is the driver's drop count")
			assert_eq(rs.wifi_tx_attempts, vap.wifi_tx_attempts,
				"radio sums its VAPs' attempts")
			assert_eq(rs.wifi_tx_dropped, vap.wifi_tx_dropped, "and their drops")
			-- The per-station field this aggregates must still be there.
			assert_not_nil(vap.sta_table[1].wifi_tx_attempts, "per-station copy kept")
		end
	},
	{
		name = "inform json: an OWE transition vap reports the clients of both its BSSes",
		fn = function()
			-- Transition mode is one section and two netdevs: OWE-capable
			-- clients sit on the hidden OWE BSS, the rest on the open one.
			local orig_sta = inform._sysinfo.sta_table
			ifnames_override = function(radio, ssid)
				if radio == "radio0" and ssid == "test" then return {"wlan0", "wlan0-2"} end
				return {}
			end
			local ok, err = pcall(function()
				inject_sysinfo(true)
				inform._sysinfo.sta_table = function(ifname)
					if ifname == "wlan0" then
						return {{mac = "00:00:5e:00:53:01", signal = -50, tx_packets = 1}}
					end
					if ifname == "wlan0-2" then
						return {{mac = "00:00:5e:00:53:02", signal = -80, tx_packets = 1}}
					end
					return {}
				end
				inject_ucihelper()
				-- Minimum RSSI at -70 dBm, so the open BSS's weak client is
				-- kicked -- on ITS netdev, not the section's own.
				inform._ucihelper.get_radio_table = function()
					return {{name = "radio0", radio = "ng", channel = "6",
						min_rssi_enabled = true, min_rssi_raw = 25}}
				end
				local kicked = {}
				-- Every station has been below Minimum RSSI for longer than its hold.
				inform._minrssi._low_since = setmetatable({}, {__index = function() return -math.huge end})
				inform._ucihelper.kick_station = function(ifname, mac)
					kicked[#kicked + 1] = {ifname = ifname, mac = mac}
				end
				local d = cjson.decode(inform.build_json({
					authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
					inform_url = "http://192.0.2.1:8080/inform", mac = "00:00:5e:00:53:0a",
					ip = "192.0.2.100", hostname = "testap",
				}, nil, ufhw))
				local vap
				for _, v in ipairs(d.vap_table) do if v.essid == "test" then vap = v end end
				assert_not_nil(vap, "fixture sanity: the vap exists")
				assert_eq(vap.num_sta, 2, "one client per BSS, both counted")
				assert_eq(#vap.sta_table, 2, "and both listed")
				assert_eq(#kicked, 1, "only the weak client is kicked")
				assert_eq(kicked[1].ifname, "wlan0-2", "on the open BSS it is associated to")
				assert_eq(inform._last_vap_by_ifname["wlan0-2"], vap.name,
					"station events on the open BSS are filed under the vap")
			end)
			inform._sysinfo.sta_table, ifnames_override = orig_sta, nil
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform json: no retry percentage is reported when nothing was transmitted",
		fn = function()
			-- A client associated but idle: 0% and 100% are both lies about a
			-- radio that has transmitted nothing, so the field is absent.
			-- (Built with clients so radio_table_stats entries exist at all --
			-- with none, this would assert on nothing.)
			local orig = inform._sysinfo.sta_table
			inform._sysinfo.sta_table = function()
				return {{mac = "aa:bb:cc:dd:ee:01", signal = -50,
					tx_packets = 0, tx_retries = 0, rx_packets = 0,
					tx_bytes = 0, rx_bytes = 0}}
			end
			local ok, err = pcall(function()
				local d = build({with_uci = true, with_clients = true})
				local rs = d.radio_table_stats[1]
				assert_not_nil(rs, "fixture sanity: a radio entry exists to check")
				assert_eq(rs.tx_packets, 0, "and it really did transmit nothing")
				assert_true(rs.tx_retries_pct == nil, "no attempts -> no percentage")
			end)
			inform._sysinfo.sta_table = orig
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform json: satisfaction is rolled up to the vap, its radio and the device",
		fn = function()
			-- The controller does not derive these from the per-client scores
			-- it already holds: without them the Devices list showed
			-- "No Clients" in the Experience column on an AP with eight
			-- connected clients, each individually scored in the Clients view.
			local d = build({with_uci = true, with_clients = true})
			local vap = d.vap_table[1]
			local sum, n = 0, 0
			for _, s in ipairs(vap.sta_table) do sum, n = sum + s.satisfaction, n + 1 end
			assert_eq(n, 2, "two clients scored")
			assert_eq(vap.satisfaction, math.floor(sum / n),
				"the vap's score is the clients' mean, truncated as the firmware does")
			assert_eq(d.satisfaction, vap.satisfaction,
				"one vap: the device's score is the vap's")
			local radio
			for _, r in ipairs(d.radio_table) do
				if r.name == d.vap_table[1].radio_name then radio = r end
			end
			assert_not_nil(radio, "the vap's radio is reported")
			assert_eq(radio.athstats.satisfaction, vap.satisfaction,
				"its radio carries the same score in athstats")
			local reasons, anomalies = 0, 0
			for _, v in pairs(vap.reasons_bar_chart) do reasons = reasons + v end
			for _, v in pairs(vap.anomalies_bar_chart) do anomalies = anomalies + v end
			assert_eq(reasons, 2, "each client limited by one term is counted once")
			assert_eq(vap.reasons_bar_chart.phy_rate, 2, "both by their phy rate")
			assert_eq(anomalies, 0, "no anomalies on these clients")
			assert_eq(vap.anomalies_bar_chart.weak_signal, 0, "every anomaly key is sent")
		end
	},
	{
		name = "inform json: satisfaction is -1, not absent or zero, when nothing is connected",
		fn = function()
			-- 0 would read as "terrible experience". The firmware sends -1,
			-- which the controller's stat archiver skips; absent would leave
			-- the device's last score standing (it copies the field only
			-- when present).
			local d = build({with_uci = true, with_clients = false})
			assert_eq(d.vap_table[1].satisfaction, -1, "no vap score without clients")
			assert_eq(d.satisfaction, -1, "no device score either")
			for _, r in ipairs(d.radio_table) do
				if r.athstats then
					assert_eq(r.athstats.satisfaction, -1, "nor a radio score")
				end
			end
			assert_eq(d.vap_table[1].reasons_bar_chart.signal, 0, "the charts are sent, all zero")
		end
	},
	{
		name = "inform json: vap_table carries cu_total/cu_self_rx/cu_self_tx/cu_interf from its radio",
		fn = function()
			local d = build({with_uci = true, with_clients = true})
			-- same fixture survey data as the radio_table_stats test: cu_total=37,
			-- cu_self_rx=18, cu_self_tx=9, cu_interf=10
			assert_eq(d.vap_table[1].cu_total, 37, "vap cu_total matches its radio's radio_table_stats")
			assert_eq(d.vap_table[1].cu_self_rx, 18, "vap cu_self_rx matches its radio's radio_table_stats")
			assert_eq(d.vap_table[1].cu_self_tx, 9, "vap cu_self_tx matches its radio's radio_table_stats")
			assert_eq(d.vap_table[1].cu_interf, 10, "vap cu_interf matches its radio's radio_table_stats")
		end
	},
	{
		name = "inform json: sta chwidth is the controller's code for the wider of tx/rx",
		fn = function()
			inform._sta_stats_cache = {}
			inject_sysinfo(true)
			inject_ucihelper()
			local run = inform._sysinfo._run_cmd
			inform._sysinfo._run_cmd = function(cmd)
				local out = run(cmd)
				if cmd:find("dev wlan0 station dump", 1, true) then
					-- First station: 80 MHz tx, 20 MHz rx. Second: 160 MHz rx.
					out = out:gsub("(tx bitrate:%s+144%.4 MBit/s MCS 15)", "%1 80MHz", 1)
					out = out:gsub("(rx bitrate:%s+54%.0 MBit/s MCS 5)", "%1 160MHz", 1)
				end
				return out
			end
			local d = cjson.decode(inform.build_json({
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.0.2.100", hostname = "testap",
			}, nil, ufhw))
			local sta_table = d.vap_table[1].sta_table
			assert_eq(sta_table[1].chwidth, 2, "80 MHz tx -> code 2")
			assert_eq(sta_table[2].chwidth, 3, "160 MHz rx -> code 3")
		end
	},
	{
		name = "inform json: guest_token is reported only while the portal is enforced",
		fn = function()
			local d = build({st = {guest_token = "00112233445566778899aabbccddeeff",
				guest = {enabled = true, portal_url = "http://192.0.2.2/"}}})
			assert_eq(d.guest_token, "00112233445566778899aabbccddeeff", "portal enforced")
			d = build({st = {guest_token = "00112233445566778899aabbccddeeff", guest = {enabled = true}}})
			assert_nil(d.guest_token, "restrictions only: no token")
		end
	},
	{
		name = "inform json: sta authorized follows the guest ledger on a portal WLAN only",
		fn = function()
			-- The controller unauthorizes any station on a portal WLAN that
			-- reports authorized without a guest record, and treats an absent
			-- `authorized` as true (PROTOCOL-VALIDATION.md, "Guest portal").
			local by_mac = function(d)
				local out = {}
				for _, s in ipairs(d.vap_table[1].sta_table) do out[s.mac] = s.authorized end
				return out
			end
			local ledger = {["aa:bb:cc:dd:ee:ff"] = 1700000000}
			local a = by_mac(build({with_uci = true, with_clients = true, vap_id = "w1",
				st = {guest_wlans = {w1 = true}, guest_authorized = ledger}}))
			assert_eq(a["aa:bb:cc:dd:ee:ff"], true, "authorized guest reports true")
			assert_eq(a["11:22:33:44:55:66"], false, "unknown guest reports false, not absent")
			local b = by_mac(build({with_uci = true, with_clients = true, vap_id = "w1",
				st = {guest_wlans = {other = true}, guest_authorized = {}}}))
			assert_eq(b["11:22:33:44:55:66"], true, "a WLAN without the portal reports true")
			local c = by_mac(build({with_uci = true, with_clients = true}))
			assert_eq(c["11:22:33:44:55:66"], true, "no guest record at all reports true")
		end
	},
	{
		name = "inform json: sta_table carries each client's ip, hostname and ipv6_addresses",
		fn = function()
			-- The controller keeps these as the client's last_ip, hostname
			-- and last_ipv6 (devmgr URbVkSXx); sta_table had none of them.
			-- Station 1 is in the ARP cache, the lease file and the IPv6
			-- neighbour cache; station 2 in none -- its keys are left out.
			inform._sta_stats_cache = {}
			inject_sysinfo(true)
			inject_ucihelper()
			local read, run = inform._sysinfo._read_file, inform._sysinfo._run_cmd
			local neigh_forks = 0
			inform._sysinfo._read_file = function(path)
				if path:find("net/arp") then
					return "IP address       HW type     Flags       HW address            Mask     Device\n"
						.. "192.0.2.50       0x1         0x2         aa:bb:cc:dd:ee:ff     *        br-lan\n"
				end
				if path:find("dhcp.leases") then
					return "1735689600 aa:bb:cc:dd:ee:ff 192.0.2.50 pixel-7 01:aa:bb:cc:dd:ee:ff\n"
				end
				return read(path)
			end
			inform._sysinfo._run_cmd = function(cmd)
				if cmd:find("ip -6 neigh", 1, true) then
					neigh_forks = neigh_forks + 1
					return fixture("ip_6_neigh.txt")
				end
				return run(cmd)
			end
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://192.0.2.1:8080/inform", mac = "aa:bb:cc:00:00:99",
				ip = "192.0.2.100", hostname = "testap",
			}
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			local sta = d.vap_table[1].sta_table
			assert_eq(sta[1].mac, "aa:bb:cc:dd:ee:ff", "station 1")
			assert_eq(sta[1].ip, "192.0.2.50", "ip from the ARP cache")
			assert_eq(sta[1].hostname, "pixel-7", "hostname from the DHCP lease")
			assert_eq(type(sta[1].ipv6_addresses), "table", "ipv6_addresses is a list")
			assert_eq(#sta[1].ipv6_addresses, 1, "its ULA, not its link-local")
			assert_eq(sta[1].ipv6_addresses[1], "fd00:db8:77::20", "the neighbour cache's address")
			assert_eq(sta[2].mac, "11:22:33:44:55:66", "station 2")
			assert_nil(sta[2].ip, "no ARP entry: ip left out, never 0.0.0.0")
			assert_nil(sta[2].hostname, "no lease: hostname left out")
			assert_nil(sta[2].ipv6_addresses, "no neighbour: no empty list either")
			assert_eq(neigh_forks, 1, "one `ip -6 neigh` for both stations")

			-- No connected client: no fork at all.
			neigh_forks = 0
			local orig_ifnames = ifnames_override
			ifnames_override = function() return {} end
			inform.build_json(st, nil, ufhw)
			ifnames_override = orig_ifnames
			assert_eq(neigh_forks, 0, "no station, no `ip -6 neigh`")
			inform._sysinfo._read_file, inform._sysinfo._run_cmd = read, run
		end
	},
	{
		name = "inform json: sta is_11r from the negotiated AKM, state 0x10 from mac80211 power save",
		fn = function()
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://192.0.2.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.0.2.100", hostname = "testap",
			}
			local function build_with(all_sta, files)
				inform._sta_stats_cache = {}
				inform._sysinfo._sta_flags_cache = {}  -- each build is a new association
				inject_sysinfo(true)
				inject_ucihelper()
				local run, read = inform._sysinfo._run_cmd, inform._sysinfo._read_file
				local forks = 0
				inform._sysinfo._run_cmd = function(cmd)
					if cmd:find("all_sta", 1, true) then
						forks = forks + 1
						return all_sta
					end
					return run(cmd)
				end
				inform._sysinfo._read_file = function(path)
					if files[path] then return files[path] end
					return read(path)
				end
				local d = cjson.decode(inform.build_json(st, nil, ufhw))
				return d.vap_table[1].sta_table, forks
			end
			-- First station on FT-SAE and dozing, second on plain SAE and awake.
			local all_sta = "aa:bb:cc:dd:ee:ff\nflags=[AUTH][ASSOC][AUTHORIZED][WMM][MFP][HT]\n"
				.. "wpa=2\nAKMSuiteSelector=00-0f-ac-9\n"
				.. "11:22:33:44:55:66\nflags=[AUTH][ASSOC][AUTHORIZED][WMM][MFP][HT]\n"
				.. "wpa=2\nAKMSuiteSelector=00-0f-ac-8\n"
			local dir = "/sys/kernel/debug/ieee80211/phy0/netdev:wlan0/stations/"
			inform._sysinfo._ps_phy_ok = {}
			local files = {
				["/sys/class/net/wlan0/phy80211/name"] = "phy0\n",
				["/sys/kernel/debug/ieee80211/phy0/hwflags"] = "SIGNAL_DBM\n",
				[dir .. "aa:bb:cc:dd:ee:ff/flags"] = "AUTH\nASSOC\nPS_STA\nAUTHORIZED\nWME\n",
				[dir .. "11:22:33:44:55:66/flags"] = "AUTH\nASSOC\nAUTHORIZED\nWME\n",
			}
			local t, forks = build_with(all_sta, files)
			assert_eq(forks, 1, "one all_sta read per BSS")
			assert_eq(t[1].is_11r, true, "FT-SAE is 802.11r")
			assert_true(t[2].is_11r == nil, "plain SAE: left out, as the firmware sends it")
			assert_eq(t[1].state, 16, "power save is the controller's state bit 0x10")
			assert_eq(t[2].state, 0, "awake: no bit")
			-- No source: both left out, which the controller reads as false.
			t = build_with("", {})
			assert_true(t[1].is_11r == nil, "no hostapd record: no is_11r")
			assert_true(t[1].state == nil, "no debugfs: no state")
			-- The same association on the next heartbeat: hostapd is not asked again.
			t, forks = build_with(all_sta, files)
			local prev_run = inform._sysinfo._run_cmd
			inform._sysinfo._run_cmd = function(cmd)
				if cmd:find("all_sta", 1, true) then forks = forks + 1; return "" end
				return prev_run(cmd)
			end
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			assert_eq(forks, 1, "a known association reuses its answer")
			assert_eq(d.vap_table[1].sta_table[1].is_11r, true, "and keeps its is_11r")
			inform._sysinfo._sta_flags_cache = {}
			inform._sta_stats_cache = {}
		end
	},
	{
		name = "inform json: vap_table nests connected clients as sta_table",
		fn = function()
			inform._sta_stats_cache = {}
			local d = build({with_uci = true, with_clients = true})
			local sta_table = d.vap_table[1].sta_table
			assert_eq(#sta_table, 2, "two entries in sta_table")
			assert_eq(sta_table[1].mac, "aa:bb:cc:dd:ee:ff", "first client mac")
			assert_eq(sta_table[1].ap_mac, "aa:bb:cc:dd:ee:ff", "ap_mac from device mac")
			-- Numeric, matching radio_table: the payload used to mix a live
			-- numeric radio_table channel with a raw UCI *string* here
			-- (including the literal "auto" on ACS radios).
			assert_eq(sta_table[1].channel, 6, "channel from vap, numeric")
			assert_eq(sta_table[1].radio, "ng", "radio from vap (the band, matching vap.radio)")
			assert_true(sta_table[1].active, "active true for a station iw actually lists")
			assert_eq(sta_table[1].signal, -62, "signal from station dump")
			assert_eq(sta_table[1].rssi, 33, "rssi is the SNR in dB (-62 over the -95 floor), as the firmware sends it")
			assert_eq(sta_table[1].noise, -95, "noise is the radio's in-use survey noise floor")
			assert_eq(sta_table[1].chwidth, 0, "chwidth 0 (20 MHz): no width token on either rate")
			-- UniFi firmware sends none of these; they were invented.
			for _, k in ipairs({"capacity", "throughput", "linkscore", "multicast"}) do
				assert_nil(sta_table[1][k], k .. " is not sent")
			end
			-- Cumulative per-client counters -- confirmed real field names via
			-- the decompiled vapInformProcessor (com.ubnt.service.devmgr.c.
			-- KHUkYjHujLgFBD), which copies these straight off each incoming
			-- sta_table entry and computes its own deltas between informs.
			assert_eq(sta_table[1].rx_bytes, 45678, "rx_bytes from station dump")
			assert_eq(sta_table[1].tx_bytes, 98765, "tx_bytes from station dump")
			assert_eq(sta_table[1].rx_packets, 312, "rx_packets from station dump")
			assert_eq(sta_table[1].tx_packets, 287, "tx_packets from station dump")
			-- tx_rate/rx_rate: controller expects Kbps, iw reports Mbit/s
			assert_eq(sta_table[1].tx_rate, 144400, "tx_rate converted to Kbps from 144.4 Mbit/s")
			assert_eq(sta_table[1].rx_rate, 72200, "rx_rate converted to Kbps from 72.2 Mbit/s")
			assert_eq(sta_table[1].uptime, 3600, "uptime from iw's connected time")
			assert_eq(sta_table[1].idletime, 0, "idletime floored from inactive_ms (120ms -> 0s)")
			-- tx_mcs/rx_mcs: part of the same controller-side wifi-experience-
			-- score input DTO (com.ubnt.service.l.e.AQODNNoMmBlFpWXX) as
			-- tx_rate/rx_rate/signal above. Real wire name is "tx_mcs", not
			-- "tx_mcs_index" (that's only the ucore-message JSON name).
			assert_eq(sta_table[1].tx_mcs, 15, "tx_mcs parsed from iw's 'MCS 15'")
			assert_eq(sta_table[1].rx_mcs, 7, "rx_mcs parsed from iw's 'MCS 7'")
			-- radio_proto/nss: confirmed real per-station wire fields, read
			-- independently of tx_mcs/rx_mcs by the real controller's client
			-- updater (com.ubnt.service.devmgr.TtZhv, confirmed via
			-- decompile) -- without these every station showed as generation
			-- "g" (the controller's own fallback) with no MIMO/stream count,
			-- regardless of tx_mcs/rx_mcs.
			assert_eq(sta_table[1].radio_proto, "n", "radio_proto from iw's bare 'MCS 15' (plain HT)")
			assert_eq(sta_table[1].nss, 2, "nss from MCS 15 -> floor(15/8)+1")
			-- is_11n/is_11ac/is_11ax/is_11be: the fields that ACTUALLY drive
			-- the live (still-connected) client's displayed generation --
			-- confirmed via decompile (com.ubnt.service.devmgr.HCKpgcBFPLu ->
			-- com.ubnt.g.s.jRsSex) that radio_proto's own string value is
			-- ignored entirely for a live client; only these booleans matter.
			assert_true(sta_table[1].is_11n, "plain HT (bare MCS) sets is_11n")
			assert_false(sta_table[1].is_11ac, "not VHT")
			assert_false(sta_table[1].is_11ax, "not HE")
			assert_false(sta_table[1].is_11be, "not EHT")
			-- The client panel's "TX Retries" is the controller's delta of
			-- tx_retries over retries + wifi_tx_attempts + dropped (devmgr
			-- TtZhv): without tx_retries per station it read 0.0 % for
			-- every client. Attempts are the 287 frames sent; 4 retries.
			local st = sta_table[1]
			assert_eq(st.tx_retries, 4, "tx_retries is sent per station")
			assert_eq(st.wifi_tx_attempts, 287, "wifi_tx_attempts = tx_packets, retries not included")
			assert_not_nil(st.wifi_tx_dropped, "wifi_tx_dropped is sent per station")
			-- exact value round-trips through cjson's %.14g float encoding,
			-- so compare with a tolerance rather than bit-for-bit equality
			assert_true(math.abs(st.wifi_tx_retries_percentage
				- 4 * 100 / (287 + 4 + st.wifi_tx_dropped)) < 1e-10,
				"wifi_tx_retries_percentage = retries / (retries + attempts + dropped)")
			-- satisfaction (unifi/satisfaction.lua): signal avg -63 dBm is far
			-- above the noise floor (100), the mean of 144.4 and 72.2
			-- Mbit/s is 108300 kbps (90), and the retry window has no
			-- minute yet (100).
			assert_eq(sta_table[1].satisfaction, 90, "the phy rate binds")
			assert_eq(sta_table[1].satisfaction_now, 90, "satisfaction_now matches satisfaction")
			assert_eq(sta_table[1].satisfaction_reason, 2, "reason: phy_rate")
			assert_eq(sta_table[1].anomalies, 0, "no anomalies")
		end
	},
	{
		-- Listed, a client that roamed away makes 10.6's roam fallback record
		-- the move a second time, without tags (upstream ea0b5d6).
		name = "inform json: a client that roamed away is left out of sta_table until hostapd drops it",
		fn = function()
			local ev = inform._staevents
			ev._reset()
			ev._roamed["aa:bb:cc:dd:ee:ff"] = 1e9
			local d = build({with_uci = true, with_clients = true})
			local macs = {}
			for _, s in ipairs(d.vap_table[1].sta_table) do macs[#macs + 1] = s.mac end
			assert_eq(table.concat(macs, ","), "11:22:33:44:55:66", "only the other client")
			assert_eq(d.vap_table[1].num_sta, 1, "and not counted")
			local listed = {}
			for _, o in ipairs(inform._last_here_obs) do listed[#listed + 1] = o.mac end
			assert_eq(#listed, 2, "roam_observe still sees both, so the mark survives")
			ev._reset()
		end
	},
	{
		name = "inform json: vap_table aggregates per-VAP traffic/retry counters from connected stations",
		fn = function()
			-- Real field names confirmed via the decompiled vap-stats DTO
			-- (cVbZoFIZsWYaVCquTr$QCtdvLKOBb) -- the controller UI's
			-- per-device "Air Stats" panel (Tx/Rx Pkts/Bytes, Tx/Rx Retry/
			-- Dropped) reads these. iw(8) only exposes per-station counters,
			-- not an already-aggregated per-VAP one, so build_json sums
			-- across sta_table. Fixture has two stations: rx_bytes
			-- 45678+1024, tx_bytes 98765+2048, rx_packets 312+8, tx_packets
			-- 287+12, tx_retries 4+0, tx_failed(->tx_dropped) 0+0.
			local d = build({with_uci = true, with_clients = true})
			local vap = d.vap_table[1]
			assert_eq(vap.rx_bytes,   46702, "rx_bytes summed across stations")
			assert_eq(vap.tx_bytes,  100813, "tx_bytes summed across stations")
			assert_eq(vap.rx_packets,   320, "rx_packets summed across stations")
			assert_eq(vap.tx_packets,   299, "tx_packets summed across stations")
			assert_eq(vap.tx_retries,     4, "tx_retries summed across stations")
			assert_eq(vap.tx_dropped,     0, "tx_dropped summed from tx_failed across stations")
		end
	},
	{
		name = "inform json: vap_table traffic/retry counters are 0 with no clients",
		fn = function()
			local d = build({with_uci = true, with_clients = false})
			local vap = d.vap_table[1]
			assert_eq(vap.rx_bytes, 0, "no clients -> zero rx_bytes")
			assert_eq(vap.tx_bytes, 0, "no clients -> zero tx_bytes")
			assert_eq(vap.tx_retries, 0, "no clients -> zero tx_retries")
		end
	},
	{
		name = "inform json: the station cache forgets a station that left",
		fn = function()
			-- _sta_stats_cache is keyed by CLIENT MAC and was never emptied,
			-- so on a daemon that runs for months in a place with transient
			-- clients it only ever grew. A station back after the window is a
			-- fresh association.
			inform._sta_stats_cache = {}
			local orig_time = inform._time
			inform._time = function() return 1000 end
			build({with_uci = true, with_clients = true})   -- seeds one station
			local seeded = 0
			for _ in pairs(inform._sta_stats_cache) do seeded = seeded + 1 end
			assert_eq(seeded, 2, "both connected stations are cached")

			-- A later payload on which that station no longer appears.
			inform._time = function() return 1000 + inform.STA_STATS_FORGET_AFTER + 1 end
			build({with_uci = true})                        -- no clients this time
			local left = 0
			for _ in pairs(inform._sta_stats_cache) do left = left + 1 end
			assert_eq(left, 0, "and dropped once it has been gone for the whole window")

			inform._time = orig_time
			inform._sta_stats_cache = {}
		end
	},
	{
		name = "inform json: satisfaction follows the firmware's terms through real counters",
		fn = function()
			inform._sta_stats_cache = {}
			inform._sysinfo._driver_cache = {}
			local orig_time = inform._time
			local t = 1000
			inform._time = function() return t end
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://192.0.2.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.0.2.100", hostname = "testap",
			}
			local last_vap
			-- One inform, ten seconds after the last: c = {signal, avg,
			-- noise, tx/rx rate, lifetime tx packets/retries/failed, driver}.
			local function inform_once(c)
				inject_ucihelper()
				inform._sysinfo._phy_info_cache = {}
				inform._sysinfo._run_cmd = function(cmd)
					if cmd:find("station dump") then
						return "Station 00:00:5e:00:53:01 (on wlan0)\n" ..
							"\ttx packets:\t" .. c.packets .. "\n" ..
							"\ttx retries:\t" .. c.retries .. "\n" ..
							"\ttx failed:\t" .. c.failed .. "\n" ..
							"\tsignal:  \t" .. c.signal .. " [-60, -61] dBm\n" ..
							(c.avg and ("\tsignal avg:\t" .. c.avg .. " [-60, -61] dBm\n") or "") ..
							"\ttx bitrate:\t" .. c.tx .. "\n" ..
							"\trx bitrate:\t" .. c.rx .. "\n"
					end
					if cmd:find("survey dump") then
						return "Survey data from wlan0\n\tfrequency:\t5180 MHz [in use]\n" ..
							"\tnoise:\t" .. c.noise .. " dBm\n"
					end
					if cmd:find("readlink", 1, true) and cmd:find("device/driver", 1, true) then
						return "../../../bus/drivers/" .. c.driver .. "\n"
					end
					if cmd:find("dev wlan0 info") then return fixture("iw_dev_info.txt") end
					if cmd:find("phy#0 info", 1, true) then return fixture("iw_phy_info_5g.txt") end
					return ""
				end
				t = t + 10
				local d = cjson.decode(inform.build_json(st, nil, ufhw))
				last_vap = d.vap_table[1]
				local sta = d.vap_table[1].sta_table[1]
				return sta.satisfaction, sta.satisfaction_reason, sta.anomalies
			end
			local VHT = "866.7 MBit/s VHT-MCS 9 80MHz short GI VHT-NSS 2"
			local function client(o)
				local c = {signal = -60, noise = -90, tx = VHT, rx = VHT,
					packets = 1000, retries = 0, failed = 0, driver = "ath9k"}
				for k, v in pairs(o) do c[k] = v end
				return c
			end
			local function step(c, pkts, retries, failed)
				c.packets, c.retries, c.failed =
					c.packets + pkts, c.retries + retries, c.failed + failed
			end

			-- Retries: judged over the last completed minute, and only then.
			inform._sta_stats_cache = {}
			local c = client{}
			assert_eq(inform_once(c), 100, "a clean VHT client at 30 dB SNR")
			for _ = 1, 5 do
				step(c, 100, 40, 5)
				assert_eq(inform_once(c), 100, "40 % retries: no minute completed yet")
			end
			step(c, 100, 40, 5)
			local score, reason, anomalies = inform_once(c)
			assert_eq(score, 50, "the minute: 40 % retries -> 80, less 30 drops")
			assert_eq(reason, 16, "reason: wifi_retries")
			assert_eq(anomalies, 0, "50 is not yet an anomaly")
			step(c, 100, 0, 0)
			assert_eq(inform_once(c), 50, "the minute's score holds until the next one")

			-- mt76's tx failed counts failed attempts, not drops.
			inform._sta_stats_cache = {}
			inform._sysinfo._driver_cache = {}
			c = client{driver = "mt798x-wmac"}
			inform_once(c)
			for _ = 1, 6 do step(c, 100, 40, 40) end
			t = t + 50
			assert_eq(inform_once(c), 80, "mt76: retries judged, failed attempts not counted as drops")
			assert_eq(last_vap.tx_dropped, 0, "nor in the VAP's drops")
			for _ = 1, 6 do step(c, 100, 40, 42) end
			t = t + 50
			assert_eq(inform_once(c), 68, "mt76: failed beyond the retries are drops: 80 less 12")
			assert_eq(last_vap.tx_dropped, 12, "and the VAP reports those 12, not 492")
			assert_eq(last_vap.wifi_tx_dropped, 12, "as does the pair the controller divides")
			-- An underflowed counter (count - 1 with count 0) is no 2^32 retries.
			c.retries, c.failed = 4294967295, 4294967295
			inform_once(c)
			assert_eq(last_vap.tx_retries, 0, "no 2^32 jump in the VAP's retries")
			assert_true(last_vap.wifi_tx_attempts < 2147483648, "nor in its attempts")
			inform._sysinfo._driver_cache = {}

			-- SNR: the averaged signal over a noise floor taken as no lower than -96.
			inform._sta_stats_cache = {}
			assert_eq(inform_once(client{signal = -80, noise = -107}), 91,
				"ath9k's -107 floor is taken as -96: SNR 16")
			inform._sta_stats_cache = {}
			assert_eq(inform_once(client{signal = -50, avg = -84, noise = -94}), 65,
				"the running average, not the last frame: SNR 10")
			inform._sta_stats_cache = {}
			score, reason, anomalies = inform_once(client{signal = -90, noise = -94})
			assert_eq(score, 0, "SNR 4: no signal")
			assert_eq(anomalies, 1, "weak_signal")

			-- PHY: the mean of the two rates, in absolute steps.
			inform._sta_stats_cache = {}
			score, reason = inform_once(client{tx = "65.0 MBit/s MCS 7", rx = "72.2 MBit/s MCS 7 short GI"})
			assert_eq(score, 85, "a 2.4 GHz single-stream client at its top rate")
			assert_eq(reason, 2, "reason: phy_rate")

			inform._time = orig_time
			inform._sta_stats_cache = {}
		end
	},
	{
		-- A UniFi AP reports utilisation over its last ~1 s (umac.ko diffs the
		-- MIB counters every 10 beacons), not since the radio came up.
		name = "inform json: channel utilisation is the delta since the previous inform",
		fn = function()
			local orig = inform._sysinfo.radio_stats
			local cur
			inform._sysinfo.radio_stats = function() return {cur} end
			local function at(freq, active, busy, rx, tx)
				cur = {freq = freq, in_use = true, noise = -95, channel_time = active,
				       channel_time_busy = busy, channel_time_rx = rx, channel_time_tx = tx}
				local a = build({with_uci = true, with_clients = true}).radio_table[1].athstats
				return a.cu_total, a.cu_self_rx, a.cu_self_tx, a.cu_interf
			end
			inform._cu_cache = {}
			-- first reading: everything since bring-up (25% lifetime average)
			local t, rx, tx, i = at(2412, 40000, 10000, 9000, 200)
			assert_eq(t, 25, "first reading: the counters as they stand")
			-- next 10 s: 8 s busy, the lifetime average would say 26%
			t, rx, tx, i = at(2412, 50000, 18000, 9500, 3200)
			assert_eq(t, 80, "cu_total over the last window")
			assert_eq(rx, 5, "cu_self_rx over the last window")
			assert_eq(tx, 30, "cu_self_tx over the last window")
			assert_eq(i, 45, "cu_interf from the windowed values")
			-- rounded like the firmware: 6 ms busy of 1000 is 0.6%, reported as 1
			t = at(2412, 51000, 18006, 9500, 3200)
			assert_eq(t, 1, "0.6% rounds to 1, as the firmware's +128>>8 does")
			-- no new active time: repeat the previous figures, don't invent 0%
			t = at(2412, 51000, 18006, 9500, 3200)
			assert_eq(t, 1, "a stalled reading repeats the previous result")
			-- radio restarted: counters went backwards, take them as they stand
			t = at(2412, 2000, 1000, 100, 100)
			assert_eq(t, 50, "after a restart: everything since the restart")
			-- channel change: no delta across two channels
			t = at(2437, 4000, 1400, 100, 100)
			assert_eq(t, 35, "after a channel change: the new channel's counters, not a delta (20)")
			inform._sysinfo.radio_stats = orig
			inform._cu_cache = {}
		end
	},
	{
		name = "inform json: radio_table_stats derived from survey dump",
		fn = function()
			local d = build({with_uci = true, with_clients = true})
			assert_eq(#d.radio_table_stats, 1, "one radio_table_stats entry")
			assert_eq(d.radio_table_stats[1].name, "radio0", "keyed by radio name")
			assert_eq(d.radio_table_stats[1].cu_total, 37, "cu_total = busy/total*100")
			assert_eq(d.radio_table_stats[1].cu_self_rx, 18, "cu_self_rx = channel_time_rx/total*100")
			assert_eq(d.radio_table_stats[1].cu_self_tx, 9, "cu_self_tx = channel_time_tx/total*100")
			assert_eq(d.radio_table_stats[1].cu_interf, 10, "cu_interf = cu_total - cu_self_rx - cu_self_tx")
		end
	},
	{
		name = "inform json: radio_table entries carry a nested athstats object for the stat archiver",
		fn = function()
			local d = build({with_uci = true, with_clients = true})
			local radio = d.radio_table[1]
			assert_not_nil(radio.athstats, "radio_table entry has athstats")
			assert_eq(radio.athstats.cu_total, 37, "athstats.cu_total matches radio_table_stats")
			assert_eq(radio.athstats.cu_self_rx, 18, "athstats.cu_self_rx matches radio_table_stats")
			assert_eq(radio.athstats.cu_self_tx, 9, "athstats.cu_self_tx matches radio_table_stats")
			assert_eq(radio.athstats.cu_interf, 10, "athstats.cu_interf matches radio_table_stats")
			-- No faithful source for the interference event counters: they
			-- stay off the wire rather than being made up.
			assert_true(radio.athstats.ast_txto == nil, "no ast_txto")
			assert_true(radio.athstats.ast_cst == nil, "no ast_cst")
			assert_true(radio.athstats.ast_be_xmit == nil, "no ast_be_xmit")
		end
	},
	{
		-- The controller stores athstats.getInt("satisfaction", -1) as the
		-- radio's score, and the archiver (service.system.v.fdwW) archives it
		-- unless it is -1 -- with the field absent, getInt()'s default 0 was
		-- archived for every radio.
		name = "inform json: athstats.satisfaction is the radio's client mean, -1 without clients",
		fn = function()
			local d = build({with_uci = true, with_clients = true})
			local vap = d.vap_table[1]
			local sum, n = 0, 0
			for _, s in ipairs(vap.sta_table) do sum, n = sum + s.satisfaction, n + 1 end
			assert_true(n > 0, "fixture has clients")
			assert_eq(d.radio_table[1].athstats.satisfaction, math.floor(sum / n),
				"radio score = mean of its clients, truncated")

			-- Two radios, clients on radio0 only (the fixture answers station
			-- dump for wlan0 alone): radio1 must carry the sentinel, not the
			-- device-wide mean.
			inform._ucihelper.get_radio_table = function()
				return {
					{ name = "radio0", radio = "ng", channel = 6, ht = "HT20", tx_power = "20",
					  disabled = false, max_txpower = 20 },
					{ name = "radio1", radio = "na", channel = 36, ht = "VHT80", tx_power = "20",
					  disabled = false, max_txpower = 20 },
				}
			end
			inform._ucihelper.get_vap_table = function()
				return {
					{ name = "openuf_test", essid = "test", radio = "ng", radio_name = "radio0",
					  encryption = "psk2", disabled = false, bssid = "00:00:5e:00:53:01",
					  channel = 6, tx_power = "20", usage = "user" },
					{ name = "openuf_test5", essid = "test", radio = "na", radio_name = "radio1",
					  encryption = "psk2", disabled = false, bssid = "00:00:5e:00:53:02",
					  channel = 36, tx_power = "20", usage = "user" },
				}
			end
			inform._ucihelper.get_ifname_for_radio = function(r)
				return ({radio0 = "wlan0", radio1 = "wlan1"})[r]
			end
			inform._ucihelper.get_ifnames_for_vap = function(r)
				return {({radio0 = "wlan0", radio1 = "wlan1"})[r]}
			end
			inject_sysinfo(true)
			local st = {authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://192.0.2.1:8080/inform", mac = "00:00:5e:00:53:03",
				ip = "192.0.2.100", hostname = "testap"}
			local d2 = cjson.decode(inform.build_json(st, nil, ufhw))
			inject_ucihelper()  -- the one-radio mock back for later tests
			local by = {}
			for _, r in ipairs(d2.radio_table) do by[r.name] = r end
			assert_not_nil(by.radio1.athstats, "radio1 has athstats (survey present)")
			assert_eq(by.radio1.athstats.satisfaction, -1, "no clients: controller's -1 sentinel")
			assert_eq(by.radio0.athstats.satisfaction, math.floor(sum / n),
				"radio0 keeps its own clients' mean")

			-- And with nothing connected anywhere, -1 rather than absent or 0.
			local d3 = build({with_uci = true, with_clients = false})
			if d3.radio_table[1].athstats then
				assert_eq(d3.radio_table[1].athstats.satisfaction, -1, "-1 without clients")
			end
		end
	},
	{
		-- "Minimum RSSI" (Devices -> [AP] -> Radios) is per-radio -- confirmed
		-- live 2026-07-14. min_rssi/min_rssi_enabled are the confirmed
		-- outbound field names (decompiled alongside radio_caps/tx_power/
		-- athstats in the same DTO). The UCI-stored value is raw wire units
		-- (an offset from the driver's noise floor, not dBm) -- build_json
		-- converts it using the live noise reading from radio_stats()'s
		-- survey dump (fixture noise: -95 dBm; raw 25 -> -95+25 = -70 dBm).
		name = "inform json: radio_table converts min_rssi from raw wire units to dBm using live noise floor",
		fn = function()
			inject_sysinfo(true)
			inject_ucihelper()
			inform._ucihelper.get_radio_table = function()
				return {
					{ name = "radio0", radio = "ng", channel = "6", ht = "HT20", tx_power = "20",
					  disabled = false, builtin_antenna = true, builtin_ant_gain = 3,
					  max_txpower = 20, min_rssi_enabled = true, min_rssi_raw = 25 },
				}
			end
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap",
			}
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			assert_eq(d.radio_table[1].min_rssi_enabled, true, "min_rssi_enabled echoed")
			assert_eq(d.radio_table[1].min_rssi, -70, "min_rssi converted: 25 + (-95 noise) = -70 dBm")
			assert_nil(d.radio_table[1].min_rssi_raw, "raw wire units not leaked into the outbound payload")
		end
	},
	{
		-- Inconsistent UCI (flag set, threshold missing -- hand-edit or an
		-- interrupted write) used to be `nil + noise`, killing the whole
		-- inform build.
		name = "inform json: min_rssi_enabled without a raw value doesn't kill the build",
		fn = function()
			inject_sysinfo(true)
			inject_ucihelper()
			inform._ucihelper.get_radio_table = function()
				return {
					{ name = "radio0", radio = "ng", channel = "6",
					  min_rssi_enabled = true },  -- no min_rssi_raw
				}
			end
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap",
			}
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			assert_eq(d.radio_table[1].min_rssi_enabled, true, "flag still echoed")
			assert_nil(d.radio_table[1].min_rssi, "no min_rssi emitted without a raw value")
		end
	},
	{
		-- The raw-units cleanup used to sit inside the ifname-resolved branch,
		-- so a radio whose netdev couldn't be resolved (radio down, ubus
		-- unavailable) leaked the internal wire-units field to the controller.
		name = "inform json: min_rssi_raw doesn't leak into the payload when ifname is unresolvable",
		fn = function()
			inject_sysinfo(true)
			inject_ucihelper()
			inform._ucihelper.get_radio_table = function()
				return {
					-- "radio9": the mock get_ifname_for_radio resolves only
					-- radio0, so this radio's ifname lookup fails.
					{ name = "radio9", radio = "ng", channel = "6",
					  min_rssi_enabled = true, min_rssi_raw = 15 },
				}
			end
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap",
			}
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			assert_nil(d.radio_table[1].min_rssi_raw, "internal raw field stripped even without an ifname")
		end
	},
	{
		-- Enforcement: a station below the radio's minrssi threshold for 30 s
		-- gets a single deauth via ucihelper.kick_station (stamgr's 30
		-- consecutive 1 s samples, openuf/minrssi.lua) -- a one-shot kick,
		-- not a persistent block, so it's deliberately separate from
		-- firewall.lua's block-sta feature (no nftables, no state.json).
		name = "inform json: stations below the radio's minrssi threshold for 30 s get kicked, others don't",
		fn = function()
			inject_sysinfo(true)  -- fixture: aa:bb:cc:dd:ee:ff at -62 dBm, 11:22:33:44:55:66 at -75 dBm
			inject_ucihelper()
			inform._minrssi._low_since = {}
			inform._ucihelper.get_radio_table = function()
				return {
					{ name = "radio0", radio = "ng", channel = "6",
					  min_rssi_enabled = true, min_rssi_raw = 25 },  -- threshold: 25 - 95 = -70 dBm
				}
			end
			local kicked = {}
			inform._ucihelper.kick_station = function(ifname, mac)
				kicked[#kicked + 1] = {ifname = ifname, mac = mac}
			end
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap",
			}
			local orig_time = inform._time
			local ok, err = pcall(function()
				for _, t in ipairs({1000, 1010, 1020}) do
					inform._time = function() return t end
					inform.build_json(st, nil, ufhw)
				end
				assert_eq(#kicked, 0, "20 s below: not yet")
				inform._time = function() return 1030 end
				inform.build_json(st, nil, ufhw)
				assert_eq(#kicked, 1, "30 s below: exactly one station kicked")
				assert_eq(kicked[1].mac, "11:22:33:44:55:66", "the -75 dBm station (below -70 threshold) is kicked")
				assert_eq(kicked[1].ifname, "wlan0", "kicked on the resolved live ifname")
			end)
			inform._time = orig_time
			if not ok then error(err, 0) end
		end
	},
	{
		-- Load balance (openuf/loadbalance.lua): above the radio's cap the most
		-- idle stations get the one-shot deauth, not counting one Minimum RSSI
		-- kicks in the same pass; the cap never reaches the payload.
		name = "inform json: Load balance kicks the most idle stations above the radio's cap",
		fn = function()
			inject_sysinfo(true)
			inject_ucihelper()
			local orig_sta = inform._sysinfo.sta_table
			inform._sysinfo.sta_table = function(ifname)
				if ifname ~= "wlan0" then return {} end
				return {
					{mac = "00:00:5e:00:53:01", signal = -50, inactive_ms = 100, tx_packets = 1},
					{mac = "00:00:5e:00:53:02", signal = -55, inactive_ms = 9000, tx_packets = 1},
					{mac = "00:00:5e:00:53:03", signal = -60, inactive_ms = 4000, tx_packets = 1},
					{mac = "00:00:5e:00:53:04", signal = -85, inactive_ms = 20000, tx_packets = 1},
				}
			end
			local radio = {name = "radio0", radio = "ng", channel = "6", loadbalance_maxsta = 2}
			inform._ucihelper.get_radio_table = function()
				local r = {}
				for k, v in pairs(radio) do r[k] = v end
				return {r}
			end
			local kicked = {}
			inform._ucihelper.kick_station = function(ifname, mac)
				kicked[#kicked + 1] = mac
			end
			inform._minrssi._low_since = {}
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap",
			}
			local ok, err = pcall(function()
				local d = cjson.decode(inform.build_json(st, nil, ufhw))
				table.sort(kicked)
				assert_eq(table.concat(kicked, ","), "00:00:5e:00:53:02,00:00:5e:00:53:04",
					"four on a cap of two: the two most idle")
				assert_nil(d.radio_table[1].loadbalance_maxsta, "internal cap stripped from the payload")

				-- Minimum RSSI (-70 dBm) has had .04 below for a minute: it is
				-- kicked for that, and the three left are one over the cap.
				kicked = {}
				radio.min_rssi_enabled, radio.min_rssi_raw = true, 25
				inform._minrssi._low_since = {["00:00:5e:00:53:04"] = os.time() - 60}
				inform.build_json(st, nil, ufhw)
				table.sort(kicked)
				assert_eq(table.concat(kicked, ","), "00:00:5e:00:53:02,00:00:5e:00:53:04",
					"Minimum RSSI's kick, then the most idle of the three left")

				kicked = {}
				radio.min_rssi_enabled, radio.min_rssi_raw = nil, nil
				radio.loadbalance_maxsta = nil
				inform.build_json(st, nil, ufhw)
				assert_eq(#kicked, 0, "off: no kicks")
			end)
			inform._sysinfo.sta_table = orig_sta
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform json: a client on a private pre-shared key's VLAN is reported, and kicked via its BSS",
		fn = function()
			-- The VLAN netdev lists its own stations (the VAP's station dump
			-- does not), but hostapd's control socket is the VAP's.
			inject_sysinfo(true)
			inject_ucihelper()
			local orig_sta = inform._sysinfo.sta_table
			inform._sysinfo.sta_table = function(ifname)
				if ifname == "wlan0" then
					return {{mac = "00:00:5e:00:53:01", signal = -50, tx_packets = 1}}
				end
				if ifname == "wlan0-20" then
					return {{mac = "00:00:5e:00:53:02", signal = -80, tx_packets = 1}}
				end
				return {}
			end
			inform._ucihelper.get_ifnames_for_vap = function(radio, ssid)
				if radio == "radio0" and ssid == "test" then return {"wlan0", "wlan0-20"} end
				return {}
			end
			inform._ucihelper.bss_ifname = function(ifname)
				return ifname == "wlan0-20" and "wlan0" or ifname
			end
			inform._ucihelper.get_radio_table = function()
				return {{name = "radio0", radio = "ng", channel = "6",
					min_rssi_enabled = true, min_rssi_raw = 25}}  -- -70 dBm
			end
			local kicked = {}
			-- Every station has been below Minimum RSSI for longer than its hold.
			inform._minrssi._low_since = setmetatable({}, {__index = function() return -math.huge end})
			inform._ucihelper.kick_station = function(ifname, mac)
				kicked[#kicked + 1] = {ifname = ifname, mac = mac}
			end
			local ok, err = pcall(function()
				local st = {
					authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
					inform_url = "http://192.0.2.1:8080/inform", mac = "00:00:5e:00:53:10",
					ip = "192.0.2.100", hostname = "testap",
				}
				local d = cjson.decode(inform.build_json(st, nil, ufhw))
				local vap
				for _, v in ipairs(d.vap_table) do if v.essid == "test" then vap = v end end
				assert_eq(vap.num_sta, 2, "the VLAN client is counted")
				assert_eq(#vap.sta_table, 2, "and listed")
				assert_eq(#kicked, 1, "the -80 dBm VLAN client is below -70")
				assert_eq(kicked[1].mac, "00:00:5e:00:53:02", "that one")
				assert_eq(kicked[1].ifname, "wlan0", "through the VAP's hostapd, not wlan0-20")
				assert_eq(inform._last_vap_by_ifname["wlan0"], "openuf_test",
					"hostapd's events name the VAP")
				assert_nil(inform._last_vap_by_ifname["wlan0-20"], "never the VLAN netdev")
			end)
			inform._sysinfo.sta_table = orig_sta
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform json: Roaming Assistant watches a client on a key's VLAN through the VAP's hostapd",
		fn = function()
			-- usteer and hostapd know the BSS, not the VLAN netdev: an
			-- observation filed under wlan0-20 would find no local node and
			-- no ubus object to send the BSS Transition request to.
			inject_sysinfo(true)
			inject_ucihelper()
			local orig_sta = inform._sysinfo.sta_table
			inform._sysinfo.sta_table = function(ifname)
				if ifname == "wlan0-20" then
					return {{mac = "00:00:5e:00:53:02", signal = -80, connected_sec = 90, tx_packets = 1}}
				end
				return {}
			end
			inform._ucihelper.get_ifnames_for_vap = function(radio, ssid)
				if radio == "radio0" and ssid == "test" then return {"wlan0", "wlan0-20"} end
				return {}
			end
			inform._ucihelper.bss_ifname = function(ifname)
				return ifname == "wlan0-20" and "wlan0" or ifname
			end
			local base = inform._ucihelper.get_vap_table
			inform._ucihelper.get_vap_table = function()
				local v = base()
				v[1].roam_assist_rssi = -70
				return v
			end
			local ok, err = pcall(function()
				local st = {
					authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
					inform_url = "http://192.0.2.1:8080/inform", mac = "00:00:5e:00:53:10",
					ip = "192.0.2.100", hostname = "testap",
				}
				inform.build_json(st, nil, ufhw)
				assert_eq(#inform._roam_obs, 1, "the VLAN client is observed")
				assert_eq(inform._roam_obs[1].mac, "00:00:5e:00:53:02", "that one")
				assert_eq(inform._roam_obs[1].ifname, "wlan0", "under the VAP's BSS, not wlan0-20")
			end)
			inform._sysinfo.sta_table = orig_sta
			inform._roam_obs = nil
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform json: no stations kicked when the radio's minrssi is disabled",
		fn = function()
			inject_sysinfo(true)
			inject_ucihelper()  -- default mock radio_table has no min_rssi_enabled
			local kicked = {}
			inform._ucihelper.kick_station = function(ifname, mac)
				kicked[#kicked + 1] = {ifname = ifname, mac = mac}
			end
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap",
			}
			inform.build_json(st, nil, ufhw)
			assert_eq(#kicked, 0, "no stations kicked when minrssi is not enabled")
		end
	},
	{
		name = "inform json: Roaming Assistant gets one observation per station of its vap, and the threshold never leaks",
		fn = function()
			inject_sysinfo(true)  -- two stations on wlan0: -62 dBm (3600 s) and -75 dBm (42 s)
			inject_ucihelper()
			local base = inform._ucihelper.get_vap_table
			inform._ucihelper.get_vap_table = function()
				local v = base()
				v[1].roam_assist_rssi = -70
				return v
			end
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://192.0.2.1:8080/inform", mac = "00:00:5e:00:53:10",
				ip = "192.0.2.100", hostname = "testap",
			}
			local cfg = {config = {roam_assist_diff_db = 6}}
			local d = cjson.decode(inform.build_json(st, cfg, ufhw))
			local seen = inform._roam_obs
			assert_eq(#seen, 2, "both stations observed")
			local o
			for _, x in ipairs(seen) do if x.signal == -75 then o = x end end
			assert_true(o ~= nil, "the -75 dBm station is among them")
			assert_eq(o.ifname, "wlan0", "live ifname")
			assert_eq(o.ssid, "test", "vap essid")
			assert_eq(o.connected_sec, 42, "connected time")
			assert_eq(o.threshold, -70, "the vap's threshold")
			assert_nil(d.vap_table[1].roam_assist_rssi, "internal threshold stripped from the payload")

			-- The loop's pass hands them over once, with the configured margin.
			local got, got_now, got_opts
			local orig = inform._roamassist
			inform._roamassist = {tick = function(obs, now, opts)
				got, got_now, got_opts = obs, now, opts
				return 0
			end}
			inform._roamassist_tick(cfg)
			local again = false
			inform._roamassist.tick = function() again = true end
			inform._roamassist_tick(cfg)
			inform._roamassist = orig
			assert_eq(got, seen, "this heartbeat's observations")
			assert_true(type(got_now) == "number", "a clock")
			assert_eq(got_opts.diff_db, 6, "roam_assist_diff_db passed through")
			assert_false(again, "consumed: a second pass without a new build does nothing")
		end
	},
	{
		name = "inform json: a station minrssi kicks is not also a Roaming Assistant observation",
		fn = function()
			inject_sysinfo(true)
			inject_ucihelper()
			inform._ucihelper.get_radio_table = function()
				return {
					{ name = "radio0", radio = "ng", channel = "6",
					  min_rssi_enabled = true, min_rssi_raw = 25 },  -- -70 dBm
				}
			end
			inform._ucihelper.kick_station = function() end
			local base = inform._ucihelper.get_vap_table
			inform._ucihelper.get_vap_table = function()
				local v = base()
				v[1].roam_assist_rssi = -70
				return v
			end
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://192.0.2.1:8080/inform", mac = "00:00:5e:00:53:10",
				ip = "192.0.2.100", hostname = "testap",
			}
			inform.build_json(st, nil, ufhw)
			assert_eq(#inform._roam_obs, 1, "only the station minrssi left alone")
			assert_eq(inform._roam_obs[1].signal, -62, "the -62 dBm one")
			inform._roam_obs = nil
		end
	},
	{
		name = "inform json: no Roaming Assistant pass when no vap has it on",
		fn = function()
			inject_sysinfo(true)
			inject_ucihelper()
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://192.0.2.1:8080/inform", mac = "00:00:5e:00:53:10",
				ip = "192.0.2.100", hostname = "testap",
			}
			inform.build_json(st, nil, ufhw)
			assert_eq(#inform._roam_obs, 0, "nothing observed")
			local called = false
			local orig = inform._roamassist
			inform._roamassist = {tick = function() called = true end}
			inform._roamassist_tick(nil)
			inform._roamassist = orig
			assert_false(called, "tick not called")
		end
	},
	{
		name = "inform json: empty list fields serialize as JSON arrays, not objects",
		fn = function()
			-- cjson encodes an empty Lua table as {} (a JSON object); the
			-- controller's DTOs type these fields as lists. Only a raw-string
			-- assertion can see the difference -- every other test in this
			-- file decodes first, which erases exactly this distinction.
			inject_sysinfo(false)
			-- A previously injected _ucihelper mock would populate the very
			-- tables this test needs empty -- park it for the duration.
			local orig_uci = inform._ucihelper
			inform._ucihelper = nil
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap",
			}
			local ok, json_str = pcall(inform.build_json, st, nil, ufhw)
			inform._ucihelper = orig_uci
			assert_true(ok, "build_json succeeded: " .. tostring(json_str))
			for _, field in ipairs({"vap_table", "radio_table", "radio_table_stats",
					"scan_radio_table", "lldp_table"}) do
				assert_contains(json_str, '"' .. field .. '":[]',
					field .. " serializes as an empty ARRAY")
			end
		end
	},
	{
		name = "inform json: _fix_empty_arrays rewrites {} to [] on old-cjson targets",
		fn = function()
			-- The validation container's lua-cjson has neither empty_array_mt
			-- nor the empty_array sentinel, so the metatable route degrades
			-- to {} exactly on the real target -- the string post-pass is
			-- what actually fixes the wire there. Pin it directly.
			local fixed = inform._fix_empty_arrays(
				'{"vap_table":{},"sta_table":{},"x":1,"nested":{"mac_table":{}}}')
			assert_eq(fixed,
				'{"vap_table":[],"sta_table":[],"x":1,"nested":{"mac_table":[]}}',
				"every known list field rewritten, other keys untouched")
			-- A non-list field named similarly must be untouched, and a quoted
			-- occurrence inside a STRING VALUE cannot match (cjson escapes the
			-- quotes there).
			local hostile = '{"ssid":"evil\\"sta_table\\":{}","sta_table":{}}'
			assert_eq(inform._fix_empty_arrays(hostile),
				'{"ssid":"evil\\"sta_table\\":{}","sta_table":[]}',
				"escaped quotes inside string values never match")
		end
	},
	{
		name = "inform json: country_code derived from the radio's UCI regdomain",
		fn = function()
			inject_sysinfo(false)
			inject_ucihelper()
			inform._ucihelper.get_radio_table = function()
				return {
					{ name = "radio0", radio = "ng", channel = 6, country = "CZ" },
				}
			end
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap",
			}
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			assert_eq(d.country_code, 203, "UCI country=CZ -> ISO numeric 203 (was hardcoded 840)")
			assert_nil(d.radio_table[1].country, "internal country field stripped from the payload")
		end
	},
	{
		name = "inform json: country_code falls back to 840 without a UCI regdomain",
		fn = function()
			local d = build({with_uci = true})
			assert_eq(d.country_code, 840, "no country option anywhere -> historic US default")
		end
	},
	{
		name = "inform json: ACS radio's band is re-derived from the live channel (real ucihelper)",
		fn = function()
			-- The inject_ucihelper mock hardcodes radio="ng" and so bypasses
			-- the real band derivation entirely -- this test wires the REAL
			-- ucihelper to a minimal mock cursor instead. Worst case on
			-- purpose: UCI holds only channel=auto (no band, no hwmode), for
			-- which the config-first derivation still guesses "na" -- but the
			-- live iw fixture has negotiated channel 6, which must win.
			-- Pre-fix the payload reported this 2.4GHz radio as "na" (5GHz).
			inject_sysinfo(false, false, false, true)  -- with_radio_caps
			local real_uci = dofile("src/openwrt/ucihelper.lua")
			local sections = {
				{[".name"] = "radio0", [".type"] = "wifi-device", channel = "auto"},
				{[".name"] = "openuf_radio0_test", [".type"] = "wifi-iface",
				 device = "radio0", ssid = "test", encryption = "psk2"},
			}
			real_uci._uci = {cursor = function() return {
				foreach = function(_, config, stype, fn)
					if config ~= "wireless" then return end
					for _, s in ipairs(sections) do
						if s[".type"] == stype then fn(s) end
					end
				end,
				get = function() return nil end,
				set = function() end,
				delete = function() end,
				commit = function() end,
			} end}
			real_uci._popen = function(cmd)
				if cmd:find("network.wireless", 1, true) then
					return '{"radio0":{"interfaces":[{"ifname":"wlan0"}]}}'
				end
				return ""
			end
			real_uci._read_file = function() return nil end
			real_uci._run_cmd = function() return true end

			local orig = inform._ucihelper
			inform._ucihelper = real_uci
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap",
			}
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			inform._ucihelper = orig
			assert_eq(d.radio_table[1].channel, 6, "live negotiated channel reported, not 'auto'")
			assert_eq(d.radio_table[1].radio, "ng", "band re-derived from the live channel")
			-- The vap inherits the same live correction -- its UCI echo was
			-- the literal string "auto" here, and used to go out as-is.
			assert_eq(d.vap_table[1].channel, 6, "vap channel overridden with the live value")
			assert_eq(d.vap_table[1].radio, "ng", "vap band matches the corrected radio band")
			-- tx_power has the same UCI-echo problem: the option is absent
			-- while Transmit Power is Auto, so both copies stayed nil.
			assert_eq(d.radio_table[1].tx_power, 20, "radio reports the live driver TX power")
			assert_eq(d.vap_table[1].tx_power, 20, "and the vap inherits the same correction")
		end
	},
	{
		name = "inform json: a 5GHz ACS radio's band re-derives to na from the live channel",
		fn = function()
			-- The na twin of the "ng" re-derivation test above: without it an
			-- inverted band mapping on the 5GHz side passes the whole suite.
			-- Same real-ucihelper wiring, but the live iw fixture negotiated
			-- channel 36 (5180 MHz).
			inject_sysinfo(false, false, false, true)
			inform._sysinfo._run_cmd = function(cmd)
				if cmd:find("dev wlan0 info") then return fixture("iw_dev_info_5g.txt") end
				if cmd:find("phy#0 info", 1, true) then return fixture("iw_phy_info_5g.txt") end
				return ""
			end
			local real_uci = dofile("src/openwrt/ucihelper.lua")
			local sections = {
				{[".name"] = "radio1", [".type"] = "wifi-device", channel = "auto"},
			}
			real_uci._uci = {cursor = function() return {
				foreach = function(_, config, stype, fn)
					if config ~= "wireless" then return end
					for _, s in ipairs(sections) do
						if s[".type"] == stype then fn(s) end
					end
				end,
				get = function() return nil end,
				set = function() end,
				delete = function() end,
				commit = function() end,
			} end}
			real_uci._popen = function(cmd)
				if cmd:find("network.wireless", 1, true) then
					return '{"radio1":{"interfaces":[{"ifname":"wlan0"}]}}'
				end
				return ""
			end
			real_uci._read_file = function() return nil end
			real_uci._run_cmd = function() return true end

			local orig = inform._ucihelper
			inform._ucihelper = real_uci
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap",
			}
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			inform._ucihelper = orig
			assert_eq(d.radio_table[1].channel, 36, "live negotiated 5GHz channel reported")
			assert_eq(d.radio_table[1].radio, "na", "band re-derived to na from channel 36")
		end
	},
	{
		name = "inform json: radio_table carries spectrum_table, one entry per width, and its age",
		fn = function()
			local orig_time = inform._time
			inform._time = function() return 1111 end
			inform._spectrum_cache = {
				radio0 = {
					table = { { channel = 6, center_freq = 2437, utilization = 37, interference = -95 } },
					table_time = 1000,
				},
			}
			local d = build({with_uci = true, with_clients = true})
			inform._time = orig_time
			inform._spectrum_cache = {}
			local r = d.radio_table[1]
			-- The controller builds radio_table_stats from radio_table and
			-- reads spectrum_table there; in radio_table_stats it is dropped.
			assert_nil(d.radio_table_stats[1].spectrum_table, "not on radio_table_stats")
			assert_eq(d.spectrum_scanning, false, "spectrum_scanning false once results are cached")
			assert_nil(d.spectrum_scan_timestamp, "the controller stamps the scan itself")
			assert_eq(r.spectrum_table_time, 111, "spectrum_table_time is the scan's age in seconds")
			local widths = {}
			for _, e in ipairs(r.spectrum_table) do
				assert_eq(e.channel, 6, "every entry is the channel's reading")
				assert_eq(e.utilization, 37, "with its utilization")
				widths[#widths + 1] = e.width
			end
			local want = r.radio == "ng" and "20,40" or "20,40,80"
			assert_eq(table.concat(widths, ","):sub(1, #want), want, "one entry per width the band offers")
		end
	},
	{
		name = "payload: spectrum_table lists each reading at every width up to the radio's",
		fn = function()
			local ufp = require("unifi.payload")
			local function widths(band, w)
				local out = {}
				for _, e in ipairs(ufp.spectrum_table({{channel = 36}}, band, w)) do out[#out + 1] = e.width end
				return table.concat(out, ",")
			end
			assert_eq(widths("ng", 20), "20,40", "2.4 GHz: 20 and 40")
			assert_eq(widths("ng", 40), "20,40", "2.4 GHz at HT40 adds nothing")
			assert_eq(widths("na", 20), "20,40,80", "5 GHz: 20/40/80 whatever the radio runs")
			assert_eq(widths("na", 160), "20,40,80,160", "up to a wider configured width")
			assert_eq(widths("6e", 320), "20,40,80,160,320", "6 GHz at 320")
			assert_eq(#ufp.spectrum_table(nil, "na", 80), 0, "no rows, no entries")
		end
	},
	{
		name = "inform json: quickscan_scanning is true exactly while a quick-scan is pending",
		fn = function()
			-- devmgr.kDxteQiUX reads the top-level flag on every inform and
			-- takes absent as false: the scan is over the moment it is.
			local orig = inform._quickscan_pending
			inform._quickscan_pending = nil
			local idle = build({with_uci = true})
			inform._quickscan_pending = {band = "ng"}
			local busy = build({with_uci = true})
			inform._quickscan_pending = orig
			assert_eq(idle.quickscan_scanning, false, "no scan: false")
			assert_eq(busy.quickscan_scanning, true, "pending scan: true")
		end
	},
	{
		name = "inform json: spectrum_scanning is true exactly while a spectrum-scan sweep has chunks left",
		fn = function()
			local orig = inform._scan_jobs
			inform._scan_jobs = {}
			local idle = build({with_uci = true})
			inform._scan_jobs = {{who = "quick-scan", radio = {name = "radio0"}}}
			local other = build({with_uci = true})
			inform._scan_jobs = {{who = "spectrum-scan", radio = {name = "radio0"}}}
			local busy = build({with_uci = true})
			inform._scan_jobs = orig
			assert_eq(idle.spectrum_scanning, false, "no sweep: false")
			assert_eq(other.spectrum_scanning, false, "a quick-scan's sweep is not a spectrum-scan")
			assert_eq(busy.spectrum_scanning, true, "spectrum-scan sweep queued: true")
		end
	},
	{
		name = "inform json: radio_table omits spectrum_table without a prior spectrum-scan cmd",
		fn = function()
			inform._spectrum_cache = {}
			local d = build({with_uci = true, with_clients = true})
			assert_true(d.radio_table[1].spectrum_table == nil,
				"no spectrum_table until a spectrum-scan cmd has run")
		end
	},
	{
		name = "inform json: radio_table includes capability defaults",
		fn = function()
			local d = build({with_uci = true})
			assert_eq(d.radio_table[1].builtin_ant_gain, 3, "builtin_ant_gain")
			assert_eq(d.radio_table[1].max_txpower, 20, "max_txpower")
		end
	},
	{
		name = "inform json: radio_table carries hardware capability fields from iw phy info",
		fn = function()
			-- Confirmed via decompile (com.ubnt.service.devmgr.PGOcbDWlbnYQdFW,
			-- copyAttrsIfPresent): the controller reads nss/is_11ac/is_11ax/
			-- is_11be/has_dfs/has_fccdfs/has_ht160 directly off each radio_table
			-- entry, independent of radio_caps/radio_caps2 -- without these,
			-- the Radios (channel-planning) tab's MIMO/capability filters
			-- excluded the device entirely, "We Couldn't Find a Match".
			inject_sysinfo(false, false, false, true)
			inject_ucihelper()
			-- Mock channel deliberately 11 while the iw fixture negotiated 6:
			-- with both at 6 (the old shape) the "live overrides UCI" claim
			-- below was indistinguishable from a plain echo of the mock.
			inform._ucihelper.get_radio_table = function()
				return {
					{ name = "radio0", radio = "ng", channel = 11, ht = "HT20", tx_power = "20",
					  disabled = false, builtin_antenna = true, builtin_ant_gain = 3,
					  max_txpower = 20 },
				}
			end
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap",
			}
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			local r = d.radio_table[1]
			assert_true(r.is_11ac, "VHT Capabilities present in the 5GHz fixture")
			assert_true(r.is_11ax, "HE PHY Capabilities present")
			assert_false(r.is_11be, "no EHT PHY Capabilities in the fixture")
			assert_true(r.has_dfs, "radar detection present on several channels")
			assert_true(r.has_fccdfs, "has_fccdfs mirrors has_dfs")
			assert_true(r.has_ht160, "'Supported Channel Width: 160 MHz, 80+80 MHz'")
			assert_eq(r.nss, 2, "nss from 'HT TX Max spatial streams: 2'")
			assert_eq(r.channel, 6, "live channel from 'iw dev' overrides UCI's 11")
		end
	},
	{
		name = "inform json: radio_table entries carry the correct radio_caps MIMO bitmask",
		fn = function()
			-- radio_caps is a genuine separate integer field (confirmed via
			-- decompile, `uCthhvfQNZ3.getInt("radio_caps", 0)`), not the
			-- flattened is_11ac/nss/etc. booleans -- openUF previously always
			-- left it at the controller's own default of 0, which is why the
			-- Radios tab's MIMO column stayed blank and its 1x1-4x4 filter
			-- excluded every radio outright ("We Couldn't Find a Match").
			-- The bit layout is NOT "value == nss" (confirmed live: sending
			-- radio_caps=2 for a 2x2 radio still showed blank/excluded) --
			-- it's a bitmask, reverse engineered by calling the controller's
			-- own live MIMO decoder (webpack module 927316's `e7` export)
			-- directly with a sweep of single-bit values: bit 3 (0x8) ->
			-- "1x1", bit 4 (0x10) -> "2x2", bit 5 (0x20) -> "3x3", bit 26
			-- (0x4000000) -> "4x4", checked highest-first when multiple bits
			-- are set. Confirmed live end-to-end 2026-07-14: a genuinely 2x2
			-- radio_caps=0x10 now renders "2x2" in the MIMO column and is
			-- included by the 2x2 filter checkbox.
			local d = build({with_uci = true, with_radio_caps = true})
			local r = d.radio_table[1]
			assert_eq(r.nss, 2, "fixture radio is 2x2 (nss=2)")
			assert_eq(r.radio_caps, 0x10, "radio_caps carries the bit 4 (0x10) MIMO flag for a 2x2 radio")
		end
	},
	{
		name = "inform json: radio_table carries radio_caps2 bits 0x1 (WPA3), 0x2 (WPA3 FT), 0x8 (OWE)",
		fn = function()
			-- This bit is the ONLY thing that makes the controller provision
			-- WPA3/SAE to a device. Traced through the 10.4.57 bytecode:
			-- the config generator (QSAkfnbfInKJ) calls radio.CVir(), which
			-- is (1 & ZPjpXpgFhJSgqk().orElse(0)) == 1; that accessor returns
			-- impl field iBjnA, fed from builder field SuUD, whose only
			-- setter the radio parser calls with getInt("radio_caps2").
			-- radio_caps goes somewhere else entirely (builder kJeOrfqt ->
			-- impl DbisCuTqoItCGd -> accessor FJaWnIAautY, the MIMO column).
			--
			-- Confirmed live end-to-end 2026-08-01 on real hardware: with
			-- this field absent every WPA3 WLAN was silently downgraded to
			-- WPA-PSK; adding it flipped the very next push to
			-- wpa.key.1.mgmt=SAE + wpa3.support/transition + sae.*, and both
			-- APs came up with hostapd key_mgmt "SAE FT-SAE WPA-PSK
			-- WPA-PSK-SHA256 FT-PSK". Losing this bit re-breaks WPA3
			-- entirely, and nothing else on the wire would say so.
			-- Gated on real SAE support, so both arms are pinned: claiming
			-- the bit on a build whose hostapd cannot do SAE would make the
			-- controller push a config the radio then fails to start.
			local prev = inform._sysinfo._sae_supported_cache
			local prev_owe = inform._sysinfo._owe_supported_cache
			inform._sysinfo._sae_supported_cache = true
			inform._sysinfo._owe_supported_cache = false
			local d = build({with_uci = true, with_radio_caps = true})
			assert_eq(#d.radio_table > 0, true, "fixture produced radios")
			for _, r in ipairs(d.radio_table) do
				assert_eq(r.radio_caps2 % 2, 1,
					"SAE-capable: radio_caps2 bit 0x1 set, so the controller provisions WPA3")
				-- Bit 0x2 is FT with WPA3. Without it the controller forces
				-- wpa3.ft.status=disabled on every SAE WLAN, and ft.status too
				-- on WPA3-only ones (lab capture, 2026-09-27).
				assert_eq(math.floor(r.radio_caps2 / 2) % 2, 1,
					"SAE-capable: radio_caps2 bit 0x2 set, so 802.11r survives on WPA3")
				assert_eq(r.radio_caps2, 0x3,
					"no other radio_caps2 bit claimed: each one needs an implementation")
			end

			inform._sysinfo._sae_supported_cache = false
			local d2 = build({with_uci = true, with_radio_caps = true})
			for _, r in ipairs(d2.radio_table) do
				assert_eq(r.radio_caps2, 0,
					"no SAE: the bit is NOT claimed, so no unrunnable config is pushed")
				assert_eq(r.owe_supported, false, "no OWE: owe_supported stays false")
			end

			-- Bit 0x8 is Enhanced Open, probed on its own: without it an OWE
			-- WLAN is not provisioned at all, and a transition one goes out
			-- as plain open (lab capture, 2026-09-27).
			inform._sysinfo._sae_supported_cache = true
			inform._sysinfo._owe_supported_cache = true
			local d3 = build({with_uci = true, with_radio_caps = true})
			for _, r in ipairs(d3.radio_table) do
				assert_eq(r.radio_caps2, 0xB, "SAE + OWE: 0x1 | 0x2 | 0x8")
				assert_eq(r.owe_supported, true, "owe_supported follows the same probe")
			end
			inform._sysinfo._sae_supported_cache = false
			local d4 = build({with_uci = true, with_radio_caps = true})
			for _, r in ipairs(d4.radio_table) do
				assert_eq(r.radio_caps2, 0x8, "OWE does not depend on SAE")
			end
			inform._sysinfo._sae_supported_cache = prev
			inform._sysinfo._owe_supported_cache = prev_owe
		end
	},
	{
		name = "inform json: a sibling openUF AP's BSS is tagged is_unifi + serialno",
		fn = function()
			-- The controller (10.6.101, com.ubnt.service.aS.rhAW) never checks
			-- a scanned BSSID against the site's vap_tables: an entry without
			-- is_unifi whose SSID is one of the site's is a rogue, full stop.
			-- is_unifi + serialno resolves to the adopted device instead.
			local d = build({with_uci = true, with_scan = "peer"})
			local st = d.scan_radio_table[1].scan_table
			assert_eq(st[1].is_unifi, true, "the sibling is a UniFi AP")
			assert_eq(st[1].serialno, "00:00:5e:00:53:20", "resolved by its identity MAC, not its BSSID")
			assert_eq(st[2].is_unifi, nil, "no IE of ours: left for the controller's rogue check")
			assert_eq(st[2].serialno, nil, "...with no serialno")
		end
	},
	{
		name = "inform json: a BSSID a sibling announced on the LAN is tagged without its IE",
		fn = function()
			-- An 802.11k-reported entry carries only a BSSID, never the
			-- vendor element; the BSSIDs siblings broadcast (siblings.lua)
			-- are what identify it. Stale announcements must not count.
			local now = os.time()
			siblings_json = cjson.encode({
				["11:22:33:44:55:66"] = {mac = "00:00:5e:00:53:21", seen = now - 10,
					model = "U6PRO", model_display = "U6-Pro"},
				["aa:bb:cc:dd:ee:01"] = {mac = "00:00:5e:00:53:22", seen = now - 3600},
			})
			local ok, d = pcall(build, {with_uci = true, with_scan = true})
			siblings_json = nil
			assert_true(ok, tostring(d))
			local st = d.scan_radio_table[1].scan_table
			assert_eq(st[2].bssid, "11:22:33:44:55:66", "fixture order")
			assert_eq(st[2].is_unifi, true, "announced BSSID is a sibling's")
			assert_eq(st[2].serialno, "00:00:5e:00:53:21", "serialno is the sibling's identity MAC")
			assert_eq(st[2].model, "U6PRO", "the sibling's model, for the controller's sighting")
			assert_eq(st[2].model_display, "U6-Pro", "and its display name")
			assert_eq(st[1].is_unifi, nil, "an announcement an hour old is forgotten")
		end
	},
	{
		name = "inform json: scan_radio_table reports neighboring networks per radio",
		fn = function()
			-- Confirmed real field names via the decompiled controller's
			-- ingestion DTOs (com.ubnt.service.aO.bLwwMKkr, literally named
			-- "PeerScan", and its consumer com.ubnt.service.aO.hhFgUVZPT) --
			-- a top-level scan_radio_table, one entry per radio, each
			-- carrying that radio's own scan_table list. Feeds Insights ->
			-- AirView -> Environment (stat/rogueap), distinct from the
			-- RF/spectrum-scan cmd's channel-utilization-only spectrum_table.
			-- Confirmed live 2026-07-14: the wire field is `age` (elapsed
			-- seconds), NOT `last_seen` -- the controller computes the
			-- absolute last_seen itself as (report_time - age), and drops
			-- any entry with age >= 30 as stale before it ever reaches the
			-- rogue-AP list, so sending an absolute timestamp under either
			-- name is silently ignored.
			local d = build({with_uci = true, with_scan = true})
			assert_eq(#d.scan_radio_table, 1, "one scan_radio_table entry (one configured radio)")
			local srt = d.scan_radio_table[1]
			assert_eq(srt.radio, "ng", "radio band from radio_table entry")
			assert_eq(srt.name, "radio0", "radio device name from radio_table entry")
			assert_eq(#srt.scan_table, 2, "two neighbor networks from the fixture")
			assert_eq(srt.scan_table[1].bssid, "aa:bb:cc:dd:ee:01", "first neighbor bssid")
			assert_eq(srt.scan_table[1].mac, "aa:bb:cc:dd:ee:01", "first neighbor mac mirrors bssid")
			assert_eq(srt.scan_table[1].band, "ng", "first neighbor band mirrors the parent radio's band")
			assert_eq(srt.scan_table[1].essid, "NeighborNet", "first neighbor essid")
			assert_eq(srt.scan_table[1].channel, 6, "first neighbor channel")
			assert_eq(srt.scan_table[1].signal, -55, "first neighbor signal")
			assert_eq(srt.scan_table[1].rssi, -55, "first neighbor rssi mirrors signal")
			assert_eq(srt.scan_table[1].security, "wpa2", "first neighbor security")
			assert_eq(srt.scan_table[1].age, 0, "first neighbor age (elapsed seconds, not a timestamp)")
			assert_eq(srt.scan_table[1].bw, 40, "first neighbor bw (Environment tab's Ch. Width column reads this directly)")
			assert_eq(srt.scan_table[2].bw, 20, "second neighbor bw defaults to 20 when iw reports no width")
			assert_eq(srt.scan_table[2].essid, "OpenGuestWifi", "second neighbor essid")
			assert_eq(srt.scan_table[2].security, "open", "second neighbor security")
		end
	},
	{
		name = "inform json: 802.11k beacon reports enrich scan_radio_table",
		fn = function()
			-- The whole point of rrmscan.lua: the passive `iw scan dump` cache
			-- only ever holds neighbours on the channel the radio is already
			-- serving, so BSSes a CLIENT saw off-channel have to reach the
			-- payload through here or they reach it not at all.
			local prev = inform._rrm_neighbours
			inform._rrm_neighbours = {
				-- a BSS the passive scan already found -- must NOT be
				-- duplicated, and must keep the scan's richer record
				{bssid = "aa:bb:cc:dd:ee:01", channel = 6, band = "ng",
				 signal = -70, seen_at = os.time()},
				-- one only the client could see
				{bssid = "00:00:5e:00:53:11", channel = 1, band = "ng",
				 signal = -73, seen_at = os.time()},
				-- and one on the other band, which belongs to no radio here
				{bssid = "00:00:5e:00:53:17", channel = 48, band = "na",
				 signal = -80, seen_at = os.time()},
			}
			local ok, d = pcall(build, {with_uci = true, with_scan = true})
			inform._rrm_neighbours = prev
			assert_true(ok, "build_json survives the merge")

			local srt = d.scan_radio_table[1]
			assert_eq(srt.radio, "ng", "the 2.4 GHz radio")
			local seen = {}
			for _, e in ipairs(srt.scan_table) do
				assert_nil(seen[e.bssid], "no BSSID appears twice: " .. tostring(e.bssid))
				seen[e.bssid] = e
			end
			assert_eq(#srt.scan_table, 3, "two scanned + one client-only neighbour")
			assert_eq(seen["aa:bb:cc:dd:ee:01"].essid, "NeighborNet",
				"the scanned record wins over the beacon report")
			assert_eq(seen["aa:bb:cc:dd:ee:01"].signal, -55, "and keeps its own signal")
			local added = seen["00:00:5e:00:53:11"]
			assert_not_nil(added, "the client-only neighbour reached the payload")
			assert_eq(added.channel, 1, "on the channel the client reported")
			assert_eq(added.signal, -73, "with the RCPI-derived signal")
			-- Without `band` the Environment tab filters the row out upstream
			-- of every visible filter, with no error and no visible cause.
			assert_eq(added.band, "ng", "band set or the row silently vanishes")
			assert_nil(seen["00:00:5e:00:53:17"],
				"a 5 GHz sighting is not filed under the 2.4 GHz radio")
		end
	},
	{
		-- A client reports the AP it sits on and its sibling APs like any
		-- other BSS. Listed, the AP showed up as its own neighbour. A sibling
		-- is tagged from the BSSIDs siblings announce; any other BSS carrying
		-- the site's SSID would be flagged as an impersonating rogue.
		name = "inform json: beacon reports of this AP are skipped; siblings are tagged and keep their SSID",
		fn = function()
			local prev_n, prev_sib = inform._rrm_neighbours, inform._sysinfo.sibling_bssids
			inform._rrm_neighbours = {
				{bssid = "00:00:5e:00:53:01", channel = 1, band = "ng", signal = -11,
				 seen_at = os.time(), essid = "SiteNet", security = "wpa2"},
				{bssid = "00:00:5e:00:53:02", channel = 11, band = "ng", signal = -60,
				 seen_at = os.time(), essid = "SiteNet", security = "wpa2"},
				{bssid = "00:00:5e:00:53:03", channel = 11, band = "ng", signal = -70,
				 seen_at = os.time(), essid = "SiteNet", security = "wpa2"},
				{bssid = "00:00:5e:00:53:04", channel = 6, band = "ng", signal = -80,
				 seen_at = os.time(), essid = "Elsewhere", security = "wpa2", bw = 40},
			}
			inform._sysinfo.sibling_bssids = function()
				return {["00:00:5e:00:53:02"] = "00:00:5e:00:53:20"}, {}
			end
			local ok, d = pcall(build, {with_uci = true, vap_patch = function(vaps)
				vaps[1].bssid, vaps[1].essid = "00:00:5E:00:53:01", "SiteNet"
			end})
			inform._rrm_neighbours, inform._sysinfo.sibling_bssids = prev_n, prev_sib
			assert_true(ok, "build_json survives: " .. tostring(d))
			local seen = {}
			for _, e in ipairs(d.scan_radio_table[1].scan_table) do seen[e.bssid] = e end
			assert_nil(seen["00:00:5e:00:53:01"], "this AP's own BSSID is skipped")
			local sib = seen["00:00:5e:00:53:02"]
			assert_true(sib and sib.is_unifi == true, "a sibling is tagged is_unifi")
			assert_eq(sib.serialno, "00:00:5e:00:53:20", "with its device MAC")
			assert_eq(sib.essid, "SiteNet", "and keeps the site's SSID")
			assert_not_nil(seen["00:00:5e:00:53:03"], "an unknown BSS is still listed")
			assert_nil(seen["00:00:5e:00:53:03"].essid, "but not with the site's SSID")
			assert_eq(seen["00:00:5e:00:53:04"].essid, "Elsewhere", "a foreign SSID is carried")
			assert_eq(seen["00:00:5e:00:53:04"].bw, 40, "with its width")
		end
	},
	{
		name = "inform json: stale beacon reports never reach the payload",
		fn = function()
			-- The controller drops any entry with age >= 30 before it reaches
			-- the rogue-AP list, so carrying one is payload nobody reads.
			local prev = inform._rrm_neighbours
			inform._rrm_neighbours = {
				{bssid = "00:00:5e:00:53:11", channel = 1, band = "ng",
				 signal = -73, seen_at = os.time() - 120},
			}
			local ok, d = pcall(build, {with_uci = true, with_scan = true})
			inform._rrm_neighbours = prev
			assert_true(ok, "build_json survives")
			assert_eq(#d.scan_radio_table[1].scan_table, 2,
				"only the two scanned neighbours; the stale sighting is dropped")
		end
	},
	{
		name = "inform json: scan_radio_table entries have empty scan_table with no neighbors detected",
		fn = function()
			local d = build({with_uci = true})
			assert_eq(#d.scan_radio_table, 1, "one scan_radio_table entry")
			assert_eq(#d.scan_radio_table[1].scan_table, 0, "no neighbors without fixtures")
		end
	},
	{
		name = "inform json: fw_caps sets the QCA-switch and OWRT-switch bits (0x110)",
		fn = function()
			-- Confirmed via decompiled controller 10.4.57: Device.hasQCASwitch()
			-- is hasFirmwareCapability(16) (gates the Ports view's projection
			-- of port_table), and Device.hasOWRTSwitch() is
			-- hasFirmwareCapability(256) (without it, the REST API's per-port
			-- VLAN validator rejects any port assignment with
			-- api.err.VlanTaggingUnsupportedByDevice -- see PROTOCOL-VALIDATION.md
			-- section 18).
			local d = build()
			assert_eq(d.fw_caps, 0x100110 + 0x1000 + 0x400000 + 0x20000000,
				"fw_caps bits 0x10 | 0x100, 0x100000 (RADIUS DAS), the WLAN Schedule "
				.. "pair 0x1000 | 0x400000 and 0x20000000 (RADIUS Filter-Id)")
		end
	},
	{
		name = "inform json: fw_caps claims Hotspot 2.0, SNMPv3 and MAC-based VLANs only where the device has them",
		fn = function()
			local base = 0x100110 + 0x1000 + 0x400000 + 0x20000000
			inject_sysinfo()
			inform._sysinfo._hs20_supported_cache = true
			local caps = inform._report.fw_caps(inform, nil)
			assert_eq(caps, base + 0x800000, "0x800000 with hostapd -vhs20")
			inform._sysinfo._hs20_supported_cache = false
			inform._snmp._cache = {}
			inform._snmp._read_file = function(path)
				if path == "/etc/init.d/snmpd" then return "#!/bin/sh /etc/rc.common\n" end
				if path == "/lib/apk/db/installed" then return "P:libnetsnmp-ssl\nV:5.9.4-r6\n\nP:snmpd-ssl\n" end
			end
			assert_eq(inform._report.fw_caps(inform, nil), base + 0x4000, "0x4000 with snmpd-ssl")
			inform._snmp._cache = {}
			inform._snmp._read_file = function(path)
				if path == "/etc/init.d/snmpd" then return "x" end
				if path == "/lib/apk/db/installed" then return "P:snmpd-nossl\n" end
			end
			assert_eq(inform._report.fw_caps(inform, nil), base, "no 0x4000 with snmpd-nossl (no privacy)")
			inform._snmp._cache = {}
			inform._snmp._read_file = function() return nil end
			inform._sysinfo._ppsk_supported_cache = true
			local signed = inform._report.fw_caps(inform, nil)
			assert_eq(signed, base + 0x80000000 - 4294967296,
				"bit 31 goes out as the Java int's negative value")
			assert_true(signed < 0, "negative on the wire")
			-- The JSON the controller parses carries it as a plain integer.
			local d = build()
			inform._sysinfo._ppsk_supported_cache = true
			local d2 = cjson.decode(inform.build_json({authkey = state.DEFAULT_KEY, adopted = false,
				cfgversion = "", inform_url = "http://192.0.2.1:8080/inform", mac = "00:00:5e:00:53:0f",
				ip = "192.0.2.100", hostname = "t"}, nil, ufhw))
			assert_eq(d2.fw_caps, signed, "build_json sends the signed value")
			assert_eq(d.fw_caps, base, "and nothing of it without the VLAN probe")
			assert_eq(inform._report.signed32(0x7fffffff), 0x7fffffff, "bit 31 clear: unchanged")
			inform._sysinfo._ppsk_supported_cache = false
		end
	},
	{
		name = "inform json: wifi_caps2 claims exactly the bits openUF implements",
		fn = function()
			-- A SEPARATE bitmask from fw_caps/wifi_caps; each bit gates a
			-- feature the controller will only push to a device claiming it.
			-- See PROTOCOL-VALIDATION.md for the bits this device does not
			-- implement and must not claim. One line per claimed bit:
			local claimed = {
				-- supportAdvertisingDeviceNameInBeacon() = hasWifiCapability2(64):
				-- wireless.<n>.advertise_ap_name ("Show AP Name in Beacon")
				0x40,
				-- supportsAssistedRoaming() = hasWifiCapability2(32):
				-- wireless.<n>.btm_disassoc.* (Roaming Assistant)
				0x20,
				-- supportsAcsDfs() = hasWifiCapability2(16):
				-- radio.<n>.blklst / radio.<n>.acsdfs (Auto-channel inputs)
				0x10,
				-- supportQuickScan() = hasWifiCapability2(128): `quick-scan`
				0x80,
				-- supportsMulticastSuppressor() = hasWifiCapability2(0x400000):
				-- wireless.<n>.multicast.suppressor
				0x400000,
				-- supportsRoamTopologyStats() = hasWifiCapability2(8192):
				-- sta_roam fed to the roaming detector, `success` no longer
				0x2000,
			}
			local want = 0
			for _, bit in ipairs(claimed) do want = want + bit end
			local d = build()
			assert_eq(d.wifi_caps2, want, "wifi_caps2 is exactly the claimed bits")
			-- supportNeighbourInScan() = hasWifiCapability2(512): only while a
			-- sibling-sighting scan is configured.
			local s = build({cfg = {config = {sibling_scan_interval = 1800}}})
			assert_eq(s.wifi_caps2, want + 0x200, "0x200 with sibling scans on")
			local i = build({cfg = {config = {idle_scan_interval = 1800, sibling_scan_interval = 0}}})
			assert_eq(i.wifi_caps2, want + 0x200, "0x200 with idle sweeps on")
			local x = build({cfg = {config = {sibling_scan_interval = 1800, idle_scan_interval = 0,
				sibling_exchange = false}}})
			assert_eq(x.wifi_caps2, want, "sibling scans without the exchange have nothing to listen for")
			-- No connection events, no roam topology.
			local n = build({cfg = {config = {sta_events = false}}})
			assert_eq(n.wifi_caps2, want - 0x2000, "0x2000 off with sta_events off")
		end
	},
	{
		name = "inform json: wifi_caps claims band steering (0x4) and per-VAP pairs (0x8)",
		fn = function()
			-- Device.supportBandsteering() is hasWifiCapability(4): without it
			-- the device-level bandsteering.* block is never emitted.
			-- supportVapBasedBandsteering() (8) keeps it on when some WLAN has
			-- no 2.4/5 GHz pair. Checked bit by bit: other bits are claimed
			-- for other features, each with its own test.
			local d = build()
			assert_eq(type(d.wifi_caps), "number", "wifi_caps sent")
			assert_eq(math.floor(d.wifi_caps / 0x4) % 2, 1, "bit 0x4 set")
			assert_eq(math.floor(d.wifi_caps / 0x8) % 2, 1, "bit 0x8 set")
		end
	},
	{
		name = "inform json: wifi_caps claims Lock to Access Point (0x1000000)",
		fn = function()
			-- Device.supportLockAp() is hasWifiCapability(0x1000000); the site
			-- offers the client setting only while every wireless device has
			-- it. The lock arrives as macacl entries hostapd enforces.
			local d = build()
			assert_eq(math.floor(d.wifi_caps / 0x1000000) % 2, 1, "bit 0x1000000 set")
		end
	},
	{
		name = "inform json: wifi_caps claims Airtime Fairness (0x20) only where airtime_flags can be switched",
		fn = function()
			-- supportATFConfig() is hasWifiCapability(32): without it the
			-- controller sends no atf.* block at all. The other wifi_caps bits
			-- gate features openUF does not implement (PROTOCOL-VALIDATION.md,
			-- Capability bitmasks).
			local off = build()
			local orig = inform._airtime.supported
			inform._airtime.supported = function() return true end
			local ok, on = pcall(build)
			inform._airtime.supported = orig
			if not ok then error(on, 0) end
			assert_eq(off.wifi_caps % 0x40 - off.wifi_caps % 0x20, 0, "no debugfs switch: 0x20 clear")
			assert_eq(on.wifi_caps % 0x40 - on.wifi_caps % 0x20, 0x20, "airtime_flags present: 0x20 set")
			assert_eq(on.wifi_caps - off.wifi_caps, 0x20, "and nothing else moves with it")
		end
	},
	{
		name = "inform json: wifi_caps claims Private Pre-Shared Keys (0x100000) only where hostapd can do per-key VLANs",
		fn = function()
			-- supportWpaPpsk() is hasWifiCapability(0x100000): without it a
			-- WLAN with Private Pre-Shared Keys is skipped entirely.
			local off = build()
			local orig = inform._sysinfo.ppsk_supported
			inform._sysinfo.ppsk_supported = function() return true end
			local ok, on = pcall(build)
			inform._sysinfo.ppsk_supported = orig
			if not ok then error(on, 0) end
			local function bit(v) return v % 0x200000 - v % 0x100000 end
			assert_eq(bit(off.wifi_caps), 0, "no VLAN-capable hostapd: 0x100000 clear")
			assert_eq(bit(on.wifi_caps), 0x100000, "0x100000 set where it can")
			assert_eq(on.wifi_caps - off.wifi_caps, 0x100000, "independent of the other bits")
		end
	},
	{
		name = "inform json: port_table has one entry per configured port, 1-based port_idx",
		fn = function()
			-- No cfg passed (build() always calls build_json with cfg=nil), so
			-- port_table falls back to the default {uplink=eth0, lan=eth1} --
			-- matching proc_net_dev.txt's interfaces.
			local d = build()
			assert_not_nil(d.port_table, "port_table present")
			assert_eq(#d.port_table, 2, "two ports (uplink + lan) from the fallback default")
			assert_eq(d.port_table[1].port_idx, 1, "first port_idx is 1-based")
			assert_eq(d.port_table[2].port_idx, 2, "second port_idx")
		end
	},
	{
		name = "inform json: port_table reports the link speed the kernel negotiated",
		fn = function()
			-- speed/full_duplex used to be hardcoded 1000/full, so the Ports
			-- view claimed "GbE" on every device and every board regardless of
			-- what the link actually came up at -- a reported metric that was
			-- never measured.
			local orig = inform._read_file
			inform._read_file = function(path)
				if path == "/sys/class/net/eth0/speed"  then return "100\n"  end
				if path == "/sys/class/net/eth0/duplex" then return "half\n" end
				if path == "/sys/class/net/eth1/speed"  then return "1000\n" end
				if path == "/sys/class/net/eth1/duplex" then return "full\n" end
				return nil
			end
			local ok, err = pcall(function()
				local d = build()
				assert_eq(d.port_table[1].speed, 100, "uplink reports its real 100Mbit link")
				assert_false(d.port_table[1].full_duplex, "and its real half duplex")
				assert_eq(d.port_table[2].speed, 1000, "the gigabit port reports 1000")
				assert_true(d.port_table[2].full_duplex, "and full duplex")
			end)
			inform._read_file = orig
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform json: a DSA board reports each socket from its own netdev",
		fn = function()
			-- Every socket is a netdev, so sysfs is already per-socket.
			local d = build_dsa()
			assert_eq(#d.port_table, 4, "one entry per socket")
			local p = by_idx(d.port_table)
			assert_true(p[1].up, "the cabled socket is up")
			assert_eq(p[1].speed, 1000, "at the speed it negotiated")
			assert_true(p[1].full_duplex, "and its duplex")
			assert_false(p[2].up, "an empty socket has no link")
			assert_eq(p[2].speed, 0, "and no speed, rather than the 1000 fallback")
		end
	},
	{
		name = "inform json: is_uplink follows the cable on DSA too",
		fn = function()
			-- A board constant would be
			-- wrong the moment the cable moves, and the socket wrongly
			-- treated as downstream reports the whole LAN as plugged into it.
			local d = build_dsa()
			local p = by_idx(d.port_table)
			assert_true(p[1].is_uplink, "wan carries the gateway as cabled today")
			assert_true(p[1].mac_table == nil, "so it reports no hosts of its own")
			assert_false(p[2].is_uplink, "and no other socket claims to")

			-- Cable moved to lan3. Nothing in the modelmap changed.
			local moved = build_dsa({
				live = "lan3",
				fdb  = "00:00:5e:00:53:12 dev lan3 master br-lan \n"
					.. "aa:bb:cc:dd:ee:01 dev lan3 master br-lan \n",
			})
			local q = by_idx(moved.port_table)
			assert_true(q[3].is_uplink, "the flag followed the cable to lan3")
			assert_false(q[1].is_uplink, "and left wan")
			assert_true(q[3].mac_table == nil, "lan3 now suppresses its hosts")
			assert_eq(#q[1].mac_table, 0, "and wan reports its own again")
		end
	},
	{
		name = "inform json: an undetectable DSA uplink falls back, never to nobody",
		fn = function()
			-- Detection that names a socket this board does not report (a
			-- guest bridge port, a stale FDB) must not silently leave every
			-- entry unflagged: the uplink would then publish a mac_table of
			-- the entire far side, which is strictly worse than the static
			-- flag the modelmap can still carry.
			local cfg = {
				net = {
					lan_cpueth = "wan", lan_vlanid = 1,
					ports = {
						{idx = 1, ifname = "wan", uplink = true},
						{idx = 2, ifname = "lan2"},
					},
				},
			}
			local d = build_dsa({cfg = cfg,
				fdb = "00:00:5e:00:53:12 dev tap0 master br-lan \n"})
			local p = by_idx(d.port_table)
			assert_true(p[1].is_uplink, "fell back to the modelmap's own flag")
			assert_false(p[2].is_uplink, "and only that one")

			-- Gateway not learned at all: same fallback.
			local d2 = build_dsa({cfg = cfg, fdb = ""})
			assert_true(by_idx(d2.port_table)[1].is_uplink, "empty FDB falls back too")
		end
	},
	{
		name = "inform json: DSA wired hosts are reported on the socket they are on",
		fn = function()
			-- The per-port bridge FDB is already per-socket here, so no ARL
			-- equivalent is needed for the host list -- only for deciding
			-- which socket to suppress. The captured dump has nothing on lan3
			-- (that board had one cable in it), so a host is added explicitly
			-- rather than fabricated into the capture.
			local d = build_dsa({fdb = fixture("bridge_fdb_br_dsa.txt")
				.. "aa:bb:cc:dd:ee:01 dev lan3 master br-lan \n"})
			local p = by_idx(d.port_table)
			assert_eq(#p[3].mac_table, 1, "the host plugged into lan3")
			assert_eq(p[3].mac_table[1].mac, "aa:bb:cc:dd:ee:01", "its mac")
			assert_eq(#p[2].mac_table, 0, "and nothing on the empty socket")
		end
	},
	{
		name = "inform json: a socket moved to a VLAN bridge still reports its hosts",
		fn = function()
			-- The socket the controller assigned to a port VLAN is not a port
			-- of the management bridge any more -- switchvlan.dsa_apply moved
			-- it into br-openuf<vid>. Asking the uplink bridge about it (which
			-- is what the port loop used to do for EVERY socket) finds nothing,
			-- the port publishes an empty mac_table, and the controller credits
			-- the client to the gateway instead of to this AP's port 2.
			local d = build_dsa({
				master   = {lan2 = "br-openuf10"},
				fdb_by_br = {["br-openuf10"] =
					"00:00:5e:00:53:07 dev lan2 master br-openuf10 \n"},
				fdb = fixture("bridge_fdb_br_dsa.txt")
					.. "00:00:5e:00:53:08 dev lan3 master br-lan \n",
			})
			local p = by_idx(d.port_table)
			assert_eq(#p[2].mac_table, 1, "the host behind the moved socket")
			assert_eq(p[2].mac_table[1].mac, "00:00:5e:00:53:07", "its mac")
			-- The sockets still in the management bridge are unchanged, and
			-- the uplink question is still answered from that bridge's dump.
			assert_eq(#p[3].mac_table, 1, "a socket still in br-lan reports as before")
			assert_eq(p[3].mac_table[1].mac, "00:00:5e:00:53:08", "its mac")
			assert_true(p[1].is_uplink, "and the uplink is still detected")
			-- One dump per BRIDGE, not one per socket: three sockets live in
			-- br-lan and share its dump, the fourth costs one dump of its own.
			assert_eq(dsa_forks.fdb_br, 2, "one FDB dump per distinct bridge")
			assert_eq(dsa_forks.fdb_br_names["br-lan"], 1, "br-lan dumped once")
			assert_eq(dsa_forks.fdb_br_names["br-openuf10"], 1, "the VLAN bridge once")
			assert_eq(dsa_forks.fdb_dev, 0, "and still no per-socket fork")
		end
	},
	{
		name = "inform json: a host behind a VLAN-assigned socket is labelled with that VLAN",
		fn = function()
			-- The field that decides which NETWORK the controller files the
			-- client under. It walks the site's layer-2 networks and keeps a
			-- reported host only where the network's VLAN equals the row's
			-- `vlan`, defaulting to 1 -- so without this every host landed in
			-- the untagged network no matter which socket reported it, and the
			-- IoT device on an assigned socket was listed under the management
			-- LAN while its port, its IP and the controller's own Native VLAN
			-- column all said otherwise.
			local d = build_dsa({
				master   = {lan2 = "br-openuf10"},
				fdb_by_br = {["br-openuf10"] =
					"00:00:5e:00:53:07 dev lan2 master br-openuf10 \n"},
				fdb = fixture("bridge_fdb_br_dsa.txt")
					.. "00:00:5e:00:53:08 dev lan3 master br-lan \n",
			})
			local p = by_idx(d.port_table)
			assert_eq(p[2].mac_table[1].vlan, 10,
				"the VLAN read off the bridge openUF moved the socket into")
			-- A socket still in the management bridge carries no vlan at all:
			-- the controller drops a vlan of 1 on arrival, so sending it says
			-- nothing and costs bytes every heartbeat.
			assert_true(p[3].mac_table[1].vlan == nil,
				"a socket on the management VLAN is left unlabelled")
		end
	},
	{
		name = "inform json: a DSA payload dumps the bridge FDB once, not once per socket",
		fn = function()
			-- build_json already dumps the whole bridge FDB to find the uplink
			-- socket, and that dump carries every socket's hosts. Each socket
			-- forked `bridge fdb show dev <socket>` for a subset of it anyway.
			-- Asserting the host lists alone cannot catch a regression here:
			-- both sources are the same kernel table and give the same answer,
			-- so only the fork count says which one was asked.
			build_dsa({fdb = fixture("bridge_fdb_br_dsa.txt")
				.. "aa:bb:cc:dd:ee:01 dev lan3 master br-lan \n"})
			assert_eq(dsa_forks.fdb_br, 1, "one dump of the kernel FDB per payload")
			assert_eq(dsa_forks.fdb_dev, 0, "and no per-socket fork at all")
			-- The payload's very first question is the uptime, and scan_table
			-- asks it again per radio as its CLOCK_BOOTTIME reference. The pass
			-- has to be open before that first call, not partway down the
			-- function -- measuring a real heartbeat on hardware is what caught
			-- it still being read twice.
			assert_eq(dsa_forks.uptime, 1, "and /proc/uptime is read once for the payload")
		end
	},
	{
		name = "inform json: a port with no carrier is reported down, at speed 0",
		fn = function()
			-- Existence in /proc/net/dev is not link state: an unused socket is
			-- present and idle. Seen on a real TL-WDR3500 whose unused WAN
			-- socket (eth1, carrier 0, kernel speed -1) went out as
			-- "up, 1000 Mbps".
			local orig = inform._read_file
			inform._read_file = function(path)
				if path == "/sys/class/net/eth0/carrier" then return "1\n" end
				if path == "/sys/class/net/eth0/speed"   then return "100\n" end
				if path == "/sys/class/net/eth1/carrier" then return "0\n" end
				if path == "/sys/class/net/eth1/speed"   then return "-1\n" end
				return nil
			end
			local ok, err = pcall(function()
				local d = build()
				assert_true(d.port_table[1].up, "eth0 has carrier -> up")
				assert_eq(d.port_table[1].speed, 100, "and its real negotiated speed")
				assert_false(d.port_table[2].up, "eth1 has no carrier -> down")
				assert_eq(d.port_table[2].speed, 0, "a down port has no speed, not the fallback")
				assert_false(d.port_table[2].full_duplex, "nor a duplex")
			end)
			inform._read_file = orig
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform json: link state falls back to operstate, then to existence",
		fn = function()
			local orig = inform._read_file
			-- No carrier file, but operstate present.
			inform._read_file = function(path)
				if path:find("/operstate") then
					return path:find("eth1") and "down\n" or "up\n"
				end
				return nil
			end
			local ok, err = pcall(function()
				local d = build()
				assert_true(d.port_table[1].up, "operstate up")
				assert_false(d.port_table[2].up, "operstate down")
			end)
			-- Neither file readable: fall back to the netdev existing at all,
			-- which is the pre-existing behaviour.
			inform._read_file = function() return nil end
			local ok2, err2 = pcall(function()
				local d = build()
				assert_true(d.port_table[1].up, "unknown link state -> existence")
			end)
			inform._read_file = orig
			if not ok then error(err, 0) end
			if not ok2 then error(err2, 0) end
		end
	},
	{
		name = "inform json: port_table falls back when the kernel reports no speed",
		fn = function()
			-- A down interface, or a virtual device with no PHY, makes the
			-- kernel return an error or -1 for speed; neither may be sent as a
			-- link rate.
			local orig = inform._read_file
			inform._read_file = function(path)
				if path:find("/speed") then return "-1\n" end
				return nil
			end
			local ok, err = pcall(function()
				local d = build()
				assert_eq(d.port_table[1].speed, 1000, "-1 is 'unknown', not a speed")
				assert_true(d.port_table[1].full_duplex, "duplex defaults to full when unknown")
			end)
			inform._read_file = orig
			if not ok then error(err, 0) end
		end
	},
	{
		name = "inform json: port_table marks exactly the uplink port is_uplink",
		fn = function()
			local d = build()
			assert_true(d.port_table[1].is_uplink, "port 1 (wan/eth0) is the uplink")
			assert_false(d.port_table[2].is_uplink, "port 2 (lan/eth1) is not the uplink")
		end
	},
	{
		name = "inform json: port_table's uplink port carries no mac_table",
		fn = function()
			local d = build({with_wired = true})
			local uplink = d.port_table[1]
			assert_true(uplink.mac_table == nil or #uplink.mac_table == 0,
				"uplink port never reports wired clients -- the controller skips client creation on it")
		end
	},
	{
		name = "inform json: port_table's downstream port reports wired hosts from the bridge fdb",
		fn = function()
			local d = build({with_wired = true})
			local lan = d.port_table[2]
			assert_not_nil(lan.mac_table, "lan port has a mac_table")
			assert_eq(#lan.mac_table, 2, "two wired hosts from the fixture")
			assert_eq(lan.mac_table[1].mac, "aa:bb:cc:dd:ee:01", "first wired host mac")
			assert_eq(lan.mac_table[1].ip, "192.168.1.50", "first wired host ip from arp")
			assert_eq(lan.mac_table[1].hostname, "laptop", "first wired host hostname from dhcp leases")
			assert_eq(lan.mac_table[2].mac, "aa:bb:cc:dd:ee:02", "second wired host mac")
			assert_true(lan.mac_table[2].hostname == nil, "second wired host has no dhcp lease -- hostname stays nil")
		end
	},
	{
		name = "inform json: port_table's downstream port is empty without wired-client fixtures",
		fn = function()
			local d = build()
			assert_eq(#d.port_table[2].mac_table, 0, "no wired hosts without fixtures")
		end
	},
	{
		name = "inform json: a wireless station is never double-reported as a wired client",
		fn = function()
			-- One of the bridge-fdb-learned MACs coincides with a currently
			-- associated wireless station -- this must be excluded from
			-- port_table's mac_table even though it's also bridged into
			-- br-lan (and thus visible in the bridge FDB), or the same client
			-- would appear twice: once correctly as wireless, once wrongly
			-- as wired.
			inject_sysinfo(false, true)
			inject_ucihelper()
			inform._sysinfo._run_cmd = function(cmd)
				if cmd:find("station dump") then
					return "Station aa:bb:cc:dd:ee:01 (on wlan0)\n" ..
						"\tsignal:  \t-60 dBm\n\ttx bitrate:\t144.4 MBit/s\n"
				end
				if cmd:find("bridge fdb show") then
					return fixture("bridge_fdb_dump.txt")
				end
				return ""
			end
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap",
			}
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			assert_eq(d.vap_table[1].num_sta, 1, "the station is reported wirelessly")
			local wired_macs = {}
			for _, host in ipairs(d.port_table[2].mac_table) do wired_macs[host.mac] = true end
			assert_true(not wired_macs["aa:bb:cc:dd:ee:01"],
				"the same MAC is excluded from the wired mac_table -- reported wireless-only")
			assert_true(wired_macs["aa:bb:cc:dd:ee:02"],
				"an unrelated bridge-learned host is still reported as wired")
		end
	},
	{
		name = "inform json: the device's own MAC is never reported as a wired client of itself",
		fn = function()
			-- proc_net_dev.txt's eth1 has a real MAC in /sys/class/net/eth1/address
			-- via inject_sysinfo's _read_file stub returning "" for that path
			-- (no MAC) -- so self-exclusion here is driven by st.mac matching
			-- one of bridge_fdb_dump.txt's fixture MACs directly.
			inject_sysinfo(false, true)
			local st = {
				authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform",
				mac = "aa:bb:cc:dd:ee:01",  -- coincides with a bridge_fdb_dump.txt MAC
				ip = "192.168.1.100", hostname = "testap",
			}
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			local wired_macs = {}
			for _, host in ipairs(d.port_table[2].mac_table) do wired_macs[host.mac] = true end
			assert_true(not wired_macs["aa:bb:cc:dd:ee:01"], "device's own MAC excluded from its own mac_table")
			assert_true(wired_macs["aa:bb:cc:dd:ee:02"], "the other bridge-learned host is still reported")
		end
	},
	{
		name = "inform json: Minimum RSSI never kicks a client locked to this AP",
		fn = function()
			inject_sysinfo(true)  -- 11:22:33:44:55:66 at -75 dBm
			inject_ucihelper()
			inform._ucihelper.get_radio_table = function()
				return {{name = "radio0", radio = "ng", channel = "6",
					min_rssi_enabled = true, min_rssi_raw = 25}}  -- -70 dBm
			end
			local kicked = {}
			inform._ucihelper.kick_station = function(_, mac) kicked[#kicked + 1] = mac end
			local orig = inform._lockap.here
			inform._lockap.here = {["11:22:33:44:55:66"] = true}
			local st = {authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap"}
			local ok, err = pcall(inform.build_json, st, nil, ufhw)
			inform._lockap.here = orig
			assert_true(ok, tostring(err))
			assert_eq(#kicked, 0, "the locked client stays, whatever its signal")
		end
	},
	{
		name = "inform json: radio_table_stats holds exactly one entry per radio, unique by name",
		fn = function()
			inject_sysinfo(true)
			inject_ucihelper()
			local rt = inform._ucihelper.get_radio_table
			inform._ucihelper.get_radio_table = function()
				local t = rt()
				local copy = {}
				for _, r in ipairs(t) do copy[#copy + 1] = r end
				local dup = {}
				for k, v in pairs(t[1]) do dup[k] = v end
				copy[#copy + 1] = dup           -- the same radio listed twice
				return copy
			end
			local st = {authkey = state.DEFAULT_KEY, adopted = false, cfgversion = "",
				inform_url = "http://10.0.0.1:8080/inform", mac = "aa:bb:cc:dd:ee:ff",
				ip = "192.168.1.100", hostname = "testap"}
			local d = cjson.decode(inform.build_json(st, nil, ufhw))
			inform._ucihelper.get_radio_table = rt
			local seen, n = {}, 0
			for _, e in ipairs(d.radio_table_stats) do
				assert_nil(seen[e.name], "no second entry for " .. tostring(e.name))
				seen[e.name] = true
				n = n + 1
			end
			assert_true(n >= 1, "the radio is there once")
		end
	},
	{
		name = "inform json: a debug_caps override with bit 31 goes out as a Java int",
		fn = function()
			local d = build({cfg = {config = {debug_caps = {fw_caps = 0x80000000, wifi_caps = 0x80000010}}}})
			assert_eq(d.fw_caps, -2147483648, "0x80000000 as a signed 32-bit value")
			assert_eq(d.wifi_caps, -2147483632, "0x80000010 too")
		end
	},
	{
		name = "inform json: every probed capability bit drops when its probe fails, and the payload still builds",
		fn = function()
			local si, sn, at = inform._sysinfo, inform._snmp, inform._airtime
			local orig = {hs = si.hs20_supported, pp = si.ppsk_supported, v3 = sn.v3_capable,
				atf = at.supported}
			local function set(fn)
				si.hs20_supported, si.ppsk_supported, sn.v3_capable, at.supported = fn, fn, fn, fn
			end
			set(function() return true end)
			local on = build({cfg = {config = {sibling_scan_interval = 1800}}})
			set(function() error("probe exploded") end)
			local ok, raised = pcall(build, {cfg = {config = {sibling_scan_interval = 0,
				idle_scan_interval = 0}}})
			set(function() return nil end)
			local silent = build()
			si.hs20_supported, si.ppsk_supported, sn.v3_capable, at.supported =
				orig.hs, orig.pp, orig.v3, orig.atf
			local function has(v, bit) return v % (bit * 2) >= bit end
			local function fw(v) return v < 0 and v + 4294967296 or v end
			assert_true(has(fw(on.fw_caps), 0x800000) and has(fw(on.fw_caps), 0x4000)
				and has(fw(on.fw_caps), 0x80000000), "all claimed while the probes say yes")
			assert_true(has(on.wifi_caps, 0x100000) and has(on.wifi_caps, 0x20), "PPSK and ATF claimed")
			assert_true(has(on.wifi_caps2, 0x200), "neighbour scan claimed with sibling scans on")
			assert_true(ok, "a raising probe does not break the payload: " .. tostring(raised))
			for _, bit in ipairs({0x800000, 0x4000, 0x80000000}) do
				assert_false(has(fw(raised.fw_caps), bit), ("fw_caps 0x%x dropped"):format(bit))
				assert_false(has(fw(silent.fw_caps), bit), ("fw_caps 0x%x dropped on nil"):format(bit))
			end
			assert_false(has(raised.wifi_caps, 0x100000), "PPSK (wifi_caps 0x100000) dropped")
			assert_false(has(raised.wifi_caps, 0x20), "Airtime Fairness (wifi_caps 0x20) dropped")
			assert_false(has(raised.wifi_caps2, 0x200), "neighbour scan dropped with no scan configured")
		end
	},
}
