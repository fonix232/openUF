'use strict';

/*
 * Drive LuCI with luci-theme-openuf installed, as run.sh sets it up:
 *
 *   node smoke.cjs BASE_URL PASSWORD OUT_DIR
 *
 * Signs in, walks every page the menu offers, and fails on a script error,
 * a failed theme or LuCI asset, a page that never finishes loading, or a
 * layout wider than the window. It checks the System and Kernel Log are
 * drawn a row per line, then switches the Interfaces and Wireless designs
 * on System > openUF Theme and checks both pages in each. Screenshots of
 * the main views, in light, dark and phone layouts, are written to OUT_DIR.
 */

const { chromium } = require('playwright');
const path = require('path');

const [ base, password, out ] = process.argv.slice(2);

if (!base || !password || !out) {
	console.error('usage: node smoke.cjs BASE_URL PASSWORD OUT_DIR');
	process.exit(2);
}

const failures = [];
const fail = (msg) => { failures.push(msg); console.log(`  FAIL ${msg}`); };

/* Pages worth a picture; everything in the menu is still visited. */
const SHOTS = {
	'admin/dashboard': 'dashboard',
	'admin/status/overview': 'overview',
	'admin/system/system': 'system',
	'admin/network/network': 'interfaces',
	'admin/network/wireless': 'wireless',
	'admin/network/firewall': 'firewall',
	'admin/network/dhcp': 'dhcp',
	'admin/system/package-manager': 'software',
	'admin/status/processes': 'processes',
	'admin/status/logs/syslog': 'syslog',
	'admin/status/logs/dmesg': 'dmesg',
	'admin/system/openuf-theme': 'theme-settings'
};

/* The logs, drawn a row per line (logs.js); run.sh writes lines of every
 * severity to both (add-logs.sh). */
const LOGS = [ 'admin/status/logs/syslog', 'admin/status/logs/dmesg' ];

function watch(page) {
	page.on('pageerror', async (err) => {
		/* LuCI 25.12's own sign-in page probes uci/get with the anonymous
		 * session and throws on the refusal, under bootstrap as much as here. */
		if (/uci\/get failed with error -32002/.test(err.message) && !await page.locator('#mainmenu').count())
			return;

		fail(`${page.url()}: script error: ${err.message}`);
	});
	page.on('response', (res) => {
		const url = new URL(res.url());

		/* The sign-in page is a 403 by design; everything static must load. */
		if (res.status() >= 400 && url.pathname.startsWith('/luci-static/'))
			fail(`${url.pathname}: HTTP ${res.status()}`);
	});

	/* "XHR request timed out" names no call: name the slow and failed ones. */
	page.on('requestfinished', (req) => {
		const took = req.timing().responseEnd;

		if (isRpc(req) && took > 5000)
			console.log(`  slow rpc ${rpcNames(req)}: ${Math.round(took)} ms`);
	});
	page.on('requestfailed', (req) => {
		if (isRpc(req))
			console.log(`  rpc ${rpcNames(req)} failed: ${req.failure()?.errorText}`);
	});
}

const isRpc = (req) => new URL(req.url()).pathname.startsWith('/ubus');

/* LuCI batches JSON-RPC calls: [ sid, object, method, args ] each. */
function rpcNames(req) {
	try {
		return [].concat(JSON.parse(req.postData() || '[]'))
			.map((c) => (Array.isArray(c.params) ? `${c.params[1]}.${c.params[2]}` : c.method)).join(', ');
	}
	catch (e) {
		return req.url();
	}
}

async function settle(page) {
	await page.waitForLoadState('networkidle', { timeout: 20000 }).catch(() => {});

	/* Attended Sysupgrade asks once whether it may check online; say no. */
	const nag = page.locator('.modal .btn, .modal button', { hasText: 'No, disable checking' });

	if (await nag.count()) {
		await nag.click();
		await page.waitForLoadState('networkidle', { timeout: 20000 }).catch(() => {});
	}

	/* A LuCI view shows "Loading view..." until its promises resolve. */
	const loaded = await page.waitForFunction(() => {
		const view = document.querySelector('#view');

		return !view || !view.querySelector(':scope > .spinning');
	}, null, { timeout: 20000 }).then(() => true, () => false);

	if (!loaded)
		fail(`${page.url()}: view never finished loading`);

	await page.waitForTimeout(300);
}

/* Every page the rail leads to, from LuCI's own menu: each category of the
 * signed-in mode and each of its pages. */
function menuPages(page) {
	return page.evaluate(() => L.require('ui').then((ui) => ui.menu.load().then((tree) => {
		const mode = ui.menu.getChildren(tree).find((node) => node.name == L.env.dispatchpath[0]);
		const urls = [];

		for (const category of ui.menu.getChildren(mode)) {
			urls.push(L.url(mode.name, category.name));

			for (const child of ui.menu.getChildren(category))
				urls.push(L.url(mode.name, category.name, child.name));
		}

		return [ ...new Set(urls.map((url) => new URL(url, location.href).pathname)) ];
	})));
}

async function checkWidth(page, label) {
	const over = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);

	if (over > 1)
		fail(`${page.url()} (${label}): content is ${over}px wider than the window`);
}

async function shot(page, name) {
	await page.screenshot({ path: path.join(out, `${name}.png`) });
}

/* The port panel, against the lab's ports (run.sh, add-ports.sh): five
 * squares, lan1-lan4 and wan, some with link and some without. The Status
 * overview's own Port status card shows the same five. */
const PORTS = 5;

async function checkPorts(page, route) {
	await page.goto(`${base}/cgi-bin/luci/${route}`);
	await settle(page);

	if (route == 'admin/status/overview') {
		const tiles = await page.locator('.ifacebox img[src*="/port_"]').count();

		if (tiles != PORTS)
			fail(`${route}: Port status shows ${tiles} ports, not ${PORTS}`);

		return;
	}

	await page.waitForSelector('.uf-ports-card .uf-port', { timeout: 10000 }).catch(() => {});

	const seen = await page.evaluate(() => {
		const count = (sel) => document.querySelectorAll(sel).length;

		return {
			cards: count('.uf-ports-card'),
			squares: count('.uf-ports-card .uf-port'),
			rows: count('.uf-ports-card .uf-ports-list tr[data-port]'),
			linked: count('.uf-ports-card .uf-port:is([data-state="fe"], [data-state="gbe"], [data-state="mgig"], [data-state="up"])'),
			unlinked: count('.uf-ports-card .uf-port:is([data-state="down"], [data-state="disabled"])')
		};
	});

	if (seen.cards != 1)
		fail(`${route}: ${seen.cards} Ports cards, not one`);
	else if (route == 'admin/network/network' && seen.rows != PORTS)
		fail(`${route}: the Port Manager lists ${seen.rows} ports, not ${PORTS}`);
	else if (seen.squares != PORTS)
		fail(`${route}: the Ports card shows ${seen.squares} ports, not ${PORTS}`);
	else if (!seen.linked || !seen.unlinked)
		fail(`${route}: the Ports card shows ${seen.linked} ports with link and ${seen.unlinked} without; expected some of each`);
	else
		console.log(`  ok   ports on ${route}: ${seen.linked} linked, ${seen.unlinked} not`);
}

/* The rail's power button: its menu opens on a click (never on hover),
 * inside the window, and closes on Escape and on a click elsewhere.
 * Nothing in it is carried out, so the lab stays up; with `dialog`, Reboot's
 * confirmation is opened and cancelled. */
async function checkPower(page, label, dialog) {
	const button = '#mainmenu .uf-power > button';
	const menu = '#mainmenu .uf-power-menu';
	const state = () => page.evaluate(([ b, m ]) => {
		const r = document.querySelector(m).getBoundingClientRect();

		const expanded = document.querySelector(b).getAttribute('aria-expanded') == 'true';
		const visible = getComputedStyle(document.querySelector(m)).visibility == 'visible';

		return {
			open: expanded && visible,
			shown: expanded || visible,
			items: [ ...document.querySelectorAll(`${m} [role="menuitem"]`) ].filter((el) => !el.hidden).map((el) => el.textContent),
			inside: r.left >= 0 && r.top >= 0 && r.right <= window.innerWidth && r.bottom <= window.innerHeight
		};
	}, [ button, menu ]);

	if (!await page.locator(button).count())
		return fail(`${label}: the rail has no power button`);

	if (await page.locator('#mainmenu [data-name="logout"]').count())
		fail(`${label}: Log out is still in the rail`);

	await page.hover(button);
	await page.waitForTimeout(400);

	if ((await state()).shown)
		fail(`${label}: hovering the power button opened its menu`);

	await page.click(button);
	await page.waitForTimeout(400);

	const open = await state();

	if (!open.open)
		fail(`${label}: clicking the power button did not open its menu`);
	else if (!open.inside)
		fail(`${label}: the power menu leaves the window`);
	else if (open.items[0] != 'Reboot…' || open.items.indexOf('Backup / flash firmware…') < 0)
		fail(`${label}: the power menu offers ${JSON.stringify(open.items)}`);
	else
		console.log(`  ok   power menu (${label}): ${open.items.join(', ')}`);

	await shot(page, `power-menu-${label}`);

	/* Escape closes the menu alone, not the drawer around it. */
	const drawer = () => page.evaluate(() => document.documentElement.classList.contains('uf-nav-open'));
	const drawerOpen = await drawer();

	await page.keyboard.press('Escape');
	await page.waitForTimeout(300);

	if ((await state()).shown)
		fail(`${label}: Escape did not close the power menu`);
	else if (await drawer() != drawerOpen)
		fail(`${label}: Escape on the power menu also closed the drawer`);

	await page.click(button);
	await page.waitForTimeout(300);
	await page.mouse.click(page.viewportSize().width - 20, page.viewportSize().height - 20);
	await page.waitForTimeout(300);

	if ((await state()).shown)
		fail(`${label}: a click elsewhere did not close the power menu`);

	if (!dialog)
		return open.items;

	await page.click(button);
	await page.waitForTimeout(300);
	await page.click(`${menu} [role="menuitem"]:has-text("Reboot")`);
	await page.waitForSelector('.modal .cbi-button-action:has-text("Perform reboot")', { timeout: 10000 })
		.catch(() => fail(`${label}: Reboot… opened no confirmation`));
	await page.waitForTimeout(400);
	await shot(page, `reboot-dialog-${label}`);
	await page.keyboard.press('Escape');
	await page.waitForTimeout(400);

	if (await page.locator('body.modal-overlay-active').count())
		fail(`${label}: Escape did not cancel the reboot confirmation`);

	return open.items;
}

/* System resources on the dashboard. The reworked one has its own (CPU and
 * memory figures, the System load chart, the Resources tab), which the
 * theme's Ports widgets must leave in place; the one before the rework has
 * none, and gets the theme's card (include/21_openuf_resources.js) once,
 * with a CPU figure after a poll. */
async function checkResources(page) {
	await page.goto(`${base}/cgi-bin/luci/admin/dashboard`);
	await settle(page);

	/* CPU usage takes two samples, a poll apart. */
	await page.waitForTimeout(6500);

	const seen = await page.evaluate(() => {
		const all = (sel) => [ ...document.querySelectorAll(sel) ];
		const value = (row) => document.querySelector(`.uf-resources-row[data-row="${row}"]:not([hidden]) .uf-resources-value`)?.textContent ?? null;

		return {
			classic: !!document.querySelector('#view > .Dashboard > .section-content'),
			cards: all('.uf-resources-card').length,
			shown: all('.uf-resources-card').filter((n) => n.offsetParent).length,
			cpu: value('cpu'),
			memory: value('memory'),
			disk: value('root'),
			figures: [ 'cpu', 'memory' ].filter((k) => document.querySelector(`.dashboard-kpi-icon[style*="/${k}.svg"]`)),
			chart: all('.dashboard-charts > .cbi-section > h3').some((h) => h.textContent == 'System load'),
			tab: !!document.querySelector('.cbi-tabmenu > li[data-tab="resources"]')
		};
	});

	if (seen.classic) {
		if (seen.cards != 1 || seen.shown != 1)
			fail(`admin/dashboard: ${seen.cards} System resources cards (${seen.shown} shown), not one`);
		else if (!/%$/.test(seen.cpu || '') || !seen.memory || !seen.disk)
			fail(`admin/dashboard: System resources shows CPU "${seen.cpu}", memory "${seen.memory}", disk "${seen.disk}"`);
		else
			console.log(`  ok   System resources card: CPU ${seen.cpu}, memory ${seen.memory}, disk ${seen.disk}`);
	}
	else if (seen.cards)
		fail(`admin/dashboard: the theme's System resources card shows on the reworked dashboard`);
	else if (seen.figures.length != 2 || !seen.chart || !seen.tab)
		fail(`admin/dashboard: the dashboard's resources are incomplete: figures ${JSON.stringify(seen.figures)}, System load chart ${seen.chart}, Resources tab ${seen.tab}`);
	else
		console.log('  ok   the dashboard\'s own resources: CPU and memory figures, System load, Resources tab');
}

/* A log as rows over LuCI's hidden textarea: a row per line of it, in its
 * order, severities on the rows (the System Log's lab lines include errors
 * and warnings), and "Raw" bringing the textarea back. */
async function checkLogs(page, route, label) {
	await page.goto(`${base}/cgi-bin/luci/${route}`);
	await settle(page);

	const drawn = await page.waitForFunction(() =>
		document.querySelector('#content_syslog[data-uf-logs="list"] .uf-log-row[data-sev]'),
	null, { timeout: 15000 }).then(() => true, () => false);

	if (!drawn)
		return fail(`${route} (${label}): the log is not drawn a row per line`);

	/* A poll may land between the textarea and the rows: a frame later
	 * they agree. */
	const seen = await page.evaluate(async () => {
		let out;

		for (let i = 0; i < 3; i++) {
			await new Promise((r) => window.requestAnimationFrame(() => window.setTimeout(r, 0)));

			const ta = document.querySelector('#syslog');
			const rows = [ ...document.querySelectorAll('.uf-log-row') ];
			const sevs = new Set(rows.map((r) => r.getAttribute('data-sev')));

			out = {
				rows: rows.length,
				lines: ta.value ? ta.value.split('\n').length : 0,
				same: rows.map((r) => r.ufLine).join('\n') === ta.value,
				hidden: window.getComputedStyle(ta).display == 'none',
				errors: [ 'emerg', 'alert', 'crit', 'err' ].some((s) => sevs.has(s)),
				warnings: sevs.has('warn')
			};

			if (out.same)
				break;
		}

		return out;
	});

	if (!seen.same || !seen.hidden)
		fail(`${route} (${label}): ${seen.rows} rows for ${seen.lines} lines${seen.same ? '' : ', not the same'}${seen.hidden ? '' : ', the textarea still shows'}`);
	else if (route.endsWith('/syslog') && (!seen.errors || !seen.warnings))
		fail(`${route} (${label}): no ${seen.errors ? 'warnings' : 'errors'} among the rows`);
	else
		console.log(`  ok   ${route} as ${seen.rows} rows (${label})`);

	await page.click('.uf-log-mode [data-mode="raw"]');

	const raw = await page.evaluate(() => window.getComputedStyle(document.querySelector('#syslog')).display != 'none' &&
		window.getComputedStyle(document.querySelector('.uf-log')).display == 'none');

	if (!raw)
		fail(`${route} (${label}): Raw does not bring LuCI's textarea back`);

	await page.click('.uf-log-mode [data-mode="list"]');
}

/* Network > Switch/VLAN config is the theme's copy of LuCI's page
 * (view/openuf-theme/switch-vlan.js): br-lan's switch ports as tiles, and its
 * wireless member (wl0-ap0, add-ports.sh) named and left out, where LuCI's own
 * page refuses a bridge with a wireless member in it. */
const BRIDGE_PORTS = [ 'lan1', 'lan2', 'lan3', 'lan4' ];

async function checkSwitchVlan(page) {
	const route = 'admin/network/switch-vlan';

	await page.goto(`${base}/cgi-bin/luci/${route}`);
	await settle(page);

	/* The page asks to be taken as experimental on every visit. */
	const agree = page.locator('.modal button', { hasText: 'I understand, continue' });

	if (await agree.count())
		await agree.first().click();

	const seen = await page.evaluate(() => ({
		ours: document.querySelector('link[href*="view/openuf-theme/switch-vlan.css"]') != null,
		blockers: [ ...document.querySelectorAll('#view .alert-message h4') ].map((n) => n.textContent.trim()),
		ports: [ ...document.querySelectorAll('.svc-port-tile .svc-port-name') ].map((n) => n.textContent.trim()),
		notes: [ ...document.querySelectorAll('#switch-vlan-view > .cbi-section-descr') ].map((n) => n.textContent).join(' ')
	}));

	if (seen.blockers.length)
		fail(`${route}: ${seen.blockers.join('; ')}`);
	else if (!seen.ours)
		fail(`${route}: LuCI's own page, not the theme's`);
	else if (seen.ports.join(' ') != BRIDGE_PORTS.join(' '))
		fail(`${route}: ports ${seen.ports.join(' ') || 'none'}, not ${BRIDGE_PORTS.join(' ')}`);
	else if (!/\bwl0-ap0\b/.test(seen.notes))
		fail(`${route}: the wireless member wl0-ap0 is not named`);
	else
		console.log(`  ok   ${route}: ports ${seen.ports.join(' ')}, wl0-ap0 left to its wireless network`);

	await shot(page, 'switch-vlan-light');
}

/* The designs (System > openUF Theme, luci.openuf_theme): each comes round on
 * Interfaces and on Wireless, with another one on the other page, so a
 * stylesheet or script leaking between pages or designs shows; the Port
 * Manager is switched off once. The run ends on the defaults. */
const DESIGNS = [
	{ interfaces: 'settings', wireless: 'cards', ports: '1' },
	{ interfaces: 'cards', wireless: 'list', ports: '1' },
	{ interfaces: 'list', wireless: 'settings', ports: '0' },
	{ interfaces: 'list', wireless: 'list', ports: '1' }
];

const DESIGNED = { interfaces: 'admin/network/network', wireless: 'admin/network/wireless' };

/* Choose on the settings page and Save & Apply, which reloads it; the page
 * then carries the saved choice on <html>, as every page does. */
async function saveDesigns(page, want) {
	await page.goto(`${base}/cgi-bin/luci/admin/system/openuf-theme`);
	await settle(page);

	for (const key of [ 'interfaces', 'wireless' ])
		await page.click(`.cbi-value[data-name="${key}"] .cbi-radio:has(> input[value="${want[key]}"]) .uf-choice-title`);

	const flag = page.locator('.cbi-value[data-name="port_manager"] input[type="checkbox"]');

	if (await flag.isChecked() != (want.ports == '1'))
		await flag.click();

	const have = await page.evaluate(() => [ 'interfaces', 'wireless', 'port-manager' ].map((k) => document.documentElement.getAttribute(`data-uf-${k}`)).join(' '));

	if (have != `${want.interfaces} ${want.wireless} ${want.ports}`)
		await Promise.all([
			page.waitForNavigation({ timeout: 60000 }).catch(() => fail('Save & Apply on the theme settings did not reload the page')),
			page.click('.cbi-page-actions .cbi-dropdown.cbi-button-apply', { position: { x: 24, y: 16 } })
		]);

	await settle(page);

	const saved = await page.evaluate(() => [ 'interfaces', 'wireless', 'port-manager' ].map((k) => document.documentElement.getAttribute(`data-uf-${k}`)).join(' '));

	if (saved != `${want.interfaces} ${want.wireless} ${want.ports}`)
		fail(`theme settings: saved "${saved}", not "${want.interfaces} ${want.wireless} ${want.ports}"`);
	else
		console.log(`  ok   theme settings saved: interfaces ${want.interfaces}, wireless ${want.wireless}, port manager ${want.ports}`);
}

/* A designed page: its design's stylesheet, and only that one, loaded; its
 * script's marks on LuCI's rows; nothing wider than the window. */
async function checkDesign(page, key, design, label) {
	const route = DESIGNED[key];

	await page.goto(`${base}/cgi-bin/luci/${route}`);
	await settle(page);
	await checkWidth(page, `${label}, ${key} ${design}`);

	const seen = await page.evaluate(([ key, design ]) => {
		const sheets = [ ...document.querySelectorAll('link[rel="stylesheet"]') ].filter((l) => /\/network\/[a-z]+-[a-z]+\.css$/.test(l.getAttribute('href')));
		const own = sheets.find((l) => l.getAttribute('href').endsWith(`/network/${key}-${design}.css`));
		let rules = 0;

		try { rules = own?.sheet?.cssRules.length ?? 0; } catch (e) {}

		return {
			sheets: sheets.map((l) => l.getAttribute('href').replace(/.*\//, '')),
			rules: rules,
			marked: !!document.querySelector('#view :is([data-uf-key], [data-uf-state], [data-uf-kind], [data-uf-row], [data-uf-before])')
		};
	}, [ key, design ]);

	if (seen.sheets.length != 1 || !seen.rules)
		fail(`${route} (${label}): design stylesheets ${JSON.stringify(seen.sheets)}, ${seen.rules} rules; expected ${key}-${design}.css alone`);
	else if (!seen.marked)
		fail(`${route} (${label}): the ${design} design's script marked none of LuCI's rows`);
	else
		console.log(`  ok   ${route} as ${design} (${label})`);
}

async function signIn(page) {
	await page.goto(`${base}/cgi-bin/luci/`);

	if (!await page.locator('.uf-login-card').count())
		fail('sign-in page is not the theme\'s');

	await page.fill('#luci_password', password);
	await Promise.all([ page.waitForNavigation(), page.click('.uf-login-submit') ]);
	await settle(page);

	if (!await page.locator('#mainmenu .uf-rail-item').count())
		fail('signed in, but the rail has no menu');
}

(async () => {
	const browser = await chromium.launch();

	/* Desktop, light scheme */
	const desktop = await browser.newContext({ viewport: { width: 1440, height: 900 }, colorScheme: 'light' });
	let page = await desktop.newPage();
	watch(page);

	await page.goto(`${base}/cgi-bin/luci/`);
	await shot(page, 'login-light');

	await page.fill('#luci_password', 'wrong');
	await Promise.all([ page.waitForNavigation(), page.click('.uf-login-submit') ]);
	if (!await page.locator('.uf-login .alert-message').count())
		fail('a wrong password shows no error');

	await signIn(page);

	const pages = await menuPages(page);

	console.log(`visiting ${pages.length} menu pages`);

	for (const p of pages) {
		const route = p.replace(/^\/cgi-bin\/luci\/?/, '');

		if (route == 'admin/logout')
			continue;

		await page.goto(`${base}${p}`);
		await settle(page);
		await checkWidth(page, 'desktop');

		const title = await page.title();
		console.log(`  ok   ${route}  (${title})`);

		if (SHOTS[route])
			await shot(page, `${SHOTS[route]}-light`);
	}

	if (pages.includes('/cgi-bin/luci/admin/dashboard'))
		await checkResources(page);

	/* run.sh sets UF_PORTS=1 once the lab has its ports. */
	if (process.env.UF_PORTS == '1') {
		for (const route of [ 'admin/network/network', 'admin/dashboard', 'admin/status/overview' ])
			await checkPorts(page, route);

		await page.goto(`${base}/cgi-bin/luci/admin/network/network`);
		await settle(page);
		await shot(page, 'ports-light');

		await checkSwitchVlan(page);
	}

	for (const route of LOGS)
		await checkLogs(page, route, 'desktop');

	/* Each design, on each page, wide and on a phone. */
	const phoneCheck = await browser.newContext({ viewport: { width: 390, height: 844 }, colorScheme: 'light', isMobile: true, hasTouch: true });
	const phonePage = await phoneCheck.newPage();
	watch(phonePage);
	await signIn(phonePage);

	for (const want of DESIGNS) {
		await saveDesigns(page, want);

		for (const key of [ 'interfaces', 'wireless' ]) {
			await checkDesign(page, key, want[key], 'desktop');
			await shot(page, `${key}-${want[key]}-light`);

			if (key == 'interfaces' && process.env.UF_PORTS == '1') {
				if (want.ports == '1')
					await checkPorts(page, DESIGNED.interfaces);
				else if (await page.locator('.uf-ports-card').count())
					fail(`${DESIGNED.interfaces}: the Port Manager shows though it is switched off`);
			}

			await checkDesign(phonePage, key, want[key], 'phone');
			await shot(phonePage, `${key}-${want[key]}-phone`);
		}
	}

	await phoneCheck.close();

	/* Unsaved changes: the top-bar chip and the changes dialog. */
	await page.goto(`${base}/cgi-bin/luci/admin/system/system`);
	await settle(page);
	await page.fill('input[id$=".hostname"]', 'openuf-test-host');
	await page.click('.cbi-page-actions .cbi-button-save');
	await page.waitForSelector('[data-indicator="uci-changes"]', { timeout: 10000 })
		.catch(() => fail('saving a change raised no "unsaved changes" indicator'));
	await page.waitForTimeout(500);
	await shot(page, 'unsaved-light');
	await page.click('[data-indicator="uci-changes"]').catch(() => {});
	await page.waitForSelector('.modal.uci-dialog', { timeout: 10000 })
		.catch(() => fail('the changes dialog did not open'));
	await page.waitForTimeout(400);
	await shot(page, 'changes-dialog-light');
	await Promise.all([
		page.waitForNavigation({ timeout: 30000 }).catch(() => fail('reverting the changes did not reload the page')),
		page.click('.modal.uci-dialog .cbi-button-reset')
	]);
	await settle(page);

	/* Hovering a rail icon opens nothing beside it (there are no flyouts):
	 * what lies just right of the rail is the page's own column. */
	await page.goto(`${base}/cgi-bin/luci/admin/status/overview`);
	await settle(page);
	await page.hover('#mainmenu .uf-rail-item[data-name="network"] > a');
	await page.waitForTimeout(400);

	const beside = await page.evaluate(() => {
		const rail = document.querySelector('#mainmenu').getBoundingClientRect();
		const icon = document.querySelector('#mainmenu .uf-rail-item[data-name="network"] > a').getBoundingClientRect();
		const el = document.elementFromPoint(rail.right + 40, icon.top + icon.height / 2);

		return el && !el.closest('#submenu, #maincontent') ? (el.className || el.tagName) : null;
	});

	if (beside)
		fail(`hovering a rail icon shows "${beside}" beside the rail`);

	await shot(page, 'rail-hover-light');

	/* The power menu offers a factory reset exactly where Backup / Flash
	 * Firmware offers "Perform reset". */
	const powerItems = await checkPower(page, 'light', true);

	await page.goto(`${base}/cgi-bin/luci/admin/system/flash`);
	await settle(page);

	const resettable = await page.locator('.cbi-value[data-name="reset"]').count() > 0;

	if (powerItems && resettable != (powerItems.indexOf('Factory reset…') > -1))
		fail(`the power menu ${resettable ? 'lacks' : 'offers'} a factory reset where Backup / Flash Firmware ${resettable ? 'offers' : 'lacks'} one`);

	/* The expanded rail. */
	await page.goto(`${base}/cgi-bin/luci/admin/status/overview`);
	await settle(page);
	await page.click('#mainmenu .uf-railbtn');
	await page.mouse.move(900, 500);
	await page.waitForTimeout(400);
	await shot(page, 'rail-expanded-light');
	await page.click('#mainmenu .uf-railbtn');

	/* Dark: the top-bar toggle cycles auto -> light -> dark and remembers it. */
	for (let i = 0; i < 3; i++) {
		if (await page.getAttribute('html', 'data-scheme') == 'dark')
			break;

		await page.click('.uf-scheme');
	}

	if (await page.getAttribute('html', 'data-darkmode') != 'true')
		fail('the scheme toggle did not reach dark');

	for (const [ route, name ] of Object.entries(SHOTS)) {
		await page.goto(`${base}/cgi-bin/luci/${route}`);
		await settle(page);

		if (await page.getAttribute('html', 'data-darkmode') != 'true')
			fail(`${route}: the dark scheme was not remembered`);

		await shot(page, `${name}-dark`);
	}

	await page.goto(`${base}/cgi-bin/luci/admin/status/overview`);
	await settle(page);
	await checkPower(page, 'dark');

	await page.goto(`${base}/cgi-bin/luci/admin/logout`);
	await page.waitForSelector('.uf-login-card');
	await shot(page, 'login-dark');

	/* Phone */
	const phone = await browser.newContext({ viewport: { width: 390, height: 844 }, colorScheme: 'light', isMobile: true, hasTouch: true });
	page = await phone.newPage();
	watch(page);
	await signIn(page);

	for (const [ route, name ] of Object.entries(SHOTS)) {
		await page.goto(`${base}/cgi-bin/luci/${route}`);
		await settle(page);
		await checkWidth(page, 'phone');
		await shot(page, `${name}-phone`);
	}

	for (const route of LOGS)
		await checkLogs(page, route, 'phone');

	await page.click('.uf-burger');
	await page.waitForTimeout(400);
	await shot(page, 'drawer-phone');
	await checkPower(page, 'phone');

	await browser.close();

	if (failures.length) {
		console.log(`\n${failures.length} failure(s)`);
		process.exit(1);
	}

	console.log('\nall pages rendered cleanly');
})().catch((err) => {
	console.error(err);
	process.exit(1);
});
