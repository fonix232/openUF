'use strict';
'require baseclass';
'require dom';
'require fs';
'require rpc';
'require uci';
'require network';
'require firewall';

/*
 * The router's own ports, drawn the way UniFi draws a device's: a strip of
 * squares (green with link, lime at Fast Ethernet, blue from 2.5 GbE, grey
 * without, outlined when disabled) with the uplink marked by a chevron, a
 * legend, and a Port Manager list of each port's link, networks and VLANs.
 *
 *   L.require('view.unifi.ports').then((ports) => ports.load().then((data) =>
 *       ports.render(data, { mode: 'strip' })));
 *
 * load() finds DSA ports (luci.getBuiltinEthernetPorts, else board.json)
 * and swconfig switch ports (the switch topology, getSwconfigPortState and
 * switch_vlan; CPU ports are left out), their link from luci-rpc and netifd,
 * and their networks, zones and VLANs from UCI (bridge-vlan, 802.1q devices,
 * switch_vlan). It does not flush LuCI's network cache; a view polling it
 * does that itself (the dashboard and Interfaces already do).
 *
 * render() returns null when there is nothing to show, else a .uf-ports
 * node in one of three modes: 'strip' (squares and legend), 'compact'
 * (with a short list beside) or 'full' (with the Port Manager list). Its
 * squares are buttons; hovering or focusing one shows its details, and
 * choosing one fires "uf-port-select" (detail.port) on the node.
 *
 * patch() brings a node rendered earlier up to date with a new one, so a
 * poll leaves the elements under the pointer (and their tooltip) alone.
 */

const callBuiltinEthernetPorts = rpc.declare({
	object: 'luci',
	method: 'getBuiltinEthernetPorts',
	expect: { result: [] }
});

const callSwconfigFeatures = rpc.declare({
	object: 'luci',
	method: 'getSwconfigFeatures',
	params: [ 'switch' ],
	expect: { '': {} }
});

const callSwconfigPortState = rpc.declare({
	object: 'luci',
	method: 'getSwconfigPortState',
	params: [ 'switch' ],
	expect: { result: [] }
});

/* Without a name netifd answers for every device it knows, in one call. */
const callNetworkDeviceStatus = rpc.declare({
	object: 'network.device',
	method: 'status',
	expect: { '': {} }
});

/* A switch's features do not change while the page is open. */
const swFeatures = {};

let tip = null;
let tipFor = null;

function isString(v) {
	return typeof(v) == 'string' && v != '';
}

function hexToRGB(hex) {
	const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex || '');

	return m ? '%d, %d, %d'.format(parseInt(m[1], 16), parseInt(m[2], 16), parseInt(m[3], 16)) : null;
}

/* "lan1:u*" -> { name: 'lan1', tagged: false, pvid: true } */
function parseBridgePort(spec) {
	const m = /^([^:]+)(?::([ut*]*))?$/.exec(spec || '');

	return m ? { name: m[1], tagged: (m[2] || '').indexOf('t') > -1, pvid: (m[2] || '').indexOf('*') > -1 } : null;
}

/* "0t" -> { num: 0, tagged: true } */
function parseSwitchPort(spec) {
	const m = /^(\d+)([tu*]*)$/.exec(spec || '');

	return m ? { num: +m[1], tagged: m[2].indexOf('t') > -1 } : null;
}

/* The devices UCI describes: bridges with their VLANs, and 802.1q/ad
 * devices, keyed by name. */
function readDeviceConfig() {
	const cfg = { bridges: {}, vlans: {}, sections: {}, disabled: {} };
	const brvlans = {};

	uci.sections('network', 'bridge-vlan', (s) => {
		if (!isString(s.device) || !/^\d{1,4}$/.test(s.vlan) || +s.vlan > 4095)
			return;

		(brvlans[s.device] = brvlans[s.device] || []).push({
			vid: +s.vlan,
			aliases: L.toArray(s.alias).map(Number).filter((a) => a > 0 && a != +s.vlan),
			ports: L.toArray(s.ports).map(parseBridgePort).filter((p) => p != null)
		});
	});

	uci.sections('network', 'device', (s) => {
		if (!isString(s.name))
			return;

		cfg.sections[s.name] = s['.name'];

		if (s.enabled == '0')
			cfg.disabled[s.name] = true;

		if (s.type == 'bridge') {
			const vlans = brvlans[s.name] || [];

			/* netifd filters as soon as a bridge has VLANs, unless told not to. */
			cfg.bridges[s.name] = {
				sid: s['.name'],
				ports: L.toArray(s.ports),
				filtering: vlans.length ? s.vlan_filtering != '0' : s.vlan_filtering == '1',
				vlans: vlans
			};
		}
		else if ((s.type == '8021q' || s.type == '8021ad') && isString(s.ifname) && /^\d{1,4}$/.test(s.vid)) {
			cfg.vlans[s.name] = { parent: s.ifname, vid: +s.vid };
		}
	});

	return cfg;
}

/* Where a device lands on the ports: every { port, vid, tagged, pvid }
 * a network on it reaches, through bridges, bridge VLANs and 802.1q
 * devices. Only names in `ports` count as ports. */
function resolveMembers(cfg, ports, name, ctx, seen, out) {
	out = out || [];
	seen = seen || {};

	if (!isString(name) || seen[name])
		return out;

	seen[name] = true;
	ctx = ctx || { vid: null, tagged: false, pvid: false };

	const emit = (port, vid, tagged, pvid) => {
		/* A tag laid on top of an untagged membership is what the wire sees. */
		if (ctx.vid != null && vid == null)
			out.push({ port: port, vid: ctx.vid, tagged: true, pvid: false });
		else
			out.push({ port: port, vid: vid, tagged: tagged || ctx.tagged, pvid: pvid });
	};

	const leaf = (port, vid, tagged, pvid) => {
		if (ports[port])
			emit(port, vid, tagged, pvid);
		else
			resolveMembers(cfg, ports, port, (vid != null) ? { vid: vid, tagged: tagged, pvid: pvid } : ctx, Object.assign({}, seen), out);
	};

	const vdev = cfg.vlans[name];
	const dotted = /^(.+)\.(\d{1,4})$/.exec(name);
	const parent = vdev ? vdev.parent : (dotted ? dotted[1] : null);
	const vid = vdev ? vdev.vid : (dotted ? +dotted[2] : null);
	const br = cfg.bridges[name];

	if (parent != null && !ports[name]) {
		const pbr = cfg.bridges[parent];

		if (pbr && pbr.filtering) {
			for (let v of pbr.vlans)
				if (v.vid == vid || v.aliases.indexOf(vid) > -1)
					for (let p of v.ports)
						leaf(p.name, v.vid, p.tagged, p.pvid);
		}
		else if (pbr) {
			for (let p of pbr.ports)
				leaf(p, vid, true, false);
		}
		else {
			leaf(parent, vid, true, false);
		}
	}
	else if (br) {
		for (let p of br.ports) {
			let native = null;

			/* On a filtering bridge the bridge itself is its ports' PVID. */
			if (br.filtering)
				for (let v of br.vlans)
					for (let bp of v.ports)
						if (bp.name == p && !bp.tagged && (bp.pvid || native == null))
							native = v.vid;

			leaf(p, native, false, native != null);
		}
	}
	else if (ports[name]) {
		emit(name, null, false, false);
	}

	return out;
}

function zoneMap(zones) {
	const map = {};

	for (let z of zones) {
		const color = hexToRGB(z.getColor());

		for (let n of z.getNetworks())
			if (!map[n])
				map[n] = { zone: z.getName(), color: color };
	}

	return map;
}

function pseInfo(raw) {
	if (!L.isObject(raw))
		return null;

	const status = raw['c33-power-status'] || raw['podl-power-status'] || null;
	const power = +raw['c33-actual-power'] || 0;

	return {
		status: status,
		power: power,
		delivering: status == 'delivering',
		fault: [ 'fault', 'otherfault', 'error' ].indexOf(status) > -1
	};
}

function speedClass(p) {
	if (p.disabled)
		return 'disabled';

	if (!p.link)
		return 'down';

	if (!(p.speed > 0))
		return 'up';

	return (p.speed < 1000) ? 'fe' : (p.speed > 1000) ? 'mgig' : 'gbe';
}

function formatSpeed(speed) {
	if (!(speed > 0))
		return null;

	if (speed < 1000)
		return _('%d Mbps').format(speed);

	return _('%s GbE').format(String(+(speed / 1000).toFixed(1)));
}

function formatBytes(n) {
	return (n != null) ? '%1024.1mB'.format(n) : '-';
}

function linkText(p) {
	if (!p.present)
		return _('Not present');

	if (p.disabled)
		return _('Disabled');

	if (!p.link)
		return _('No link');

	return formatSpeed(p.speed) || _('Connected');
}

function duplexText(p) {
	if (!p.link || !p.duplex)
		return null;

	return (p.duplex == 'half') ? _('Half duplex') : _('Full duplex');
}

function poeText(pse) {
	if (!pse || !pse.status)
		return null;

	if (pse.delivering)
		return pse.power ? '%.1f W'.format(pse.power / 1000) : _('Delivering');

	return {
		searching: _('Searching'),
		disabled: _('Off'),
		fault: _('Fault'),
		otherfault: _('Fault'),
		error: _('Fault')
	}[pse.status] || pse.status;
}

/* Build the ports: DSA from their netdevs, swconfig from the switch. */
function collect(res) {
	const cfg = readDeviceConfig();
	const zones = zoneMap(res.zones);
	const devstatus = L.isObject(res.devstatus) ? res.devstatus : {};
	const ports = [];
	const known = {};
	const cpus = {};

	for (let name in res.topologies) {
		const topo = res.topologies[name];

		for (let tp of (Array.isArray(topo.ports) ? topo.ports : []))
			if (isString(tp.device))
				cpus[tp.device] = true;
	}

	/* A board with a switch lists its CPU port's VLANs (eth0.1) as ports;
	 * those are the switch's ports, below. */
	for (let bp of res.builtin) {
		if (!L.isObject(bp) || !isString(bp.device) || known[bp.device] || cpus[bp.device.replace(/\.\d+$/, '')])
			continue;

		const dev = network.instantiateDevice(bp.device);
		const status = L.isObject(devstatus[bp.device]) ? devstatus[bp.device] : {};
		const present = (dev._devstate('idx') != null || dev._devstate('name') != null || status.present === true);
		const port = {
			id: bp.device,
			label: bp.device,
			device: bp.device,
			role: bp.role || 'lan',
			present: present,
			disabled: !present || !dev.isUp() || !!cfg.disabled[bp.device],
			link: present && dev.getCarrier(),
			speed: dev.getSpeed(),
			duplex: dev.getDuplex(),
			rx: present ? dev.getRXBytes() : null,
			tx: present ? dev.getTXBytes() : null,
			pse: pseInfo(dev._devstate('pse') || status.pse),
			bridge: null,
			members: []
		};

		for (let b in cfg.bridges)
			if (cfg.bridges[b].ports.indexOf(bp.device) > -1)
				port.bridge = { name: b, sid: cfg.bridges[b].sid, filtering: cfg.bridges[b].filtering };

		port.section = cfg.sections[bp.device] || null;
		known[bp.device] = port;
		ports.push(port);
	}

	ports.sort((a, b) => L.naturalCompare(a.device, b.device));

	/* Map every network onto the ports (and CPU netdevs) it reaches. */
	const targets = Object.assign({}, known);
	const cpumembers = {};

	for (let c in cpus)
		targets[c] = cpumembers[c] = { members: [] };

	const nets = res.networks.map((net) => net.getName()).filter(isString);

	for (let name of nets) {
		let dev = uci.get('network', name, 'device');

		if (isString(dev) && dev.charAt(0) == '@')
			dev = uci.get('network', dev.substring(1), 'device');

		if (!isString(dev))
			continue;

		for (let m of resolveMembers(cfg, targets, dev))
			targets[m.port].members.push({ vid: m.vid, tagged: m.tagged, pvid: m.pvid, net: name });
	}

	/* Bridge VLANs without a network on them still exist on the wire. */
	for (let b in cfg.bridges)
		if (cfg.bridges[b].filtering)
			for (let v of cfg.bridges[b].vlans)
				for (let p of v.ports)
					if (known[p.name])
						known[p.name].members.push({ vid: v.vid, tagged: p.tagged, pvid: p.pvid, net: null });

	/* swconfig: each switch's front ports, and the VLANs they carry. */
	for (let name in res.topologies) {
		const topo = res.topologies[name];
		const state = {};
		const feat = swFeatures[name] || {};
		const swports = (Array.isArray(topo.ports) ? topo.ports : []).filter((tp) => !isString(tp.device));
		const cpuports = (Array.isArray(topo.ports) ? topo.ports : []).filter((tp) => isString(tp.device));

		for (let ps of (res.portstate[name] || []))
			if (L.isObject(ps))
				state[ps.port] = ps;

		const vlans = uci.sections('network', 'switch_vlan').filter((s) => s.device == name).map((s) => {
			const vid = +((feat.vid_option ? s[feat.vid_option] : null) || s.vid || s.vlan);
			const specs = String(s.ports || '').split(/\s+/).map(parseSwitchPort).filter((p) => p != null);
			const vnets = [];

			for (let c of cpuports) {
				const spec = specs.find((p) => p.num == c.num);

				if (!spec)
					continue;

				for (let m of cpumembers[c.device].members)
					if ((spec.tagged ? m.vid == vid && m.tagged : m.vid == null) && vnets.indexOf(m.net) < 0)
						vnets.push(m.net);
			}

			return { vid: vid, specs: specs, nets: vnets };
		});

		for (let tp of swports) {
			const ps = state[tp.num] || {};
			const port = {
				id: '%s:%d'.format(name, tp.num),
				label: tp.label || _('Port %d').format(tp.num),
				device: null,
				switch: name,
				num: tp.num,
				role: /^wan/i.test(tp.label || '') ? 'wan' : 'lan',
				present: true,
				disabled: false,
				link: !!ps.link,
				speed: +ps.speed || null,
				duplex: ps.link ? (ps.duplex ? 'full' : 'half') : null,
				rx: null,
				tx: null,
				pse: null,
				bridge: null,
				members: []
			};

			for (let v of vlans) {
				const spec = v.specs.find((p) => p.num == tp.num);

				if (!spec)
					continue;

				if (!v.nets.length)
					port.members.push({ vid: v.vid, tagged: spec.tagged, pvid: !spec.tagged, net: null });

				for (let n of v.nets)
					port.members.push({ vid: v.vid, tagged: spec.tagged, pvid: !spec.tagged, net: n });
			}

			ports.push(port);
		}
	}

	/* Group memberships: the untagged VLAN(s) and networks, then the tagged. */
	for (let p of ports) {
		const groups = {};

		p.native = [];
		p.tagged = [];

		for (let m of p.members) {
			const key = (m.tagged ? 't' : 'u') + (m.vid != null ? m.vid : '');
			let g = groups[key];

			if (!g) {
				g = groups[key] = { vid: m.vid, pvid: false, nets: [] };
				(m.tagged ? p.tagged : p.native).push(g);
			}

			g.pvid = g.pvid || m.pvid;

			if (m.net != null && !g.nets.some((n) => n.name == m.net))
				g.nets.push({ name: m.net, zone: zones[m.net] ? zones[m.net].zone : null, color: zones[m.net] ? zones[m.net].color : null });
		}

		p.native.sort((a, b) => (b.pvid - a.pvid) || ((a.vid || 0) - (b.vid || 0)));
		p.tagged.sort((a, b) => a.vid - b.vid);
		p.state = speedClass(p);
		delete p.members;
	}

	/* The uplink: the one port a WAN network leaves through, else the WAN
	 * role's ports. */
	const wan = res.wan.map((n) => n.getName());
	const carries = (p) => p.native.concat(p.tagged).some((g) => g.nets.some((n) => wan.indexOf(n.name) > -1));
	let uplinks = ports.filter(carries);

	if (uplinks.length > 1)
		uplinks = uplinks.filter((p) => p.role == 'wan');

	if (uplinks.length != 1)
		uplinks = ports.filter((p) => p.role == 'wan');

	for (let p of ports)
		p.uplink = uplinks.indexOf(p) > -1;

	return {
		ports: ports,
		swconfig: Object.keys(res.topologies).length > 0,
		poe: ports.some((p) => p.pse != null),
		linked: ports.filter((p) => p.link && !p.disabled).length
	};
}

function zoneDot(net) {
	return E('i', {
		'class': 'uf-ports-zone',
		'style': net.color ? '--zone-color-rgb:%s'.format(net.color) : null,
		'title': net.zone ? _('Zone %s').format(net.zone) : _('No zone assigned')
	});
}

function netName(net) {
	return E('span', { 'class': 'uf-ports-net' }, [ zoneDot(net), net.name ]);
}

function vlanChip(g) {
	return E('span', { 'class': 'uf-ports-vlan' }, [
		E('b', {}, [ String(g.vid) ]),
		...g.nets.map(netName)
	]);
}

function nativeCell(p, compact) {
	if (!p.native.length)
		return E('span', { 'class': 'uf-ports-none' }, [ '-' ]);

	return E('span', { 'class': 'uf-ports-natives' }, p.native.map((g) => E('span', { 'class': 'uf-ports-native' }, [
		...(g.nets.length ? g.nets.map(netName) : [ E('span', { 'class': 'uf-ports-none' }, [ _('No network') ]) ]),
		(g.vid != null && !compact) ? E('small', {}, [ _('VLAN %d').format(g.vid) ]) : ''
	])));
}

function taggedCell(p) {
	if (!p.tagged.length)
		return E('span', { 'class': 'uf-ports-none' }, [ '-' ]);

	return E('span', { 'class': 'uf-ports-vlans' }, p.tagged.map(vlanChip));
}

/* The dot says whether there is link; with `speed` the text is the speed
 * (compact), else "Connected" beside a Speed column. */
function linkCell(p, speed) {
	const poe = poeText(p.pse);

	return E('span', { 'class': 'uf-ports-link', 'data-state': p.state }, [
		E('i', { 'class': 'uf-ports-dot' }),
		E('span', {}, [ (p.link && !p.disabled && !speed) ? _('Connected') : linkText(p) ]),
		poe ? E('span', { 'class': 'uf-ports-poe', 'data-fault': p.pse.fault ? '' : null }, [ poe ]) : ''
	]);
}

function speedCell(p) {
	if (!p.link || p.disabled)
		return E('span', { 'class': 'uf-ports-none' }, [ '-' ]);

	const duplex = duplexText(p);

	return E('span', { 'class': 'uf-ports-speed' }, [
		E('span', {}, [ formatSpeed(p.speed) || _('Unknown') ]),
		duplex ? E('small', { 'data-half': (p.duplex == 'half') ? '' : null }, [ duplex ]) : ''
	]);
}

function portCell(p) {
	return E('span', { 'class': 'uf-ports-name', 'data-state': p.state }, [
		E('i', { 'class': 'uf-ports-mini', 'data-uplink': p.uplink ? '' : null }),
		E('span', {}, [ p.label ]),
		p.uplink ? E('small', {}, [ _('Uplink') ]) : ''
	]);
}

/* A switch port (swconfig) has no counters of its own. */
function trafficCell(n, dir) {
	if (n == null)
		return E('span', { 'class': 'uf-ports-none' }, [ '-' ]);

	return E('span', { 'class': 'uf-ports-' + dir }, [ formatBytes(n) ]);
}

/* The Port Manager list; compact (the dashboard) folds the speed into the
 * link and leaves out the tagged VLANs. Received is what came in on the
 * port, so on the uplink it is the download. */
function list(data, compact) {
	const cols = compact ? [
		[ 'port', _('Port'), portCell ],
		[ 'link', _('Link'), (p) => linkCell(p, true) ],
		[ 'native', _('Network'), (p) => nativeCell(p, true) ],
		[ 'rx', _('RX'), (p) => trafficCell(p.rx, 'rx') ],
		[ 'tx', _('TX'), (p) => trafficCell(p.tx, 'tx') ]
	] : [
		[ 'port', _('Port'), portCell ],
		[ 'link', _('Link'), (p) => linkCell(p, false) ],
		[ 'speed', _('Speed'), speedCell ],
		[ 'native', _('Native VLAN'), (p) => nativeCell(p, false) ],
		[ 'tagged', _('Tagged VLANs'), taggedCell ],
		[ 'rx', _('RX'), (p) => trafficCell(p.rx, 'rx') ],
		[ 'tx', _('TX'), (p) => trafficCell(p.tx, 'tx') ]
	];

	return E('table', { 'class': 'table uf-ports-list' }, [
		E('tr', { 'class': 'tr table-titles' }, cols.map(([ name, title ]) => E('th', { 'class': 'th', 'data-name': name }, [ title ]))),
		...data.ports.map((p, i) => E('tr', {
			'class': 'tr cbi-rowstyle-%d'.format(i % 2 + 1),
			'data-port': p.id
		}, cols.map(([ name, title, fn ]) => E('td', { 'class': 'td', 'data-name': name, 'data-title': title }, [ fn(p) ]))))
	]);
}

function describe(p) {
	const parts = [ p.label, linkText(p) ];
	const duplex = duplexText(p);

	if (duplex)
		parts.push(duplex);

	if (p.uplink)
		parts.push(_('Uplink'));

	for (let g of p.native)
		parts.push(g.nets.map((n) => n.name).join(', ') || (g.vid != null ? _('VLAN %d').format(g.vid) : ''));

	return parts.filter((s) => s).join(', ');
}

/* Buttons even where choosing one does nothing: focus shows the details. */
function strip(data) {
	return E('div', { 'class': 'uf-ports-strip' }, data.ports.map((p) => E('button', {
		'type': 'button',
		'class': 'uf-port',
		'data-port': p.id,
		'data-state': p.state,
		'data-uplink': p.uplink ? '' : null,
		'data-poe': (p.pse && p.pse.delivering) ? '' : null,
		'aria-label': describe(p)
	}, [
		E('span', { 'class': 'uf-port-jack' }),
		E('span', { 'class': 'uf-port-label' }, [ p.label ])
	])));
}

function legend(data) {
	const item = (state, label, attrs) => E('li', Object.assign({ 'data-state': state }, attrs || {}), [ E('i'), label ]);

	return E('ul', { 'class': 'uf-ports-legend' }, [
		item('fe', _('FE')),
		item('gbe', _('GbE')),
		item('mgig', _('2.5 GbE+')),
		item('down', _('No link')),
		item('disabled', _('Disabled')),
		data.poe ? item('poe', _('PoE')) : '',
		data.ports.some((p) => p.uplink) ? item('uplink', _('Uplink')) : ''
	]);
}

/* The hover card: the port's link, networks, VLANs, power and traffic,
 * as label/value rows. */
function tipContent(p) {
	const rows = [];
	const row = (label, value) => rows.push(E('div', { 'class': 'uf-ports-tip-row' }, [ E('span', {}, [ label ]), E('span', {}, value) ]));
	const duplex = duplexText(p);
	const poe = poeText(p.pse);

	row(_('Link'), [ linkText(p), duplex ? ' · ' + duplex : '' ]);

	for (let g of p.native)
		row((g.vid != null) ? _('VLAN %d').format(g.vid) : _('Network'),
			g.nets.length ? g.nets.map(netName) : [ E('span', { 'class': 'uf-ports-none' }, [ _('No network') ]) ]);

	if (p.tagged.length)
		row(_('Tagged'), [ E('span', { 'class': 'uf-ports-vlans' }, p.tagged.map(vlanChip)) ]);

	if (poe)
		row(_('PoE'), [ poe ]);

	if (p.rx != null)
		row(_('Traffic'), [
			E('span', { 'class': 'uf-ports-rx' }, [ formatBytes(p.rx) ]),
			' ',
			E('span', { 'class': 'uf-ports-tx' }, [ formatBytes(p.tx) ])
		]);

	return [
		E('div', { 'class': 'uf-ports-tip-head', 'data-state': p.state }, [
			E('i', { 'class': 'uf-ports-mini', 'data-uplink': p.uplink ? '' : null }),
			E('strong', {}, [ p.label ]),
			p.uplink ? E('small', {}, [ _('Uplink') ]) : (p.role == 'wan' ? E('small', {}, [ _('WAN') ]) : '')
		]),
		...rows
	];
}

function hideTip() {
	if (tip)
		tip.removeAttribute('data-open');

	if (tipFor)
		tipFor.removeAttribute('aria-describedby');

	tipFor = null;
}

function showTip(root, btn) {
	const p = (root.ufData ? root.ufData.ports : []).find((p) => p.id == btn.getAttribute('data-port'));

	if (!p)
		return hideTip();

	if (!tip) {
		tip = document.body.appendChild(E('div', { 'class': 'uf-ports-tip', 'id': 'uf-ports-tip', 'role': 'tooltip' }));
		window.addEventListener('scroll', hideTip, { passive: true, capture: true });
		window.addEventListener('resize', hideTip, { passive: true });
		document.addEventListener('keydown', (ev) => { if (ev.key == 'Escape') hideTip(); });
	}

	dom.content(tip, tipContent(p));
	tip.setAttribute('data-open', '');

	/* Fixed, so it never widens the page; kept inside the window. */
	const r = btn.querySelector('.uf-port-jack').getBoundingClientRect();
	const vw = document.documentElement.clientWidth;
	const w = tip.offsetWidth;
	const h = tip.offsetHeight;
	let x = r.left + r.width / 2 - w / 2;
	let y = r.bottom + 8;

	x = Math.max(8, Math.min(x, vw - w - 8));

	if (y + h > window.innerHeight - 8 && r.top - h - 8 > 8)
		y = r.top - h - 8;

	tip.style.left = '%dpx'.format(Math.round(x));
	tip.style.top = '%dpx'.format(Math.round(y));

	if (tipFor && tipFor !== btn)
		tipFor.removeAttribute('aria-describedby');

	tipFor = btn;
	btn.setAttribute('aria-describedby', 'uf-ports-tip');
}

function bind(root) {
	const portOf = (ev) => {
		const btn = ev.target.closest ? ev.target.closest('.uf-port') : null;
		return (btn && root.contains(btn)) ? btn : null;
	};

	root.addEventListener('mouseover', (ev) => {
		const btn = portOf(ev);

		if (btn && btn !== tipFor)
			showTip(root, btn);
	});

	root.addEventListener('mouseout', (ev) => {
		const btn = portOf(ev);

		if (btn && !btn.contains(ev.relatedTarget) && document.activeElement !== btn)
			hideTip();
	});

	root.addEventListener('focusin', (ev) => {
		const btn = portOf(ev);

		if (btn)
			showTip(root, btn);
	});

	root.addEventListener('focusout', (ev) => {
		if (portOf(ev))
			hideTip();
	});

	root.addEventListener('click', (ev) => {
		const btn = portOf(ev);
		const p = btn ? root.ufData.ports.find((p) => p.id == btn.getAttribute('data-port')) : null;

		if (p && root.hasAttribute('data-clickable'))
			root.dispatchEvent(new CustomEvent('uf-port-select', { bubbles: true, detail: { port: p } }));
	});
}

/* Make `target` look like `fresh`, reusing target's nodes where the tags
 * match, so a poll never rebuilds what is hovered or focused. */
function patch(target, fresh) {
	if (target.nodeType != fresh.nodeType || target.nodeName != fresh.nodeName) {
		target.parentNode.replaceChild(fresh, target);
		return fresh;
	}

	if (target.nodeType != Node.ELEMENT_NODE) {
		if (target.nodeValue !== fresh.nodeValue)
			target.nodeValue = fresh.nodeValue;

		return target;
	}

	for (let a of Array.from(target.attributes))
		if (!fresh.hasAttribute(a.name))
			target.removeAttribute(a.name);

	for (let a of Array.from(fresh.attributes))
		if (target.getAttribute(a.name) !== a.value)
			target.setAttribute(a.name, a.value);

	const tc = Array.from(target.childNodes);
	const fc = Array.from(fresh.childNodes);

	fc.forEach((f, i) => {
		if (i < tc.length)
			patch(tc[i], f);
		else
			target.appendChild(f);
	});

	for (let i = fc.length; i < tc.length; i++)
		target.removeChild(tc[i]);

	if (fresh.ufData !== undefined)
		target.ufData = fresh.ufData;

	return target;
}

return baseclass.extend({
	load() {
		return Promise.all([
			L.resolveDefault(callBuiltinEthernetPorts(), []),
			L.resolveDefault(network.getSwitchTopologies(), {}),
			L.resolveDefault(network.getNetworks(), []),
			L.resolveDefault(network.getWANNetworks(), []),
			L.resolveDefault(network.getWAN6Networks(), []),
			L.resolveDefault(firewall.getZones(), []),
			L.resolveDefault(callNetworkDeviceStatus(), {}),
			L.resolveDefault(uci.load('network'))
		]).then(([ builtin, topologies, networks, wan, wan6, zones, devstatus ]) => {
			const res = {
				builtin: Array.isArray(builtin) ? builtin : [],
				topologies: L.isObject(topologies) ? topologies : {},
				networks: Array.isArray(networks) ? networks : [],
				wan: [].concat(wan || [], wan6 || []),
				zones: Array.isArray(zones) ? zones : [],
				devstatus: devstatus,
				portstate: {}
			};
			const tasks = [];

			/* Older rpcd-mod-luci has no getBuiltinEthernetPorts: read the
			 * ports from board.json, as it would. */
			if (!res.builtin.length)
				tasks.push(L.resolveDefault(fs.read('/etc/board.json'), '').then((json) => {
					let board = {};

					try { board = JSON.parse(json || '{}'); } catch (e) {}

					for (let role of [ 'lan', 'wan' ]) {
						const net = L.isObject(board.network) ? board.network[role] : null;

						if (!L.isObject(net))
							continue;

						if (Array.isArray(net.ports))
							net.ports.forEach((p) => res.builtin.push({ role: role, device: p }));
						else if (isString(net.device))
							res.builtin.push({ role: role, device: net.device });
					}
				}));

			for (let name in res.topologies) {
				if (!swFeatures[name])
					tasks.push(L.resolveDefault(callSwconfigFeatures(name), {}).then((f) => { swFeatures[name] = L.isObject(f) ? f : {}; }));

				tasks.push(L.resolveDefault(callSwconfigPortState(name), []).then((ps) => { res.portstate[name] = Array.isArray(ps) ? ps : []; }));
			}

			return Promise.all(tasks).then(() => collect(res));
		});
	},

	/**
	 * Render the ports. `opts.mode` is 'strip', 'compact' or 'full';
	 * `opts.clickable` makes the squares actionable (see uf-port-select).
	 * Returns null when there are no ports.
	 */
	render(data, opts) {
		opts = opts || {};

		if (!L.isObject(data) || !Array.isArray(data.ports) || !data.ports.length)
			return null;

		/* The body inside the root lays out by the root's width (a container
		 * query cannot style the container itself). */
		const mode = [ 'strip', 'compact', 'full' ].indexOf(opts.mode) > -1 ? opts.mode : 'strip';
		const root = E('div', { 'class': 'uf-ports', 'data-mode': mode, 'data-clickable': opts.clickable ? '' : null }, [
			E('div', { 'class': 'uf-ports-body' }, [
				E('div', { 'class': 'uf-ports-map' }, [ strip(data), legend(data) ]),
				(mode != 'strip') ? list(data, mode == 'compact') : ''
			])
		]);

		root.ufData = data;
		bind(root);

		return root;
	},

	/** "3 of 5 connected", for a card's caption. */
	summary(data) {
		if (!L.isObject(data) || !Array.isArray(data.ports) || !data.ports.length)
			return '';

		return _('%d of %d connected').format(data.linked, data.ports.length);
	},

	/**
	 * A card around a rendered node: `opts.title`, `opts.desc` and
	 * `opts.actions` (nodes on the title's line).
	 */
	card(body, opts) {
		opts = opts || {};

		return E('div', { 'class': 'cbi-section uf-ports-card' }, [
			E('div', { 'class': 'uf-ports-head' }, [
				E('div', {}, [
					E('h3', {}, [ opts.title || _('Ports') ]),
					opts.desc ? E('div', { 'class': 'cbi-section-descr' }, [ opts.desc ]) : ''
				]),
				opts.actions ? E('div', { 'class': 'uf-ports-actions' }, opts.actions) : ''
			]),
			body
		]);
	},

	/**
	 * Update `node` (rendered earlier) to look like `fresh`; returns the
	 * node now in the document. Either may be null.
	 */
	patch(node, fresh) {
		if (!node)
			return fresh;

		if (!fresh) {
			if (node.parentNode)
				node.parentNode.removeChild(node);

			if (tipFor && !tipFor.isConnected)
				hideTip();

			return null;
		}

		const kept = node.parentNode ? patch(node, fresh) : fresh;

		/* Keep an open tooltip current, or close it with its port. */
		if (tipFor && kept.contains(tipFor))
			showTip(tipFor.closest('.uf-ports'), tipFor);
		else if (tipFor && !tipFor.isConnected)
			hideTip();

		return kept;
	}
});
