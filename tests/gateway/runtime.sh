#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} != inside ]]; then
  "${CONTAINER:-podman}" run --rm -i --network none --read-only --cap-drop ALL \
    --cap-add NET_ADMIN --cap-add NET_RAW --cap-add NET_BIND_SERVICE --cap-add SETGID \
    --sysctl net.ipv4.ip_forward=1 --tmpfs /run/podroute:rw --entrypoint bash \
    podroute-gateway:local -s -- inside < "$0"
  "${CONTAINER:-podman}" run --rm --network none --read-only --cap-drop ALL podroute-controller:local -h >/dev/null 2>&1
  printf 'Non-root controller image execution passed.\n'
  exit
fi
export PODROUTE_CONFIG='{"gatewayHost":"10.200.0.11","clusterDNS":["10.200.0.1"]}'
ip link add eth0 type dummy
ip addr add 10.200.0.10/24 dev eth0
ip link set eth0 up
ip route add default via 10.200.0.1
podroute gateway-init
ip link add wg0 type wireguard
result=0
timeout 2 podroute gateway-sidecar > /run/podroute/dns.log 2>&1 || result=$?
[[ $result == 124 ]]
grep -q 'started, version' /run/podroute/dns.log
grep -q 'DNSSEC validation enabled' /run/podroute/dns.log
result=0
podroute > /run/podroute/usage.log 2>&1 || result=$?
[[ $result == 2 ]]
printf 'Read-only reduced-capability gateway and DNSSEC smoke passed.\n'