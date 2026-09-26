'use strict';
'require baseclass';

/*
 * Network > Interfaces as UniFi device cards: the "cards" design
 * (luci-static/openuf/network/interfaces-cards.css). This only labels
 * LuCI's own nodes with data attributes, which the stylesheet reads. It
 * never adds, moves, removes or rewrites a node, so the view behaves
 * exactly as without it; without it (or if LuCI's markup changes) the
 * cards simply lose their status words and keyed rows.
 *
 *   rows      data-uf-key on each "Label: value" line (protocol, rx, ...),
 *             data-uf-label on its label (the label without LuCI's colon)
 *             and data-uf-bytes on a counter (its bytes without packets)
 *   state     data-uf-state on a card, and a translated word for its chip
 *   traffic   --uf-network-rx: the received share of an interface's bytes
 *   names     data-uf-fade on an interface's and a device's name
 *
 * LuCI redraws the view (and an open dialog, which lives beside it) every
 * few seconds, and spins a button while it works; a MutationObserver on
 * both labels whatever changed, once a frame, before the frame is drawn.
 * It watches nodes and classes only, which this never changes, so it
 * never wakes itself. menu-openuf.js calls enhance() on this page.
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

function setProperty(node, name, value) {
	if (value == null) {
		if (node.style.getPropertyValue(name))
			node.style.removeProperty(name);
	}
	else if (node.style.getPropertyValue(name) !== value) {
		node.style.setProperty(name, value);
	}
}

/* A long name fades out at its end and slides into view on hover
 * (cascade.css, "Fading names"). view/openuf-theme/fade.js measures it
 * and rewrites the mark, so a node is marked once and left alone after. */
function fade(node) {
	if (node && !node.hasAttribute('data-uf-fade'))
		node.setAttribute('data-uf-fade', '');
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
			up: _('Connected'), down: _('Not connected'), disabled: _('Disabled'),
			error: _('Error'), pending: _('Pending'), starting: _('Connecting'),
			restarting: _('Restarting'), stopping: _('Stopping')
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

			/* A counter's bytes, without LuCI's packet count after them. */
			if (key == 'rx' || key == 'tx')
				set(line, 'data-uf-bytes', this.value(line).replace(/\s*\(.*\)$/, ''));

			lines[key] = lines[key] || line;
		}

		return lines;
	},

	value(line) {
		return line ? line.textContent.replace(line.firstElementChild?.textContent || '', '').trim() : null;
	},

	tag() {
		try {
			for (const row of document.querySelectorAll('#cbi-network-interface .cbi-section-table-row'))
				this.tagInterface(row);

			/* A device's name: the text beside its tile, not the badge the
			 * tile sits in. */
			for (const name of document.querySelectorAll('#cbi-network-device .td[data-name="name"] > .ifacebadge > span:not(.cbi-tooltip-container)'))
				fade(name);

			for (const status of document.querySelectorAll('.modal [id$="-ifc-status"] > span'))
				this.keyLines(status);
		}
		catch (e) {
			/* LuCI's markup changed under us: the cards keep what they had. */
			console.warn('luci-theme-openuf: interfaces-cards:', e);
		}
	},

	tagInterface(row) {
		const stat = row.querySelector('[data-name="_ifacestat"] > div');
		const head = row.querySelector('[data-name="_ifacebox"] .ifacebox-head');

		if (!stat || !head)
			return;

		const lines = this.keyLines(stat);
		const up = row.querySelector('.cbi-section-actions .reconnect');

		fade(head.querySelector(':scope > strong'));
		fade(row.querySelector('[data-name="_ifacebox"] .ifacebox-body > small'));

		const down = row.querySelector('.cbi-section-actions .down');
		let state;

		/* LuCI marks a restart or a stop under way on the status (and spins
		 * the button's icon), pending changes as a link, errors as lines;
		 * while netifd is still bringing a network up, it leaves only Stop. */
		if (stat.hasAttribute('reconnect') || up?.classList.contains('spinning'))
			state = 'restarting';
		else if (stat.hasAttribute('disconnect') || down?.classList.contains('spinning'))
			state = 'stopping';
		else if (lines.note?.querySelector('a, em'))
			state = 'pending';
		else if (lines.error || stat.querySelector(':scope > em'))
			state = 'error';
		else if (lines.uptime)
			state = 'up';
		else if (lines.info && [ ...stat.querySelectorAll('[data-uf-key="info"]') ].some(l => this.value(l) == _('Interface disabled')))
			state = 'disabled';
		else if (up && down && up.disabled && !down.disabled)
			state = 'starting';
		else
			state = 'down';

		set(row, 'data-uf-state', state);
		set(head, 'data-uf-state-label', this.words[state]);

		const rx = bytes(this.value(lines.rx));
		const tx = bytes(this.value(lines.tx));

		setProperty(stat, '--uf-network-rx', rx + tx > 0 ? `${(100 * rx / (rx + tx)).toFixed(1)}%` : null);
	}
});
