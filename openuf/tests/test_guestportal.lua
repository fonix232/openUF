-- Tests for src/openwrt/guestportal.lua (the HTTP answer that sends an
-- unauthorized guest to the portal). The portal's nft side is guestguard's,
-- tested in test_guest.lua. Ported from upstream's tests/test_guestportal.lua.
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local gp = dofile("src/openwrt/guestportal.lua")

local CTL = "192.0.2.2"

-- A connected client for serve_one: lines to read, everything sent.
local function fake_client(lines, peer)
	local c = {sent = {}, closed = false}
	local i = 0
	function c:settimeout() end
	function c:getpeername() return peer end
	function c:receive()
		i = i + 1
		return lines[i]
	end
	function c:send(s) self.sent[#self.sent + 1] = s; return #s end
	function c:close() self.closed = true end
	return c
end

local ARP = table.concat({
	"IP address       HW type     Flags       HW address            Mask     Device",
	"198.51.100.50    0x1         0x2         DE:AD:BE:EF:00:03     *        br-lan",
	"198.51.100.51    0x1         0x0         00:00:00:00:00:00     *        br-lan",
	"198.51.100.52    0x1         0x6         00:00:5e:00:53:01     *        br-lan",
}, "\n") .. "\n"

return {
	{
		name = "guestportal: arp_mac takes complete entries only",
		fn = function()
			assert_eq(gp.arp_mac("198.51.100.50", ARP), "de:ad:be:ef:00:03", "complete, lowercased")
			assert_eq(gp.arp_mac("198.51.100.51", ARP), nil, "incomplete")
			assert_eq(gp.arp_mac("198.51.100.52", ARP), "00:00:5e:00:53:01", "complete + permanent flags")
			assert_eq(gp.arp_mac("198.51.100.5", ARP), nil, "a prefix of another address is not a match")
		end
	},
	{
		name = "guestportal: location carries id, ap, t, url and ssid, encoded",
		fn = function()
			local ctx = {url = "http://" .. CTL .. ":8880/guest/s/default/", ap = "00:00:5e:00:53:02"}
			local loc = gp.location(ctx, "de:ad:be:ef:00:03", "http://example.com/a?b=1&c", "Lab Guest", 1791583472)
			assert_eq(loc, "http://" .. CTL .. ":8880/guest/s/default/?id=de%3Aad%3Abe%3Aef%3A00%3A03"
				.. "&ap=00%3A00%3A5e%3A00%3A53%3A02&t=1791583472"
				.. "&url=http%3A%2F%2Fexample.com%2Fa%3Fb%3D1%26c&ssid=Lab%20Guest", "the controller's parameters")
			ctx.url = "http://" .. CTL .. "/p?x=1"
			assert_true(gp.location(ctx, "de:ad:be:ef:00:03", nil, nil, 1):find("/p?x=1&id=", 1, true) ~= nil,
				"appends to a URL that has a query")
		end
	},
	{
		name = "guestportal: serve_one answers a guest with the portal, a stranger with 503",
		fn = function()
			local ctx = {url = "http://" .. CTL .. ":8880/guest/s/default/", ap = "00:00:5e:00:53:02",
				arp = function() return ARP end, now = function() return 100 end,
				ssid_for = function() return "Lab Guest" end}
			local guest = fake_client({"GET /generate_204 HTTP/1.1", "Host: connectivitycheck.example", "", }, "198.51.100.50")
			local server = {accept = function() return guest end}
			assert_true(gp.serve_one(server, ctx), "answered")
			local resp = table.concat(guest.sent)
			assert_true(resp:find("^HTTP/1.1 302 Found\r\n") ~= nil, "a redirect")
			assert_true(resp:find("id=de%3Aad%3Abe%3Aef%3A00%3A03", 1, true) ~= nil, "the guest's MAC")
			assert_true(resp:find("url=http%3A%2F%2Fconnectivitycheck.example%2Fgenerate_204", 1, true) ~= nil,
				"where it was going")
			assert_true(resp:find("&t=100&", 1, true) ~= nil, "the AP's clock")
			assert_true(guest.closed, "closed")
			local stranger = fake_client({"GET / HTTP/1.1", ""}, "198.51.100.99")
			assert_true(gp.serve_one({accept = function() return stranger end}, ctx), "answered")
			assert_true(table.concat(stranger.sent):find("^HTTP/1.1 503") ~= nil, "no MAC: try again")
			assert_false(gp.serve_one({accept = function() return nil end}, ctx), "nothing waiting")
		end
	},
	{
		name = "guestportal: serve_one reads a bounded request",
		fn = function()
			local lines = {"GET / HTTP/1.1"}
			for i = 1, 100 do lines[#lines + 1] = "X-Pad-" .. i .. ": y" end
			local c = fake_client(lines, "198.51.100.50")
			local read = 0
			local recv = c.receive
			c.receive = function(self) read = read + 1; return recv(self) end
			gp.serve_one({accept = function() return c end}, {url = "http://" .. CTL .. "/", ap = "",
				arp = function() return ARP end, now = function() return 1 end})
			assert_eq(read, 32, "stops after 32 lines")
			assert_true(table.concat(c.sent):find("302", 1, true) ~= nil, "still answers")
			assert_eq(table.concat(c.sent):find("url=", 1, true), nil, "no Host: no url=")
		end
	},
}
