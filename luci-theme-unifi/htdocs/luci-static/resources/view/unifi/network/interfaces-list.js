'use strict';
'require baseclass';

/*
 * Network > Interfaces listed the way UniFi lists devices: the "list"
 * design (luci-static/unifi/network/interfaces-list.css).
 *
 * LuCI writes an interface's status as a run of "Label: value" items, and
 * which items appear shifts with the state, so the stylesheet cannot tell
 * an uptime from an address by position. This names each item by its
 * label (data-uf-key), gives the stylesheet a value it cannot cut out
 * itself (a byte count without its packet count) and the column titles,
 * in LuCI's own translations.
 *
 * It only adds attributes: LuCI's nodes are never moved, replaced or
 * re-rendered. It runs again after every redraw (the 5s status poll
 * replaces the items), and without it the list keeps a plain label/value
 * look. menu-unifi.js calls enhance() on this page.
 */

const KEYS = [
	[ 'protocol', 'Protocol' ], [ 'device', 'Device' ], [ 'carrier', 'Carrier' ],
	[ 'uptime', 'Uptime' ], [ 'mac', 'MAC' ], [ 'rx', 'RX' ], [ 'tx', 'TX' ],
	[ 'ipv4', 'IPv4' ], [ 'ipv6', 'IPv6' ], [ 'ipv6-pd', 'IPv6-PD' ],
	[ 'info', 'Information' ], [ 'error', 'Error' ]
];

/* Where LuCI writes status items: the list's rows and the dialog's status. */
const ITEMS = [
	'#cbi-network-interface [data-name="_ifacestat"] .nowrap',
	'.modal [id$="-ifc-status"] .nowrap'
].join(', ');

/* Set an attribute (null removes it), touching the node only on a change. */
function set(node, name, value) {
	if (value == null)
		node.removeAttribute(name);
	else if (node.getAttribute(name) !== value)
		node.setAttribute(name, value);
}

return baseclass.extend({
	enhance() {
		if (this.keys)
			return;

		this.keys = {};

		for (const [ key, msgid ] of KEYS)
			this.keys[_(msgid)] = key;

		this.pending = false;
		new MutationObserver(() => this.schedule())
			.observe(document.body, { childList: true, subtree: true });

		this.schedule();
	},

	schedule() {
		if (this.pending)
			return;

		this.pending = true;
		window.requestAnimationFrame(() => {
			this.pending = false;
			this.apply();
		});
	},

	apply() {
		document.querySelectorAll(ITEMS).forEach((item) => this.tagItem(item));

		this.heads('#cbi-network-interface > .table',
			[ _('Protocol'), _('Address') ], [ _('Status'), `${_('RX')} / ${_('TX')}` ]);
	},

	/* "RX: 31.29 MB (216242 Pkts.)" is data-uf-key="rx", data-uf-value="31.29 MB";
	 * "RX: 0 B (0 Pkts.)" is also data-uf-idle. */
	tagItem(item) {
		const label = item.firstElementChild?.matches('strong') ? item.firstElementChild : null;
		const key = label ? this.keys[label.textContent.replace(/:\s*$/, '')] : 'status';

		set(item, 'data-uf-key', key || 'other');

		if (key == 'rx' || key == 'tx') {
			const value = item.textContent.slice(label.textContent.length).trim();
			const bytes = value.replace(/\s*\(.*\)$/, '');

			set(item, 'data-uf-value', bytes);
			set(item, 'data-uf-idle', /^0\s/.test(bytes) ? '' : null);
			set(item, 'title', `${label.textContent}${value}`);
		}
	},

	/* Four column titles for a list that has none, as the ::before and
	 * ::after of the table and of its body. */
	heads(selector, table, body) {
		const node = document.querySelector(selector);

		if (!node || !node.tBodies[0])
			return;

		set(node, 'data-uf-before', table[0]);
		set(node, 'data-uf-after', table[1]);
		set(node.tBodies[0], 'data-uf-before', body[0]);
		set(node.tBodies[0], 'data-uf-after', body[1]);
	}
});
