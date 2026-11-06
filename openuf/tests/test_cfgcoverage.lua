-- Tests for tools/cfg-coverage.lua (which keys of a captured push openUF reads)
-- and for unifi/network.lua's parse_settings, the tokenizer it needed reachable.
-- Run from project root: lua tests/run_tests.lua
--
-- The tool is loaded as a module: its script half runs only when it is the
-- script. The suite also runs from `sh tools/strip-tree.sh --verify`, whose
-- scratch tree is a copy of openuf/ (tools/ included), so the relative path
-- holds there too.

local cfgcov = dofile("tools/cfg-coverage.lua")
local network = require("unifi.network")
local recognized = require("unifi.recognized")

local function bucket_of(report)
	local verdict = {}
	for _, name in ipairs({"consumed", "inert", "ignored"}) do
		for _, row in ipairs(report[name]) do verdict[row.key] = name end
	end
	return verdict
end

return {
	{
		name = "net settings: IP Settings, DNS order and the controller's hostname out of one blob",
		fn = function()
			local net = network.parse_settings(table.concat({
				"netconf.1.ip=192.0.2.7",
				"netconf.1.netmask=255.255.255.0",
				"route.1.gateway=192.0.2.1",
				"dhcpc.1.status=disabled",
				-- Out of wire order: the index decides, not the line position.
				"resolv.nameserver.2.ip=192.0.2.3",
				"resolv.nameserver.1.ip=192.0.2.2",
				"resolv.nameserver.3.ip=",
				"resolv.host.1.name=U6IW",
				"ebtables.status=enabled",
				"unifi.key=0123456789abcdef",
			}, "\n"))
			assert_eq(net.ip, "192.0.2.7", "static address")
			assert_eq(net.netmask, "255.255.255.0", "netmask")
			assert_eq(net.gateway, "192.0.2.1", "gateway")
			assert_false(net.dhcp, "dhcpc.1.status=disabled is not DHCP")
			assert_eq(net.device_name, "U6IW", "the controller's name for the device")
			assert_eq(table.concat(net.dns, ","), "192.0.2.2,192.0.2.3",
				"sorted by wire index, the empty one dropped")
			assert_true(net.full_push, "ebtables.status marks a full push")
			assert_eq(net.site_key, "0123456789abcdef", "unifi.key")
		end
	},
	{
		name = "net settings: DHCP, and a blob with none of these keys",
		fn = function()
			local dh = network.parse_settings("dhcpc.1.status=enabled\nnetconf.1.ip=192.0.2.7")
			assert_true(dh.dhcp, "enabled means DHCP")
			local none = network.parse_settings("")
			assert_eq(none.ip, nil, "no address")
			assert_eq(#none.dns, 0, "no DNS")
			assert_false(none.full_push, "not a full push")
		end
	},
	{
		name = "cfg-coverage: a replay sorts a push into consumed / inert / ignored",
		fn = function()
			local report = cfgcov.analyse(table.concat({
				"# no wlan provisioned as no radio found",
				"radio.1.phyname=wifi0",
				"radio.1.channel=36",
				"",
				"wireless.1.devname=ath0",
				"wireless.1.parent=wifi0",
				"wireless.1.ssid=openuf-test",
				"wireless.1.status=enabled",
				-- Claimed by `^wireless%.%d+%.` yet read by nothing: the
				-- MAC-filter decoy from PROTOCOL-VALIDATION.md.
				"wireless.1.mac_acl.policy=deny",
				"unifi.version=10.6.106",
				"",
			}, "\n"), cfgcov.parsers(), recognized.RECOGNIZED_SYSTEM_CFG)
			local verdict = bucket_of(report)
			assert_eq(verdict["radio.1.channel"], "consumed", "the channel reaches a radio")
			assert_eq(verdict["wireless.1.mac_acl.policy"], "inert",
				"recognized by prefix, read by nothing")
			assert_eq(verdict["unifi.version"], "ignored", "neither claimed nor read")
			assert_eq(report.lines, 8, "key=value lines")
			assert_eq(report.blanks, 2, "the comment and the blank line")
		end
	},
	{
		name = "cfg-coverage: a real guest-portal push is read by the parsers",
		fn = function()
			local f = assert(io.open("tests/fixtures/system_cfg_guest_portal_lab.txt", "r"))
			local blob = f:read("*a")
			f:close()
			local verdict = bucket_of(cfgcov.analyse(blob, cfgcov.parsers(),
				recognized.RECOGNIZED_SYSTEM_CFG))
			assert_eq(verdict["wireless.1.ssid"], "consumed", "a WLAN's SSID is read by the wifi parser")
			assert_eq(verdict["redirector.status"], "consumed", "the portal switch is read")
			assert_eq(verdict["ebtables.status"], "consumed", "the full-push marker is read")
		end
	},
	{
		name = "cfg-coverage: mutating the value catches a key a fallback hides from deletion",
		fn = function()
			-- radio.<n>.countrycode falls back to the unindexed radio.countrycode,
			-- so DELETING either leaves the regdomain unchanged and a
			-- deletion-only sweep reports both as unread. Modelled as a parser
			-- with exactly that fallback.
			local parsers = {{"fallback", function(blob)
				return blob:match("\na%.1%.k=([%w_]+)") or blob:match("\na%.k=([%w_]+)")
			end}}
			local verdict = bucket_of(cfgcov.analyse("\na.1.k=203\na.k=203", parsers, {}))
			assert_eq(verdict["a.1.k"], "consumed", "the indexed key is read, fallback or not")
			assert_eq(verdict["a.k"], "ignored", "shadowed: no probe can move the output")
		end
	},
	{
		name = "cfg-coverage: a report never prints a pushed secret",
		fn = function()
			local parsers = {{"none", function() return nil end}}
			local report = cfgcov.analyse(table.concat({
				"aaa.1.wpa.psk=letmeinnow",
				"aaa.1.radius.auth.1.secret=letmeinnow",
				"aaa.1.iapp_key=letmeinnow",
				"authkey=letmeinnow",
				"aaa.1.ssid=openuf-test",
			}, "\n"), parsers, {})
			local out = cfgcov.format(report, {values = true})
			assert_nil(out:find("letmeinnow", 1, true), "no secret in the report")
			assert_true(out:find("openuf%-test") ~= nil, "a non-secret value still prints")
			assert_true(out:find("<redacted>") ~= nil, "and says it was redacted")
		end
	},
}
