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
 * its label (data-uf-key), gives the stylesheet a few short values it
 * cannot cut out itself (a rate without its PHY details, a radio's
 * channel, band and width) and the column titles, in LuCI's own
 * translations.
 *
 * It only adds attributes: LuCI's nodes are never moved, replaced or
 * re-rendered. It runs again after every redraw (the 5s status poll
 * replaces the items), and without it the page keeps a plain label/value
 * look. menu-openuf.js calls enhance() on this page.
 */

const KEYS = [
	[ 'ssid', 'SSID' ], [ 'ssid', 'Mesh ID' ], [ 'mode', 'Mode' ], [ 'bssid', 'BSSID' ],
	[ 'encryption', 'Encryption' ], [ 'channel', 'Channel' ], [ 'bitrate', 'Bitrate' ],
	[ 'txpower', 'Tx-Power' ], [ 'signal', 'Signal' ], [ 'noise', 'Noise' ],
	[ 'country', 'Country' ]
];

/* Where LuCI writes status items: the list's rows and the dialog's status. */
const ITEMS = [
	'#cbi-wireless-wifi-device [data-name="_stat"] .nowrap',
	'.modal .ifacebadge.large[data-network] .nowrap'
].join(', ');

const BANDS = { '2g': '2.4', '5g': '5', '6g': '6', '60g': '60' };

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

		this.heads('#cbi-wireless-wifi-device > .table',
			[ _('Mode'), _('BSSID') ], [ _('Encryption'), _('Signal') ]);

		document.querySelectorAll('#cbi-wireless-wifi-device .tr[data-sid]').forEach((row) => this.tagRadio(row));
		/* A station's rates: receive and transmit, either side of a <br>. */
		document.querySelectorAll('#wifi_assoclist_table > .tr > .td > span > br').forEach((br) => {
			this.tagRate(br.previousElementSibling);
			this.tagRate(br.nextElementSibling);
		});
	},

	/* "BSSID: 3C:22:FB:31:D3:C9" is data-uf-key="bssid"; an item without a
	 * label ("Wireless is not associated") is the status. */
	tagItem(item) {
		const label = item.firstElementChild?.matches('strong') ? item.firstElementChild : null;
		const key = label ? this.keys[label.textContent.replace(/:\s*$/, '')] : 'status';

		set(item, 'data-uf-key', key || 'other');
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
	},

	/* A radio row: "Channel 36 · 5 GHz · 80 MHz" for its chip, the channel
	 * in use if it is up, else the configured one. */
	tagRadio(row) {
		const sid = row.getAttribute('data-sid');
		const badge = row.querySelector('[data-name="_badge"]');

		if (!badge || uci.get('wireless', sid) == null || uci.get('wireless', sid, '.type') != 'wifi-device')
			return;

		const live = row.querySelector('[data-uf-key="channel"]')?.lastChild?.textContent.match(/^\s*(\d+)/);
		const conf = uci.get('wireless', sid, 'channel');
		const hwmode = uci.get('wireless', sid, 'hwmode');
		const band = uci.get('wireless', sid, 'band') || (hwmode ? (hwmode == '11a' ? '5g' : '2g') : null);
		const htmode = uci.get('wireless', sid, 'htmode');
		const width = htmode ? (htmode == 'NOHT' ? 20 : +(htmode.match(/\d+/) || [])[0]) : null;
		const channel = live ? live[1] : (conf && conf != 'auto' ? conf : _('auto'));

		set(badge, 'data-uf-chip', [
			`${_('Channel')} ${channel}`,
			BANDS[band] ? `${BANDS[band]} ${_('GHz')}` : null,
			width ? `${width} ${_('MHz')}` : null
		].filter(Boolean).join(' · '));
	},

	/* "866.7 Mbit/s, 80 MHz, VHT-MCS 9, …" shows as its rate; the rest is its title. */
	tagRate(rate) {
		if (!rate)
			return;

		const text = rate.textContent;

		set(rate, 'data-uf-value', text.split(', ')[0]);
		set(rate, 'title', text);
	}
});
