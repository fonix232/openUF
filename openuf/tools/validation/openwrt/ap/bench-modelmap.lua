-- Bench board: `wan` is a veth cable to the bench gateway, lan1/lan2 are veths.
-- U6IW numbering: 1-4 downstream, 5 = the uplink ("PoE In + Data").
local dev = {}
dev.conf = {}
dev.conf.net = {
	lan_name   = "lan",
	lan_cpueth = "wan",
	lan_vlanid = 1,
	wan_cpueth = "wan",
	ports = {
		{idx = 1, ifname = "lan1"},
		{idx = 2, ifname = "lan2"},
		{idx = 5, ifname = "wan"},
	},
}
dev.conf.led = nil
return dev
