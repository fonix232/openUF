'use strict';

/*
 * The theme as a browser without Chromium's newer CSS sees it, for the
 * fallbacks in cascade.css (only Chromium runs here):
 *
 *   node compat.cjs BASE_URL PASSWORD OUT_DIR
 *
 * cascade.css (and the Network designs' stylesheets beside it) is served
 * with the declarations of every property in ABSENT dropped, "@supports
 * (P: ...)" false and "@supports not (P: ...)" true, which is what Firefox
 * ESR or Safari make of it. Every page in the menu is then visited wide,
 * in the 961-1200px band where grids scroll inside their cards, and at
 * phone width; a layout wider than the window, a script error or a
 * read-only field that cuts its value off fails. Screenshots of the pages
 * that use these properties are written to OUT_DIR.
 */

const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const [ base, password, out ] = process.argv.slice(2);

if (!base || !password || !out) {
	console.error('usage: node compat.cjs BASE_URL PASSWORD OUT_DIR');
	process.exit(2);
}

/* Shipped in Chromium, missing from Firefox ESR or Safari (or both). */
const ABSENT = [
	'field-sizing',          /* Firefox ESR 140, Safari before 26.2 */
	'scroll-initial-target', /* Firefox, Safari */
	'animation-timeline',    /* Firefox (scroll-driven animations) */
	'scrollbar-color'        /* Safari (parsed, not drawn on macOS) */
];

/* Tabs the menu walk does not reach that use one of them. */
const EXTRA = [ 'admin/system/admin/repokeys' ];

const SHOTS = {
	'admin/system/system': 'system',
	'admin/system/admin/repokeys': 'repokeys',
	'admin/network/firewall': 'firewall'
};

const LAYOUTS = [
	{ name: 'wide', viewport: { width: 1440, height: 900 } },
	{ name: 'narrow', viewport: { width: 1000, height: 900 } },
	{ name: 'phone', viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }
];

const failures = [];
const fail = (msg) => { failures.push(msg); console.log(`  FAIL ${msg}`); };

function withoutFeatures(css) {
	for (const prop of ABSENT) {
		css = css.split(`(${prop}:`).join(`(-uf-absent-${prop}:`);
		css = css.replace(new RegExp(`(^|[\\s;{])${prop}\\s*:[^;{}]*;?`, 'g'), '$1');
	}

	return css;
}

async function settle(page) {
	await page.waitForLoadState('networkidle', { timeout: 20000 }).catch(() => {});

	const nag = page.locator('.modal .btn, .modal button', { hasText: 'No, disable checking' });

	if (await nag.count()) {
		await nag.click();
		await page.waitForLoadState('networkidle', { timeout: 20000 }).catch(() => {});
	}

	await page.waitForFunction(() => {
		const view = document.querySelector('#view');

		return !view || !view.querySelector(':scope > .spinning');
	}, null, { timeout: 20000 }).catch(() => fail(`${page.url()}: view never finished loading`));

	await page.waitForTimeout(300);
}

(async () => {
	fs.mkdirSync(out, { recursive: true });

	const browser = await chromium.launch();

	for (const layout of LAYOUTS) {
		const { name, ...options } = layout;
		const ctx = await browser.newContext({ colorScheme: 'light', ...options });
		const page = await ctx.newPage();
		let rewritten = 0;

		await ctx.route(/\/luci-static\/unifi[^/]*\/(cascade|network\/[a-z]+-[a-z]+)\.css(\?|$)/, async (route) => {
			const res = await route.fetch();

			await route.fulfill({ response: res, body: withoutFeatures(await res.text()) });
			rewritten++;
		});

		page.on('pageerror', async (err) => {
			if (/uci\/get failed with error -32002/.test(err.message) && !await page.locator('#mainmenu').count())
				return;

			fail(`${page.url()} (${name}): script error: ${err.message}`);
		});

		await page.goto(`${base}/cgi-bin/luci/`);
		await page.fill('#luci_password', password);
		await Promise.all([ page.waitForNavigation(), page.click('.uf-login-submit') ]);
		await settle(page);

		if (!rewritten)
			fail(`${name}: cascade.css was not rewritten`);

		const pages = await page.$$eval('#mainmenu .uf-flyout a, #mainmenu .uf-rail-item > a', (links, extra) =>
			[ ...new Set(links.map((a) => new URL(a.href).pathname).concat(extra.map((r) => `/cgi-bin/luci/${r}`))) ], EXTRA);

		console.log(`${name}: ${pages.length} menu pages without ${ABSENT.join(', ')}`);

		for (const p of pages) {
			const route = p.replace(/^\/cgi-bin\/luci\/?/, '');

			if (route == 'admin/logout')
				continue;

			await page.goto(`${base}${p}`);
			await settle(page);

			const over = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);

			if (over > 1)
				fail(`${route} (${name}): content is ${over}px wider than the window`);

			/* A read-only value cut off at the field's edge cannot be read. */
			const clipped = await page.evaluate(() => [ ...document.querySelectorAll('#view input[readonly]:not([type="hidden"])') ]
				.filter((el) => el.offsetParent && el.scrollWidth > el.clientWidth + 1)
				.map((el) => el.id || el.name || el.className));

			for (const id of clipped)
				fail(`${route} (${name}): read-only field ${id} cuts its value off`);

			if (SHOTS[route])
				await page.screenshot({ path: path.join(out, `${SHOTS[route]}-${name}.png`) });
		}

		await ctx.close();
	}

	await browser.close();

	if (failures.length) {
		console.log(`\n${failures.length} compat failure(s)`);
		process.exit(1);
	}

	console.log('\nfallbacks hold without Chromium-only CSS');
})().catch((err) => {
	console.error(err);
	process.exit(1);
});
