'use strict';
'require view';
'require rpc';
'require ui';

// openUF's unhandled-message ledger (luci-app-openuf): every response type,
// command, field and config key the controller sent that openUF did not act
// on. Read from /etc/openuf/unhandled.json through the luci.openuf backend;
// the daemon redacts secrets before it ever writes the file.

const callUnhandled = rpc.declare({
	object: 'luci.openuf',
	method: 'unhandled',
	expect: { '': {} }
});

const CATEGORIES = {
	cmd: _('Command'),
	response: _('Response type'),
	field: _('Response field'),
	mgmt_cfg: _('Management config key'),
	system_cfg: _('System config key')
};

// Controller-supplied text is inserted as text, never as markup: LuCI's E()
// treats a string child as HTML, which turned "sshd.<n>.status" into
// "sshd..status" -- and would render whatever a payload carried.
function T(s) {
	return document.createTextNode(String(s));
}

function when(iso) {
	if (!iso)
		return '-';
	const d = new Date(iso);
	return isNaN(d) ? iso : d.toLocaleString();
}

return view.extend({
	load: function() {
		return L.resolveDefault(callUnhandled(), {});
	},

	render: function(data) {
		const entries = Array.isArray(data.entries) ? data.entries : [];
		const cats = [];
		entries.forEach(function(e) { if (cats.indexOf(e.category) < 0) cats.push(e.category); });
		cats.sort();

		const table = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Kind')),
				E('th', { 'class': 'th' }, _('Name')),
				E('th', { 'class': 'th' }, _('Seen')),
				E('th', { 'class': 'th' }, _('First seen')),
				E('th', { 'class': 'th' }, _('Last seen')),
				E('th', { 'class': 'th' }, _('Last payload'))
			])
		]);

		const rows = entries.map(function(e) {
			const payload = e.payload
				? E('details', {}, [
					E('summary', {}, _('show')),
					E('pre', { 'style': 'white-space:pre-wrap;max-width:48em;margin:.5em 0' }, T(e.payload))
				])
				: E('em', {}, _('none'));
			const tr = E('tr', { 'class': 'tr', 'data-category': e.category }, [
				E('td', { 'class': 'td', 'data-title': _('Kind') }, T(CATEGORIES[e.category] || e.category)),
				E('td', { 'class': 'td', 'data-title': _('Name') }, E('code', {}, T(e.key))),
				E('td', { 'class': 'td', 'data-title': _('Seen') }, T(e.count)),
				E('td', { 'class': 'td', 'data-title': _('First seen') }, T(when(e.first_seen))),
				E('td', { 'class': 'td', 'data-title': _('Last seen') }, T(when(e.last_seen))),
				E('td', { 'class': 'td', 'data-title': _('Last payload') }, payload)
			]);
			table.appendChild(tr);
			return tr;
		});

		if (!entries.length)
			table.appendChild(E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': 6 }, E('em', {}, _('Nothing recorded: openUF has acted on everything the controller sent.')))
			]));

		const filter = E('select', {
			'class': 'cbi-input-select',
			'change': function(ev) {
				const want = ev.target.value;
				rows.forEach(function(tr) {
					tr.style.display = (!want || tr.getAttribute('data-category') === want) ? '' : 'none';
				});
			}
		}, [ E('option', { 'value': '' }, _('All kinds (%d)').format(entries.length)) ].concat(cats.map(function(c) {
			const n = entries.filter(function(e) { return e.category === c; }).length;
			return E('option', { 'value': c }, T('%s (%d)'.format(CATEGORIES[c] || c, n)));
		})));

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Unhandled messages')),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('Everything the controller sent that openUF did not act on: new commands, response types and fields, and config keys no part of openUF reads. Many are deliberate (features an OpenWrt AP does not have); new entries are how new controller behaviour gets noticed.'),
				' ',
				_('Secrets are redacted by field name before anything is written.'),
				data.updated ? T(' ' + _('Last written: %s.').format(when(data.updated))) : ''
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'margin-bottom:.5em' }, [ E('label', {}, [ _('Show') + ': ', filter ]) ]),
				table
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
