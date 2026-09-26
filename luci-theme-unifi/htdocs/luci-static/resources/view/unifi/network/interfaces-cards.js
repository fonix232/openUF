'use strict';
'require baseclass';

/*
 * Network > Interfaces as UniFi device cards: the "cards" design
 * (luci-static/unifi/network/interfaces-cards.css). This only labels
 * LuCI's own nodes with data attributes, which the stylesheet reads. It
 * never adds, moves, removes or rewrites a node, so the view behaves
 * exactly as without it; without it (or if LuCI's markup changes) the
 * cards simply lose their status words and keyed rows.
 *
 *   rows      data-uf-key on each "Label: value" line (protocol, rx, ...)
 *   state     data-uf-state on a card, and a translated word for its chip
 *   traffic   --uf-network-rx: the received share of an interface's bytes
 *
 * LuCI redraws the view every few seconds; a MutationObserver labels
 * whatever it redrew. Setting an attribute is not a childList mutation,
 * so the observer never wakes itself. menu-unifi.js calls enhance() on
 * this page.
 */

const LABELS = {
	'Protocol': 'protocol', 'Device': 'device', 'Carrier': 'carrier',
	'Uptime': 'uptime', 'MAC': 'mac', 'RX': 'rx', 'TX': 'tx',
	'IPv4': 'ipv4', 'IPv6': 'ipv6', 'IPv6-PD': 'ipv6pd',
	'Information': 'info', 'Error': 'error'
};

function set(node, name, value) {
	if (value == null || value === '') {
		if (node.hasAttribute(name))
			node.removeAttribute(name);
	}
	else if (node.getAttribute(name) !== String(value)) {
		node.setAttribute(name, value);
	}
}

/* "12.60 GB (14000000 Pkts.)": LuCI's %m scale, the same for RX and TX. */
function bytes(text) {
	const m = /^([\d.]+)\s*([KMGTPE]?)/.exec(text || '');

	return m ? +m[1] * Math.pow(1000, ' KMGTPE'.indexOf(m[2] || ' ')) : 0;
}

return baseclass.extend({
	enhance() {
		if (this.keys)
			return;

		this.keys = {};

		for (const label in LABELS)
			this.keys[`${_(label)}: `] = LABELS[label];

		this.words = {
			up: _('Connected'), down: _('Not connected'), busy: _('Not connected'),
			disabled: _('Disabled'), error: _('Error'), pending: _('Changes')
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
		for (const row of document.querySelectorAll('#cbi-network-interface .cbi-section-table-row'))
			this.tagInterface(row);

		for (const status of document.querySelectorAll('.modal [id$="-ifc-status"] > span'))
			this.keyLines(status);
	},

	tagInterface(row) {
		const stat = row.querySelector('[data-name="_ifacestat"] > div');
		const head = row.querySelector('[data-name="_ifacebox"] .ifacebox-head');

		if (!stat || !head)
			return;

		const lines = this.keyLines(stat);
		const up = row.querySelector('.cbi-section-actions .reconnect');
		const down = row.querySelector('.cbi-section-actions .down');
		let state;

		if (stat.hasAttribute('reconnect') || stat.hasAttribute('disconnect') || row.querySelector('.cbi-section-actions .spinning'))
			state = 'busy';
		else if (lines.note?.querySelector('a, em'))
			state = 'pending';
		else if (lines.error || stat.querySelector(':scope > em'))
			state = 'error';
		else if (lines.uptime)
			state = 'up';
		else if (lines.info && [ ...stat.querySelectorAll('[data-uf-key="info"]') ].some(l => this.value(l) == _('Interface disabled')))
			state = 'disabled';
		else if (up && down && up.disabled && !down.disabled)
			state = 'busy';
		else
			state = 'down';

		set(row, 'data-uf-state', state);
		set(head, 'data-uf-state-label', this.words[state]);

		const rx = bytes(this.value(lines.rx));
		const tx = bytes(this.value(lines.tx));

		if (rx + tx > 0)
			stat.style.setProperty('--uf-network-rx', `${(100 * rx / (rx + tx)).toFixed(1)}%`);
		else
			stat.style.removeProperty('--uf-network-rx');
	}
});
