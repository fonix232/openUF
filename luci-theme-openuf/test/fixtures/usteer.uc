// Stand-in for usteerd's "usteer" ubus object, as an rpcd ucode plugin, so
// luci-app-usteer has an AP to show in a container without Wi-Fi.
//
// Replies follow usteer's ubus.c (github.com/openwrt/usteer): node tables are
// keyed by node name ("hostapd.<iface>" here, "<ip>#hostapd.<iface>" for a
// remote AP), stations by MAC, and signal/noise are dBm. The data is fixed so
// screenshots stay comparable: this AP has a 2.4 and a 5 GHz radio on
// HomeNet, one more AP (192.168.1.3) is heard over the LAN, six clients are
// connected and one phone with a random MAC is only probing.

'use strict';

const REMOTE = '192.168.1.3';

// name: [ bssid, freq, n_assoc, noise, load, roam source, roam target ]
const nodes = {
	'hostapd.phy0-ap0':             [ '78:8a:20:4c:1e:a1', 2437, 1, -91, 34, 14, 3 ],
	'hostapd.phy1-ap0':             [ '7a:8a:20:4c:1e:a1', 5180, 3, -95, 9, 5, 11 ],
	[`${REMOTE}#hostapd.phy0-ap0`]: [ '74:83:c2:9d:07:52', 2462, 1, -89, 41, 8, 6 ],
	[`${REMOTE}#hostapd.phy1-ap0`]: [ '76:83:c2:9d:07:52', 5500, 1, -94, 17, 2, 9 ]
};

// mac: { node: [ connected, signal ] }, the node it is connected to first
const stations = {
	'a4:83:e7:2f:91:0c': {
		'hostapd.phy1-ap0': [ true, -52 ], 'hostapd.phy0-ap0': [ false, -47 ],
		[`${REMOTE}#hostapd.phy1-ap0`]: [ false, -78 ]
	},
	'3c:22:fb:7a:10:4e': {
		'hostapd.phy1-ap0': [ true, -61 ], [`${REMOTE}#hostapd.phy1-ap0`]: [ false, -81 ]
	},
	'f0:18:98:44:c2:71': {
		'hostapd.phy1-ap0': [ true, -73 ], 'hostapd.phy0-ap0': [ false, -66 ],
		[`${REMOTE}#hostapd.phy1-ap0`]: [ false, -70 ]
	},
	'dc:a6:32:11:5e:9b': {
		'hostapd.phy0-ap0': [ true, -64 ], [`${REMOTE}#hostapd.phy0-ap0`]: [ false, -82 ]
	},
	'50:02:91:a8:3c:17': {
		[`${REMOTE}#hostapd.phy0-ap0`]: [ true, -58 ], 'hostapd.phy0-ap0': [ false, -84 ]
	},
	'9c:b6:d0:e1:07:33': {
		[`${REMOTE}#hostapd.phy1-ap0`]: [ true, -55 ], 'hostapd.phy1-ap0': [ false, -76 ],
		[`${REMOTE}#hostapd.phy0-ap0`]: [ false, -49 ]
	},
	'0e:5d:13:9a:40:c8': {
		'hostapd.phy0-ap0': [ false, -83 ], [`${REMOTE}#hostapd.phy0-ap0`]: [ false, -79 ]
	}
};

// usteer's defaults (main.c) with the settings in fixtures/usteer.config
const config = {
	syslog: true, debug_level: 2, ipv6: false, local_mode: false,
	sta_block_timeout: 30000, local_sta_timeout: 120000, local_sta_update: 1000,
	max_neighbor_reports: 8, max_retry_band: 5, seen_policy_timeout: 30000,
	measurement_report_timeout: 120000, load_balancing_threshold: 0,
	band_steering_threshold: 5, remote_update_interval: 1000, remote_node_timeout: 10,
	assoc_steering: false, aggressiveness: 3, aggressive_disassoc_timer: 0,
	min_connect_snr: 0, min_snr: 0, min_snr_kick_delay: 5000,
	steer_reject_timeout: 60000, roam_process_timeout: 5000, roam_scan_snr: -70,
	roam_scan_tries: 3, roam_scan_timeout: 0, roam_scan_interval: 10000,
	roam_trigger_snr: -75, roam_trigger_interval: 60000, roam_kick_delay: 10000,
	signal_diff_threshold: 8, initial_connect_delay: 0, load_kick_enabled: false,
	load_kick_threshold: 75, load_kick_delay: 10000, load_kick_min_clients: 10,
	load_kick_reason_code: 5, band_steering_interval: 30000, band_steering_min_snr: -60,
	link_measurement_interval: 30000, interfaces: [ 'br-lan' ],
	event_log_types: [], ssid_list: [ 'HomeNet' ]
};

function is_local(name) {
	return index(name, '#') < 0;
}

function dump_nodes(local) {
	const reply = {};

	for (let name, n in nodes) {
		if (is_local(name) != local)
			continue;

		reply[name] = {
			bssid: n[0], ssid: 'HomeNet', freq: n[1], n_assoc: n[2],
			noise: n[3], load: n[4], max_assoc: 0,
			roam_events: { source: n[5], target: n[6] },
			// hostapd's rrm_nr_get_own: bssid, ssid, neighbour report
			rrm_nr: [ n[0], 'HomeNet', replace(n[0], ':', '') + 'af0900005106030900' ]
		};
	}

	return reply;
}

return {
	usteer: {
		local_info: { call: () => dump_nodes(true) },
		remote_info: { call: () => dump_nodes(false) },

		remote_hosts: {
			call: () => ({ [REMOTE]: { id: 3214501721 } })
		},

		get_clients: {
			call: function() {
				const reply = {};

				for (let mac, seen in stations) {
					reply[mac] = {};

					for (let name, s in seen)
						reply[mac][name] = { connected: s[0], signal: s[1] };
				}

				return reply;
			}
		},

		get_client_info: {
			args: { address: '' },
			call: function(req) {
				const seen = stations[lc(req.args.address ?? '')];

				if (!seen)
					return req.error(4); // UBUS_STATUS_NOT_FOUND

				const reply = { '2ghz': false, '5ghz': false, nodes: {} };

				for (let name, s in seen) {
					reply[nodes[name][1] < 5000 ? '2ghz' : '5ghz'] = true;
					reply.nodes[name] = { connected: s[0], signal: s[1], stats: {} };
				}

				return reply;
			}
		},

		connected_clients: {
			call: function() {
				const reply = {};
				let age = 0;

				for (let name in dump_nodes(true)) {
					reply[name] = {};

					for (let mac, seen in stations) {
						if (!seen[name]?.[0])
							continue;

						age += 413000;
						reply[name][mac] = {
							signal: seen[name][1], created: age + 6000, connected: age,
							'snr-kick': { 'seen-below': 0 },
							'roam-state-machine': {
								state: 'ROAM_TRIGGER_IDLE', tries: 0, event: 0,
								'kick-count': 0, 'last-kick': 0, scan_start: 0, scan_timeout_start: 0
							},
							'bss-transition-response': { 'status-code': 0, age: 0 },
							'beacon-measurement-modes': [ 'PASSIVE', 'ACTIVE', 'TABLE' ],
							'link-measurement': true,
							'bss-transition-management': true,
							'multi-band-operation': false,
							measurements: []
						};
					}
				}

				return reply;
			}
		},

		get_config: { call: () => config }
	}
};
