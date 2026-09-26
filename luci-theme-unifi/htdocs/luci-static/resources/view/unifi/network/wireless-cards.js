'use strict';
'require baseclass';
'require uci';

/*
 * Network > Wireless as UniFi device cards: the "cards" design
 * (luci-static/unifi/network/wireless-cards.css). This only labels LuCI's
 * own nodes with data attributes, which the stylesheet reads. It never
 * adds, moves, removes or rewrites a node, so the view behaves exactly as
 * without it; without it (or if LuCI's markup changes) the cards simply
 * lose their status words and keyed rows.
 *
 *   rows      data-uf-key on each "Label: value" line (ssid, mode, ...)
 *   state     data-uf-state on a radio or SSID, a translated word for a
 *             radio's chip
 *   radios    the channel line ("Channel 36", "(5 GHz, 80 MHz)", "WiFi 6")
 *   stations  a rate's figure apart from its PHY details
 *
 * LuCI redraws the view every few seconds; a MutationObserver labels
 * whatever it redrew. Setting an attribute is not a childList mutation,
 * so the observer never wakes itself. menu-unifi.js calls enhance() on
 * this page.
 */

const LABELS = {
	'SSID': 'ssid', 'Mesh ID': 'ssid', 'Mode': 'mode', 'BSSID': 'bssid',
	'Encryption': 'encryption', 'Channel': 'channel', 'Bitrate': 'bitrate'
};

const BANDS = { '2g': '2.4', '5g': '5', '6g': '6', '60g': '60' };
const STANDARDS = { HT: 'WiFi 4', VHT: 'WiFi 5', HE: 'WiFi 6', EHT: 'WiFi 7' };

function set(node, name, value) {
	if (value == null || value === '') {
		if (node.hasAttribute(name))
			node.removeAttribute(name);
	}
	else if (node.getAttribute(name) !== String(value)) {
		node.setAttribute(name, value);
	}
}

return baseclass.extend({
	enhance() {
		if (this.keys)
			return;

		this.keys = {};

		for (const label in LABELS)
			this.keys[`${_(label)}: `] = LABELS[label];

		this.words = {
			active: _('Active'), disabled: _('Disabled'), off: _('Down')
		};

		this.tag();

		new MutationObserver(() => this.tag())
			.observe(document.body, { childList: true, subtree: true });
	},

	/* Keys each "Label: value" line of an itemlist, returns them by key. */
	keyLines(list) {
		const lines = {};

		for (const line of list ? list.children : []) {
			if (!line.classList.contains('nowrap'))
				continue;

			const label = line.firstElementChild?.tagName == 'STRONG' ? line.firstElementChild.textContent : null;
			const key = label != null ? (this.keys[label] || 'other') : 'note';

			set(line, 'data-uf-key', key);
			lines[key] = lines[key] || line;
		}

		return lines;
	},

	value(line) {
		return line ? line.textContent.replace(line.firstElementChild?.textContent || '', '').trim() : null;
	},

	tag() {
		for (const row of document.querySelectorAll('#cbi-wireless-wifi-device .cbi-section-table-row'))
			this.tagWireless(row);

		for (const rate of document.querySelectorAll('#wifi_assoclist_table .td > span > span')) {
			const text = rate.textContent;
			const cut = text.indexOf(', ');

			set(rate, 'data-uf-rate', cut > 0 ? text.slice(0, cut) : text);
			set(rate, 'data-uf-phy', cut > 0 ? text.slice(cut + 2) : null);
			set(rate, 'title', text);
		}
	},

	tagWireless(row) {
		const sid = row.getAttribute('data-sid');
		const conf = sid ? uci.get('wireless', sid) : null;
		const stat = row.querySelector('[data-name="_stat"] > div');

		if (!conf || !stat)
			return;

		if (conf['.type'] == 'wifi-device') {
			const line = stat.querySelector(':scope > div');
			const badge = row.querySelector('[data-name="_badge"] .ifacebadge');
			const lines = this.keyLines(line);
			const busy = !!row.querySelector('.cbi-section-actions .spinning') || !line;
			const state = busy ? 'busy' : (lines.channel ? 'up' : 'down');

			set(row, 'data-uf-kind', 'radio');
			set(row, 'data-uf-state', state);

			if (badge)
				set(badge, 'data-uf-state-label', lines.channel ? this.words.active : (conf.disabled == '1' ? this.words.disabled : this.words.off));

			if (!line)
				return;

			/* The live channel, or the configured one while the radio is down. */
			const live = /^(\d+)/.exec(this.value(lines.channel) || '');
			const channel = live ? live[1] : (/^\d+$/.test(conf.channel || '') ? conf.channel : null);
			const mode = /^(EHT|HE|VHT|HT)(\d+)/.exec(conf.htmode || '');
			const band = BANDS[conf.band] || (channel ? (+channel > 14 ? '5' : '2.4') : null);
			const freq = [ band && `${band} ${_('GHz')}`, mode && `${mode[2]} ${_('MHz')}` ].filter(Boolean).join(', ');
			let std = mode ? STANDARDS[mode[1]] : null;

			if (std && mode[1] == 'HE' && conf.band == '6g')
				std += 'E';

			set(line, 'data-uf-chan', channel ? `${_('Channel')} ${channel}` : null);
			set(line, 'data-uf-freq', freq ? `(${freq})` : null);

			/* The standard's chip takes the place of LuCI's channel fact. */
			if (lines.channel)
				set(lines.channel, 'data-uf-std', std);
		}
		else {
			const lines = this.keyLines(stat);
			const radio = conf.device ? uci.get('wireless', conf.device) : null;
			let state;

			if (lines.note?.querySelector('a'))
				state = 'pending';
			else if (conf.disabled == '1' || radio?.disabled == '1')
				state = 'disabled';
			else if (lines.note || !lines.bssid)
				state = 'down';
			else
				state = 'up';

			set(row, 'data-uf-kind', 'ssid');
			set(row, 'data-uf-state', state);
		}
	}
});
