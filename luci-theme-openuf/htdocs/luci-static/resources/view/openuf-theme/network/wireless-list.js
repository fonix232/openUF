'use strict';
'require baseclass';
'require uci';

/*
 * Network > Wireless listed the way UniFi lists devices and clients: the
 * "list" design (luci-static/openuf/network/wireless-list.css).
 *
 * LuCI writes a radio's and an SSID's status as a run of "Label: value"
 * items, and which items appear shifts with the state, so the stylesheet
 * cannot tell a BSSID from a cipher by position. This names each item by
 * its label (data-uf-key), marks radio and SSID rows (data-uf-row) and
 * gives the stylesheet what it cannot work out itself: the column titles
 * (--uf-th-*), the network an SSID serves (--uf-wifi-network), a radio's
 * channel, band and width, a station's rates without their PHY details,
 * and a name for the Disconnect button once it shows as an icon, all in
 * LuCI's own translations; and it marks the names that fade out when too
 * long (data-uf-fade).
 *
 * It only adds attributes and custom properties: LuCI's nodes are never
 * moved, replaced or re-rendered. It runs again after every redraw (the
 * 5s status poll replaces the items), and without it the page keeps a
 * plain label/value look. menu-openuf.js calls enhance() on this page.
 */

const KEYS = [
	[ 'ssid', 'SSID' ], [ 'ssid', 'Mesh ID' ], [ 'mode', 'Mode' ], [ 'bssid', 'BSSID' ],
	[ 'encryption', 'Encryption' ], [ 'channel', 'Channel' ], [ 'bitrate', 'Bitrate' ],
	[ 'txpower', 'Tx-Power' ], [ 'signal', 'Signal' ], [ 'noise', 'Noise' ],
	[ 'country', 'Country' ]
];

const BANDS = { '2g': '2.4', '5g': '5', '6g': '6', '60g': '60' };

/* A CSS string, for content: var(...). */
function cssString(s) {
	return '"' + String(s).replace(/[\\"]/g, '\\$&').replace(/[\n\r]+/g, ' ') + '"';
}

/* Set an attribute (null removes it), touching the node only on a change. */
function attr(node, name, value) {
	if (value == null)
		node.removeAttribute(name);
	else if (node.getAttribute(name) !== value)
		node.setAttribute(name, value);
}

/* The same for a custom property. */
function prop(node, name, value) {
	if (value == null)
		node.style.removeProperty(name);
	else if (node.style.getPropertyValue(name) !== value)
		node.style.setProperty(name, value);
}

/* A name to fade out at its end when too long (cascade.css, "Fading
 * names"). Marked once: fade.js then keeps the attribute's value. */
function fade(node) {
	if (node && !node.hasAttribute('data-uf-fade'))
		node.setAttribute('data-uf-fade', '');
}

return baseclass.extend({
	enhance() {
		const view = document.querySelector('#view');

		if (!view || this.keys)
			return;

		this.keys = {};

		for (const [ key, msgid ] of KEYS)
			this.keys[_(msgid)] = key;

		/* Tag after LuCI's redraw has settled, once per frame at most. The
		 * dialog's status is drawn outside the view, in LuCI's modal. */
		let queued = false;
		const observer = new MutationObserver(() => {
			if (queued)
				return;

			queued = true;
			window.requestAnimationFrame(() => {
				queued = false;
				this.tag(view);
			});
		});

		observer.observe(view, { childList: true, subtree: true });

		const modal = document.querySelector('#modal_overlay');

		if (modal)
			observer.observe(modal, { childList: true, subtree: true });

		this.tag(view);
	},

	tag(view) {
		try {
			const section = view.querySelector('#cbi-wireless-wifi-device');
			const stations = view.querySelector('#wifi_assoclist_table');

			if (section) {
				this.titles(section, {
					name: _('SSID'),
					network: _('Network'),
					bssid: _('BSSID'),
					encryption: _('Encryption'),
					signal: _('Signal'),
					status: _('Status')
				});

				for (const row of section.querySelectorAll('.cbi-section-table-row[data-sid]'))
					this.tagRow(row);
			}

			if (stations)
				this.tagStations(stations);

			for (const list of document.querySelectorAll('.modal .ifacebadge.large[data-network] > span'))
				this.tagItems(list);
		}
		catch (e) {
			/* Unfamiliar markup: leave the page as LuCI drew it. */
		}
	},

	titles(node, titles) {
		for (const name in titles)
			prop(node, `--uf-th-${name}`, cssString(titles[name]));
	},

	/* "BSSID: 3C:22:FB:31:D3:C9" is data-uf-key="bssid"; an item without a
	 * label ("Wireless is not associated", a pending-changes link) is the
	 * status. */
	tagItems(list) {
		for (const item of list.children) {
			if (item.matches('.nowrap')) {
				const label = item.firstElementChild?.matches('strong') ? item.firstElementChild : null;

				attr(item, 'data-uf-key', label ? (this.keys[label.textContent.replace(/:\s*$/, '')] ?? 'other') : 'status');
			}
			else if (item.matches('em, a')) {
				attr(item, 'data-uf-key', 'status');
			}
		}
	},

	/* A radio's row is the one that can add a network. */
	tagRow(row) {
		const sid = row.getAttribute('data-sid');
		const stat = row.querySelector('[data-name="_stat"]');

		if (!stat)
			return;

		if (row.querySelector('.cbi-section-actions .cbi-button-add')) {
			attr(row, 'data-uf-row', 'radio');

			for (const list of stat.querySelectorAll(':scope > div > div'))
				this.tagItems(list);

			if (uci.get('wireless', sid, '.type') == 'wifi-device')
				this.tagRadio(row, sid);

			/* The chipset, which a phone may not fit. */
			fade(stat.querySelector(':scope > div > big'));
		}
		else {
			attr(row, 'data-uf-row', 'network');

			for (const list of stat.querySelectorAll(':scope > div'))
				this.tagItems(list);

			fade(stat.querySelector('[data-uf-key="ssid"]'));

			const networks = L.toArray(uci.get('wireless', sid, 'network')).join(', ');

			prop(row, '--uf-wifi-network', networks ? cssString(networks) : null);
		}
	},

	/* A radio: "Channel 36 · 5 GHz · 80 MHz" for its chip, the channel in
	 * use if it is up, else the configured one. */
	tagRadio(row, sid) {
		const badge = row.querySelector('[data-name="_badge"] > div');

		if (!badge)
			return;

		const live = row.querySelector('[data-uf-key="channel"]')?.lastChild?.textContent.match(/^\s*(\d+)/);
		const conf = uci.get('wireless', sid, 'channel');
		const hwmode = uci.get('wireless', sid, 'hwmode');
		const band = uci.get('wireless', sid, 'band') || (hwmode ? (hwmode == '11a' ? '5g' : '2g') : null);
		const htmode = uci.get('wireless', sid, 'htmode');
		const width = htmode ? (htmode == 'NOHT' ? 20 : +(htmode.match(/\d+/) || [])[0]) : null;
		const channel = live ? live[1] : (conf && conf != 'auto' ? conf : _('auto'));

		attr(badge, 'data-uf-chip', [
			`${_('Channel')} ${channel}`,
			BANDS[band] ? `${BANDS[band]} ${_('GHz')}` : null,
			width ? `${width} ${_('MHz')}` : null
		].filter(Boolean).join(' · '));
	},

	/* The stations: the rates split into their own column titles; each
	 * rate ("866.7 Mbit/s, 80 MHz, VHT-MCS 9, …") shows as its figure,
	 * the rest is its title; Disconnect, drawn as an icon, keeps a name. */
	tagStations(table) {
		this.titles(table, {
			rx: `\u2193 ${_('RX Rate')}`,
			tx: `\u2191 ${_('TX Rate')}`
		});

		for (const br of table.querySelectorAll(':scope > .tr > .td > span > br')) {
			for (const rate of [ br.previousElementSibling, br.nextElementSibling ]) {
				if (!rate)
					continue;

				const text = rate.textContent;

				attr(rate, 'data-uf-value', text.split(', ')[0]);
				attr(rate, 'title', text);
			}
		}

		/* The host and the network it is on. */
		for (const host of table.querySelectorAll(':scope > .tr:not(.table-titles, .placeholder) > .td:nth-child(3)'))
			fade(host);

		for (const network of table.querySelectorAll(':scope > .tr > .td:nth-child(1) > .ifacebadge > span'))
			fade(network);

		for (const button of table.querySelectorAll(':scope > .tr > .td > .cbi-button-remove')) {
			attr(button, 'title', _('Disconnect'));
			attr(button, 'aria-label', _('Disconnect'));
		}
	}
});
