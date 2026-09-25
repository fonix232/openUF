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
		const on = document.documentElement.classList.toggle(cls);

		pref(key, on ? value : null);
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
