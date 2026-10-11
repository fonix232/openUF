#!/bin/sh
# Bridge-ownership bench driver. Run from this directory:
#   sh bench.sh up          build + start everything, first-run the controller
#   sh bench.sh adopt       start openUF on the AP and adopt it
#   sh bench.sh state       show the AP's bridge/VLAN/address state
#   sh bench.sh mgmt <vid>  set the AP's Management VLAN (0 = none)
#   sh bench.sh portvlan    port 2 native VLAN 3 (Port VLAN on)
#   sh bench.sh client <n>  DHCP from the wired client behind lan<n>
#   sh bench.sh clients     the controller's client list (port + network per host)
#   sh bench.sh provision   force the controller to re-push the full config
#   sh bench.sh down
set -eu
B=https://127.0.0.1:28443
JAR=$(mktemp -t openuf-bench.XXXXXX)
trap 'rm -f "$JAR"' EXIT
CTL_IP=172.31.0.10
AP="docker compose exec -T ap"

api() {   # api METHOD PATH [JSON]
	if ! curl -sk -b "$JAR" "$B/api/self" | grep -q '"rc":"ok"'; then
		curl -sk -c "$JAR" -H 'Content-Type: application/json' \
			-d '{"username":"admin","password":"openuf-bench-1"}' "$B/api/login" >/dev/null
	fi
	if [ -n "${3:-}" ]; then
		curl -sk -b "$JAR" -X "$1" -H 'Content-Type: application/json' -d "$3" "$B/$2"
	else
		curl -sk -b "$JAR" -X "$1" "$B/$2"
	fi
}

wait_controller() {
	i=0
	until curl -sk "$B/status" | grep -q '"up":true'; do
		i=$((i + 1)); [ $i -gt 90 ] && { echo "controller did not come up" >&2; exit 1; }
		sleep 2
	done
}

net_id() {   # net_id NAME
	api GET api/s/default/rest/networkconf | python3 -c \
		"import json,sys; print([n['_id'] for n in json.load(sys.stdin)['data'] if n['name']=='$1'][0])"
}

dev_json() { api GET api/s/default/stat/device; }
ap_mac() {
	dev_json | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(d[0]['mac'] if d else '')"
}
ap_id() {
	dev_json | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(d[0]['_id'] if d else '')"
}

case "${1:-}" in
up)
	docker compose up -d --build
	# The cable: a veth pair between the gateway's `trunk` and the AP's `wan`,
	# created from the host's view of both network namespaces.
	pa=$(docker inspect -f '{{.State.Pid}}' "$(docker compose ps -q ap)")
	pg=$(docker inspect -f '{{.State.Pid}}' "$(docker compose ps -q gw)")
	docker run --rm --privileged --pid=host --net=host alpine:3.20 sh -c "
		apk add -q iproute2 >/dev/null
		ip link add benchwan type veth peer name benchtrunk
		ip link set benchwan netns $pa && ip link set benchtrunk netns $pg"
	$AP sh -c 'ip link set benchwan name wan'
	docker compose exec -T gw ip link set benchtrunk name trunk
	# Wired clients: the far ends of lan1/lan2, in a container of their own --
	# left in the AP's namespace they would be the AP's own netdevs, which
	# openUF (rightly) never reports as clients.
	docker rm -f openuf-owrt-bench-clients >/dev/null 2>&1 || true
	docker run -d --name openuf-owrt-bench-clients --network none --privileged alpine:3.20 sleep infinity >/dev/null
	pc=$(docker inspect -f '{{.State.Pid}}' openuf-owrt-bench-clients)
	$AP sh -c 'for n in 1 2; do ip link show lan$n >/dev/null 2>&1 || ip link add lan$n type veth peer name c${n}eth; done'
	docker run --rm --privileged --pid=host --net=host alpine:3.20 sh -c "
		apk add -q iproute2 util-linux >/dev/null
		nsenter -t $pa -n ip link set c1eth netns $pc && nsenter -t $pa -n ip link set c2eth netns $pc"
	docker exec openuf-owrt-bench-clients sh -c 'ip link set c1eth up; ip link set c2eth up'
	wait_controller
	for req in \
		'api/cmd/sitemgr|{"cmd":"add-default-admin","name":"admin","email":"bench@example.invalid","x_password":"openuf-bench-1"}' \
		'api/set/setting/country|{"code":826}' \
		'api/cmd/system|{"cmd":"set-installed"}'; do
		curl -sk -X POST -H 'Content-Type: application/json' -d "${req#*|}" "$B/${req%%|*}" >/dev/null
	done
	for spec in Guest:2 IoT:3 VPN:12 Mgmt:50 Dead:60; do
		api POST api/s/default/rest/networkconf \
			"{\"name\":\"${spec%%:*}\",\"purpose\":\"vlan-only\",\"vlan_enabled\":true,\"vlan\":${spec##*:}}" >/dev/null
	done
	$AP sh -c 'until ubus call network.interface.lan status >/dev/null 2>&1; do sleep 1; done; bench-prepare'
	echo "bench up; controller $B (admin / openuf-bench-1)"
	;;
adopt)
	$AP sh -c "uci set openuf.main.l2_announce=0 && uci set openuf.main.bridge_rollback_timeout=60 \
		&& uci commit openuf; syswrapper.sh set-inform http://$CTL_IP:8080/inform; \
		/etc/init.d/openuf enable; /etc/init.d/openuf restart"
	i=0; mac=""
	until [ -n "$mac" ]; do i=$((i + 1)); [ $i -gt 30 ] && { echo "AP never showed up" >&2; exit 1; }; sleep 2; mac=$(ap_mac); done
	api POST api/s/default/cmd/devmgr "{\"cmd\":\"adopt\",\"mac\":\"$mac\"}" >/dev/null
	echo "adopt sent for $mac"
	;;
wlans)
	g=$(api GET v2/api/site/default/apgroups | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['_id'])")
	for spec in "10_Fwd:Default" "HoloDeck:Guest" "10fwd_iot:IoT" "Transporter_Room_3:VPN"; do
		n=$(net_id "${spec##*:}")
		api POST api/s/default/rest/wlanconf "{\"name\":\"${spec%%:*}\",\"x_passphrase\":\"benchpass123\",\"security\":\"wpapsk\",\"wpa_mode\":\"wpa2\",\"wpa_enc\":\"ccmp\",\"networkconf_id\":\"$n\",\"ap_group_ids\":[\"$g\"],\"enabled\":true}" >/dev/null
	done
	echo "4 WLANs created"
	;;
portvlan)
	iot=$(net_id IoT); guest=$(net_id Guest)
	api PUT "api/s/default/rest/device/$(ap_id)" "{\"switch_vlan_enabled\":true,\"port_overrides\":[{\"port_idx\":2,\"native_networkconf_id\":\"$iot\",\"tagged_vlan_mgmt\":\"custom\",\"excluded_networkconf_ids\":[\"$guest\"]}]}" >/dev/null
	echo "port 2: native IoT (VLAN 3), Guest excluded"
	;;
mgmt)
	case "${2:-0}" in
		0)  body='{"mgmt_network_id":""}' ;;
		50) body="{\"mgmt_network_id\":\"$(net_id Mgmt)\"}" ;;
		60) body="{\"mgmt_network_id\":\"$(net_id Dead)\"}" ;;
		*)  echo "vid must be 0, 50 or 60 (60 has no DHCP: a stranding push)" >&2; exit 2 ;;
	esac
	api PUT "api/s/default/rest/device/$(ap_id)" "$body" >/dev/null
	echo "management VLAN -> ${2:-0}"
	;;
provision)
	api POST api/s/default/cmd/devmgr "{\"cmd\":\"force-provision\",\"mac\":\"$(ap_mac)\"}" >/dev/null
	echo "force-provision sent"
	;;
state)
	dev_json | python3 -c "import json,sys
for d in json.load(sys.stdin)['data']:
    print('controller: state=%s adopted=%s ip=%s cfgversion=%s' % (d.get('state'), d.get('adopted'), d.get('ip'), d.get('cfgversion')))"
	$AP sh -c 'echo "--- bridge vlan"; bridge vlan show; echo "--- addresses"; ip -4 -br addr | grep -v "^lo"; echo "--- netmodel"; lua -e "local c=require(\"cjson\"); local s=c.decode(io.open(\"/etc/openuf/state.json\"):read(\"*a\")); for _,k in ipairs({\"netmodel_applied\",\"netmodel_failed\"}) do print(k, tostring(s[k])) end; print(\"pending\", s.netmodel_pending and c.encode(s.netmodel_pending) or \"-\")"; logread | grep -E "netmodel|openuf|inform:" | tail -6'
	;;
client)
	# DHCP through the client behind lan<n>; the lease is applied in the clients
	# container, so the host then shows up in the controller as a wired client.
	docker exec openuf-owrt-bench-clients sh -c "udhcpc -i c${2:-2}eth -n -q -t 4 -T 2 2>&1 | grep -iE 'obtained|failed|no lease' || echo 'no lease'"
	;;
clients)
	# The controller's client list: which AP port and which network each host landed on.
	api GET api/s/default/stat/sta | python3 -c "import json,sys
for c in json.load(sys.stdin)['data']:
    print(c.get('mac'), 'network=%s vlan=%s port=%s ip=%s' % (c.get('network'), c.get('vlan'), c.get('sw_port'), c.get('ip')))"
	;;
down)
	docker rm -f openuf-owrt-bench-clients >/dev/null 2>&1 || true
	docker compose down -v
	;;
*)
	sed -n '2,10p' "$0"; exit 2 ;;
esac
