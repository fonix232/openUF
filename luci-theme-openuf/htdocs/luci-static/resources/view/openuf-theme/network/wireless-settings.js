'use strict';
'require baseclass';
'require uci';

/*
 * Network > Wireless drawn as UniFi's Settings > WiFi list: the "settings"
 * design (luci-static/openuf/network/wireless-settings.css). LuCI writes a
 * row's facts as "Label: value" runs that CSS cannot tell apart, and puts
 * no column titles over these lists. This names each fact (data-uf-key),
 * sets the translated column titles on the list (--uf-th-*), words each
 * radio's state (data-uf-state, data-uf-status), and adds, from the
 * configuration, what a UniFi list shows but LuCI's rows leave out: a
 * radio's band and channel, a wireless network's security and the network
 * it serves. It also splits each station's rates from their PHY details,
 * names the icon that disconnects a station, and marks the long names
 * (SSIDs, hosts, their networks) that fade out at their end
 * (data-uf-fade).
 *
 * It only adds attributes to LuCI's nodes (and takes back its own), never
 * moves, removes or re-renders them. LuCI redraws the rows every few
 * seconds, so it tags them again after each redraw; markup it does not
 * recognise it leaves alone, and the stylesheet keeps LuCI's own runs.
 * menu-openuf.js calls enhance() on this page.
 */

const ENCRYPTION = {
	'none': () => _('No Encryption'),
	'owe': 'OWE',
	'psk': 'WPA',
	'psk2': 'WPA2',
	'psk-mixed': 'WPA/WPA2',
	'psk+psk2': 'WPA/WPA2',
	'sae': 'WPA3',
	'sae-mixed': 'WPA2/WPA3',
	'sae-compat': 'WPA2/WPA3',
	'wpa': 'WPA-EAP',
	'wpa2': 'WPA2-EAP',
	'wpa3': 'WPA3-EAP',
	'wpa3-mixed': 'WPA2/WPA3-EAP',
	'wpa3-192': 'WPA3-EAP 192',
	'wep': 'WEP',
	'wep-open': 'WEP',
	'wep-shared': 'WEP'
};

const BANDS = { '2g': '2.4 GHz', '5g': '5 GHz', '6g': '6 GHz', '60g': '60 GHz' };

/* A CSS string, for content: var(...). */
function cssString(s) {
	return '"' + String(s).replace(/[\\"]/g, '\\$&').replace(/[\n\r]+/g, ' ') + '"';
}

/* Set only on change, so a pass over unchanged rows writes nothing; null
 * takes the attribute back. */
function attr(node, name, value) {
	if (value == null)
		node.removeAttribute(name);
	else if (node.getAttribute(name) !== value)
		node.setAttribute(name, value);
}

function prop(node, name, value) {
	if (node.style.getPropertyValue(name) !== value)
		node.style.setProperty(name, value);
}

/* A long name fades out at its end and slides into view on hover:
 * fade.js measures what is marked and rewrites the mark, so it is set
 * only once. */
function fade(node) {
	if (node && !node.hasAttribute('data-uf-fade'))
		node.setAttribute('data-uf-fade', '');
}

/* A run's value, without its label. */
function value(item) {
	const label = item.querySelector(':scope > strong');

	return (label ? item.textContent.slice(label.textContent.length) : item.textContent).trim();
}

return baseclass.extend({
	enhance() {
		const view = document.querySelector('#view');

		if (!view || this.labels)
			return;

		this.labels = {
			[_('SSID')]: 'ssid',
			[_('Mesh ID')]: 'ssid',
			[_('Mode')]: 'mode',
			[_('BSSID')]: 'bssid',
			[_('Encryption')]: 'encryption',
			[_('Channel')]: 'channel',
			[_('Bitrate')]: 'bitrate'
		};

		this.values = {
			[_('Wireless is disabled')]: 'disabled',
			[_('Device is not active')]: 'inactive'
		};

		/* A radio's state, as its chip reads. */
		this.words = {
			active: _('Active'),
			down: _('Down'),
			disabled: _('Disabled')
		};

		/* Tag after LuCI's redraw has settled, once per frame at most. */
		let queued = false;

		new MutationObserver(() => {
			if (queued)
				return;

			queued = true;
			window.requestAnimationFrame(() => {
				queued = false;
				this.tag(view);
			});
		}).observe(view, { childList: true, subtree: true });

		this.tag(view);
	},

	tag(view) {
		try {
			const wifi = view.querySelector('#cbi-wireless-wifi-device');
			const assoc = view.querySelector('#wifi_assoclist_table');

			if (wifi)
				this.tagWireless(wifi);

			if (assoc)
				this.tagStations(assoc);
		}
		catch (e) {
			/* Unfamiliar markup: leave the page as LuCI drew it. */
		}
	},

	/* "Label: value" runs (L.itemlist) and bare notes, named by label;
	 * returns the first run of each name. */
	tagItems(list) {
		const found = {};

		for (const item of list.children) {
			let key = null;

			if (item.matches('span.nowrap')) {
				const label = item.querySelector(':scope > strong');

				key = label ? (this.labels[label.textContent.replace(/:\s*$/, '')] ?? 'other') : 'note';

				if (key == 'note')
					key = this.values[value(item)] ?? key;
			}
			else if (item.matches('em')) {
				key = this.values[item.textContent.trim()] ?? 'note';
			}
			else if (item.matches('a')) {
				key = 'note';
			}

			if (key) {
				attr(item, 'data-uf-key', key);
				found[key] = found[key] ?? item;
			}
		}

		return found;
	},

	titles(node, titles) {
		for (const name in titles)
			prop(node, '--uf-th-' + name, cssString(titles[name]));
	},

	tagWireless(section) {
		this.titles(section, {
			name: _('Name'),
			network: _('Network'),
			mode: _('Mode'),
			security: _('Encryption'),
			signal: _('Signal'),
			status: _('Status')
		});

		for (const row of section.querySelectorAll('.cbi-section-table-row[data-sid]')) {
			const sid = row.getAttribute('data-sid');
			const stat = row.querySelector('[data-name="_stat"]');

			if (!stat)
				continue;

			/* A radio names its hardware in <big>, except for the moment it
			 * restarts. */
			if (uci.get('wireless', sid, '.type') == 'wifi-device' || stat.querySelector(':scope > div > big'))
				this.tagRadio(row, stat, sid);
			else
				this.tagNetwork(row, stat, sid);
		}
	},

	/* A radio heads its group: its state as a chip after its name, its
	 * band and channel as configured, then its hardware and bitrate. While
	 * it is up, the channel "auto" chose; while it is down, the configured
	 * one. The stylesheet then leaves out LuCI's live runs, which say
	 * nothing more. */
	tagRadio(row, stat, sid) {
		const badge = row.querySelector('[data-name="_badge"] .ifacebadge');
		const hardware = stat.querySelector(':scope > div > big');
		const band = uci.get('wireless', sid, 'band');
		const channel = uci.get('wireless', sid, 'channel') || 'auto';
		const width = (uci.get('wireless', sid, 'htmode') || '').match(/(\d+)$/);
		const items = {};

		for (const list of stat.querySelectorAll(':scope > div > div'))
			Object.assign(items, this.tagItems(list));

		let state = null;

		if (uci.get('wireless', sid, 'disabled') == '1')
			state = 'disabled';
		else if (items.channel || items.bitrate)
			state = 'active';
		else if (items.inactive)
			state = 'down';

		/* "6 (2.437 GHz)" is channel 6. */
		const live = (state == 'active' && items.channel) ? value(items.channel).replace(/\s*\(.*$/, '') : null;

		attr(row, 'data-uf-row', 'radio');
		attr(row, 'data-uf-state', state);

		if (badge)
			attr(badge, 'data-uf-status', this.words[state] ?? null);

		if (hardware)
			attr(hardware, 'data-uf-bitrate', (state == 'active' && items.bitrate) ? value(items.bitrate) : null);

		attr(stat, 'data-uf-band', BANDS[band] ?? null);
		attr(stat, 'data-uf-channel', '%s %s%s'.format(_('Channel'),
			channel != 'auto' ? channel : (live && live != '?') ? '%s (%s)'.format(live, _('auto')) : _('auto'),
			width ? ' · %s %s'.format(width[1], _('MHz')) : ''));
	},

	tagNetwork(row, stat, sid) {
		/* "psk2+ccmp" is WPA2 with its cipher named. */
		const enc = (uci.get('wireless', sid, 'encryption') || 'none').replace(/\+(tkip|ccmp|ccmp256|gcmp|gcmp256|aes)\b/g, '');
		const label = ENCRYPTION[enc];
		const known = uci.get('wireless', sid) != null;
		const networks = L.toArray(uci.get('wireless', sid, 'network')).join(', ');

		attr(row, 'data-uf-row', 'network');
		attr(stat, 'data-uf-network', networks || null);
		attr(stat, 'data-uf-security', (known && label) ? (typeof(label) == 'function' ? label() : label) : null);
		attr(stat, 'data-uf-open', (known && enc == 'none') ? '' : null);

		for (const list of stat.querySelectorAll(':scope > div')) {
			const items = this.tagItems(list);

			fade(items.ssid);

			/* The BSSID shows without its label; the label stays its tooltip. */
			if (items.bssid)
				attr(items.bssid, 'title', items.bssid.textContent.trim());
		}
	},

	/* A rate is its figure, with the PHY details ("80 MHz, VHT-MCS 9, ...")
	 * after it; name both, and keep the whole as the tooltip. LuCI's
	 * Disconnect button is drawn as an icon: its name stays with it. */
	tagStations(table) {
		for (const rates of table.querySelectorAll('.tr > .td > span:has(> span + br + span)')) {
			rates.querySelectorAll(':scope > span').forEach((rate, i) => {
				const text = rate.textContent;
				const cut = text.indexOf(', ');

				attr(rate, 'title', text);
				attr(rate, 'data-uf-rate', cut > 0 ? text.slice(0, cut) : text);

				/* The receive side's details stand for the link's. */
				if (i == 0)
					attr(rates, 'data-uf-phy', cut > 0 ? text.slice(cut + 2).replace(/, /g, ' · ') : '');
			});
		}

		/* A station's host, and the network it is on ("HomeNet (phy1-ap0)"). */
		for (const row of table.querySelectorAll('.tr:not(.table-titles, .placeholder)')) {
			fade(row.querySelector(':scope > .td:nth-child(3)'));
			fade(row.querySelector(':scope > .td:first-child .ifacebadge:not([data-signal]) > span'));
		}

		for (const button of table.querySelectorAll('.tr > .td > .cbi-button-remove')) {
			attr(button, 'title', _('Disconnect'));
			attr(button, 'aria-label', _('Disconnect'));
		}
	}
});
