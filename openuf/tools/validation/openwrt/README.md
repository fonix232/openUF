# Real-netifd bench (bridge ownership)

`tools/validation/ap` mocks `uci`, `ubus` and `iw`, which is fine for the inform protocol
and useless for testing what happens when openUF rewrites `/etc/config/network`. This bench
runs genuine OpenWrt userspace (procd, ubusd, netifd, uci, from `openwrt/rootfs`), so every
network change is applied by the real netifd, `bridge-vlan` included.

```
controller (10.6.106) ── Docker net ── gw ══ veth "cable" ══ ap (OpenWrt, openUF)
                                         trunk                 wan   lan1 ── c1eth (client)
                                   untagged + VLAN 2/3/12/50         lan2 ── c2eth (client)
```

- **gw** is a VLAN-aware gateway. It serves DHCP on the untagged trunk
  (192.168.1.0/24) and on VLANs 2/3/12/50 (10.<vid>.0.0/24), and NATs to the
  controller. The trunk is a point-to-point veth to the AP's `wan`, not the Docker
  network. The Docker bridge reflects broadcasts back into the AP, which makes the
  AP's bridge learn its own clients on the uplink.
- **ap** starts from this network's real AP layout (`ap/network.bifrost`): one
  VLAN-filtering bridge named `switch`, management on `switch.1`. That layout is the
  one openUF has to take over.
- **c1eth/c2eth** are the far ends of the `lan1`/`lan2` sockets, in a container of
  their own. If they stayed in the AP's namespace they would be the AP's own netdevs,
  which openUF never reports. `bench.sh client <n>` takes a DHCP lease through one
  (which shows the VLAN the socket really lands in), and `bench.sh clients` shows where
  the controller filed each host.

The AP has no radios, so the WLAN side is exercised at the UCI level only.

## Scenarios

```sh
sh bench.sh up          # build, start, first-run the controller, lay out the AP
sh bench.sh adopt       # start openUF (L3, rollback window 60 s) and adopt it
sh bench.sh state       # controller view + bridge vlan + addresses + netmodel state
sh bench.sh portvlan    # port 2: native IoT (VLAN 3), Guest excluded
sh bench.sh client 2    #   -> a 10.3.0.x lease through lan2
sh bench.sh mgmt 50     # Management VLAN 50 -> the AP re-homes onto br-lan.50
sh bench.sh mgmt 60     # VLAN 60 has no DHCP: the plan strands the AP and is rolled back
sh bench.sh provision   # force-provision (note: 10.6 skips identical configs)
sh bench.sh down
```

What was verified on 2026-09-25 (OpenWrt SNAPSHOT r36402, Network 10.6.106):

- **Takeover.** The adoption push replaced `switch` with a VLAN-filtering `br-lan`.
  VLANs 2/3/12 were kept for the pre-existing `guest`/`iot`/`vpn_se` interfaces, and
  management moved to `br-lan.1` with the same DHCP address. The rollback window was
  confirmed by the next inform.
- **Port VLAN.** `lan2` became PVID 3 untagged, with VLAN 12 excluded and the rest
  tagged. The client behind it leased 10.3.0.x, while `lan1`'s client stayed untagged.
  The controller files the `lan2` host under **IoT (VLAN 3), port 2** and the `lan1` host
  under Default, port 1. The per-host VLAN is read from the filtering bridge's FDB.
- **Management VLAN 50.** `br-lan.50` leased 10.50.0.x, and the AP stayed connected
  through the gateway.
- **Stranding push (VLAN 60).** Informs failed. After 60 s the previous
  `/etc/config/network` was restored, and the AP reconnected on its own. The plan was
  remembered and not retried.
- **Image upgrade.** With `/usr/share/openuf` removed and `/etc/openuf` and `/etc/config/openuf` kept,
  the `contrib/asu` first-boot script's bootstrap reinstalled openUF. The AP came back
  connected under its existing adoption.
- **STUN.** The controller's wake packet (`0x8888`) on a Custom Upgrade reached the AP
  through the gateway's NAT, and the upgrade was delivered in the same second.

## Notes

- `OPENWRT_TAG` selects the rootfs (`armsr-armv8-SNAPSHOT` by default; use
  `x86-64-SNAPSHOT` on an x86 host).
- Docker Desktop's kernel loads `br_netfilter` in every namespace. That sends bridged
  frames through fw4's forward chain, so `prepare.sh` turns it off, as it is on an
  OpenWrt AP.
- The controller UI is on https://127.0.0.1:28443 (admin / `openuf-bench-1`).
