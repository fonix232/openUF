-- Tests for src/openwrt/netconfig.lua (IP Settings: the value validator).
-- The apply itself is netmodel.apply_addressing (test_netmodel.lua).
-- Run from project root: lua tests/run_tests.lua

local netconfig = dofile("src/openwrt/netconfig.lua")

return {
	{
		name = "netconfig: is_ipv4 takes four 0-255 octets and nothing else",
		fn = function()
			-- These values come off the wire, and before adoption that wire is
			-- plain HTTP under the well-known default key.
			assert_true(netconfig.is_ipv4("192.0.2.5"), "a dotted quad")
			assert_true(netconfig.is_ipv4("255.255.255.0"), "a netmask")
			assert_false(netconfig.is_ipv4("10.0.0.5; reboot"), "a command tail")
			assert_false(netconfig.is_ipv4("999.1.1.1"), "an out-of-range octet")
			assert_false(netconfig.is_ipv4("1.2.3"), "three octets")
			assert_false(netconfig.is_ipv4("0001.2.3.4"), "a four-digit octet")
			assert_false(netconfig.is_ipv4(nil), "nil")
		end
	},
}
