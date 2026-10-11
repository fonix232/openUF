'use strict';
'require baseclass';
'require uci';

/*
 * Network > Wireless as UniFi device cards: the "cards" design
 * (luci-static/openuf/network/wireless-cards.css). This only labels LuCI's
 * own nodes with data attributes (and names the few buttons LuCI leaves
 * nameless or misleads with), which the stylesheet reads. It never adds,
 * moves, removes or rewrites a node, so the view behaves exactly as
 * without it; without it (or if LuCI's markup changes) the cards simply
 * lose their status words and keyed rows.
 *
 *   rows      data-uf-key on each "Label: value" line (ssid, mode, ...),
 *             data-uf-label on its label (the label without LuCI's colon)
 *   state     data-uf-state on a radio or SSID, a translated word for a
 *             radio's chip; data-uf-switch on an SSID's Enable/Disable
 *             (on while the network is configured enabled)
 *   radios    the channel line ("Channel 36", "(5 GHz, 80 MHz)", "WiFi 6")
 *   stations  a rate's figure apart from its PHY details, a network's
 *             SSID for its name (data-uf-ssid), and Disconnect's name for
 *             the icon it becomes
 *   names     data-uf-fade on SSIDs, a radio's chipset, a station's host
 *             and network
 *
 * LuCI redraws the view (and an open dialog, which lives beside it) every
 * few seconds, and spins a button while it works; a MutationObserver on
 * both labels whatever changed, once a frame, before the frame is drawn.
 * It watches nodes and classes only, which this never changes, so it
 * never wakes itself. menu-openuf.js calls enhance() on this page.
 */

const LABELS = {
	'SSID': 'ssid', 'Mesh ID': 'ssid', 'Mode': 'mode', 'BSSID': 'bssid',
	'Encryption': 'encryption', 'Channel': 'channel', 'Bitrate': 'bitrate'
};

const BANDS = { '2g': '2.4', '5g': '5', '6g': '6', '60g': '60' };

function set(node, name, value) {
	if (value == null || value === '') {
		if (node.hasAttribute(name))
			node.removeAttribute(name);
	}
	else if (node.getAttribute(name) !== String(value)) {
		node.setAttribute(name, value);
	}
}

/* A long name fades out at its end and slides into view on hover
 * (cascade.css, "Fading names"). view/openuf-theme/fade.js measures it
 * and rewrites the mark, so a node is marked once and left alone after. */
function fade(node) {
	if (node && !node.hasAttribute('data-uf-fade'))
		node.setAttribute('data-uf-fade', '');
}

return baseclass.extend({
	enhance() {
		if (this.keys)
			return;

		this.keys = {};

		for (const label in LABELS)
			this.keys[`${_(label)}: `] = LABELS[label];

		this.words = {
			active: _('Active'), disabled: _('Disabled'), off: _('Down'), busy: _('Restarting')
		};

		/* The WiFi generation of a radio's mode, as its chip names it. */
		this.standards = {
			HT: _('WiFi 4'), VHT: _('WiFi 5'), HE: _('WiFi 6'), HE6: _('WiFi 6E'), EHT: _('WiFi 7')
		};

		this.tag();

		/* LuCI redraws a card in several steps; label them once, together. */
		const roots = [ document.querySelector('#view'), document.querySelector('#modal_overlay') ].filter(Boolean);
		let queued = false;

		const observer = new MutationObserver(() => {
			if (queued)
				return;

			queued = true;
			window.requestAnimationFrame(() => {
				queued = false;
				this.tag();
			});
		});

		for (const root of roots.length ? roots : [ document.body ])
			observer.observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: [ 'class' ] });
	},

	/* Keys each "Label: value" line of an itemlist, returns them by key. */
	keyLines(list) {
		const lines = {};

		for (const line of list ? list.children : []) {
			if (!line.classList.contains('nowrap'))
				continue;

			const strong = line.firstElementChild?.tagName == 'STRONG' ? line.firstElementChild : null;
			const label = strong ? strong.textContent : null;
			const key = label != null ? (this.keys[label] || 'other') : 'note';

			set(line, 'data-uf-key', key);

			if (strong)
				set(strong, 'data-uf-label', label.replace(/:\s*$/, ''));

			lines[key] = lines[key] || line;
		}

		return lines;
	},

	value(line) {
		return line ? line.textContent.replace(line.firstElementChild?.textContent || '', '').trim() : null;
	},

	tag() {
		try {
			for (const row of document.querySelectorAll('#cbi-wireless-wifi-device .cbi-section-table-row'))
				this.tagWireless(row);

			/* The details wrap between facts, not inside "VHT-NSS 2". */
			for (const rate of document.querySelectorAll('#wifi_assoclist_table .td > span > span')) {
				const text = rate.textContent;
				const cut = text.indexOf(', ');

				set(rate, 'data-uf-rate', cut > 0 ? text.slice(0, cut) : text);
				set(rate, 'data-uf-phy', cut > 0 ? text.slice(cut + 2).replace(/-/g, '\u2011') : null);
				set(rate, 'title', text);
			}

			/* A station's host (LuCI's cell holds its name as bare text), and
			 * its network: the badge's own text reads 'Access Point "HomeNet"',
			 * so the SSID is handed to it to show instead. */
			for (const host of document.querySelectorAll('#wifi_assoclist_table > .tr:not(.table-titles, .placeholder) > .td:nth-child(3)'))
				fade(host);

			for (const badge of document.querySelectorAll('#wifi_assoclist_table .td > .ifacebadge[data-ssid]')) {
				const name = badge.querySelector(':scope > span');

				if (name) {
					set(name, 'data-uf-ssid', badge.getAttribute('data-ssid'));
					fade(name);
				}
			}

			/* Disconnect becomes an icon: its word stays its name. */
			for (const button of document.querySelectorAll('#wifi_assoclist_table .td .cbi-button-remove')) {
				set(button, 'title', _('Disconnect'));
				set(button, 'aria-label', _('Disconnect'));
			}

			for (const status of document.querySelectorAll('.modal .ifacebadge.large > span'))
				this.keyLines(status);
		}
		catch (e) {
			/* LuCI's markup changed under us: the cards keep what they had. */
			console.warn('luci-theme-openuf: wireless-cards:', e);
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
			const busy = !!row.querySelector('.cbi-section-actions .spinning') || stat.hasAttribute('restart') || !line;
			const state = busy ? 'busy' : (lines.channel ? 'up' : 'down');

			set(row, 'data-uf-kind', 'radio');
			set(row, 'data-uf-state', state);
			fade(stat.querySelector(':scope > big'));

			if (badge)
				set(badge, 'data-uf-state-label', busy ? this.words.busy : (lines.channel ? this.words.active : (conf.disabled == '1' ? this.words.disabled : this.words.off)));

			if (!line)
				return;

			/* The live channel, or the configured one while the radio is down. */
			const live = /^(\d+)/.exec(this.value(lines.channel) || '');
			const channel = live ? live[1] : (/^\d+$/.test(conf.channel || '') ? conf.channel : null);
			const mode = /^(EHT|HE|VHT|HT)(\d+)/.exec(conf.htmode || '');
			const band = BANDS[conf.band] || (channel ? (+channel > 14 ? '5' : '2.4') : null);
			const freq = [ band && `${band} ${_('GHz')}`, mode && `${mode[2]} ${_('MHz')}` ].filter(Boolean).join(', ');
			const std = mode ? this.standards[(mode[1] == 'HE' && conf.band == '6g') ? 'HE6' : mode[1]] : null;

			set(line, 'data-uf-chan', channel ? `${_('Channel')} ${channel}` : null);
			set(line, 'data-uf-freq', freq ? `(${freq})` : null);

			/* The standard's chip takes the place of LuCI's channel fact. */
			if (lines.channel)
				set(lines.channel, 'data-uf-std', std);
		}
		else {
			const lines = this.keyLines(stat);
			const radio = conf.device ? uci.get('wireless', conf.device) : null;
			const off = conf.disabled == '1' || radio?.disabled == '1';
			const toggle = row.querySelector('.cbi-section-actions .enable-disable');
			let state;

			if (lines.note?.querySelector('a'))
				state = 'pending';
			else if (off)
				state = 'disabled';
			else if (lines.note || !lines.bssid)
				state = 'down';
			else
				state = 'up';

			set(row, 'data-uf-kind', 'ssid');
			set(row, 'data-uf-state', state);
			fade(lines.ssid);

			/* The switch shows the configuration, as LuCI's word on it does,
			 * and says that pressing it applies at once, with whatever else
			 * is waiting to be applied (LuCI saves, then applies, all
			 * changes). */
			if (toggle) {
				set(toggle, 'data-uf-switch', off ? 'off' : 'on');
				set(toggle, 'title', `${off ? _('Enable this network') : _('Disable this network')}. ${_('Applies at once, with any other unsaved changes.')}`);
			}
		}
	}
});
