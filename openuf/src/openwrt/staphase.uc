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
// It also keeps the roam log (ROAM_OUT, unifi/staevents.lua roam_ingest): the
// assoc / sta-authorized / disassoc steps of every client, written out the
// moment they happen and stamped with /proc/uptime, because inform.lua sends
// roam reports within ~250 ms (the controller pairs a departure with an
// arrival only within 10 s); and, through a child shell, the bridge's address
// moves from `bridge monitor fdb` (FDB_OUT): a client that left for another
// AP is learned on the uplink here in the same second, while hostapd still
// lists it for 6-40 s.
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
const ROAM_OUT = '/tmp/openuf-roam.log';
const MAX_ROAM = 64;                // lines kept in ROAM_OUT

let attempts = {};      // mac -> {ifname, auth, signal, assoc, authorized, alg, done, seq}
let failures = [];      // {seq, mac, ifname, auth, signal, assoc, at}
let seq = 0;
let dirty = true;
let to_clear = {};
let clear_timer = null;
let roam = [];          // the last MAX_ROAM roam log lines
let roam_seq = 0;

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

function uptime() {
	return split(fs.readfile('/proc/uptime') ?? '0', ' ')[0];
}

// One roam log line: "<seq> <uptime> <ev> <rest>". Stamped now, written a
// millisecond later, after the notification has been answered: the file
// write stays out of hostapd's path.
let roam_timer = null;
function roam_write() {
	roam_timer = null;
	if (fs.writefile(`${ROAM_OUT}.tmp`, join('\n', roam) + '\n') != null)
		fs.rename(`${ROAM_OUT}.tmp`, ROAM_OUT);
}
function roam_log(ev, rest) {
	push(roam, `${++roam_seq} ${uptime()} ${ev} ${rest}`);
	if (length(roam) > MAX_ROAM)
		splice(roam, 0, length(roam) - MAX_ROAM);
	if (!roam_timer)
		roam_timer = uloop.timer(1, roam_write);
}

const ROAM_EVENTS = { 'assoc': true, 'sta-authorized': true, 'disassoc': true, 'deauth': true };

function handle(type, d) {
	let mac = lc(d?.address ?? '');
	if (!match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/))
		return;
	if (ROAM_EVENTS[type])
		roam_log(type, `${mac} ${d.ifname ?? '-'} ${d.signal ?? '-'} ${d['auth-alg'] ?? '-'}`);
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

// The bridge's address moves, through a shell pipeline: a `read` loop hands
// on each line the moment it arrives (within 10 ms on both upstream boards),
// where a buffered read here could hold a burst back until the next event.
// Appended to FDB_OUT, which inform.lua drains (openwrt/staphase.lua
// drain_fdb). Ageing ("Deleted") and the switch's own table ("self") are
// dropped before they reach the file. A leftover monitor from an earlier
// run is killed first (bracketed so that pgrep does not match the kill); one
// whose collector died exits on its next line. Restarted in 30 s if it ends.
const FDB_OUT = '/tmp/openuf-fdb.log';
const FDB_SCRIPT = `p=$PPID
bridge monitor fdb 2>/dev/null | while IFS= read -r l; do
	kill -0 "$p" 2>/dev/null || exit 0
	case "$l" in Deleted*|*' self'*) continue ;; esac
	read -r u _ < /proc/uptime
	printf '%s fdb %s\\n' "$u" "$l" >> ${FDB_OUT}
done`;
// Its own process: the monitor's script names "bridge monitor fdb" too.
const FDB_KILL = "kill $(pgrep -f '[b]ridge monitor fdb') 2>/dev/null";
function fdb_start() {
	uloop.process('/bin/sh', [ '-c', FDB_KILL ], {}, () =>
		uloop.process('/bin/sh', [ '-c', FDB_SCRIPT ], {}, () => uloop.timer(30000, fdb_start)));
}
fdb_start();

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
