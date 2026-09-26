'use strict';
'require view';
'require form';
'require uci';

/*
 * System > UniFi Theme: the theme's own settings, kept in LuCI's config.
 *
 *   luci.unifi.interfaces    Network > Interfaces design: list, settings, cards
 *   luci.unifi.wireless      Network > Wireless design: list, settings, cards
 *   luci.unifi.port_manager  the Port Manager on Interfaces: 1 or 0
 *   luci.main.mediaurlbase   the colour scheme: /luci-static/unifi (follow
 *                            the system), unifi-light or unifi-dark
 *
 * header.ut reads them on every page load, so Save & Apply (which reloads
 * the page) shows the change at once. Each choice is a card with a small
 * schematic of what it looks like, drawn here in SVG and coloured by the
 * theme's tokens (cascade.css, "page: unifi-theme").
 */

const SVG_NS = 'http://www.w3.org/2000/svg';

/* An SVG element; `cls` names its colour in cascade.css (uf-pv-*). */
function svg(tag, attrs, children) {
	const node = document.createElementNS(SVG_NS, tag);

	for (const name in attrs)
		if (attrs[name] != null)
			node.setAttribute(name, attrs[name]);

	for (const child of children || [])
		node.appendChild(child);

	return node;
}

function rect(x, y, w, h, cls, r) {
	return svg('rect', { x: x, y: y, width: w, height: h, rx: r ?? Math.min(h / 2, 1.5), 'class': cls });
}

function dot(x, y, cls) {
	return svg('circle', { cx: x, cy: y, r: 1.6, 'class': cls });
}

/* The schematics, on a 120 x 72 canvas: a card and what the page holds. */
const PREVIEWS = {
	/* UniFi's device list: a row each, a dot, a tile, the name, columns. */
	list: () => {
		const rows = [ 'uf-pv-green', 'uf-pv-green', 'uf-pv-muted', 'uf-pv-orange' ];

		return [
			rect(4, 4, 112, 64, 'uf-pv-card', 4),
			rect(44, 11, 14, 3, 'uf-pv-line'),
			rect(66, 11, 14, 3, 'uf-pv-line'),
			rect(88, 11, 14, 3, 'uf-pv-line'),
			rect(10, 18, 100, 0.8, 'uf-pv-rule', 0),
			...rows.flatMap((state, i) => {
				const y = 25 + i * 11;

				return [
					dot(13, y + 2.5, state),
					rect(18, y - 1, 7, 7, 'uf-pv-tile', 1.5),
					rect(29, y + 1, 12, 3, 'uf-pv-text'),
					rect(44, y + 1, 16, 3, 'uf-pv-line'),
					rect(66, y + 1, 18, 3, 'uf-pv-line'),
					rect(88, y + 1, 8, 3, 'uf-pv-cyan'),
					rect(98, y + 1, 8, 3, 'uf-pv-purple')
				];
			})
		];
	},

	/* UniFi's Settings lists: the title and "Create New", titled columns,
	 * a line each with chips and quiet actions. */
	settings: () => [
		rect(4, 4, 112, 64, 'uf-pv-card', 4),
		rect(10, 10, 26, 4, 'uf-pv-text'),
		rect(90, 9, 20, 6, 'uf-pv-accent', 2),
		rect(10, 20, 12, 2.5, 'uf-pv-line'),
		rect(40, 20, 12, 2.5, 'uf-pv-line'),
		rect(64, 20, 12, 2.5, 'uf-pv-line'),
		rect(10, 25, 100, 0.8, 'uf-pv-rule', 0),
		...[ 'uf-pv-green', 'uf-pv-green', 'uf-pv-muted', 'uf-pv-red' ].flatMap((state, i) => {
			const y = 31 + i * 9.5;

			return [
				dot(12, y + 1.5, state),
				rect(16, y, 16, 3, 'uf-pv-text'),
				rect(39, y - 1, 16, 5, 'uf-pv-chip', 1.5),
				rect(62, y - 1, 12, 5, 'uf-pv-zone', 2.5),
				rect(80, y, 12, 3, 'uf-pv-line'),
				dot(101, y + 1.5, 'uf-pv-icon'),
				dot(107, y + 1.5, 'uf-pv-icon')
			];
		})
	],

	/* UniFi's device panel: a card each, a tile, the name and a chip, then
	 * label/value rows and a traffic bar. */
	cards: () => [ [ 4, 4 ], [ 62, 4 ], [ 4, 38 ], [ 62, 38 ] ].flatMap(([ x, y ], i) => [
		rect(x, y, 54, 30, 'uf-pv-card', 3),
		rect(x + 4, y + 4, 8, 8, i == 2 ? 'uf-pv-tile-alt' : 'uf-pv-tile', 2),
		rect(x + 15, y + 4.5, 16, 3, 'uf-pv-text'),
		rect(x + 15, y + 9, 12, 3, i == 3 ? 'uf-pv-chip-off' : 'uf-pv-chip-on', 1.5),
		rect(x + 4, y + 16, 12, 2, 'uf-pv-line'),
		rect(x + 34, y + 16, 16, 2, 'uf-pv-line'),
		rect(x + 4, y + 20.5, 10, 2, 'uf-pv-line'),
		rect(x + 38, y + 20.5, 12, 2, 'uf-pv-line'),
		rect(x + 4, y + 25, 30, 1.6, 'uf-pv-cyan', 0.8),
		rect(x + 34, y + 25, 16, 1.6, 'uf-pv-purple', 0.8)
	])
};

/* A colour scheme: the page's chrome in its colours, light and dark side
 * by side for "follow the system". */
function schemePreview(kinds) {
	const w = 120 / kinds.length;

	return kinds.flatMap((kind, i) => {
		const x = i * w;

		return [
			svg('svg', { x: x, y: 0, width: w, height: 72, viewBox: '%d 0 %d 72'.format(x, w), 'class': 'uf-scheme-' + kind }, [
				rect(x, 0, w, 72, 'uf-pv-canvas', 0),
				rect(x, 0, w, 10, 'uf-pv-bar', 0),
				rect(0, 10, 10, 62, 'uf-pv-rail', 0),
				rect(14, 16, 102, 24, 'uf-pv-card', 3),
				rect(20, 22, 30, 3, 'uf-pv-text'),
				rect(20, 29, 60, 2.5, 'uf-pv-line'),
				rect(20, 34, 44, 2.5, 'uf-pv-line'),
				rect(14, 44, 102, 24, 'uf-pv-card', 3),
				rect(20, 50, 24, 3, 'uf-pv-text'),
				rect(92, 49, 18, 6, 'uf-pv-accent', 2),
				rect(20, 58, 50, 2.5, 'uf-pv-line')
			])
		];
	});
}

const SCHEMES = {
	'/luci-static/unifi': () => schemePreview([ 'light', 'dark' ]),
	'/luci-static/unifi-light': () => schemePreview([ 'light' ]),
	'/luci-static/unifi-dark': () => schemePreview([ 'dark' ])
};

/* One choice as a card: the schematic, its name and a line about it. */
function choice(shapes, title, desc) {
	return E('span', { 'class': 'uf-choice' }, [
		E('span', { 'class': 'uf-choice-preview', 'aria-hidden': 'true' }, [
			svg('svg', { viewBox: '0 0 120 72', width: 120, height: 72 }, shapes)
		]),
		E('span', { 'class': 'uf-choice-title' }, [ title ]),
		desc ? E('span', { 'class': 'uf-choice-desc' }, [ desc ]) : ''
	]);
}

/* A ListValue drawn as a row of cards (LuCI's radio widget underneath, so
 * saving, resetting and validation are LuCI's own). */
const CardValue = form.ListValue.extend({
	__init__(...args) {
		this.super('__init__', args);
		this.widget = 'radio';
		this.orientation = 'vertical';
		this.cards = {};
	},

	card(key, shapes, title, desc) {
		this.cards[key] = [ shapes, title, desc ];
		this.value(key, title);
	},

	renderWidget(section_id, option_index, cfgvalue) {
		/* Fresh nodes for every render: LuCI renders a form again after
		 * saving, and a node can only be in one place. */
		this.vallist = this.keylist.map((key) => choice(this.cards[key][0](), this.cards[key][1], this.cards[key][2]));

		const node = this.super('renderWidget', [ section_id, option_index, cfgvalue ]);

		node.classList.add('uf-choices');

		/* LuCI labels a radio with an empty <label>; name it after its card. */
		node.querySelectorAll('input[type="radio"]').forEach((input) => {
			if (this.cards[input.value])
				input.setAttribute('aria-label', this.cards[input.value][1]);
		});

		return node;
	}
});

return view.extend({
	load() {
		return uci.load('luci').then(() => {
			/* The package's uci-defaults hook makes this; a hand install
			 * without it gets it here. */
			if (uci.get('luci', 'unifi') == null)
				uci.add('luci', 'internal', 'unifi');
		});
	},

	render() {
		const m = new form.Map('luci', _('UniFi Theme'),
			_('How the theme draws Network › Interfaces and Network › Wireless, whether Interfaces shows the Port Manager, and its colour scheme. Changes show once they are applied.'));
		let s, o;

		s = m.section(form.NamedSection, 'unifi', 'internal', _('Network pages'));
		s.addremove = false;

		const designs = [
			[ 'list', PREVIEWS.list, _('Device list'), _('A compact row each, in aligned columns, as UniFi lists devices and clients.') ],
			[ 'settings', PREVIEWS.settings, _('Settings list'), _('A line each with its facts as chips, as UniFi\'s Settings pages list networks and WiFi.') ],
			[ 'cards', PREVIEWS.cards, _('Device cards'), _('A card each, as UniFi\'s device panel: status, facts and traffic.') ]
		];

		o = s.option(CardValue, 'interfaces', _('Interfaces layout'),
			_('Network › Interfaces: the interfaces and the devices.'));
		designs.forEach((d) => o.card(...d));
		o.default = 'list';
		o.rmempty = false;

		o = s.option(CardValue, 'wireless', _('Wireless layout'),
			_('Network › Wireless: the radios, their networks and the associated stations.'));
		designs.forEach((d) => o.card(...d));
		o.default = 'list';
		o.rmempty = false;

		o = s.option(form.Flag, 'port_manager', _('Port Manager on Interfaces'),
			_('The router\'s ports at the top of Network › Interfaces, whichever layout: each port\'s link, speed, VLANs and traffic.'));
		o.default = o.enabled;
		o.rmempty = false;

		s = m.section(form.NamedSection, 'main', 'core', _('Appearance'));
		s.addremove = false;

		o = s.option(CardValue, 'mediaurlbase', _('Colour scheme'),
			_('The same choice as UniFi, UniFiLight and UniFiDark under System › System › Language and Style.'));
		o.card('/luci-static/unifi', SCHEMES['/luci-static/unifi'], _('Follow system'), _('Light or dark, as the browser prefers, with a button in the top bar to choose.'));
		o.card('/luci-static/unifi-light', SCHEMES['/luci-static/unifi-light'], _('Light'), _('Light for everyone, whatever the browser prefers.'));
		o.card('/luci-static/unifi-dark', SCHEMES['/luci-static/unifi-dark'], _('Dark'), _('Dark for everyone, whatever the browser prefers.'));
		/* With another theme selected no card is checked; leave it be
		 * unless one is chosen. */
		o.remove = () => {};

		return m.render();
	}
});
