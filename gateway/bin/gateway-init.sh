#!/usr/bin/env bash
set -euo pipefail
source "${PODROUTE_HOME:-/usr/local/lib/podroute}/lib/common.sh"
load_config
gateway_guard
mkdir -p "$STATE"
underlay=$(ip -4 route show default dev eth0 | awk '/via/ {print $3; exit}')
if [[ -n "$underlay" ]]; then printf '%s\n' "$underlay" > "$STATE/underlay-gateway"; fi
if [[ -s "$STATE/underlay-gateway" ]]; then ip -4 route replace "$(< "$STATE/underlay-gateway")/32" dev eth0 scope link; fi
while IFS= read -r cidr; do
  [[ -s "$STATE/underlay-gateway" ]] || fail 'gateway bypass requires original eth0 gateway'
  underlay_route "$cidr" "$(< "$STATE/underlay-gateway")"
done < <(value '.gatewayBypassCIDRs[]')
while IFS= read -r upstream; do
  [[ -s "$STATE/underlay-gateway" ]] || fail 'cluster DNS requires original eth0 gateway'
  underlay_route "$upstream/32" "$(< "$STATE/underlay-gateway")"
done < <(value '.clusterDNS[]')
create_vxlan ""
ip -4 addr replace "$OVERLAY_GATEWAY/24" dev vxlan0
gateway_nat
if [[ $(< /proc/sys/net/ipv4/ip_forward) != 1 ]]; then sysctl -w net.ipv4.ip_forward=1 >/dev/null; fi
log "gateway initialized; only $VPN_IF and explicit local bypasses permit forwarding"