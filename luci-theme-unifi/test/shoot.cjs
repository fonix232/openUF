'use strict';

/*
 * Full-page screenshots of chosen LuCI pages, for working on the theme:
 *
 *   node shoot.cjs [options] ROUTE...
 *
 *   --base URL        LuCI to drive           (http://127.0.0.1:8080)
 *   --password PW     root password           (unifi-test, as run.sh sets)
 *   --out DIR         where the PNGs go       (./shots)
 *   --schemes LIST    light,dark and/or phone (light,dark)
 *   --viewport WxH    desktop viewport        (1440x900)
 *   --viewport-only   capture the viewport, not the whole page
 *
 * ROUTE is a path below /cgi-bin/luci/, e.g. admin/network/firewall. Each
 * page is captured once its view has finished loading; errors thrown by the
 * page are printed, so a broken view is not mistaken for a styled one.
 */

const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const opts = { base: 'http://127.0.0.1:8080', password: 'unifi-test', out: 'shots', schemes: 'light,dark', viewport: '1440x900' };
const routes = [];
const argv = process.argv.slice(2);

for (let i = 0; i < argv.length; i++) {
	if (argv[i] == '--viewport-only')
		opts.viewportOnly = true;
	else if (argv[i].startsWith('--'))
		opts[argv[i].slice(2)] = argv[++i];
	else
		routes.push(argv[i].replace(/^\/?(cgi-bin\/luci\/)?/, ''));
}

if (!routes.length) {
	console.error('usage: node shoot.cjs [--base URL] [--out DIR] [--schemes light,dark,phone] ROUTE...');
	process.exit(2);
}

const [ vw, vh ] = opts.viewport.split('x').map(Number);

async function settle(page) {
	await page.waitForLoadState('networkidle', { timeout: 20000 }).catch(() => {});

	const nag = page.locator('.modal button', { hasText: 'No, disable checking' });

	if (await nag.count()) {
		await nag.click();
		await page.waitForLoadState('networkidle', { timeout: 20000 }).catch(() => {});
	}

	await page.waitForFunction(() => {
		const view = document.querySelector('#view');

		return !view || !view.querySelector(':scope > .spinning');
	}, null, { timeout: 20000 }).catch(() => console.log(`  ! ${page.url()}: view still loading`));

	await page.waitForTimeout(600);
}

(async () => {
	fs.mkdirSync(opts.out, { recursive: true });

	const browser = await chromium.launch();

	for (const scheme of opts.schemes.split(',')) {
		const phone = (scheme == 'phone');
		const ctx = await browser.newContext(phone
			? { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, colorScheme: 'light' }
			: { viewport: { width: vw, height: vh }, colorScheme: scheme == 'dark' ? 'dark' : 'light' });
		const page = await ctx.newPage();

		page.on('pageerror', (err) => {
			if (!/uci\/get failed with error -32002/.test(err.message))
				console.log(`  ! ${page.url()}: ${err.message.split('\n')[0]}`);
		});

		await page.goto(`${opts.base}/cgi-bin/luci/`);
		await page.fill('#luci_password', opts.password);
		await Promise.all([ page.waitForNavigation(), page.click('.uf-login-submit, button[type="submit"], .cbi-button-positive') ]);

		for (const route of routes) {
			await page.goto(`${opts.base}/cgi-bin/luci/${route}`);
			await settle(page);

			const file = path.join(opts.out, `${route.replace(/^admin\//, '').replace(/[\/#?]+/g, '-')}-${scheme}.png`);

			await page.screenshot({ path: file, fullPage: !opts.viewportOnly });
			console.log(file);
		}

		await ctx.close();
	}

	await browser.close();
})().catch((err) => {
	console.error(err);
	process.exit(1);
});
