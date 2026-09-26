'use strict';
'require baseclass';
'require ui';

/*
 * Navigation for luci-theme-unifi, laid out the way the UniFi Network
 * Application lays out its own:
 *
 *   top bar   the LuCI modes as app tabs ("Network" in UniFi)
 *   rail      the first menu level as icons, with a flyout of each
 *             category's pages on hover
 *   subnav    the active category's pages as a list, like UniFi's Settings
 *   tabs      the third level and deeper, as underlined tabs
 */

const PREFIX = 'luci-theme-unifi.';

/* Categories pinned to the foot of the rail, as UniFi pins Settings. */
const RAIL_FOOT = [ 'system', 'logout' ];

const SCHEMES = [ 'auto', 'light', 'dark' ];

/* Pages drawn in a design of the user's choosing (System > UniFi Theme):
 * header.ut puts the choice on <html> and links its stylesheet; its script
 * is view/unifi/network/<page>-<design>.js. */
const DESIGNED = {
	'admin/network/network': 'interfaces',
	'admin/network/wireless': 'wireless'
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
	},

	/* The design's script names what its stylesheet needs in LuCI's rows.
	 * Without one (or with an unknown design) the rows stay as LuCI drew
	 * them. */
	loadDesign() {
		const page = DESIGNED[L.env.dispatchpath.slice(0, 3).join('/')];
		const design = page ? document.documentElement.getAttribute('data-uf-' + page) : null;

		if (!design || !/^[a-z]+$/.test(design))
			return;

		L.resolveDefault(L.require('view.unifi.network.%s-%s'.format(page, design)), null).then((mod) => {
			if (mod && typeof(mod.enhance) == 'function')
				mod.enhance();
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

		Promise.all([ L.require('view.unifi.ports'), L.require('poll'), loaded ]).then(([ ports, poll ]) => {
			let card = null;

			const update = () => ports.load().then((data) => {
				const body = ports.render(data, { mode: 'full', clickable: true });

				card = ports.patch(card, body ? ports.card(body, {
					title: _('Port Manager'),
					desc: ports.summary(data)
				}) : null);

				if (card && !card.parentNode) {
					card.addEventListener('uf-port-select', (ev) => this.openPort(ev.detail.port));
					view.parentNode.insertBefore(card, view);
				}
			});

			return update().then(() => poll.add(update, 5));
		}).catch((err) => console.warn('luci-theme-unifi: no port panel:', err));
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
			const isActive = (L.env.dispatchpath[1] == child.name);
			const pages = ui.menu.getChildren(child);
			const title = _(child.title);

			const flyout = pages.length
				? E('div', { 'class': 'uf-flyout' }, [
					E('div', { 'class': 'uf-flyout-title' }, [ title ]),
					E('ul', {}, pages.map(page => E('li', {
						'class': (isActive && L.env.dispatchpath[2] == page.name) ? 'active' : ''
					}, [
						E('a', { 'href': L.url(url, child.name, page.name) }, [ _(page.title) ])
					])))
				])
				: E('div', { 'class': 'uf-flyout uf-tip' }, [ title ]);

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
				]),
				flyout
			]);

			(RAIL_FOOT.indexOf(child.name) > -1 ? foot : head).appendChild(li);

			if (isActive && pages.length)
				this.renderSubMenu(child, url + '/' + child.name, title);
		});

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
		});
	}
});
