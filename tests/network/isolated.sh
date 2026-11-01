#!/usr/bin/env bash
set -euo pipefail
umask 022
printf 'Local Linux fixture: %s\n' "$(uname -m)"
ip link add preflight-vxlan type vxlan id 42 dstport 4789
ip link delete preflight-vxlan
ip link add preflight-wg type wireguard
ip link delete preflight-wg
iptables -w 5 -L >/dev/null
ip6tables -w 5 -L >/dev/null
ip netns add preflight
ip netns delete preflight
printf 'VXLAN, WireGuard, netfilter and namespace prerequisites passed.\n'

ROOT=/run/podroute-tests
mkdir -p "$ROOT"/{vpn,lan,leak,static}
printf 'VPN\n' > "$ROOT/vpn/index.html"
printf 'LAN\n' > "$ROOT/lan/index.html"
printf 'LEAK\n' > "$ROOT/leak/index.html"
printf 'STATIC\n' > "$ROOT/static/index.html"
background=()
cleanup() {
	local result=$? namespace process
	trap - EXIT
	if (( result != 0 )); then
		for namespace in gw peer dynamic static; do
			printf '\n--- %s diagnostics ---\n' "$namespace"
			ip -n "$namespace" -4 addr || true
			ip -n "$namespace" -4 route || true
			ip netns exec "$namespace" iptables-save || true
		done
		for logfile in "$ROOT"/*.log; do [[ ! -f "$logfile" ]] || tail -40 "$logfile"; done
	fi
	for process in "${background[@]}"; do kill -TERM "$process" 2>/dev/null || true; done
	for namespace in gw peer dynamic static; do
		for process in $(ip netns pids "$namespace" 2>/dev/null); do kill -TERM "$process" 2>/dev/null || true; done
		ip netns delete "$namespace" 2>/dev/null || true
	done
	ip link delete pr-underlay 2>/dev/null || true
	exit "$result"
}
trap cleanup EXIT

ip link add pr-underlay type bridge
ip addr add 10.200.0.1/24 dev pr-underlay
ip link set pr-underlay up
ip link set lo up
ip addr add 192.0.2.10/32 dev lo
ip addr add 10.201.0.1/32 dev lo
ip -6 addr add 2001:db8::10/128 dev lo
ip -6 addr add fd00:200::1/64 dev pr-underlay
sysctl -w net.ipv4.ip_forward=1 >/dev/null
for namespace in gw peer dynamic static; do
	case $namespace in gw) host=10;; peer) host=11;; dynamic) host=20;; static) host=21;; esac
	ip netns add "$namespace"
	ip link add "host-$namespace" type veth peer name "ns-$namespace"
	ip link set "ns-$namespace" netns "$namespace"
	ip link set "host-$namespace" master pr-underlay
	ip link set "host-$namespace" up
	ip -n "$namespace" link set "ns-$namespace" name eth0
	ip -n "$namespace" link set eth0 up
	ip -n "$namespace" link set lo up
	ip -n "$namespace" addr add "10.200.0.$host/24" dev eth0
	ip -n "$namespace" route add default via 10.200.0.1
	ip -n "$namespace" -6 addr add "fd00:200::$host/64" dev eth0
	ip -n "$namespace" -6 route add default via fd00:200::1
	ip netns exec "$namespace" sysctl -w net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.eth0.rp_filter=0 >/dev/null
	mkdir -p "$ROOT/$namespace/state"
done

CONFIG=$(jq -nc '{gatewayHost:"gateway.example",clusterDNS:["10.200.0.1"],upstreamDNS:["192.0.2.53"],dnssec:false,mtu:1420,retrySeconds:1,clientBypassCIDRs:["10.200.0.0/24"],gatewayBypassCIDRs:["10.200.0.0/24","10.201.0.0/24"],vpnEndpointCIDRs:["10.200.0.11/32"],staticClients:[{id:"static-app",address:"172.16.1.10",ports:[{protocol:"tcp",externalPort:18080,targetPort:8080},{protocol:"udp",externalPort:18081,targetPort:8053}]}]}')
role() {
	local namespace=$1 command=$2; shift 2
	ip netns exec "$namespace" env PODROUTE_CONFIG="$CONFIG" PODROUTE_STATE_DIR="$ROOT/$namespace/state" "$@" /usr/local/bin/podroute "$command"
}
fetch() { ip netns exec "$1" curl --noproxy '*' -fsS --connect-timeout 2 --max-time 4 "$2"; }
await() {
	local deadline=$((SECONDS + 35))
	until "$@"; do
		if (( SECONDS >= deadline )); then
			printf 'Timed out waiting for: %s\n' "$*" >&2
			return 1
		fi
		sleep 0.2
	done
}

busybox-extras httpd -f -p 10.200.0.1:8080 -h "$ROOT/lan" & background+=("$!")
busybox-extras httpd -f -p 10.201.0.1:8080 -h "$ROOT/lan" & background+=("$!")
busybox-extras httpd -f -p 192.0.2.10:8080 -h "$ROOT/leak" & background+=("$!")
busybox-extras httpd -f -p '[2001:db8::10]:8080' -h "$ROOT/leak" & background+=("$!")
printf '10.200.0.10 gateway.example\n' > "$ROOT/gateway-hosts"
dnsmasq --keep-in-foreground --conf-file=/dev/null --listen-address=10.200.0.1 --bind-interfaces \
	--no-resolv --no-hosts --addn-hosts="$ROOT/gateway-hosts" --address=/cluster.local/10.200.0.1 \
	--pid-file="$ROOT/cluster.pid" > "$ROOT/cluster.log" 2>&1 & cluster_pid=$!; background+=("$cluster_pid")
tcpdump -i pr-underlay -U -w "$ROOT/leaks.pcap" 'dst host 192.0.2.10 and tcp dst port 8080' > "$ROOT/capture.log" 2>&1 & capture_pid=$!; background+=("$capture_pid")

role gw gateway-init
if fetch gw http://192.0.2.10:8080 2>/dev/null; then printf 'gateway leaked before VPN startup\n' >&2; exit 1; fi
printf 'PASS: gateway fails closed before VPN startup\n'

umask 077
wg genkey > "$ROOT/gw.key"
wg genkey > "$ROOT/peer.key"
umask 022
gw_public=$(wg pubkey < "$ROOT/gw.key")
peer_public=$(wg pubkey < "$ROOT/peer.key")
ip -n gw link add wg0 type wireguard
ip -n peer link add wg0 type wireguard
ip -n gw addr add 198.18.0.1/30 dev wg0
ip -n peer addr add 198.18.0.2/30 dev wg0
ip netns exec gw wg set wg0 private-key "$ROOT/gw.key" listen-port 51820 peer "$peer_public" allowed-ips 0.0.0.0/0 endpoint 10.200.0.11:51820
ip netns exec peer wg set wg0 private-key "$ROOT/peer.key" listen-port 51820 peer "$gw_public" allowed-ips 198.18.0.1/32 endpoint 10.200.0.10:51820
ip -n gw link set wg0 mtu 1420 up
ip -n peer link set wg0 mtu 1420 up
ip -n gw route replace default dev wg0
ip -n peer addr add 192.0.2.10/32 dev lo
ip -n peer addr add 192.0.2.53/32 dev lo
ip netns exec peer busybox-extras httpd -f -p 192.0.2.10:8080 -h "$ROOT/vpn" & background+=("$!")
ip netns exec peer dnsmasq --keep-in-foreground --conf-file=/dev/null --listen-address=192.0.2.53 --bind-interfaces \
	--no-resolv --no-hosts --address=/vpn.test/192.0.2.10 --pid-file="$ROOT/upstream.pid" > "$ROOT/upstream.log" 2>&1 & background+=("$!")
role gw gateway-sidecar > "$ROOT/gateway.log" 2>&1 & background+=("$!")
await test -s "$ROOT/gw/state/dnsmasq.pid"
role dynamic client-init
role static client-init PODROUTE_CLIENT_ID=static-app
ip netns exec static busybox-extras httpd -f -p 0.0.0.0:8080 -h "$ROOT/static" & background+=("$!")
ip netns exec static dnsmasq --keep-in-foreground --conf-file=/dev/null --listen-address=172.16.1.10 --port=8053 --bind-interfaces \
	--no-resolv --no-hosts --address=/forward.test/172.16.1.10 --pid-file="$ROOT/static.pid" > "$ROOT/static.log" 2>&1 & background+=("$!")
[[ $(fetch dynamic http://192.0.2.10:8080) == VPN ]]
[[ $(fetch static http://192.0.2.10:8080) == VPN ]]
ip netns exec gw wg show wg0 latest-handshakes | awk '$2 > 0 {found=1} END {exit !found}'
printf 'PASS: DHCP/static clients egress through a real local WireGuard tunnel\n'
[[ $(fetch dynamic http://10.200.0.1:8080) == LAN ]]
[[ $(fetch dynamic http://10.201.0.1:8080) == LAN ]]
[[ $(curl --noproxy '*' -fsS --max-time 4 http://10.200.0.21:8080) == STATIC ]]
[[ $(ip netns exec dynamic dig +short +time=2 +tries=1 @172.16.1.1 service.cluster.local A) == 10.200.0.1 ]]
[[ $(ip netns exec dynamic dig +short +time=2 +tries=1 @172.16.1.1 vpn.test A) == 192.0.2.10 ]]
[[ $(fetch peer http://198.18.0.1:18080) == STATIC ]]
[[ $(ip netns exec peer dig +short +time=2 +tries=1 @198.18.0.1 -p 18081 forward.test A) == 172.16.1.10 ]]
printf 'PASS: cluster/LAN bypass, conditional DNS and translated inbound static forwarding\n'

ip netns exec dynamic ping -n -c 1 -W 2 -M 'do' -s 1392 172.16.1.1 >/dev/null
if ip netns exec dynamic ping -n -c 1 -W 1 -M 'do' -s 1393 172.16.1.1 >/dev/null 2>&1; then printf 'MTU ceiling not enforced\n' >&2; exit 1; fi
rules_before=$(ip netns exec gw iptables-save | grep -v '^#')
role gw gateway-init
rules_after=$(ip netns exec gw iptables-save | grep -v '^#')
[[ "$rules_before" == "$rules_after" ]]
role dynamic client-init
[[ $(ip -n dynamic -j link show dev vxlan0 | jq -r '.[0].address') == "$(< "$ROOT/dynamic/state/vxlan-mac")" ]]
[[ $(fetch dynamic http://192.0.2.10:8080) == VPN ]]
printf 'PASS: MTU ceiling and repeat initialization without rule duplication\n'

kill -STOP "$cluster_pid"
ip -n dynamic link delete vxlan0
if role dynamic client-init 2>/dev/null; then printf 'unexpected discovery with DNS stopped\n' >&2; exit 1; fi
if fetch dynamic http://192.0.2.10:8080 2>/dev/null; then printf 'DNS-down fallback leak\n' >&2; exit 1; fi
kill -CONT "$cluster_pid"
role dynamic client-init
[[ $(fetch dynamic http://192.0.2.10:8080) == VPN ]]
printf 'PASS: failed gateway DNS discovery remains closed and recovers\n'

role dynamic client-sidecar > "$ROOT/client.log" 2>&1 & monitor_pid=$!; background+=("$monitor_pid")
printf '1\n' > "$ROOT/dynamic/state/renew-at"
renewed() { (( $(< "$ROOT/dynamic/state/renew-at") > 1 )); }
await renewed
[[ $(fetch dynamic http://192.0.2.10:8080) == VPN ]]
printf 'PASS: monitor renews a DHCP lease with stable client identity\n'
ip netns exec gw sysctl -w net.ipv4.conf.all.promote_secondaries=0 net.ipv4.conf.eth0.promote_secondaries=0 >/dev/null
ip -n gw addr del 10.200.0.10/24 dev eth0
ip -n gw addr add 10.200.0.15/24 dev eth0
ip -n gw -j -4 addr show dev eth0 | jq -e 'any(.[].addr_info[]; .local == "10.200.0.15")' >/dev/null
ip netns exec peer wg set wg0 peer "$gw_public" endpoint 10.200.0.15:51820
printf '10.200.0.15 gateway.example\n' > "$ROOT/gateway-hosts"
kill -HUP "$cluster_pid"
await grep -q 10.200.0.15 "$ROOT/dynamic/state/gateway-ip"
[[ $(fetch dynamic http://192.0.2.10:8080) == VPN ]]
printf 'PASS: gateway IP rediscovery and client reconnection\n'

ip -n gw link set wg0 down
ip -n gw route replace default via 10.200.0.1 dev eth0
if fetch dynamic http://192.0.2.10:8080 2>/dev/null; then printf 'VPN-down leak\n' >&2; exit 1; fi
if fetch gw http://192.0.2.10:8080 2>/dev/null; then printf 'gateway fallback leak\n' >&2; exit 1; fi
if fetch dynamic 'http://[2001:db8::10]:8080' 2>/dev/null; then printf 'IPv6 leak\n' >&2; exit 1; fi
[[ $(fetch dynamic http://10.200.0.1:8080) == LAN ]]
ip -n gw link set wg0 up
ip -n gw route replace default dev wg0
[[ $(fetch dynamic http://192.0.2.10:8080) == VPN ]]
kill -TERM "$monitor_pid"
wait "$monitor_pid"
kill -INT "$capture_pid"
wait "$capture_pid"
[[ $(tcpdump -nn -r "$ROOT/leaks.pcap" 2>/dev/null | wc -l) == 0 ]]
printf 'PASS: VPN-down and IPv6 fail-closed, permitted LAN retained, zero cleartext egress packets\n'
printf 'All isolated Linux networking tests passed.\n'