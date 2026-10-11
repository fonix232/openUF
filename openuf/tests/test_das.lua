-- Tests for src/openwrt/das.lua (the RADIUS Dynamic Authorization dispatcher).
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local cjson = require("cjson")
local das   = require("openwrt.das")

-- A RADIUS packet: code, id 7, a zero authenticator, and {type, value} attrs.
local function packet(code, attrs)
	local body = {}
	for _, a in ipairs(attrs or {}) do
		body[#body + 1] = string.char(a[1], #a[2] + 2) .. a[2]
	end
	local b = table.concat(body)
	local len = 20 + #b
	return string.char(code, 7, math.floor(len / 256), len % 256)
		.. string.rep("\0", 16) .. b
end

local PLAN = {
	{port = 3801, nas_id = "ap-corp", ssid = "corp",  clients = {"192.0.2.10/32"}},
	{port = 3802, nas_id = "ap-lab",  ssid = "lab",   clients = {"192.0.2.10/32", "198.51.100.0/24"}},
	{port = 3803, ssid = "staff", clients = {"192.0.2.99/32"}},
}

-- relay() stub: answers[port] = code, or nil for no answer; records calls.
local function stub_relay(answers)
	local calls = {}
	return function(port, data)
		calls[#calls + 1] = port
		local code = answers[port]
		return code and packet(code) or nil
	end, calls
end

return {
	{
		name = "das: a RADIUS packet parses to its code and attributes; junk does not",
		fn = function()
			local code, attrs = das.parse(packet(40, {{32, "ap-corp"}, {30, "00-00-5E-00-53-01:corp"}}))
			assert_eq(code, 40, "Disconnect-Request")
			assert_eq(attrs[32], "ap-corp", "NAS-Identifier")
			assert_eq(attrs[30], "00-00-5E-00-53-01:corp", "Called-Station-Id")
			assert_nil(das.parse("short"), "under 20 bytes")
			local p = packet(43, {{32, "x"}})
			assert_nil(das.parse(p:sub(1, -2)), "length field longer than the datagram")
			assert_nil(das.parse(p:sub(1, 20) .. string.char(32, 1)), "attribute length below 2")
			local bad = string.char(43, 7, 0, 23) .. string.rep("\0", 16) .. string.char(32, 9, 65)
			assert_nil(das.parse(bad), "attribute running past the packet")
		end
	},
	{
		name = "das: CIDR matching",
		fn = function()
			assert_true(das.in_cidr("192.0.2.10", "192.0.2.10/32"), "exact /32")
			assert_false(das.in_cidr("192.0.2.11", "192.0.2.10/32"), "neighbour of a /32")
			assert_true(das.in_cidr("198.51.100.77", "198.51.100.0/24"), "inside a /24")
			assert_false(das.in_cidr("198.51.101.1", "198.51.100.0/24"), "outside a /24")
			assert_true(das.in_cidr("192.0.2.10", "192.0.2.10"), "bare address is /32")
			assert_true(das.in_cidr("2001:db8::1", "2001:db8::1/128"), "IPv6 exact")
			assert_false(das.in_cidr("2001:db8::2", "2001:db8::1/128"), "IPv6 other")
			assert_false(das.in_cidr("999.0.0.1", "0.0.0.0/0"), "not an address")
		end
	},
	{
		name = "das: routing by NAS-Identifier, then Called-Station-Id SSID, else every allowed WLAN",
		fn = function()
			local function ports(list)
				local p = {}
				for _, e in ipairs(list) do p[#p + 1] = e.port end
				return table.concat(p, ",")
			end
			assert_eq(ports(das.route(PLAN, "192.0.2.10", {[32] = "ap-lab"})), "3802", "NAS-Identifier")
			assert_eq(ports(das.route(PLAN, "192.0.2.10", {[30] = "00-00-5E-00-53-01:corp"})), "3801",
				"Called-Station-Id SSID")
			assert_eq(ports(das.route(PLAN, "192.0.2.10", {})), "3801,3802", "fan out to the allowed WLANs")
			assert_eq(ports(das.route(PLAN, "198.51.100.5", {})), "3802", "only where the source is a client")
			assert_eq(ports(das.route(PLAN, "198.51.100.5", {[32] = "ap-corp"})), "3802",
				"a NAS-Identifier the source may not address does not widen it")
			assert_eq(#das.route(PLAN, "203.0.113.1", {[32] = "ap-corp"}), 0, "an unlisted source gets nothing")
		end
	},
	{
		name = "das: handle relays requests, answers with the first ACK, else a NAK; ignores the rest",
		fn = function()
			local relay, calls = stub_relay({[3801] = 42, [3802] = 41})
			local answer = das.handle(PLAN, packet(40), "192.0.2.10", relay)
			assert_eq(answer:byte(1), 41, "Disconnect-ACK from the WLAN that had the session")
			assert_eq(table.concat(calls, ","), "3801,3802", "tried in order")
			relay, calls = stub_relay({[3801] = 41, [3802] = 41})
			das.handle(PLAN, packet(43), "192.0.2.10", relay)
			assert_eq(table.concat(calls, ","), "3801", "stops at the first ACK")
			relay = stub_relay({[3801] = 45, [3802] = 45})
			assert_eq(das.handle(PLAN, packet(43), "192.0.2.10", relay):byte(1), 45, "CoA-NAK when none accepts")
			relay, calls = stub_relay({[3801] = 41})
			assert_nil(das.handle(PLAN, packet(40), "203.0.113.1", relay), "unlisted source: no answer")
			assert_eq(#calls, 0, "and nothing relayed")
			assert_nil(das.handle(PLAN, packet(1), "192.0.2.10", relay), "Access-Request is not ours")
			assert_nil(das.handle(PLAN, "junk", "192.0.2.10", relay), "junk")
			relay = stub_relay({})
			assert_nil(das.handle(PLAN, packet(40), "192.0.2.10", relay), "hostapd silent: nothing to send")
		end
	},
	{
		name = "das: wlan.parse_radius takes DAS only when radius.das.status is enabled",
		fn = function()
			local wlan = require("unifi.wlan")
			local a = {
				["radius.auth.1.ip"] = "192.0.2.10", ["radius.auth.1.secret"] = "s",
				["radius.das.port"] = "3801", ["radius.das.secret"] = "s",
				["radius.das.client"] = "192.0.2.10",
				["radius.dad.client.1.cidr"] = "192.0.2.10/32",
			}
			a["radius.das.status"] = "enabled"
			assert_eq(wlan.parse_radius(a).das.port, 3801, "enabled: parsed")
			a["radius.das.status"] = "disabled"
			assert_nil(wlan.parse_radius(a).das, "disabled: no DAS")
			a["radius.das.status"] = nil
			assert_nil(wlan.parse_radius(a).das, "absent: no DAS")
			a["radius.das.status"] = "enabled"
			a["radius.das.port"] = "80"
			assert_nil(wlan.parse_radius(a).das, "a privileged port is refused")
		end
	},
	{
		name = "das: the plan holds Enterprise WLANs with DAS only, and is written only when it changes",
		fn = function()
			local das_cfg = {port = 3801, secret = "s", clients = {{cidr = "192.0.2.10/32"}}}
			local plan = das.plan({
				{ssid = "corp", security = "wpa2-eap", radius = {nas_id = "n", das = das_cfg}},
				{ssid = "psk",  security = "wpa2",     radius = {das = das_cfg}},
				{ssid = "eap-no-das", security = "wpa3-eap", radius = {}},
			})
			assert_eq(#plan, 1, "only the Enterprise WLAN with DAS")
			assert_eq(plan[1].ssid, "corp", "corp")
			local file = os.tmpname()
			os.remove(file)
			assert_true(das.save(plan, file, cjson), "written")
			assert_false(das.save(plan, file, cjson), "unchanged: not rewritten")
			local f = io.open(file, "r")
			local back = das.load(f:read("*a"), cjson)
			f:close()
			assert_eq(back[1].port, 3801, "round-trips")
			assert_true(das.save({}, file, cjson), "an empty plan removes it")
			assert_nil(io.open(file, "r"), "file gone")
			assert_eq(#das.load("{garbage", cjson), 0, "garbage loads empty")
		end
	},
}
