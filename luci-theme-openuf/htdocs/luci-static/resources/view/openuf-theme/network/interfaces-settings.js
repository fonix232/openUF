'use strict';
'require baseclass';
'require uci';

/*
 * Network > Interfaces drawn as UniFi's Settings > Networks list: the
 * "settings" design (luci-static/openuf/network/interfaces-settings.css).
 * LuCI writes a row's facts as "Label: value" runs that CSS cannot tell
 * apart, and puts no column titles over these lists. This names each fact
 * (data-uf-key), sets the translated column titles on the list
 * (--uf-th-*), and adds, from the configuration, what a UniFi list shows
 * but LuCI's rows leave out: a network's zone and its addresses while it
 * is down.
 *
 * It only adds attributes to LuCI's nodes (and takes back its own), never
 * moves, removes or re-renders them. LuCI redraws the rows every few
 * seconds, so it tags them again after each redraw; markup it does not
 * recognise it leaves alone, and the stylesheet keeps LuCI's own runs.
 * menu-openuf.js calls enhance() on this page.
 */

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
			[_('Protocol')]: 'protocol',
			[_('Device')]: 'device',
			[_('Carrier')]: 'carrier',
			[_('Uptime')]: 'uptime',
			[_('MAC')]: 'mac',
			[_('RX')]: 'rx',
			[_('TX')]: 'tx',
			[_('IPv4')]: 'ipv4',
			[_('IPv6')]: 'ipv6',
			[_('IPv6-PD')]: 'ipv6pd',
			[_('Information')]: 'info',
			[_('Error')]: 'error'
		};

		this.values = {
			[_('Interface disabled')]: 'disabled',
			[_('Not started on boot')]: 'noboot'
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
			const ifaces = view.querySelector('#cbi-network-interface');
			const devices = view.querySelector('#cbi-network-device');

			if (ifaces)
				this.tagInterfaces(ifaces);

			/* A device's "-" (no MAC, no MTU), which a phone leaves out. */
			if (devices)
				for (const cell of devices.querySelectorAll('.td:is([data-name="macaddr"], [data-name="mtu"])'))
					attr(cell, 'data-uf-empty', cell.textContent.trim() == '-' ? '' : null);
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

	tagInterfaces(section) {
		const zoneTitle = _('Part of zone %q').split('%q');

		this.titles(section, {
			name: _('Name'),
			device: _('Device'),
			protocol: _('Protocol'),
			zone: _('Zone'),
			address: _('IP Address'),
			status: _('Status')
		});

		for (const row of section.querySelectorAll('.cbi-section-table-row[data-sid]')) {
			const head = row.querySelector('[data-name="_ifacebox"] .ifacebox-head');
			const desc = row.querySelector('[data-name="_ifacestat"] > div');

			if (head && zoneTitle.length == 2) {
				const title = head.getAttribute('title') || '';
				const [ pre, post ] = zoneTitle;

				/* "" is no zone. */
				attr(head, 'data-uf-zone', (title.length > pre.length + post.length && title.startsWith(pre) && title.endsWith(post))
					? title.slice(pre.length, title.length - post.length) : '');
			}

			if (desc) {
				this.tagItems(desc);

				/* A static network's own addresses, which LuCI shows only
				 * while it is up. */
				const sid = row.getAttribute('data-sid');
				const addrs = (uci.get('network', sid, 'proto') == 'static')
					? L.toArray(uci.get('network', sid, 'ipaddr')).concat(L.toArray(uci.get('network', sid, 'ip6addr'))) : [];

				attr(desc, 'data-uf-address', addrs.length
					? addrs.map((a) => this.withPrefix(a, uci.get('network', sid, 'netmask'))).join('\n') : null);
			}
		}
	},

	/* "192.168.1.1" with a netmask "255.255.255.0" reads "192.168.1.1/24". */
	withPrefix(addr, mask) {
		if (addr.indexOf('/') > -1 || addr.indexOf(':') > -1 || !mask || !/^[\d.]+$/.test(mask))
			return addr;

		const bits = mask.split('.').reduce((n, o) => n + ((+o).toString(2).match(/1/g) || []).length, 0);

		return '%s/%d'.format(addr, bits);
	}
});
