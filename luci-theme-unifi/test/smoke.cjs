'use strict';

/*
 * Drive LuCI with luci-theme-unifi installed, as run.sh sets it up:
 *
 *   node smoke.cjs BASE_URL PASSWORD OUT_DIR
 *
 * Signs in, walks every page the menu offers, and fails on a script error,
 * a failed theme or LuCI asset, a page that never finishes loading, or a
 * layout wider than the window. Then it switches the Interfaces and
 * Wireless designs on System > UniFi Theme and checks both pages in each.
 * Screenshots of the main views, in light, dark and phone layouts, are
 * written to OUT_DIR.
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
	'admin/status/overview': 'overview',
	'admin/system/system': 'system',
	'admin/network/network': 'interfaces',
	'admin/network/wireless': 'wireless',
	'admin/network/firewall': 'firewall',
	'admin/network/dhcp': 'dhcp',
	'admin/system/package-manager': 'software',
	'admin/status/processes': 'processes',
	'admin/system/unifi-theme': 'theme-settings'
};

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

/* The designs (System > UniFi Theme, luci.unifi): each comes round on
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
	await page.goto(`${base}/cgi-bin/luci/admin/system/unifi-theme`);
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

	const pages = await page.$$eval('#mainmenu .uf-flyout a, #mainmenu .uf-rail-item > a', (links) =>
		[ ...new Set(links.map((a) => new URL(a.href).pathname)) ]);

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

	/* run.sh sets UF_PORTS=1 once the lab has its ports. */
	if (process.env.UF_PORTS == '1') {
		for (const route of [ 'admin/network/network', 'admin/dashboard', 'admin/status/overview' ])
			await checkPorts(page, route);

		await page.goto(`${base}/cgi-bin/luci/admin/network/network`);
		await settle(page);
		await shot(page, 'ports-light');
	}

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
	await page.fill('input[id$=".hostname"]', 'unifi-test-host');
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

	/* A flyout, as it opens on hover. */
	await page.goto(`${base}/cgi-bin/luci/admin/status/overview`);
	await settle(page);
	await page.hover('#mainmenu .uf-rail-item[data-name="network"] > a');
	await page.waitForTimeout(400);
	await shot(page, 'flyout-light');

	/* The expanded rail. */
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

	await page.click('.uf-burger');
	await page.waitForTimeout(400);
	await shot(page, 'drawer-phone');

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
