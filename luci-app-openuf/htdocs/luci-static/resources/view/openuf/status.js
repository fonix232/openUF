'use strict';
'require view';
'require rpc';
'require ui';

// openUF status (luci-app-openuf). Everything shown comes from the
// luci.openuf rpcd backend (root/usr/share/rpcd/ucode/luci.openuf); the
// Settings toggles are its one write.

const callStatus = rpc.declare({
	object: 'luci.openuf',
	method: 'status',
	expect: { '': {} }
});

const SETTING_KEYS = [ 'use_only_unifi_wlan', 'sta_events', 'l2guard', 'rrm_enrichment',
	'system_timezone', 'system_ntp', 'system_cron' ];

const callSetSettings = rpc.declare({
	object: 'luci.openuf',
	method: 'set_settings',
	params: SETTING_KEYS,
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

// Values from state files and conf.lua are inserted as text, never as markup
// (LuCI's E() treats a string child as HTML).
function T(s) {
	return document.createTextNode(String(s));
}

function yesno(v) {
	return v ? _('yes') : _('no');
}

function value(v, fallback) {
	return (v === null || v === undefined || v === '') ? E('em', {}, fallback || _('not set')) : T(v);
}

// A settings row's label: the name with a line on what it does underneath.
function described(label, text) {
	return E('span', {}, [ label, E('div', { 'class': 'cbi-value-description' }, text) ]);
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
		const own = conf.own_config !== 'false';
		const set = s.settings || {}, sv = set.values || {}, locked = set.locked || [];
		const editable = set.editable && L.hasViewPermission();
		const widgets = {}, initial = {};
		const toggle = function(key, label, text) {
			const fixed = locked.indexOf(key.replace(/^system_.*/, 'controller_system')) >= 0;
			initial[key] = !!sv[key];
			widgets[key] = new ui.Checkbox(sv[key] ? '1' : '0', { disabled: !editable || fixed });
			return [ described(label, fixed ? _('Set by an expression in conf.lua; change it there.') : text),
				widgets[key].render() ];
		};
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
				[ _('Last controller contact'), T(hb.last_ok ? '%s (%s)'.format(ago(now, hb.last_ok), hb.last_type || '-') : _('never')) ],
				hb.last_fail ? [ _('Last failure'), T('%s: %s'.format(ago(now, hb.last_fail), hb.last_fail_msg || '-')) ] : null
			]),

			section(_('Controller'), [
				[ _('Inform URL'), value(ctl.inform_url) ],
				[ _('Adopted'), badge(ctl.adopted, _('adopted'), _('pending adoption')) ],
				[ _('Configuration'), ctl.cfgversion
					? E('span', {}, [ badge(applied, _('applied'), _('not applied')), ' ', T(ctl.cfgversion) ])
					: E('em', {}, _('none received yet')) ],
				(!applied && ctl.cfgversion_effective) ? [ _('Last applied configuration'), T(ctl.cfgversion_effective) ] : null,
				[ _('Wake-up (STUN)'), value(ctl.stun_url) ],
				ctl.upgrade_requested ? [ _('Upgrade requested'), T(ctl.upgrade_requested) ] : null
			]),

			section(_('Identity'), [
				[ _('Presented as'), cat.name ? T('%s (%s, %s)'.format(cat.name, cat.sku, id.model)) : value(id.model) ],
				cat.sysid ? [ _('System ID'), T(cat.sysid) ] : null,
				[ _('Reported firmware'), value(ctl.fw_version || cat.fw) ],
				[ _('Identity MAC'), value(id.mac) ],
				[ _('Management address'), id.ip ? T(id.addressing ? '%s (%s)'.format(id.ip, id.addressing === 'dhcp' ? _('DHCP') : _('static')) : id.ip) : value(null) ],
				[ _('Hostname'), value(id.hostname) ]
			]),

			section(_('Hardware'), [
				[ _('Model map'), value(hw.modelmap) ],
				[ _('Uplink socket'), value(hw.uplink) ],
				[ _('Ports'), ports.length ? E('span', {}, ports.map(function(p) { return E('div', {}, T(p)); })) : E('em', {}, _('none')) ],
				[ _('Radios'), (hw.radios || []).length ? T(hw.radios.join(', ')) : E('em', {}, _('none')) ],
				[ _('Locate LED'), value(hw.led) ]
			]),

			section(_('Network ownership'), [
				[ _('Bridge backend'), value(conf.bridge_backend, 'auto') ],
				[ _('Controller owns interfaces and SSIDs'), yesno(conf.own_config !== 'false') ],
				[ _('Applied network plan'), value(net.applied, _('none')) ],
				net.pending ? [ _('Rollback window'), _('open: the plan is rolled back unless the controller answers') ] : null,
				net.failed ? [ _('Rolled-back plan'), T(net.failed) ] : null,
				(net.removed || []).length ? [ _('Removed interfaces'), T(net.removed.join(', ')) ] : null,
				[ _('Original config saved'), [
					net.network_backup ? _('network') : null,
					net.wireless_backup ? _('wireless') : null
				].filter(function(x) { return x; }).join(', ') || E('em', {}, _('none')) ]
			]),

			section(_('Firmware upgrades'), [
				[ _('Reinstall on new images'), badge(up.bootstrap && up.bootstrap_enabled, _('ready'), _('not set up')) ],
				[ _('Kept copy of this build'), up.cached_build ? T('%1024.1mB'.format(up.cached_build)) : E('em', {}, _('none')) ],
				[ _('Kept copy of conf.lua'), yesno(up.conf_backup) ],
				[ _('Controller upgrades'), conf.upgrade_mode === 'owut' ? _('run an attended sysupgrade (owut)') : _('recorded only') ]
			]),

			section(_('Settings'), [
				toggle('use_only_unifi_wlan', _('Controller WLANs only'), own
					? _('Removes SSIDs the controller did not create; the original wireless config is kept in /etc/openuf. Switching this off does not bring them back.')
					: _('Disables SSIDs the controller did not create. Switching this off enables them again.')),
				toggle('sta_events', _('Connection events'),
					_('Reports clients connecting and leaving, for the controller\'s client history and connectivity view.')),
				toggle('system_timezone', _('Controller timezone'),
					_('Uses the site timezone set in the controller.')),
				toggle('system_ntp', _('Controller NTP servers'),
					_('Uses the controller\'s NTP servers. Switching this off keeps the current servers until you change them.')),
				toggle('system_cron', _('Controller scheduled scan'),
					_('Runs the controller\'s nightly neighbouring-AP scan. Switching this off removes the job.')),
				toggle('l2guard', _('L2 hardening'),
					_('Drops STP BPDUs and VLAN-tagged frames from WiFi clients, as UniFi APs do.')),
				toggle('rrm_enrichment', _('802.11k neighbour reports'),
					_('Asks 802.11k-capable clients to report the APs they can hear. A client that takes part spends about a second off-channel.')),
				conf.country_override ? [ _('Regulatory override'), T(conf.country_override) ] : null,
				conf.debug_dump_file ? [ _('Debug capture'), T(conf.debug_dump_file) ] : null
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('p', { 'class': 'cbi-value-description' },
					_('Saving restarts openUF, which takes a few seconds. WLAN, system and L2 changes also have the controller send its configuration again, applied at the next check-in.')),
				E('button', {
					'class': 'btn cbi-button cbi-button-apply important',
					'disabled': editable ? null : '',
					'click': ui.createHandlerFn(this, 'handleSettingsSave', widgets, initial)
				}, _('Save & Apply'))
			]),

			section(_('Diagnostics'), [
				[ _('Unhandled controller messages'), T(_('%d kinds (/etc/openuf/unhandled.json)').format(diag.unhandled || 0)) ],
				[ _('Blocked clients'), T(diag.blocked_clients || 0) ]
			])
		]);
	},

	handleSettingsSave: function(widgets, initial) {
		const want = {};
		let n = 0;
		SETTING_KEYS.forEach(function(k) {
			if (widgets[k] && widgets[k].isChecked() !== initial[k]) {
				want[k] = widgets[k].isChecked();
				n++;
			}
		});
		if (!n) {
			ui.addNotification(null, E('p', {}, _('No settings changed.')), 'info');
			return;
		}
		ui.showModal(_('Applying settings'), [
			E('p', { 'class': 'spinning' }, _('Saving conf.lua and restarting openUF…'))
		]);
		return callSetSettings.apply(null, SETTING_KEYS.map(function(k) { return want[k]; })).then(function(r) {
			if (r.error) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, T(_('Settings not saved: %s').format(r.error))), 'danger');
				return;
			}
			window.location.reload();
		}).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, T(_('Settings not saved: %s').format(err.message || err))), 'danger');
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
