'use strict';
'require baseclass';
'require uci';

/*
 * Network > Interfaces drawn as UniFi's Settings > Networks list: the
 * "settings" design (luci-static/openuf/network/interfaces-settings.css).
 * LuCI writes a row's facts as "Label: value" runs that CSS cannot tell
 * apart, and puts no column titles over these lists. This names each fact
 * (data-uf-key), sets the translated column titles on the list
 * (--uf-th-*), words each row's state (data-uf-state, and data-uf-status
 * where LuCI has no word for it), trims its byte counts to the figures
 * (data-uf-rx, data-uf-tx), and adds, from the configuration, what a
 * UniFi list shows but LuCI's rows leave out: a network's zone and its
 * addresses while it is down. It marks the long names (networks,
 * devices) that fade out at their end (data-uf-fade). The edit dialog's
 * status is named the same way.
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

/* A long name fades out at its end and slides into view on hover:
 * fade.js measures what is marked and rewrites the mark, so it is set
 * only once. */
function fade(node) {
	if (node && !node.hasAttribute('data-uf-fade'))
		node.setAttribute('data-uf-fade', '');
}

/* A run's value, without its label. */
function value(item) {
	const label = item.querySelector(':scope > strong');

	return (label ? item.textContent.slice(label.textContent.length) : item.textContent).trim();
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

		/* A state in words, where LuCI leaves only "Carrier: Absent". */
		this.words = {
			disabled: _('Disabled'),
			starting: _('Not connected'),
			down: _('Not connected')
		};

		/* Tag after LuCI's redraw has settled, once per frame at most. */
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

		/* The edit dialog opens in LuCI's overlay, outside the view. */
		const overlay = document.querySelector('#modal_overlay');

		if (overlay)
			observer.observe(overlay, { childList: true, subtree: true });

		this.tag(view);
	},

	tag(view) {
		try {
			const ifaces = view.querySelector('#cbi-network-interface');
			const devices = view.querySelector('#cbi-network-device');

			if (ifaces)
				this.tagInterfaces(ifaces);

			/* A device's "-" (no MAC, no MTU), which a phone leaves out, and
			 * its name. */
			if (devices) {
				for (const cell of devices.querySelectorAll('.td:is([data-name="macaddr"], [data-name="mtu"])'))
					attr(cell, 'data-uf-empty', cell.textContent.trim() == '-' ? '' : null);

				for (const name of devices.querySelectorAll('.td[data-name="name"] > .ifacebadge > span:not(.cbi-tooltip-container)'))
					fade(name);
			}

			for (const status of document.querySelectorAll('.modal [id$="-ifc-status"] > span'))
				this.tagItems(status);
		}
		catch (e) {
			/* Unfamiliar markup: leave the page as LuCI drew it. */
		}
	},

	/* "Label: value" runs (L.itemlist) and bare notes, named by label;
	 * returns the first run of each name. */
	tagItems(list) {
		const found = {};

		for (const item of list.children) {
			let key = null;

			if (item.matches('span.nowrap')) {
				const label = item.querySelector(':scope > strong');

				key = label ? (this.labels[label.textContent.replace(/:\s*$/, '')] ?? 'other') : 'note';

				if (key == 'info' || key == 'note')
					key = this.values[value(item)] ?? key;
			}
			else if (item.matches('em')) {
				key = this.values[item.textContent.trim()] ?? 'note';
			}
			else if (item.matches('a')) {
				key = 'note';
			}

			if (key) {
				attr(item, 'data-uf-key', key);
				found[key] = found[key] ?? item;
			}
		}

		return found;
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

			/* The network's name, and its device's ('Alias of "wan"'). */
			fade(head?.querySelector(':scope > strong'));
			fade(row.querySelector('[data-name="_ifacebox"] .ifacebox-body > small'));

			if (head && zoneTitle.length == 2) {
				const title = head.getAttribute('title') || '';
				const [ pre, post ] = zoneTitle;

				/* "" is no zone. */
				attr(head, 'data-uf-zone', (title.length > pre.length + post.length && title.startsWith(pre) && title.endsWith(post))
					? title.slice(pre.length, title.length - post.length) : '');
			}

			if (desc) {
				const items = this.tagItems(desc);
				const state = this.state(row, desc, items);

				attr(row, 'data-uf-state', state);
				attr(desc, 'data-uf-status', this.words[state] ?? null);

				if (items.rx)
					this.tagTraffic(items.rx, items.tx);

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

	/* A row's state, from what LuCI drew: its own note while it starts,
	 * stops or cannot be run; its pending changes; an error; up (it has an
	 * uptime); disabled; not started on boot; starting while LuCI allows
	 * only Stop; otherwise down. */
	state(row, desc, items) {
		const restart = row.querySelector('.cbi-section-actions .reconnect');
		const stop = row.querySelector('.cbi-section-actions .down');

		if (desc.hasAttribute('reconnect') || desc.hasAttribute('disconnect') || desc.querySelector(':scope > em, :scope > .nowrap > em'))
			return 'note';
		else if (items.note?.querySelector('a'))
			return 'changes';
		else if (items.error)
			return 'error';
		else if (items.uptime)
			return 'up';
		else if (items.disabled)
			return 'disabled';
		else if (items.noboot)
			return 'noboot';
		else if (restart?.disabled && stop && !stop.disabled)
			return 'starting';

		return 'down';
	},

	/* "1.23 MB (4567 Pkts.)" reads "1.23 MB". The RX run draws both
	 * figures on one line, each grey while it is nothing. */
	tagTraffic(rx, tx) {
		const figure = (item) => item ? value(item).replace(/\s*\([^)]*\)$/, '') : null;
		const down = figure(rx);
		const up = figure(tx);

		attr(rx, 'data-uf-rx', down);
		attr(rx, 'data-uf-tx', up);
		attr(rx, 'data-uf-idle', [ [ 'rx', down ], [ 'tx', up ] ]
			.filter(([ , v ]) => v != null && /^0\s/.test(v)).map(([ k ]) => k).join(' ') || null);
	},

	/* "192.168.1.1" with a netmask "255.255.255.0" reads "192.168.1.1/24". */
	withPrefix(addr, mask) {
		if (addr.indexOf('/') > -1 || addr.indexOf(':') > -1 || !mask || !/^[\d.]+$/.test(mask))
			return addr;

		const bits = mask.split('.').reduce((n, o) => n + ((+o).toString(2).match(/1/g) || []).length, 0);

		return '%s/%d'.format(addr, bits);
	}
});
