'use strict';
'require baseclass';
'require fs';
'require rpc';
'require session';
'require uci';
'require ui';

/*
 * Navigation for luci-theme-openuf, laid out the way the UniFi Network
 * Application lays out its own:
 *
 *   top bar   the LuCI modes as app tabs ("Network" in UniFi)
 *   rail      the first menu level as icons, and at its foot a power
 *             button whose menu reboots or resets the device
 *   subnav    the active category's pages as a list, like UniFi's Settings
 *   tabs      the third level and deeper, as underlined tabs
 */

const PREFIX = 'luci-theme-openuf.';

/* Categories pinned to the foot of the rail, as UniFi pins Settings. */
const RAIL_FOOT = [ 'system' ];

/* System > Reboot's call (luci-mod-system, view/system/reboot.js). */
const callReboot = rpc.declare({
	object: 'system',
	method: 'reboot',
	expect: { result: 0 }
});

const SCHEMES = [ 'auto', 'light', 'dark' ];

/* Pages drawn in a design of the user's choosing (System > openUF Theme):
 * header.ut puts the choice on <html> and links its stylesheet; its script
 * is view/openuf-theme/network/<page>-<design>.js. */
const DESIGNED = {
	'admin/network/network': 'interfaces',
	'admin/network/wireless': 'wireless'
};

/* LuCI views a script of the theme's redraws, by the view the page runs
 * (its node's action): view/openuf-theme/<script>.js, whose enhance() is
 * given the view's path. Its styles are in cascade.css. */
const ENHANCED = {
	'status/syslog': 'logs',
	'status/dmesg': 'logs'
};

function pref(key, value) {
	try {
		if (value === undefined)
			return window.localStorage.getItem(PREFIX + key);
		else if (value === null)
			window.localStorage.removeItem(PREFIX + key);
		else
			window.localStorage.setItem(PREFIX + key, value);
	}
	catch (e) {
		/* Private mode or storage disabled: the choice lasts this page only. */
	}

	return null;
}

return baseclass.extend({
	__init__() {
		ui.menu.load().then((tree) => this.render(tree));
		this.loadDesign();
		this.loadEnhancement();
	},

	/* The script for a view in ENHANCED. It checks LuCI's markup itself,
	 * and without it the view stays as LuCI draws it. */
	loadEnhancement() {
		const action = L.env.nodespec ? L.env.nodespec.action : null;
		const path = (action && action.type == 'view') ? action.path : null;

		if (!Object.prototype.hasOwnProperty.call(ENHANCED, path))
			return;

		L.resolveDefault(L.require('view.openuf-theme.' + ENHANCED[path]), null).then((mod) => {
			if (mod && typeof(mod.enhance) == 'function')
				mod.enhance(path);
		});
	},

	/* The design's script names what its stylesheet needs in LuCI's rows.
	 * Without one (or with an unknown design) the rows stay as LuCI drew
	 * them. */
	loadDesign() {
		const page = DESIGNED[L.env.dispatchpath.slice(0, 3).join('/')];
		const design = page ? document.documentElement.getAttribute('data-uf-' + page) : null;

		if (!design || !/^[a-z]+$/.test(design))
			return;

		L.resolveDefault(L.require('view.openuf-theme.network.%s-%s'.format(page, design)), null).then((mod) => {
			if (mod && typeof(mod.enhance) == 'function')
				mod.enhance();
		});

		/* The names the design marks to fade (cascade.css, "Fading names"). */
		L.resolveDefault(L.require('view.openuf-theme.fade'), null).then((fade) => {
			if (fade)
				fade.watch(document.querySelector('#view'));
		});
	},

	render(tree) {
		let node = tree;
		let url = '';

		this.renderModeMenu(tree);

		if (L.env.dispatchpath.length >= 3) {
			for (let i = 0; i < 3 && node; i++) {
				node = node.children[L.env.dispatchpath[i]];
				url = url + (url ? '/' : '') + L.env.dispatchpath[i];
			}

			if (node)
				this.renderTabMenu(node, url);
		}

		this.bindChrome();

		if (L.env.dispatchpath.slice(0, 3).join('/') == 'admin/network/network' &&
		    document.documentElement.getAttribute('data-uf-port-manager') != '0')
			this.renderPorts();
	},

	/* Network > Interfaces: UniFi's Port Manager, the router's ports as a
	 * strip of squares over a list of each port's link, networks, VLANs
	 * and traffic. A card above LuCI's view (never inside it, which LuCI
	 * redraws), so it sits the same over every design; LuCI's poll updates
	 * it in place. */
	renderPorts() {
		const view = document.querySelector('#view');

		if (!view)
			return;

		/* network.js asks LuCI for the system's features, which it has only
		 * once it has set the page up. */
		const loaded = L.loaded ? Promise.resolve() : new Promise((resolve) => document.addEventListener('luci-loaded', resolve, { once: true }));

		Promise.all([ L.require('view.openuf-theme.ports'), L.require('poll'), loaded ]).then(([ ports, poll ]) => {
			let card = null;

			/* On a phone the per-port list would push the interfaces a
			 * screen down, so there it folds away behind "Details" (the
			 * squares stay); the choice is remembered. Each poll draws the
			 * card afresh, so the state goes into every drawing. */
			let open = pref('ports-list') == 'open';

			const toggle = () => E('button', {
				'type': 'button',
				'class': 'cbi-button uf-ports-toggle',
				'aria-expanded': open ? 'true' : 'false'
			}, [ _('Details') ]);

			const update = () => ports.load().then((data) => {
				const body = ports.render(data, { mode: 'full', clickable: true });
				const fresh = body ? ports.card(body, {
					title: _('Port Manager'),
					desc: ports.summary(data),
					actions: [ toggle() ]
				}) : null;

				if (fresh)
					fresh.setAttribute('data-list', open ? 'open' : 'closed');

				card = ports.patch(card, fresh);

				if (card && !card.parentNode) {
					card.addEventListener('uf-port-select', (ev) => this.openPort(ev.detail.port));
					card.addEventListener('click', (ev) => {
						const button = ev.target.closest('.uf-ports-toggle');

						if (!button)
							return;

						open = !open;
						pref('ports-list', open ? 'open' : null);
						card.setAttribute('data-list', open ? 'open' : 'closed');
						button.setAttribute('aria-expanded', open ? 'true' : 'false');
					});
					view.parentNode.insertBefore(card, view);
				}
			});

			return update().then(() => poll.add(update, 5));
		}).catch((err) => console.warn('luci-theme-openuf: no port panel:', err));
	},

	/* Show a port's settings: the Devices tab, and on it the dialog of the
	 * port's bridge (its VLAN tab, if it filters) or of the port itself.
	 * swconfig ports live on the Switch page. */
	openPort(port) {
		if (port && port.switch) {
			window.location.href = L.url('admin/network/switch');
			return;
		}

		const tab = document.querySelector('#view .cbi-tabmenu > li[data-tab="device"] > a');

		if (!tab)
			return;

		if (!document.querySelector('#view .cbi-map-tabbed > [data-tab="device"][data-tab-active="true"]'))
			tab.click();

		const sid = port ? (port.bridge ? port.bridge.sid : (port.section || (port.device ? 'dev:' + port.device : null))) : null;
		const row = sid ? document.querySelector('#cbi-network-device .cbi-section-table-row[data-sid="%s"]'.format(CSS.escape(sid))) : null;
		const edit = row ? row.querySelector('.cbi-button-edit') : null;

		if (!edit)
			return (row || tab).scrollIntoView({ block: 'nearest' });

		edit.click();

		if (!port.bridge || !port.bridge.filtering)
			return;

		/* The dialog renders asynchronously; give it a moment to appear. */
		const until = Date.now() + 3000;
		const pick = () => {
			const vlans = document.querySelector('.modal .cbi-tabmenu > li[data-tab="bridgevlan"] > a');

			if (vlans)
				vlans.click();
			else if (Date.now() < until)
				window.setTimeout(pick, 50);
		};

		pick();
	},

	renderModeMenu(tree) {
		const ul = document.querySelector('#modemenu');
		const children = ui.menu.getChildren(tree);

		children.forEach((child, index) => {
			const isActive = L.env.requestpath.length
				? child.name === L.env.requestpath[0]
				: index === 0;

			ul.appendChild(E('li', { 'class': isActive ? 'active' : '' }, [
				E('a', { 'href': L.url(child.name) }, [
					E('span', { 'class': 'uf-appicon', 'aria-hidden': 'true' }),
					E('span', { 'class': 'uf-apptab-label' }, [ _(child.title) ])
				])
			]));

			if (isActive)
				this.renderMainMenu(child, child.name);
		});

		if (ul.children.length)
			ul.style.display = '';
	},

	renderMainMenu(tree, url) {
		const nav = document.querySelector('#mainmenu');
		const head = E('ul', { 'class': 'uf-rail-list' });
		const foot = E('ul', { 'class': 'uf-rail-list uf-rail-foot' });
		const children = ui.menu.getChildren(tree);

		if (!children.length)
			return;

		children.forEach(child => {
			/* Log out is in the avatar menu (header.ut), or failing that
			 * in the power menu (renderPower). */
			if (child.name == 'logout')
				return;

			const isActive = (L.env.dispatchpath[1] == child.name);
			const title = _(child.title);

			const li = E('li', {
				'class': 'uf-rail-item' + (isActive ? ' active' : ''),
				'data-name': child.name
			}, [
				E('a', {
					'href': L.url(url, child.name),
					'aria-label': title,
					'aria-current': isActive ? 'page' : null
				}, [
					E('span', { 'class': 'uf-icon', 'aria-hidden': 'true' }),
					E('span', { 'class': 'uf-rail-label' }, [ title ])
				])
			]);

			(RAIL_FOOT.indexOf(child.name) > -1 ? foot : head).appendChild(li);

			if (isActive && ui.menu.getChildren(child).length) {
				this.renderSubMenu(child, url + '/' + child.name, title);

				li.addEventListener('mouseenter', () => this.trace(li, true));
				li.addEventListener('mouseleave', () => this.trace(li, false));
			}
		});

		const power = this.renderPower(tree, url);

		if (power)
			foot.appendChild(power);

		foot.appendChild(E('li', { 'class': 'uf-rail-item uf-rail-toggle' }, [
			E('button', {
				'type': 'button',
				'class': 'uf-railbtn',
				'aria-label': _('Expand'),
				'click': () => this.toggleState('uf-rail-expanded', 'rail', 'expanded')
			}, [
				E('span', { 'class': 'uf-icon', 'aria-hidden': 'true' }),
				E('span', { 'class': 'uf-rail-label' }, [ _('Collapse') ])
			])
		]));

		nav.appendChild(head);
		nav.appendChild(foot);
		nav.style.display = '';

		/* On a phone the drawer stacks the pages under the categories;
		 * cascade.css places them by this height. */
		if (window.ResizeObserver)
			new ResizeObserver(() => {
				document.documentElement.style.setProperty('--uf-drawer-rail-h', `${nav.offsetHeight}px`);
			}).observe(nav);
	},

	/* The rail's power button: what System > Reboot and System > Backup /
	 * Flash Firmware do, in a menu that opens on a click, never on hover.
	 * Each item only if the session has its page (and may change the
	 * device, for the ones that do); Log out only if the avatar menu lacks
	 * it. No item, no button. */
	renderPower(tree, url) {
		const find = (path) => path.reduce((node, name) =>
			node ? ui.menu.getChildren(node).find((child) => child.name == name) : null, tree);
		const reboot = find([ 'system', 'reboot' ]);
		const flash = find([ 'system', 'flash' ]);
		const logout = document.querySelector('.uf-signout') ? null : find([ 'logout' ]);

		const item = (label, click, cls) => E('button', {
			'type': 'button',
			'role': 'menuitem',
			'tabindex': '-1',
			'class': cls || null,
			'click': click
		}, [ label ]);

		const link = (label, href, cls) => E('a', {
			'role': 'menuitem',
			'tabindex': '-1',
			'class': cls || null,
			'href': href
		}, [ label ]);

		/* Shown once canReset() says the device can be reset. */
		const reset = (flash && !flash.readonly)
			? item(_('Factory reset…'), () => this.confirmReset(), 'uf-danger') : null;

		const items = [
			(reboot && !reboot.readonly) ? item(_('Reboot…'), () => this.confirmReboot()) : null,
			flash ? link(_('Backup / flash firmware…'), L.url(url, 'system', 'flash')) : null,
			reset,
			logout ? link(_('Log out'), L.url(url, 'logout'), 'uf-danger') : null
		].filter((el) => el);

		if (!items.length)
			return null;

		const menu = E('div', {
			'class': 'uf-power-menu',
			'id': 'uf-power-menu',
			'role': 'menu',
			'aria-label': _('Power')
		}, items);

		const button = E('button', {
			'type': 'button',
			'aria-label': _('Power'),
			'aria-haspopup': 'menu',
			'aria-expanded': 'false',
			'aria-controls': 'uf-power-menu'
		}, [
			E('span', { 'class': 'uf-icon', 'aria-hidden': 'true' }),
			E('span', { 'class': 'uf-rail-label' }, [ _('Power') ])
		]);

		const li = E('li', { 'class': 'uf-rail-item uf-power', 'data-name': 'power' }, [ button, menu ]);

		this.power = { li: li, button: button, menu: menu, items: items, reset: reset };

		button.addEventListener('click', () => this.openPower(!li.classList.contains('open')));

		button.addEventListener('keydown', (ev) => {
			if (ev.key != 'ArrowDown' && ev.key != 'ArrowUp')
				return;

			ev.preventDefault();
			this.openPower(true, ev.key == 'ArrowUp');
		});

		/* A menu's keys: the arrows, Home and End move, Escape closes it
		 * back onto the button, Tab closes it and moves on. */
		menu.addEventListener('keydown', (ev) => {
			const list = items.filter((el) => !el.hidden);
			const i = list.indexOf(document.activeElement);
			let next = null;

			switch (ev.key) {
			case 'ArrowDown': next = list[(i + 1) % list.length]; break;
			case 'ArrowUp': next = list[(i > 0 ? i : list.length) - 1]; break;
			case 'Home': next = list[0]; break;
			case 'End': next = list[list.length - 1]; break;
			case 'Escape': this.openPower(false); next = button; break;
			case 'Tab': this.openPower(false); return;
			case ' ':
				if (document.activeElement.tagName != 'A')
					return;

				document.activeElement.click();
				break;
			default: return;
			}

			ev.preventDefault();
			ev.stopPropagation();
			next?.focus();
		});

		menu.addEventListener('click', (ev) => {
			if (ev.target.closest('[role="menuitem"]'))
				this.openPower(false);
		});

		/* Capturing, as the avatar button stops its clicks. */
		document.addEventListener('click', (ev) => {
			if (!li.contains(ev.target))
				this.openPower(false);
		}, true);

		/* The rail scrolls, and the window can change under an open menu. */
		document.addEventListener('scroll', () => this.placePower(), true);
		window.addEventListener('resize', () => this.placePower());

		return li;
	},

	/* Open the power menu, onto its first item (or its last), or close it. */
	openPower(open, last) {
		const p = this.power;

		if (!p)
			return;

		/* Each call supersedes an opening still waiting on canReset(), so
		 * a click elsewhere in the meantime keeps the menu shut. */
		const ticket = this.powerTicket = {};

		if (!open) {
			p.li.classList.remove('open');
			p.button.setAttribute('aria-expanded', 'false');
			return;
		}

		if (p.li.classList.contains('open'))
			return;

		(p.reset ? this.canReset() : Promise.resolve(false)).then((can) => {
			if (this.powerTicket !== ticket)
				return;

			if (p.reset)
				p.reset.hidden = !can;

			p.li.classList.add('open');
			p.button.setAttribute('aria-expanded', 'true');
			this.placePower();

			const list = p.items.filter((el) => !el.hidden);

			list[last ? list.length - 1 : 0].focus();
		});
	},

	/* Beside the power button, on the side away from the rail and inside
	 * the window: level with the button, or rising from its foot where the
	 * window ends first. In the drawer, whose rail is wide, under the
	 * button or over it. */
	placePower() {
		const p = this.power;

		if (!p || !p.li.classList.contains('open'))
			return;

		const gap = 8;
		const btn = p.button.getBoundingClientRect();
		const w = p.menu.offsetWidth;
		const h = p.menu.offsetHeight;
		const vw = document.documentElement.clientWidth;
		const vh = document.documentElement.clientHeight;
		const bar = document.querySelector('.uf-topbar');
		let x = btn.right + gap;
		let y = btn.top - 6;

		if (x + w > vw - gap) {
			x = btn.left;
			y = (btn.bottom + 4 + h > vh - gap) ? btn.top - 4 - h : btn.bottom + 4;
		}
		else if (y + h > vh - gap) {
			y = btn.bottom + 6 - h;
		}

		p.menu.style.left = '%dpx'.format(Math.max(gap, Math.min(x, vw - w - gap)));
		p.menu.style.top = '%dpx'.format(Math.max((bar ? bar.offsetHeight : 0) + gap, Math.min(y, vh - h - gap)));
	},

	/* Backup / Flash Firmware offers a reset only where there is an overlay
	 * to erase (flash.js: rootfs_data in /proc/mtd, or the overlay mounted
	 * on /). Asked once a session. */
	canReset() {
		const known = session.getLocalData('openuf-can-reset');

		if (known != null)
			return Promise.resolve(known);

		return Promise.all([ fs.trimmed('/proc/mtd'), fs.trimmed('/proc/mounts') ]).then(([ mtd, mounts ]) => {
			const can = (mtd.match(/"rootfs_data"/) != null) || (mounts.indexOf('overlayfs:/overlay / ') > -1);

			session.setLocalData('openuf-can-reset', can);

			return can;
		});
	},

	/* A dialog's Cancel: LuCI's Escape presses it, and the focus goes back
	 * to the power button. */
	cancelButton() {
		return E('button', {
			'class': 'btn',
			'click': () => {
				ui.hideModal();
				this.power.button.focus();
			}
		}, [ _('Cancel') ]);
	},

	/* System > Reboot's page, as a dialog: it warns of unsaved changes as
	 * that page does. */
	confirmReboot() {
		return L.resolveDefault(uci.changes(), {}).then((changes) => {
			ui.showModal(_('Reboot'), [
				E('p', {}, [ _('Reboots the operating system of your device') ]),
				Object.keys(changes || {}).length
					? E('p', { 'class': 'alert-message warning' }, [ _('Warning: There are unsaved changes that will get lost on reboot!') ])
					: '',
				E('div', { 'class': 'right' }, [
					this.cancelButton(), ' ',
					E('button', {
						'class': 'btn cbi-button-action important',
						'click': ui.createHandlerFn(this, 'handleReboot')
					}, [ _('Perform reboot') ])
				])
			]);
		});
	},

	/* "Perform reboot", as reboot.js does it: system.reboot, then wait for
	 * the device to answer again and reload. */
	handleReboot() {
		return callReboot().then((res) => {
			if (res != 0)
				throw new Error(_('The reboot command failed with code %d').format(res));

			ui.showModal(_('Rebooting…'), [
				E('p', { 'class': 'spinning' }, [ _('Waiting for device...') ])
			]);

			window.setTimeout(() => {
				ui.showModal(_('Rebooting…'), [
					E('p', { 'class': 'spinning alert-message warning' }, [ _('Device unreachable! Still waiting for device...') ])
				]);
			}, 150000);

			ui.awaitReconnect();
		}).catch((err) => {
			ui.hideModal();
			ui.addNotification(null, E('p', [ err.message ]));
		});
	},

	confirmReset() {
		ui.showModal(_('Factory reset'), [
			E('p', {}, [ _('Do you really want to erase all settings?') ]),
			E('p', { 'class': 'alert-message danger' }, [
				_('This erases all settings and every package installed since the firmware was flashed, then restarts the device with its defaults, at its default address. It cannot be undone.')
			]),
			E('div', { 'class': 'right' }, [
				this.cancelButton(), ' ',
				E('button', {
					'class': 'btn cbi-button-negative important',
					'click': () => this.handleReset()
				}, [ _('Perform reset') ])
			])
		]);
	},

	/* Backup / Flash Firmware's "Perform reset", as flash.js does it:
	 * firstboot erases the overlay and reboots, so its call does not
	 * return; LuCI then waits for the device at OpenWrt's default
	 * address. */
	handleReset() {
		ui.showModal(_('Erasing...'), [
			E('p', { 'class': 'spinning' }, [ _('The system is erasing the configuration partition now and will reboot itself when finished.') ])
		]);

		fs.exec('/sbin/firstboot', [ '-r', '-y' ]).catch(() => {});

		ui.awaitReconnect('192.168.1.1', 'openwrt.lan');
	},

	/* Hovering the category whose pages the column shows traces a line from
	 * its icon into the column's heading (cascade.css, "traces a line"):
	 * measure both ends, relative to the column, which scrolls. Only while
	 * the column stands beside the rail, not in the phone drawer. */
	trace(li, on) {
		const nav = document.querySelector('#submenu');
		const head = nav ? nav.querySelector('.uf-subnav-head') : null;

		if (!on || !head || !nav.offsetParent || !window.matchMedia('(min-width: 961px)').matches) {
			if (nav)
				nav.removeAttribute('data-trace');

			return;
		}

		const icon = li.firstElementChild.getBoundingClientRect();
		const from = icon.top + icon.height / 2 - nav.getBoundingClientRect().top + nav.scrollTop;
		const to = head.offsetTop + head.offsetHeight / 2;

		nav.style.setProperty('--uf-trace-top', '%dpx'.format(Math.min(from, to)));
		nav.style.setProperty('--uf-trace-h', '%dpx'.format(Math.abs(from - to)));
		nav.setAttribute('data-trace', (from >= to) ? 'down' : 'up');
	},

	renderSubMenu(tree, url, title) {
		const nav = document.querySelector('#submenu');
		const pages = ui.menu.getChildren(tree);

		nav.appendChild(E('div', { 'class': 'uf-subnav-head' }, [
			E('span', { 'class': 'uf-subnav-title' }, [ title ]),
			E('button', {
				'type': 'button',
				'class': 'uf-iconbtn uf-subnav-collapse',
				'aria-label': _('Collapse'),
				'click': () => this.toggleState('uf-subnav-collapsed', 'subnav', 'collapsed')
			})
		]));

		nav.appendChild(E('ul', { 'class': 'uf-subnav-list' }, pages.map(page => {
			const isActive = (L.env.dispatchpath[2] == page.name);

			return E('li', { 'class': isActive ? 'active' : '' }, [
				E('a', {
					'href': L.url(url, page.name),
					'aria-current': isActive ? 'page' : null
				}, [ _(page.title) ])
			]);
		})));

		/* Brings a collapsed column back, from the content's leading edge. */
		document.querySelector('#maincontent').prepend(E('button', {
			'type': 'button',
			'class': 'uf-iconbtn uf-subnav-expand',
			'aria-label': _('Expand'),
			'title': title,
			'click': () => this.toggleState('uf-subnav-collapsed', 'subnav', 'collapsed')
		}));

		document.documentElement.classList.add('uf-has-subnav');
		nav.style.display = '';
	},

	renderTabMenu(tree, url, level) {
		const container = document.querySelector('#tabmenu');
		const ul = E('ul', { 'class': 'tabs' });
		const children = ui.menu.getChildren(tree);
		let activeNode = null;

		children.forEach(child => {
			const isActive = (L.env.dispatchpath[3 + (level || 0)] == child.name);
			const activeClass = isActive ? ' active' : '';
			const className = 'tabmenu-item-%s %s'.format(child.name, activeClass);

			ul.appendChild(E('li', { 'class': className }, [
				E('a', { 'href': L.url(url, child.name) }, [ _(child.title) ] )]));

			if (isActive)
				activeNode = child;
		});

		if (ul.children.length == 0)
			return E([]);

		container.appendChild(ul);
		container.style.display = '';

		if (activeNode)
			this.renderTabMenu(activeNode, url + '/' + activeNode.name, (level || 0) + 1);

		return ul;
	},

	toggleState(cls, key, value) {
		const root = document.documentElement;

		/* The rail animates its width only while this class is set (see
		 * cascade.css), so a relayout at any other time never catches it
		 * mid-transition. */
		root.classList.add('uf-rail-animating');
		window.clearTimeout(this.animating);
		this.animating = window.setTimeout(() => root.classList.remove('uf-rail-animating'), 250);

		pref(key, root.classList.toggle(cls) ? value : null);
	},

	bindChrome() {
		const root = document.documentElement;
		const scheme = document.querySelector('.uf-scheme');
		const burger = document.querySelector('.uf-burger');
		const scrim = document.querySelector('.uf-scrim');
		const user = document.querySelector('.uf-user');

		if (scheme) {
			const label = () => {
				const s = root.getAttribute('data-scheme') || 'auto';

				scheme.setAttribute('title', {
					auto: _('Colour scheme: follow system'),
					light: _('Colour scheme: light'),
					dark: _('Colour scheme: dark')
				}[s]);
			};

			scheme.addEventListener('click', () => {
				const cur = SCHEMES.indexOf(root.getAttribute('data-scheme') || 'auto');
				const next = SCHEMES[(cur + 1) % SCHEMES.length];

				pref('scheme', next == 'auto' ? null : next);
				window.ufApplyScheme();
				label();
			});

			label();
		}

		const setDrawer = (open) => {
			root.classList.toggle('uf-nav-open', open);
			burger.setAttribute('aria-expanded', open ? 'true' : 'false');
		};

		burger.addEventListener('click', () => setDrawer(!root.classList.contains('uf-nav-open')));
		scrim.addEventListener('click', () => setDrawer(false));

		if (user) {
			const btn = user.querySelector('.uf-avatar');
			const setMenu = (open) => {
				user.classList.toggle('open', open);
				btn.setAttribute('aria-expanded', open ? 'true' : 'false');
			};

			btn.addEventListener('click', (ev) => {
				ev.stopPropagation();
				setMenu(!user.classList.contains('open'));
			});

			document.addEventListener('click', (ev) => {
				if (!user.contains(ev.target))
					setMenu(false);
			});
		}

		document.addEventListener('keydown', (ev) => {
			if (ev.key !== 'Escape')
				return;

			setDrawer(false);
			user?.classList.remove('open');
			this.openPower(false);
		});
	}
});
