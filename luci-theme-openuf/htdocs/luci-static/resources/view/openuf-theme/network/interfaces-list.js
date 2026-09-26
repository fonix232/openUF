'use strict';
'require baseclass';
'require uci';

/*
 * Network > Interfaces listed the way UniFi lists clients: the "list"
 * design (luci-static/openuf/network/interfaces-list.css).
 *
 * LuCI writes an interface's status as a run of "Label: value" items, and
 * which items appear shifts with the state, so the stylesheet cannot tell
 * an uptime from an address by position. This names each item by its
 * label (data-uf-key) and gives the stylesheet what it cannot work out
 * itself: the column titles (--uf-th-*), a network's zone and its
 * colour (--uf-network-zone*), its state (data-uf-state) and a word for
 * it where LuCI shows none, a static network's configured addresses while
 * it is down, and a byte count without its packet count, all in LuCI's
 * own translations; and it marks the names that fade out when too long
 * (data-uf-fade).
 *
 * It only adds attributes and custom properties: LuCI's nodes are never
 * moved, replaced or re-rendered. It runs again after every redraw (the
 * 5s status poll replaces the items), and without it the list keeps a
 * plain label/value look. menu-openuf.js calls enhance() on this page.
 */

const KEYS = [
	[ 'protocol', 'Protocol' ], [ 'device', 'Device' ], [ 'carrier', 'Carrier' ],
	[ 'uptime', 'Uptime' ], [ 'mac', 'MAC' ], [ 'rx', 'RX' ], [ 'tx', 'TX' ],
	[ 'ipv4', 'IPv4' ], [ 'ipv6', 'IPv6' ], [ 'ipv6-pd', 'IPv6-PD' ],
	[ 'info', 'Information' ], [ 'error', 'Error' ]
];

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

		/* Information LuCI words as a state of its own. */
		this.values = {
			[_('Interface disabled')]: 'disabled',
			[_('Not started on boot')]: 'noboot'
		};

		this.words = { down: _('Not connected'), busy: _('Not connected'), disabled: _('Disabled') };
		this.zoneTitle = _('Part of zone %q').split('%q');

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
			const section = view.querySelector('#cbi-network-interface');

			if (section) {
				this.titles(section, {
					name: _('Name'),
					zone: _('Zone'),
					protocol: _('Protocol'),
					address: _('IP Address'),
					status: _('Status'),
					rx: `\u2193 ${_('RX')}`,
					tx: `\u2191 ${_('TX')}`
				});

				for (const row of section.querySelectorAll('.cbi-section-table-row[data-sid]'))
					this.tagInterface(row);
			}

			/* Devices: the name beside the icon. */
			for (const name of view.querySelectorAll('#cbi-network-device .td[data-name="name"] .ifacebadge > span:not(.cbi-tooltip-container)'))
				fade(name);

			for (const list of document.querySelectorAll('.modal [id$="-ifc-status"] > span'))
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

	/* "RX: 31.29 MB (216242 Pkts.)" is data-uf-key="rx", data-uf-value="31.29 MB"
	 * ("RX: 0 B" is also data-uf-idle); "Information: Interface disabled" is
	 * data-uf-key="disabled"; an item without a label is a note. Returns
	 * the keys found. */
	tagItems(list) {
		const found = {};

		for (const item of list.children) {
			let key = null;

			if (item.matches('.nowrap')) {
				const label = item.firstElementChild?.matches('strong') ? item.firstElementChild : null;
				const value = (label ? item.textContent.slice(label.textContent.length) : item.textContent).trim();

				key = label ? (this.keys[label.textContent.replace(/:\s*$/, '')] ?? 'other') : 'note';

				if (key == 'info' || key == 'note')
					key = this.values[value] ?? key;

				if (key == 'rx' || key == 'tx') {
					const bytes = value.replace(/\s*\(.*\)$/, '');

					attr(item, 'data-uf-value', bytes);
					attr(item, 'data-uf-idle', /^0\s/.test(bytes) ? '' : null);
					attr(item, 'title', `${label.textContent}${value}`);
				}
			}
			else if (item.matches('em, a')) {
				key = 'note';
			}

			if (key) {
				attr(item, 'data-uf-key', key);
				found[key] = true;
			}
		}

		return found;
	},

	tagInterface(row) {
		const cell = row.querySelector('[data-name="_ifacebox"]');
		const head = cell?.querySelector('.ifacebox-head');
		const desc = row.querySelector('[data-name="_ifacestat"] > div');

		if (!head || !desc)
			return;

		const found = this.tagItems(desc);

		/* The network's name and its device ('Alias of "wan"'). */
		fade(head.querySelector(':scope > strong'));
		fade(row.querySelector('.ifacebox-body > small'));

		/* The zone, from the tile's title ("Part of zone lan"); "" is none. */
		const title = head.getAttribute('title') || '';
		const [ pre, post ] = this.zoneTitle;
		const zone = (this.zoneTitle.length == 2 && title.length > pre.length + post.length && title.startsWith(pre) && title.endsWith(post))
			? title.slice(pre.length, title.length - post.length) : '';
		const rgb = head.style.getPropertyValue('--zone-color-rgb').trim()
			|| (head.style.backgroundColor.match(/^rgba?\((\d+),\s*(\d+),\s*(\d+)/) || []).slice(1).join(', ');

		prop(row, '--uf-network-zone', title ? cssString(zone) : null);
		prop(row, '--uf-network-zone-rgb', zone && rgb ? rgb : null);

		/* The state, as the buttons and the items tell it. */
		const up = row.querySelector('.cbi-section-actions .reconnect');
		const down = row.querySelector('.cbi-section-actions .down');
		let state;

		if (desc.hasAttribute('reconnect') || desc.hasAttribute('disconnect') || row.querySelector('.cbi-section-actions .spinning'))
			state = 'busy';
		else if (desc.querySelector(':scope > a, :scope > .nowrap > a'))
			state = 'pending';
		else if (found.error || desc.querySelector(':scope > em'))
			state = 'error';
		else if (found.uptime)
			state = 'up';
		else if (found.disabled)
			state = 'disabled';
		else if (up && down && up.disabled && !down.disabled)
			state = 'busy';
		else
			state = 'down';

		attr(row, 'data-uf-state', state);

		/* A word where the status would be empty: LuCI says nothing of a
		 * network that is down, and "Interface disabled" reads long. */
		const said = found.uptime || found.error || found.noboot || found.note || found.other;

		attr(desc, 'data-uf-state-label', said ? null : (this.words[state] ?? null));

		/* A static network's own addresses, which LuCI shows only while it
		 * is up: greyed where the live ones would be. */
		const sid = row.getAttribute('data-sid');
		const addrs = (!found.ipv4 && !found.ipv6 && uci.get('network', sid, 'proto') == 'static')
			? L.toArray(uci.get('network', sid, 'ipaddr')).concat(L.toArray(uci.get('network', sid, 'ip6addr'))) : [];

		attr(desc, 'data-uf-address', addrs.length
			? addrs.map((a) => this.withPrefix(a, uci.get('network', sid, 'netmask'))).join('\n') : null);
	},

	/* "192.168.1.1" with a netmask "255.255.255.0" reads "192.168.1.1/24". */
	withPrefix(addr, mask) {
		if (addr.indexOf('/') > -1 || addr.indexOf(':') > -1 || !mask || !/^[\d.]+$/.test(mask))
			return addr;

		const bits = mask.split('.').reduce((n, o) => n + ((+o).toString(2).match(/1/g) || []).length, 0);

		return '%s/%d'.format(addr, bits);
	}
});
