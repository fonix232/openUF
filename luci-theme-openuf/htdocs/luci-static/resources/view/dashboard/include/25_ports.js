'use strict';
'require baseclass';
'require ui';
'require view.openuf-theme.ports as ports';

/*
 * luci-mod-dashboard widgets from luci-theme-openuf: the router's ports as
 * UniFi's port strip, with a short list beside it (a full-width card in the
 * charts row), and the Port Manager list as a detail tab (off by default;
 * Layout adds it). The nodes are kept between polls and patched, so the
 * five-second redraw leaves a hovered port and its details in place.
 */

return baseclass.extend({
	title: _('Ports'),

	widgets: [
		{ id: 'ports', slot: 'charts', title: _('Ports'), order: 30 },
		{ id: 'ports', slot: 'tabs', title: _('Ports'), order: 25, hidden: true }
	],

	/* The markup is this theme's; under another one it would be bare. */
	available() {
		if (!/\/luci-static\/openuf(-dark|-light)?\/?$/.test(L.env.media || ''))
			return false;

		return Promise.all([
			ports.load(),
			L.resolveDefault(ui.menu.load(), null)
		]).then(([ data, menu ]) => {
			const node = menu ? [ 'admin', 'network', 'network' ].reduce((n, k) => (n && n.children) ? n.children[k] : null, menu) : null;

			this.manager = node ? L.url('admin/network/network') : null;

			return data.ports.length > 0;
		});
	},

	load() {
		return ports.load();
	},

	renderCard(data) {
		const fresh = ports.card(ports.render(data, { mode: 'compact' }), {
			title: this.title,
			desc: ports.summary(data),
			actions: this.manager ? [ E('a', { 'class': 'btn cbi-button cbi-button-action', 'href': this.manager }, [ _('Port Manager') ]) ] : null
		});

		return (this.cardNode = ports.patch(this.cardNode, fresh));
	},

	renderTab(data) {
		return (this.tabNode = ports.patch(this.tabNode, ports.render(data, { mode: 'full' })));
	},

	render(data) {
		if (!data || !Array.isArray(data.ports) || !data.ports.length)
			return null;

		return {
			charts: [ { id: 'ports', node: () => this.renderCard(data) } ],
			tabs: [ { id: 'ports', title: this.title, content: () => this.renderTab(data) } ]
		};
	}
});
