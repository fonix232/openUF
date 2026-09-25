'use strict';
'require view';
'require rpc';
'require ui';

// openUF status (luci-app-openuf): read-only for now. Everything shown comes
// from the luci.openuf rpcd backend (root/usr/share/rpcd/ucode/luci.openuf).

const callStatus = rpc.declare({
	object: 'luci.openuf',
	method: 'status',
	expect: { '': {} }
});

function ago(now, t) {
	if (!t)
		return _('never');
	const s = Math.max(0, now - t);
	if (s < 60)
		return _('%ds ago').format(s);
	if (s < 3600)
		return _('%dm %ds ago').format(Math.floor(s / 60), s % 60);
	if (s < 86400)
		return _('%dh %dm ago').format(Math.floor(s / 3600), Math.floor(s % 3600 / 60));
	return _('%dd %dh ago').format(Math.floor(s / 86400), Math.floor(s % 86400 / 3600));
}

function badge(ok, yes, no) {
	return E('span', {
		'class': 'label',
		'style': 'background:%s;color:#fff;padding:1px 6px;border-radius:3px'.format(ok ? '#4caf50' : '#e0a030')
	}, ok ? yes : no);
}

function yesno(v) {
	return v ? _('yes') : _('no');
}

function value(v, fallback) {
	return (v === null || v === undefined || v === '') ? E('em', {}, fallback || _('not set')) : String(v);
}

function section(title, rows) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, title),
		E('table', { 'class': 'table' }, rows.filter(function(r) { return r; }).map(function(r) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'style': 'width:33%' }, r[0]),
				E('td', { 'class': 'td left' }, r[1])
			]);
		}))
	]);
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	render: function(s) {
		const now = s.now || Math.floor(Date.now() / 1000);
		const svc = s.service || {}, hb = s.heartbeat || {}, ctl = s.controller || {};
		const id = s.identity || {}, hw = s.hardware || {}, net = s.network || {};
		const up = s.upgrade || {}, diag = s.diagnostics || {}, conf = s.config || {};
		const cat = id.catalogue || {};

		if (!svc.installed)
			return E('div', { 'class': 'cbi-map' }, [
				E('h2', {}, _('openUF')),
				E('p', {}, _('openUF is not installed in /opt/openuf.'))
			]);

		const applied = ctl.cfgversion && ctl.cfgversion_effective === ctl.cfgversion;
		const ports = (hw.ports || []).map(function(p) {
			return _('Port %d: %s').format(p.idx, p.ifname) + (p.ifname === hw.uplink ? ' ' + _('(uplink)') : '');
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('openUF')),
			E('div', { 'class': 'cbi-map-descr' },
				_('This access point presents itself to a UniFi Network controller as a UniFi device. The controller manages its WiFi, VLANs and bridge; this page shows what openUF is doing.')),

			section(_('Service'), [
				[ _('Daemon'), badge(svc.running, _('running'), _('stopped')) ],
				[ _('Start at boot'), yesno(svc.enabled) ],
				[ _('L2 discovery broadcasts'), svc.announcing ? _('on') : _('off') ],
				[ _('Build'), value(svc.build) ],
				[ _('Last controller contact'), hb.last_ok ? '%s (%s)'.format(ago(now, hb.last_ok), hb.last_type || '-') : _('never') ],
				hb.last_fail ? [ _('Last failure'), '%s: %s'.format(ago(now, hb.last_fail), hb.last_fail_msg || '-') ] : null
			]),

			section(_('Controller'), [
				[ _('Inform URL'), value(ctl.inform_url) ],
				[ _('Adopted'), badge(ctl.adopted, _('adopted'), _('pending adoption')) ],
				[ _('Configuration'), ctl.cfgversion
					? E('span', {}, [ badge(applied, _('applied'), _('not applied')), ' ', ctl.cfgversion ])
					: E('em', {}, _('none received yet')) ],
				(!applied && ctl.cfgversion_effective) ? [ _('Last applied configuration'), ctl.cfgversion_effective ] : null,
				[ _('Wake-up (STUN)'), value(ctl.stun_url) ],
				ctl.upgrade_requested ? [ _('Upgrade requested'), ctl.upgrade_requested ] : null
			]),

			section(_('Identity'), [
				[ _('Presented as'), cat.name ? '%s (%s, %s)'.format(cat.name, cat.sku, id.model) : value(id.model) ],
				cat.sysid ? [ _('System ID'), cat.sysid ] : null,
				[ _('Reported firmware'), value(ctl.fw_version || cat.fw) ],
				[ _('Identity MAC'), value(id.mac) ],
				[ _('Management address'), id.ip ? (id.addressing ? '%s (%s)'.format(id.ip, id.addressing === 'dhcp' ? _('DHCP') : _('static')) : id.ip) : value(null) ],
				[ _('Hostname'), value(id.hostname) ]
			]),

			section(_('Hardware'), [
				[ _('Model map'), value(hw.modelmap) ],
				[ _('Uplink socket'), value(hw.uplink) ],
				[ _('Ports'), ports.length ? E('span', {}, ports.map(function(p) { return E('div', {}, p); })) : E('em', {}, _('none')) ],
				[ _('Radios'), (hw.radios || []).join(', ') || E('em', {}, _('none')) ],
				[ _('Locate LED'), value(hw.led) ]
			]),

			section(_('Network ownership'), [
				[ _('Bridge backend'), value(conf.bridge_backend, 'auto') ],
				[ _('Controller owns interfaces and SSIDs'), yesno(conf.own_config !== 'false') ],
				[ _('Applied network plan'), value(net.applied, _('none')) ],
				net.pending ? [ _('Rollback window'), _('open: the plan is rolled back unless the controller answers') ] : null,
				net.failed ? [ _('Rolled-back plan'), net.failed ] : null,
				(net.removed || []).length ? [ _('Removed interfaces'), net.removed.join(', ') ] : null,
				[ _('Original config saved'), [
					net.network_backup ? _('network') : null,
					net.wireless_backup ? _('wireless') : null
				].filter(function(x) { return x; }).join(', ') || E('em', {}, _('none')) ]
			]),

			section(_('Firmware upgrades'), [
				[ _('Reinstall on new images'), badge(up.bootstrap && up.bootstrap_enabled, _('ready'), _('not set up')) ],
				[ _('Kept copy of this build'), up.cached_build ? '%1024.1mB'.format(up.cached_build) : E('em', {}, _('none')) ],
				[ _('Kept copy of conf.lua'), yesno(up.conf_backup) ],
				[ _('Controller upgrades'), conf.upgrade_mode === 'owut' ? _('run an attended sysupgrade (owut)') : _('recorded only') ]
			]),

			section(_('Settings'), [
				[ _('Controller WLANs only'), yesno(conf.use_only_unifi_wlan !== 'false') ],
				[ _('Connection events'), yesno(conf.sta_events !== 'false') ],
				[ _('Controller time, NTP and cron'), yesno(conf.controller_system !== 'false') ],
				[ _('L2 hardening'), yesno(conf.l2guard !== 'false') ],
				[ _('802.11k neighbour reports'), yesno(conf.rrm_enrichment !== 'false') ],
				conf.country_override ? [ _('Regulatory override'), conf.country_override ] : null,
				conf.debug_dump_file ? [ _('Debug capture'), conf.debug_dump_file ] : null
			]),

			section(_('Diagnostics'), [
				[ _('Unhandled controller messages'), _('%d kinds (/etc/openuf/unhandled.json)').format(diag.unhandled || 0) ],
				[ _('Blocked clients'), String(diag.blocked_clients || 0) ]
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
