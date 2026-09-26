'use strict';
'require baseclass';

/*
 * Fading names (cascade.css): a design script marks a long name with
 * data-uf-fade, and this measures it. One wider than its box becomes
 * data-uf-fade="over", with --uf-fade-shift (how far to slide, negative)
 * and --uf-fade-time (how long, at a steady reading pace); one that fits
 * becomes "fit". LuCI redraws rows and windows resize, so both are
 * watched, and nothing is written unless it changed. Touch screens have no
 * hover: there a tap slides the name (data-uf-fade-run) and a tap anywhere
 * else slides it back.
 *
 * Mark an element once (only if it has no data-uf-fade yet): writing the
 * attribute again would undo the measurement.
 */

/* Reading pace while sliding, in pixels a second. */
const PACE = 60;

return baseclass.extend({
	watch(root) {
		if (!root || root.ufFade)
			return;

		const seen = new WeakSet();
		const sizes = new ResizeObserver((entries) => entries.forEach((e) => this.measure(e.target)));
		let queued = false;

		const scan = () => {
			queued = false;

			root.querySelectorAll('[data-uf-fade]').forEach((el) => {
				if (!seen.has(el)) {
					seen.add(el);
					sizes.observe(el);
				}

				this.measure(el);
			});
		};

		const queue = () => {
			if (!queued) {
				queued = true;
				window.requestAnimationFrame(scan);
			}
		};

		document.addEventListener('click', (ev) => {
			if (!window.matchMedia('(hover: none)').matches)
				return;

			const el = ev.target.closest?.('[data-uf-fade="over"]');

			document.querySelectorAll('[data-uf-fade-run]').forEach((other) => {
				if (other !== el)
					other.removeAttribute('data-uf-fade-run');
			});

			if (el)
				el.toggleAttribute('data-uf-fade-run');
		});

		root.ufFade = new MutationObserver(queue);
		root.ufFade.observe(root, {
			childList: true,
			subtree: true,
			characterData: true,
			attributes: true,
			attributeFilter: [ 'data-uf-fade' ]
		});

		queue();
	},

	measure(el) {
		/* Mid-slide the text is shifted, whatever started the slide; the
		 * next change measures it. */
		if (!el.isConnected || el.matches(':hover, :focus-within, [data-uf-fade-run]') ||
		    parseFloat(window.getComputedStyle(el).textIndent))
			return;

		const over = el.scrollWidth - el.clientWidth;
		const state = (over > 1) ? 'over' : 'fit';

		if (el.getAttribute('data-uf-fade') != state)
			el.setAttribute('data-uf-fade', state);

		if (state == 'over') {
			const shift = '%dpx'.format(-over);
			const time = '%.2fs'.format(Math.max(0.6, over / PACE));

			if (el.style.getPropertyValue('--uf-fade-shift') != shift)
				el.style.setProperty('--uf-fade-shift', shift);

			if (el.style.getPropertyValue('--uf-fade-time') != time)
				el.style.setProperty('--uf-fade-time', time);
		}
	}
});
