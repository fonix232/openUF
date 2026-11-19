'use strict';
'require baseclass';

/*
 * The station tables (Network > Wireless, Status > Overview) name each
 * station's network the way LuCI names the interface, 'Access Point
 * "HomeNet"', with "(phy0-ap0)" after it. This copies the badge's own
 * data-ssid onto that label as data-uf-ssid, and cascade.css shows the SSID
 * alone ("HomeNet (phy0-ap0)"). Only an attribute is written: LuCI's nodes
 * stay as drawn, and the rows its status poll redraws are tagged again.
 * menu-openuf.js calls enhance() on both pages.
 */

return baseclass.extend({
	enhance() {
		const root = document.querySelector('#view');

		if (!root || root.ufStations)
			return;

		const tag = () => {
			for (const label of root.querySelectorAll('.ifacebadge[data-ssid][data-ifname] > span')) {
				const ssid = label.parentNode.getAttribute('data-ssid');

				if (ssid && label.getAttribute('data-uf-ssid') !== ssid)
					label.setAttribute('data-uf-ssid', ssid);
			}
		};

		/* Rows only: the attribute written here is not watched. */
		root.ufStations = new MutationObserver(tag);
		root.ufStations.observe(root, { childList: true, subtree: true });
		tag();
	}
});
