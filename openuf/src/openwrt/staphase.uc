// Connection-phase collector: stamps the 802.11 steps of every client
// connection, for the controller's WiFi Connectivity view.
//
// The controller times each connection in phases -- association,
// authentication, DHCP, DNS -- from the cumulative deltas an AP reports with
// its STA_ASSOC_TRACKER success (unifi/staevents.lua). The 802.11 half is
// visible only to hostapd, which announces each step as a ubus notification
// on its per-BSS object:
//
//   auth            an Authentication frame arrived (the connection starts)
//   assoc           the (Re)Association Request
//   sta-authorized  the key handshake finished: the client may send data
//   key-mismatch    the handshake failed on the passphrase
//
// This process subscribes to every BSS, stamps those with the wall clock (µs)
// and keeps the finished attempts in OUT, which openwrt/staphase.lua reads
// every heartbeat and completes with the DHCP and DNS half from nftables
// (openwrt/dnswatch.lua).
//
// It sits in hostapd's path. With notify_response on (usteer turns it on),
// hostapd waits up to 100 ms for every subscriber's answer to an auth, assoc
// or probe notification and REJECTS the client when any answer is non-zero --
// and a ucode handler that returns nothing answers UBUS_STATUS_NO_DATA. So
// every notification is answered 0 at once, whatever happens inside, and the
// one slow step (clearing the client from the nftables timing sets, a fork)
// runs as a separate process afterwards.
'use strict';

import * as ubus from 'ubus';
import * as uloop from 'uloop';
import * as fs from 'fs';

const OUT = '/tmp/openuf-phases.json';
const NFT_TABLE = 'bridge openuf_ev';
const KEEP_US = 600 * 1000000;      // a finished attempt stays readable this long
const STALE_US = 30 * 1000000;      // an unfinished one is abandoned after this
const MAX_FAILURES = 500;

let attempts = {};      // mac -> {ifname, auth, signal, assoc, authorized, alg, done, seq}
let failures = [];      // {seq, mac, ifname, auth, signal, assoc, at}
let seq = 0;
let dirty = true;
let to_clear = {};
let clear_timer = null;

function now_us() {
	let c = clock();
	return c[0] * 1000000 + int(c[1] / 1000);
}

// A new attempt starts timing from scratch: the client's first DHCP ACK and
// DNS answer are "add"ed to the nftables sets, which never refreshes an
// element, so one left over from its previous connection would be read as
// this one's. Batched, and spawned rather than run: never in hostapd's path.
function clear_nft() {
	clear_timer = null;
	let cmds = [];
	for (let mac in to_clear) {
		push(cmds, `destroy element ${NFT_TABLE} dhcpfirst { 0x${replace(mac, /:/g, '')} }`);
		push(cmds, `destroy element ${NFT_TABLE} dnsfirst { ${mac} }`);
	}
	to_clear = {};
	// Through sh only for the redirect: a missing element, or the table
	// before dnswatch.lua created it, is not worth a log line.
	if (length(cmds))
		uloop.process('/bin/sh', [ '-c', 'exec nft "$1" >/dev/null 2>&1', 'sh', join('; ', cmds) ],
			{}, () => {});
}

function handle(type, d) {
	let mac = lc(d?.address ?? '');
	if (!match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/))
		return;
	let t = now_us();
	let a = attempts[mac];

	switch (type) {
	case 'auth':
		// SAE and retries send several Authentication frames per attempt:
		// the first one starts it.
		if (!a || a.done || t - a.auth > STALE_US) {
			attempts[mac] = { ifname: d.ifname, auth: t, signal: d.signal };
			to_clear[mac] = true;
			if (!clear_timer)
				clear_timer = uloop.timer(10, clear_nft);
		}
		break;

	case 'assoc':
		if (a && !a.done && a.assoc == null)
			a.assoc = t;
		break;

	case 'sta-authorized':
		if (a && !a.done) {
			a.authorized = t;
			a.alg = d['auth-alg'];
			a.ifname = d.ifname ?? a.ifname;
			a.done = true;
			a.seq = ++seq;
			dirty = true;
		}
		break;

	case 'key-mismatch':
		push(failures, {
			seq: ++seq, mac, ifname: d.ifname ?? a?.ifname, at: t,
			auth: a?.auth, signal: a?.signal, assoc: a?.assoc,
		});
		if (length(failures) > MAX_FAILURES)
			splice(failures, 0, length(failures) - MAX_FAILURES);
		if (a)
			a.done = true;
		dirty = true;
		break;

	case 'disassoc':
	case 'deauth':
		// Left before finishing: never reported as a connection.
		if (a && !a.done)
			a.done = true;
		break;
	}
}

function on_notify(req) {
	if (req.type != 'probe') {
		try {
			handle(req.type, req.data);
		}
		catch (e) {
			warn(`openuf-phases: ${e}\n`);
		}
	}
	return 0;
}

function flush() {
	let t = now_us();
	for (let mac in keys(attempts)) {
		let a = attempts[mac];
		if ((a.done && t - a.auth > KEEP_US) || (!a.done && t - a.auth > STALE_US)) {
			if (a.seq)
				dirty = true;
			delete attempts[mac];
		}
	}
	while (length(failures) && t - failures[0].at > KEEP_US) {
		shift(failures);
		dirty = true;
	}
	if (!dirty)
		return;
	dirty = false;

	let connections = [];
	for (let mac, a in attempts)
		if (a.authorized)
			push(connections, {
				seq: a.seq, mac, ifname: a.ifname, auth: a.auth, signal: a.signal,
				assoc: a.assoc, authorized: a.authorized, alg: a.alg,
			});
	if (fs.writefile(`${OUT}.tmp`, sprintf('%J', { at: t, connections, failures })) != null)
		fs.rename(`${OUT}.tmp`, OUT);
}

uloop.init();
let conn = ubus.connect();
if (!conn) {
	warn('openuf-phases: cannot connect to ubus\n');
	exit(1);
}
let sub = conn.subscriber(on_notify, () => {});

function watch(path) {
	if (match(path ?? '', /^hostapd\.[^.]+$/))
		sub.subscribe(path);
}

// Every BSS now, and every one created later: a wifi reload tears the
// objects down and brings them back under the same names.
for (let path in conn.list() ?? [])
	watch(path);
conn.listener('ubus.object.add', (ev, data) => watch(data?.path));

let tick;
tick = uloop.timer(1000, () => {
	try {
		flush();
	}
	catch (e) {
		warn(`openuf-phases: ${e}\n`);
	}
	tick.set(1000);
});

uloop.run();
