'use strict';
'require view';
'require form';

// openUF settings (luci-app-openuf): /etc/config/openuf, section `main`.
// Saving restarts the daemon (procd's reload trigger on the openuf config).
// Defaults mirror /usr/share/openuf/config.lua; USAGE.md documents each one.

// A checkbox that always writes 0/1: a default-on option removed from the
// file would read as on again.
function flag(s, tab, name, title, description, def) {
	const o = s.taboption(tab, form.Flag, name, title, description);
	o.default = def ? '1' : '0';
	o.rmempty = false;
	return o;
}

return view.extend({
	render: function() {
		const m = new form.Map('openuf', _('openUF settings'),
			_('How this access point presents itself to a UniFi Network controller, and what it lets the controller manage. Saving restarts openUF, which takes a few seconds; settings that change what the controller provisions also have it send its configuration again.'));

		const s = m.section(form.NamedSection, 'main', 'openuf');
		s.addremove = false;
		s.tab('controller', _('Controller'));
		s.tab('features', _('Controller features'));
		s.tab('network', _('Network'));
		s.tab('upgrades', _('Firmware upgrades'));
		s.tab('advanced', _('Advanced'));

		// ── Controller ────────────────────────────────────────────────────
		let o = s.taboption('controller', form.Value, 'inform_url', _('Inform URL'),
			_('Where an unadopted AP looks for the controller. Once adopted, the URL the controller assigned is used instead.'));
		o.placeholder = 'http://unifi:8080/inform';
		o.validate = function(section_id, value) {
			return (!value || /^https?:\/\/\S+$/.test(value)) ? true : _('An http:// or https:// URL');
		};

		flag(s, 'controller', 'l2_announce', _('L2 discovery broadcasts'),
			_('Announce the AP on its subnet so the controller lists it for adoption. Off for adoption through the inform URL only.'), true);
		flag(s, 'controller', 'ssh_adopt', _('SSH adoption account'),
			_('A temporary ubnt/ubnt login that can only run the adoption command, for a controller that adopts over SSH. Locked once adopted.'), false);
		flag(s, 'controller', 'stun', _('Wake-up (STUN)'),
			_('Let the controller ask for an immediate check-in instead of waiting for the next one.'), true);

		// ── Controller features ───────────────────────────────────────────
		flag(s, 'features', 'use_only_unifi_wlan', _('Controller WLANs only'),
			_('Take SSIDs the controller did not create off the air. With "Controller owns interfaces and SSIDs" they are removed (a copy of the original wireless config is kept in /etc/openuf); otherwise they are disabled and come back when this is switched off.'), true);
		flag(s, 'features', 'sta_events', _('Connection events'),
			_('Report clients connecting and leaving, and time each connection, for the controller\'s client history and WiFi Connectivity view.'), true);
		flag(s, 'features', 'system_timezone', _('Controller timezone'),
			_('Use the site timezone set in the controller.'), true);
		flag(s, 'features', 'system_ntp', _('Controller NTP servers'),
			_('Use the controller\'s NTP servers. Switching this off keeps the current servers until you change them.'), true);
		flag(s, 'features', 'system_cron', _('Controller scheduled scan'),
			_('Run the controller\'s nightly neighbouring-AP scan. Switching this off removes the job.'), true);
		flag(s, 'features', 'l2guard', _('L2 hardening'),
			_('Drop STP BPDUs and VLAN-tagged frames from WiFi clients, as UniFi APs do.'), true);
		flag(s, 'features', 'rrm_enrichment', _('802.11k neighbour reports'),
			_('Ask 802.11k-capable clients to report the APs they can hear. A client that takes part spends about a second off-channel.'), true);
		o = s.taboption('features', form.Value, 'rrm_request_interval', _('Neighbour report interval'),
			_('Seconds between two requests.'));
		o.datatype = 'range(60,86400)';
		o.placeholder = '600';
		o.depends('rrm_enrichment', '1');

		// ── Network ───────────────────────────────────────────────────────
		flag(s, 'network', 'own_config', _('Controller owns interfaces and SSIDs'),
			_('Remove interfaces and SSIDs the controller did not ask for, so the AP carries exactly what it pushed. The originals are kept in /etc/openuf.'), true);
		o = s.taboption('network', form.ListValue, 'bridge_backend', _('VLAN bridge'),
			_('How the controller\'s VLANs are built: one VLAN-filtering bridge, or a bridge per VLAN.'));
		o.value('auto', _('Automatic'));
		o.value('vlan_filtering', _('VLAN-filtering bridge'));
		o.value('bridges', _('A bridge per VLAN'));
		o.default = 'auto';
		flag(s, 'network', 'bridge_takeover', _('Rebuild the bridge'),
			_('Let openUF rebuild the management bridge for the controller\'s VLANs, with an automatic rollback if the AP loses the controller.'), true);
		o = s.taboption('network', form.Value, 'bridge_rollback_timeout', _('Rollback after'),
			_('Seconds without the controller before a new network plan is rolled back.'));
		o.datatype = 'range(30,3600)';
		o.placeholder = '180';
		o.depends('bridge_takeover', '1');
		o = s.taboption('network', form.ListValue, 'port_default', _('Ports without a profile'),
			_('What a wired port the controller has not configured carries besides the native VLAN.'));
		o.value('all', _('All VLANs, tagged'));
		o.value('none', _('Native VLAN only'));
		o.default = 'all';
		o = s.taboption('network', form.Value, 'country_override', _('Regulatory override'),
			_('Program this country\'s regulatory domain instead of the controller\'s (which is still reported). For a driver that cannot do DFS. Channel use and transmit power are legal limits: leave empty unless you mean it.'));
		o.placeholder = _('off');
		o.validate = function(section_id, value) {
			return (!value || /^[A-Z]{2}$/.test(value)) ? true : _('Two capital letters, e.g. US');
		};

		// ── Firmware upgrades ─────────────────────────────────────────────
		o = s.taboption('upgrades', form.ListValue, 'upgrade_mode', _('Controller upgrades'),
			_('What the controller\'s Upgrade button does. owut builds an image for this board with its packages kept; openUF reinstalls itself from its feed on the first boot.'));
		o.value('', _('Record only'));
		o.value('owut', _('Attended sysupgrade (owut)'));
		flag(s, 'upgrades', 'advertise_updates', _('Show available updates'),
			_('Check for a newer OpenWrt build and show it in the controller as an available upgrade.'), false)
			.depends('upgrade_mode', 'owut');
		o = s.taboption('upgrades', form.Value, 'advertise_interval', _('Check every'),
			_('Seconds between two checks.'));
		o.datatype = 'range(3600,604800)';
		o.placeholder = '21600';
		o.depends('advertise_updates', '1');

		// ── Advanced ──────────────────────────────────────────────────────
		o = s.taboption('advanced', form.Value, 'stun_local_port', _('STUN local port'));
		o.datatype = 'port';
		o.placeholder = '3478';
		o = s.taboption('advanced', form.Value, 'cfg_retries', _('Configuration retries'),
			_('How often a configuration push that failed to apply is asked for again.'));
		o.datatype = 'range(0,10)';
		o.placeholder = '2';
		o = s.taboption('advanced', form.Value, 'unhandled_file', _('Unhandled-message ledger'),
			_('Where messages openUF did not act on are recorded; "off" keeps them in memory only.'));
		o.placeholder = '/etc/openuf/unhandled.json';
		o = s.taboption('advanced', form.Value, 'debug_dump_file', _('Debug capture'),
			_('Append every decrypted controller message to this file. For protocol research; leave empty.'));
		o.placeholder = _('off');
		flag(s, 'advanced', 'debug_dump_requests', _('Capture what openUF sends'),
			_('Also log openUF\'s own messages and transport errors.'), false)
			.depends({ debug_dump_file: /./ });

		return m.render();
	}
});
