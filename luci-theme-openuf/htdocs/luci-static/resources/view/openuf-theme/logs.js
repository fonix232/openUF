'use strict';
'require baseclass';
'require fs';

/*
 * Status > System Log and Kernel Log, a line at a time (pages/_logs.scss).
 *
 * LuCI's views (tools/views.js's LogreadBox for the System Log,
 * status/dmesg.js for the Kernel Log; alike on 25.12 and master) write the
 * whole log into a read-only textarea#syslog, again on every poll and on
 * every change of their filters. This draws each line as a row of its own
 * under the view's filters: the time, the severity as a chip
 * (facility.severity in the System Log), the process and the message, the
 * row tinted for errors and warnings. LuCI's textarea stays where it was,
 * hidden, and keeps all it does: its poll, its filters, its scroll
 * buttons; "Raw" shows it again. The views' own severity and text filters
 * stay the filters, so there are no second ones here.
 *
 * The hook: the views assign textarea.value, which fires no event and
 * changes no DOM. The textarea gets a value property of its own that calls
 * the native setter and then queues a redraw, so nothing runs until LuCI
 * writes and the redraw follows every write. (Polling would compare the
 * whole log every tick; a MutationObserver never sees a value.) Observers
 * still catch a change of the textarea's text and a view drawn afresh.
 *
 * A redraw walks the rows it has against the new lines, keeps the rows
 * whose line is still there, in order, and builds only the lines it has no
 * row for. A poll that adds lines at the end (or at the start, sorted
 * newest first) and drops the oldest touches just those rows; a filter
 * removes or adds rows in place. The rows come in chunks of about CHUNK,
 * each skipping layout while off screen (content-visibility), so that a
 * change restyles and lays out one chunk and not a log of thousands of
 * lines. When the end of the list is in view, it stays in view as lines
 * arrive.
 *
 * The Kernel Log's view reads "dmesg -r" but strips each line's <level>
 * prefix, so the levels come from a read of its own (the view's ACL grants
 * it), taken again only when lines arrive it has not seen.
 *
 * Nothing changes until the log parses: if half its lines are not in the
 * expected form, or anything throws, LuCI's textarea is left as it is.
 * menu-openuf.js calls enhance() on these two views only.
 */

/* Most severe first, numbered as syslog numbers them (0-7). */
const SEVERITIES = [ 'emerg', 'alert', 'crit', 'err', 'warn', 'notice', 'info', 'debug' ];

/* The other names syslog.h gives the same severities. */
const ALIASES = { panic: 'emerg', error: 'err', warning: 'warn' };

/* "[time] facility.severity: tag[pid]: message", as LuCI writes logd's
 * entries, or "time facility.severity tag[pid]: message", as logread
 * prints them (the view's fallback). The time is whatever comes before
 * the first facility.severity. */
const SYSLOG = /^\[?(.+?)\]? ([a-z]+[0-9]?)\.(emerg|panic|alert|crit|err|error|warn|warning|notice|info|debug|unknown):? (.*)$/;
const TAG = /^([^\s:[\]]+(?:\[\d+\])?): (.*)$/;

/* "[ seconds] message", with the "<level>" of dmesg -r should a view keep
 * it. A line without a time continues the one before it. */
const DMESG = /^(?:<(\d+)>)?\[\s*(\d+\.\d+)\] ?(.*)$/;

/* Rows to a chunk; one grown to twice that (rows put in above a row) is
 * split. */
const CHUNK = 100;

const PREF = 'luci-theme-openuf.logs';

function pref(value) {
	try {
		if (value === undefined)
			return window.localStorage.getItem(PREF);
		else if (value === null)
			window.localStorage.removeItem(PREF);
		else
			window.localStorage.setItem(PREF, value);
	}
	catch (e) {
		/* Private mode or storage disabled: the choice lasts this page only. */
	}

	return null;
}

function rank(sev) {
	return sev ? SEVERITIES.indexOf(sev) : -1;
}

/* How many of each length a column holds, for its widest. */
function widen(counts, length, n) {
	const left = (counts.get(length) || 0) + n;

	if (left > 0)
		counts.set(length, left);
	else
		counts.delete(length);
}

function widest(counts) {
	let max = 0;

	for (const length of counts.keys())
		max = Math.max(max, length);

	return max;
}

return baseclass.extend({
	/* path: the view, status/syslog or status/dmesg. */
	enhance(path) {
		const view = document.querySelector('#view');

		if (!view || this.view)
			return;

		this.view = view;
		this.kind = (path == 'status/dmesg') ? 'dmesg' : 'syslog';
		this.levels = new Map();

		/* The textarea arrives with the view's first render; a view drawn
		 * afresh brings a new one. */
		const look = () => {
			if (this.textarea && this.textarea.isConnected)
				return;

			const ta = view.querySelector('#content_syslog > textarea#syslog');

			if (ta && ta !== this.textarea)
				this.attach(ta);
		};

		new MutationObserver(look).observe(view, { childList: true, subtree: true });
		look();
	},

	attach(ta) {
		for (const old of [ this.list, this.tools ])
			if (old)
				old.remove();

		this.textarea = ta;
		this.box = ta.parentNode;
		this.list = this.tools = null;
		this.dead = false;

		try {
			this.template = E('div', { 'class': 'uf-log-row' }, [
				E('span', { 'class': 'uf-log-time' }),
				E('span', { 'class': 'uf-log-sev' }),
				E('span', { 'class': 'uf-log-msg' })
			]);

			const value = ta.value;

			this.list = E('div', { 'class': 'uf-log', 'role': 'log', 'data-kind': this.kind, 'data-empty': _('No log lines') });
			this.reset();
			this.touched = new Set();
			this.append(this.split(value), 0);
			this.settle();

			/* Not a log this can read: LuCI's textarea as it is. */
			if (!this.usable()) {
				this.list = null;
				this.box.removeAttribute('data-uf-logs');
				return;
			}

			this.shown = value;
			this.want = (pref() == 'raw') ? 'raw' : 'list';

			this.list.addEventListener('copy', (ev) => this.copy(ev));
			ta.after(this.list);

			this.tools = this.renderTools();
			this.hook(ta);
			this.measure();
			this.summarise();
			this.setMode(this.want);

			if (this.kind == 'dmesg')
				this.readLevels();
		}
		catch (err) {
			this.fail(err);
		}
	},

	/* The textarea's value property, and its text, for LuCI's writes. */
	hook(ta) {
		const native = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
		let queued = false;

		const queue = () => {
			if (queued || this.dead || this.textarea !== ta)
				return;

			queued = true;
			window.requestAnimationFrame(() => {
				queued = false;
				this.update();
			});
		};

		Object.defineProperty(ta, 'value', {
			configurable: true,
			enumerable: true,
			get() { return native.get.call(this); },
			set(v) {
				native.set.call(this, v);
				queue();
			}
		});

		new MutationObserver(queue).observe(ta, { childList: true, characterData: true, subtree: true });
	},

	renderTools() {
		const scroll = this.box.querySelector(':scope > div > #scrollDownButton');
		const bar = scroll ? scroll.parentNode : E('div', {});

		if (!scroll)
			this.box.insertBefore(bar, this.textarea);

		bar.classList.add('uf-log-bar');

		this.summary = E('span', { 'class': 'uf-log-summary', 'aria-live': 'polite' });
		this.buttons = [ [ 'list', _('List') ], [ 'raw', _('Raw') ] ].map(([ mode, label ]) =>
			E('button', {
				'type': 'button',
				'class': 'cbi-button',
				'data-mode': mode,
				'aria-pressed': 'false',
				'click': () => {
					this.want = mode;
					pref(mode == 'raw' ? 'raw' : null);
					this.setMode(mode);
				}
			}, [ label ]));

		const tools = E('div', { 'class': 'uf-log-tools' }, [
			this.summary,
			E('div', { 'class': 'uf-log-mode', 'role': 'group', 'aria-label': _('Show the log as') }, this.buttons)
		]);

		bar.appendChild(tools);

		return tools;
	},

	/* list, raw, or off (LuCI's textarea, no choice: a log this cannot
	 * read). The stylesheet shows one or the other by this. */
	setMode(mode) {
		if (this.box.getAttribute('data-uf-logs') != mode)
			this.box.setAttribute('data-uf-logs', mode);

		for (const b of this.buttons)
			b.setAttribute('aria-pressed', (b.getAttribute('data-mode') == mode) ? 'true' : 'false');
	},

	fail(err) {
		this.dead = true;
		console.warn('luci-theme-openuf: the log stays as LuCI draws it:', err);

		if (this.box)
			this.box.setAttribute('data-uf-logs', 'off');
	},

	split(value) {
		value = (value == null) ? '' : String(value);

		return value.length ? value.replace(/\n$/, '').split('\n') : [];
	},

	/* Half the lines at least must be in the form expected. */
	usable() {
		return !this.count.total || this.count.parsed * 2 >= this.count.total;
	},

	update() {
		if (this.dead || !this.list)
			return;

		try {
			const value = this.textarea.value;

			if (value === this.shown)
				return;

			this.shown = value;

			/* Newest lines stay in view: if the end of the list shows, it
			 * stays where it is on screen as rows come and go. */
			const before = this.list.getBoundingClientRect();
			const stick = before.height > 0 && before.bottom > 0 && before.bottom <= window.innerHeight + 2;

			this.sync(this.split(value));
			this.measure();
			this.summarise();
			this.setMode(this.usable() ? this.want : 'off');

			if (stick) {
				const moved = this.list.getBoundingClientRect().bottom - before.bottom;

				if (moved > 0)
					window.scrollBy(0, moved);
			}

			if (this.pending.size && this.kind == 'dmesg')
				this.readLevels();
		}
		catch (err) {
			this.fail(err);
		}
	},

	/* No rows, and nothing counted. */
	reset() {
		this.list.textContent = '';
		this.count = { total: 0, parsed: 0, err: 0, warn: 0 };
		this.widths = { time: new Map(), chip: new Map() };
		this.pending = new Set();
	},

	/* The rows to the new lines: keep each row whose line is still there
	 * and in order, drop the others, and build rows only for lines that
	 * have none. */
	sync(lines) {
		if (!lines.length)
			return this.reset();

		/* Where each line is in the new log; a line can repeat. */
		const at = new Map();

		lines.forEach((line, i) => {
			const seen = at.get(line);

			if (seen)
				seen.push(i);
			else
				at.set(line, [ i ]);
		});

		/* The first place a line is at from index j on (j only grows);
		 * take it, or only look. */
		const cursor = new Map();
		const find = (line, j, take) => {
			const seen = at.get(line);

			if (!seen)
				return -1;

			let c = cursor.get(line) || 0;

			while (c < seen.length && seen[c] < j)
				c++;

			cursor.set(line, take ? c + 1 : c);

			return (c < seen.length) ? seen[c] : -1;
		};

		let j = 0;

		this.touched = new Set();

		for (let row = this.first(); row; ) {
			const next = this.next(row);
			const k = find(row.ufLine, j, false);

			/* Kept if found, unless the row after it comes first: then this
			 * one moved, and is built again where it is now. */
			const later = (k > j && next) ? find(next.ufLine, j, false) : -1;

			if (k < 0 || (later >= j && later < k)) {
				this.drop(row);
			}
			else {
				find(row.ufLine, j, true);

				if (k > j) {
					this.touched.add(row.parentNode);
					row.parentNode.insertBefore(this.build(lines, j, k), row);
				}

				j = k + 1;
			}

			row = next;
		}

		this.append(lines, j);
		this.settle();
	},

	first() {
		const chunk = this.list.firstElementChild;

		return chunk ? chunk.firstElementChild : null;
	},

	next(row) {
		const chunk = row.parentNode.nextElementSibling;

		return row.nextElementSibling || (chunk ? chunk.firstElementChild : null);
	},

	previous(row) {
		const chunk = row.parentNode.previousElementSibling;

		return row.previousElementSibling || (chunk ? chunk.lastElementChild : null);
	},

	chunk() {
		return E('div', { 'class': 'uf-log-chunk' });
	},

	/* lines[from...] after the last row: the last chunk filled up, then
	 * new ones. */
	append(lines, from) {
		let chunk = this.list.lastElementChild;

		for (let i = from; i < lines.length; ) {
			const fresh = !chunk || chunk.childElementCount >= CHUNK;

			if (fresh)
				chunk = this.chunk();

			const to = Math.min(lines.length, i + CHUNK - chunk.childElementCount);

			chunk.appendChild(this.build(lines, i, to));
			this.touched.add(chunk);

			if (fresh)
				this.list.appendChild(chunk);

			i = to;
		}
	},

	/* Chunks that rows went into or out of: split one grown too long, and
	 * tell the stylesheet how many rows each holds, for its height while
	 * it is off screen. */
	settle() {
		for (let chunk of this.touched) {
			if (!chunk.parentNode)
				continue;

			if (chunk.childElementCount > 2 * CHUNK) {
				const rows = [ ...chunk.children ];

				for (let i = CHUNK; i < rows.length; i += CHUNK) {
					const next = this.chunk();

					next.append(...rows.slice(i, i + CHUNK));
					next.style.setProperty('--uf-log-rows', next.childElementCount);
					chunk.after(next);
					chunk = next;
				}

				chunk = rows[0].parentNode;
			}

			chunk.style.setProperty('--uf-log-rows', chunk.childElementCount);
		}

		this.touched.clear();
	},

	build(lines, from, to) {
		const frag = document.createDocumentFragment();

		for (let i = from; i < to; i++)
			frag.appendChild(this.row(lines[i]));

		return frag;
	},

	row(line) {
		const row = this.template.cloneNode(true);
		const [ time, chip, msg ] = row.children;
		const p = (this.kind == 'dmesg') ? this.parseDmesg(line) : this.parseSyslog(line);

		row.ufLine = line;
		row.ufParsed = !!(p && !p.cont);

		if (!p) {
			row.classList.add('uf-log-raw');
			msg.textContent = line;
		}
		else {
			time.textContent = p.time || '';
			msg.textContent = p.msg;

			if (p.tag)
				msg.prepend(E('span', { 'class': 'uf-log-tag' }, [ p.tag ]), ' ');

			if (p.cont)
				row.classList.add('uf-log-cont');

			if (this.kind == 'syslog') {
				chip.textContent = p.chip;
				this.setSeverity(row, p.sev);
			}
			else if (p.sev) {
				this.setSeverity(row, p.sev);
			}
			else if (this.levels.has(line)) {
				this.setSeverity(row, SEVERITIES[this.levels.get(line)]);
			}
			else {
				this.pending.add(row);
			}
		}

		this.tally(row, 1);

		return row;
	},

	/* A row's severity, and the Kernel Log's chip, which names it (a
	 * continued line carries the level of the line it continues, without
	 * the chip). */
	setSeverity(row, sev) {
		row.ufSev = sev || null;

		if (sev)
			row.setAttribute('data-sev', sev);

		if (this.kind == 'dmesg' && sev && !row.classList.contains('uf-log-cont'))
			row.children[1].textContent = sev;
	},

	drop(row) {
		const chunk = row.parentNode;

		this.tally(row, -1);
		this.pending.delete(row);
		row.remove();
		this.touched.add(chunk);

		if (!chunk.firstElementChild)
			chunk.remove();
	},

	/* Counts (lines, parsed lines, errors, warnings) and column widths. */
	tally(row, n) {
		const r = rank(row.ufSev);

		this.count.total += n;

		if (row.ufParsed)
			this.count.parsed += n;

		widen(this.widths.time, row.children[0].textContent.length, n);
		widen(this.widths.chip, row.children[1].textContent.length, n);

		if (row.classList.contains('uf-log-cont'))
			return;

		if (r >= 0 && r <= 3)
			this.count.err += n;
		else if (r == 4)
			this.count.warn += n;
	},

	parseSyslog(line) {
		const m = SYSLOG.exec(line);

		if (!m)
			return null;

		const t = TAG.exec(m[4]);

		return {
			time: m[1],
			chip: `${m[2]}.${m[3]}`,
			sev: ALIASES[m[3]] || (SEVERITIES.indexOf(m[3]) > -1 ? m[3] : null),
			tag: t ? t[1] : null,
			/* logd keeps an empty tag as a leading ": ". */
			msg: t ? t[2] : m[4].replace(/^: ?/, '')
		};
	},

	parseDmesg(line) {
		const m = DMESG.exec(line);

		if (!m)
			return { cont: true, msg: line };

		return {
			time: m[2],
			sev: (m[1] != null) ? SEVERITIES[(+m[1]) & 7] : null,
			msg: m[3]
		};
	},

	/* The time and chip columns, as wide as their longest entries, so the
	 * messages line up (the times are monospaced; a chip's "ch" is its own
	 * font's). */
	measure() {
		const set = (name, value) => {
			if (this.list.style.getPropertyValue(name) != value)
				this.list.style.setProperty(name, value);
		};

		set('--uf-log-time', `${widest(this.widths.time)}ch`);
		set('--uf-log-sev', `${widest(this.widths.chip)}ch`);
	},

	summarise() {
		const c = this.count;
		const parts = [ E('span', {}, [ N_(c.total, '%d line', '%d lines').format(c.total) ]) ];

		if (c.err)
			parts.push(E('span', { 'data-sev': 'err' }, [ N_(c.err, '%d error', '%d errors').format(c.err) ]));

		if (c.warn)
			parts.push(E('span', { 'data-sev': 'warn' }, [ N_(c.warn, '%d warning', '%d warnings').format(c.warn) ]));

		this.summary.replaceChildren(...parts);
	},

	/* The Kernel Log's levels, from dmesg -r: the line as the view shows
	 * it (without its "<level>") to its level. Rows that were waiting for
	 * one when a read began and still have none keep none. */
	readLevels() {
		if (this.reading || this.noLevels)
			return;

		const asked = [ ...this.pending ].filter((row) => !row.ufAsked);

		if (!asked.length)
			return;

		this.reading = true;

		fs.exec_direct('/bin/dmesg', [ '-r' ]).then((raw) => {
			const levels = new Map();
			let level = null;

			for (const line of String(raw).split('\n')) {
				const m = /^<(\w+)>/.exec(line);

				if (!m)
					continue;

				if (m[1] != 'c') {
					const n = parseInt(m[1], 10);
					level = isNaN(n) ? null : (n & 7);
				}

				if (level != null)
					levels.set(line.slice(m[0].length), level);
			}

			this.levels = levels;
		}).catch(() => {
			/* No levels (no access, say): the rows stay neutral. */
			this.noLevels = true;
		}).finally(() => {
			this.reading = false;

			if (this.dead || !this.list)
				return;

			try {
				for (const row of asked)
					row.ufAsked = true;

				for (const row of this.pending) {
					if (this.levels.has(row.ufLine)) {
						this.tally(row, -1);
						this.setSeverity(row, SEVERITIES[this.levels.get(row.ufLine)]);
						this.tally(row, 1);
						this.pending.delete(row);
					}
				}

				this.measure();
				this.summarise();
				this.readLevels();
			}
			catch (err) {
				this.fail(err);
			}
		});
	},

	/* Across rows, the lines as the log has them, not the columns one per
	 * line as a copy of the grid would give. Within a column the browser's
	 * own copy stands. */
	copy(ev) {
		const sel = window.getSelection();

		if (!ev.clipboardData || !sel || sel.isCollapsed || !sel.rangeCount)
			return;

		const range = sel.getRangeAt(0);
		const cell = (node) => {
			const el = (node.nodeType == 1) ? node : node.parentElement;
			const found = el ? el.closest('.uf-log-row > span') : null;

			return (found && this.list.contains(found)) ? found : null;
		};

		const start = cell(range.startContainer);
		const end = cell(range.endContainer);

		if (!start || !end || start === end)
			return;

		const first = start.parentNode;
		let last = end.parentNode;

		/* A selection that ends at the very start of a row leaves it out. */
		const edge = document.createRange();

		edge.setStart(last, 0);
		edge.setEnd(range.endContainer, range.endOffset);

		if (!edge.toString() && last !== first)
			last = this.previous(last);

		const lines = [];

		for (let row = first; row; row = this.next(row)) {
			lines.push(row.ufLine);

			if (row === last)
				break;
		}

		ev.clipboardData.setData('text/plain', lines.join('\n'));
		ev.preventDefault();
	}
});
