'use strict';
'require baseclass';
'require dom';
'require fs';
'require rpc';

/*
 * luci-mod-dashboard as it was before its rework (LuCI of early September
 * 2026 and older, as 24.10 and older 25.12 feeds ship it) shows no system
 * resources: CPU and memory came with the rework (its 12_resources.js, as
 * figures, a chart and a tab). This card gives that dashboard CPU usage,
 * load, memory and storage (the root and tmp filesystems, as Status >
 * Overview shows them), as label/value rows with a bar under each share.
 *
 * The reworked dashboard asks every include whether it is available; this
 * one says no, so the dashboard's own widgets are never doubled. The one
 * before the rework never asks: on each poll it loads every include and
 * appends what render() returns (includes after the first two go into the
 * second section, after the DHCP leases; the stylesheet lifts the card to
 * its top). The card is kept and updated in place, so appending it again
 * moves it rather than adding a second one, however that section is
 * refreshed.
 *
 * CPU usage is the busy share of the time /proc/stat counts between two
 * polls, so the first poll has nothing to show yet. Reading it takes the
 * theme's "luci-theme-openuf-resources" ACL; the rest is system.info, which
 * the dashboard's own ACL grants.
 */

const callSystemInfo = rpc.declare({
	object: 'system',
	method: 'info'
});

const themed = () => /\/luci-static\/openuf(-dark|-light)?\/?$/.test(L.env.media || '');

/* The first eight fields of each cpu line, the total's under "cpu". Guest
 * time is already part of user and nice, so it is left out. */
function cpuTimes(stat) {
	const times = {};

	String(stat || '').split('\n').forEach((line) => {
		const m = line.match(/^(cpu\d*)\s+(\d.*)$/);

		if (m)
			times[m[1]] = m[2].trim().split(/\s+/).slice(0, 8).map(Number);
	});

	return times.cpu ? times : null;
}

/* The share of the time between two samples not spent idle or waiting for
 * I/O, in percent. The iowait counter may step back, hence the clamp. */
function busy(prev, cur) {
	const d = cur.map((v, i) => Math.max(0, v - (prev[i] || 0)));
	const total = d.reduce((sum, v) => sum + v, 0);

	return (total > 0) ? 100 * (total - d[3] - (d[4] || 0)) / total : null;
}

/* "used / total (share)" for a pair of byte counts. */
function share(used, total) {
	return {
		text: '%1024.1mB / %1024.1mB (%d%%)'.format(used, total, Math.round(100 * used / total)),
		percent: 100 * used / total
	};
}

/* A filesystem from system.info, which counts in KiB. */
function disk(mount) {
	return (L.isObject(mount) && mount.total > 0)
		? share((mount.used != null ? mount.used : mount.total - (mount.free || 0)) * 1024, mount.total * 1024) : null;
}

return baseclass.extend({
	title: _('System resources'),

	/* The reworked dashboard shows its own; see above. */
	available() {
		return false;
	},

	load() {
		/* Under another theme there is no card to fill. */
		if (!themed())
			return Promise.resolve(null);

		return Promise.all([
			L.resolveDefault(callSystemInfo(), {}),
			L.resolveDefault(fs.read('/proc/stat'), null)
		]).then(([ info, stat ]) => {
			const cur = cpuTimes(stat);
			const now = Date.now();

			/* LuCI's poll runs once more as soon as the dashboard is drawn,
			 * which would measure little more than drawing it: a sample is
			 * compared with one at least a second older. */
			if (!cur)
				this.cpu = null;
			else if (!this.times || now - this.at >= 1000) {
				this.cpu = this.times ? busy(this.times.cpu, cur.cpu) : null;
				this.times = cur;
				this.at = now;
			}

			return {
				info: L.isObject(info) ? info : {},
				cpu: this.cpu,
				sampled: !!this.times
			};
		});
	},

	/* The card, built once; update() fills it in. */
	build() {
		this.rows = {};

		const row = (id, label, meter) => {
			const value = E('span', { 'class': 'uf-resources-value' });
			const bar = meter ? E('div', {
				'class': 'cbi-progressbar',
				'role': 'progressbar',
				'aria-label': label,
				'aria-valuemin': '0',
				'aria-valuemax': '100'
			}, [ E('div') ]) : null;

			this.rows[id] = { value: value, bar: bar, node: E('div', { 'class': 'uf-resources-row', 'data-row': id }, [
				E('span', { 'class': 'uf-resources-label' }, [ label ]),
				value,
				bar || ''
			]) };

			return this.rows[id].node;
		};

		const group = (id, rows) => E('div', { 'class': 'uf-resources-group', 'data-group': id }, rows);

		return E('div', { 'class': 'dashboard-bg uf-resources-card' }, [
			E('div', { 'class': 'title' }, [ E('h3', {}, [ this.title ]) ]),
			E('div', { 'class': 'uf-resources' }, [
				group('cpu', [
					row('cpu', _('CPU usage'), true),
					row('load', _('Load Average'))
				]),
				group('memory', [
					row('memory', _('Memory'), true),
					row('cache', '%s / %s'.format(_('Buffered'), _('Cached'))),
					row('swap', _('Swap'), true)
				]),
				group('storage', [
					row('root', _('Disk space'), true),
					row('tmp', _('Temp space'), true)
				])
			])
		]);
	},

	/* A row's value (a string or node; null hides the row) and its bar. */
	set(id, value, percent) {
		const r = this.rows[id];

		r.node.hidden = (value == null);

		if (value == null)
			return;

		dom.content(r.value, value);

		if (r.bar) {
			const p = Math.max(0, Math.min(100, percent || 0));

			r.bar.firstChild.style.width = '%.2f%%'.format(p);
			r.bar.setAttribute('aria-valuenow', Math.round(p));
			r.bar.setAttribute('data-level', (p >= 90) ? 'high' : 'normal');
		}
	},

	update(data) {
		const info = data.info;
		const mem = L.isObject(info.memory) ? info.memory : {};
		const swap = L.isObject(info.swap) ? info.swap : {};

		if (data.cpu != null)
			this.set('cpu', '%.1f%%'.format(data.cpu), data.cpu);
		else
			this.set('cpu', data.sampled ? E('em', {}, [ _('Collecting data...') ]) : '-', 0);

		this.set('load', Array.isArray(info.load)
			? info.load.map((v) => '%.2f'.format(v / 65536)).join(', ') : null);

		/* Used is what the kernel could not give back without swapping, as
		 * the reworked dashboard counts it; buffers and cache are apart. */
		if (mem.total > 0) {
			const available = (mem.available != null) ? mem.available : (mem.free || 0) + (mem.buffered || 0) + (mem.cached || 0);
			const used = share(Math.max(0, mem.total - available), mem.total);

			this.set('memory', used.text, used.percent);
			this.set('cache', (mem.buffered != null || mem.cached != null)
				? '%1024.1mB / %1024.1mB'.format(mem.buffered || 0, mem.cached || 0) : null);
		}
		else {
			this.set('memory', '-', 0);
			this.set('cache', null);
		}

		const swapped = (swap.total > 0) ? share(swap.total - (swap.free || 0), swap.total) : null;
		const root = disk(info.root);
		const tmp = disk(info.tmp);

		this.set('swap', swapped && swapped.text, swapped && swapped.percent);
		this.set('root', root && root.text, root && root.percent);
		this.set('tmp', tmp && tmp.text, tmp && tmp.percent);

		/* Storage goes altogether where system.info has no filesystems. */
		this.node.querySelectorAll('.uf-resources-group').forEach((g) => {
			g.hidden = !g.querySelector('.uf-resources-row:not([hidden])');
		});
	},

	render(data) {
		/* The markup is this theme's; under another one it would be bare. */
		if (!data || !themed())
			return null;

		if (!this.node)
			this.node = this.build();

		this.update(data);

		return this.node;
	}
});
