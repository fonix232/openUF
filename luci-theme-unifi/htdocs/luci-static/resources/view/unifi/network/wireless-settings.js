'use strict';
'require baseclass';
'require uci';

/*
 * Network > Wireless drawn as UniFi's Settings > WiFi list: the "settings"
 * design (luci-static/unifi/network/wireless-settings.css). LuCI writes a
 * row's facts as "Label: value" runs that CSS cannot tell apart, and puts
 * no column titles over these lists. This names each fact (data-uf-key),
 * sets the translated column titles on the list (--uf-th-*), and adds,
 * from the configuration, what a UniFi list shows but LuCI's rows leave
 * out: a radio's band and channel, a wireless network's security and the
 * network it serves. It also splits each station's rates from their PHY
 * details.
 *
 * It only adds attributes to LuCI's nodes (and takes back its own), never
 * moves, removes or re-renders them. LuCI redraws the rows every few
 * seconds, so it tags them again after each redraw; markup it does not
 * recognise it leaves alone, and the stylesheet keeps LuCI's own runs.
 * menu-unifi.js calls enhance() on this page.
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

	/* "Label: value" runs (L.itemlist) and bare notes, named by label. */
	tagItems(list) {
		for (const item of list.children) {
			let key = null;

			if (item.matches('span.nowrap')) {
				const label = item.querySelector(':scope > strong');

				key = label ? (this.labels[label.textContent.replace(/:\s*$/, '')] ?? 'other') : 'note';

				if (key == 'info' || key == 'note') {
					const value = label ? item.textContent.slice(label.textContent.length) : item.textContent;
					key = this.values[value.trim()] ?? key;
				}
			}
			else if (item.matches('em')) {
				key = this.values[item.textContent.trim()] ?? 'note';
			}
			else if (item.matches('a')) {
				key = 'note';
			}

			if (key)
				attr(item, 'data-uf-key', key);
		}
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
			const type = uci.get('wireless', sid, '.type');

			if (!stat)
				continue;

			if (type == 'wifi-device') {
				const band = uci.get('wireless', sid, 'band');
				const channel = uci.get('wireless', sid, 'channel');
				const width = (uci.get('wireless', sid, 'htmode') || '').match(/(\d+)$/);

				attr(row, 'data-uf-row', 'radio');
				attr(stat, 'data-uf-band', BANDS[band] ?? null);
				attr(stat, 'data-uf-channel', channel ? '%s %s%s'.format(_('Channel'),
					channel == 'auto' ? _('auto') : channel,
					width ? ' · %s %s'.format(width[1], _('MHz')) : '') : null);

				/* Then the live channel says which one "auto" chose. */
				attr(stat, 'data-uf-auto', channel == 'auto' ? '' : null);

				for (const list of stat.querySelectorAll(':scope > div > div'))
					this.tagItems(list);
			}
			else if (type == 'wifi-iface') {
				/* "psk2+ccmp" is WPA2 with its cipher named. */
				const enc = (uci.get('wireless', sid, 'encryption') || 'none').replace(/\+(tkip|ccmp|ccmp256|gcmp|gcmp256|aes)\b/g, '');
				const label = ENCRYPTION[enc];
				const networks = L.toArray(uci.get('wireless', sid, 'network')).join(', ');

				attr(row, 'data-uf-row', 'network');
				attr(stat, 'data-uf-network', networks || null);
				attr(stat, 'data-uf-security', label ? (typeof(label) == 'function' ? label() : label) : null);
				attr(stat, 'data-uf-open', enc == 'none' ? '' : null);

				for (const list of stat.querySelectorAll(':scope > div'))
					this.tagItems(list);
			}
		}
	},

	/* A rate is its figure, with the PHY details ("80 MHz, VHT-MCS 9, ...")
	 * after it; name both, and keep the whole as the tooltip. */
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
	}
});
