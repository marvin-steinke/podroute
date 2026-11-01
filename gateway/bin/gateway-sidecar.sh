#!/usr/bin/env bash
set -euo pipefail
source "${PODROUTE_HOME:-/usr/local/lib/podroute}/lib/common.sh"
load_config
mkdir -p "$STATE"
child=
terminate() { if [[ -n "$child" ]]; then kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi; exit 0; }
trap terminate TERM INT
until ip link show dev "$VPN_IF" >/dev/null 2>&1; do
  log "waiting for VPN interface $VPN_IF; gateway firewall remains closed"
  sleep "$RETRY" & child=$!; wait "$child"; child=
done
{
  printf 'interface=vxlan0\nbind-dynamic\nno-resolv\nno-hosts\nuser=root\ngroup=root\n'
  printf 'dhcp-range=%s.%s,%s.254,255.255.255.0,12h\n' "$NETWORK" "$(value '.dhcpStart')" "$NETWORK"
  printf 'dhcp-option=option:router,%s\ndhcp-option=option:dns-server,%s\n' "$OVERLAY_GATEWAY" "$OVERLAY_GATEWAY"
  printf 'dhcp-leasefile=%s/leases\npid-file=%s/dnsmasq.pid\nlog-facility=-\n' "$STATE" "$STATE"
  while IFS= read -r upstream; do printf 'server=%s@%s\n' "$upstream" "$VPN_IF"; done < <(value '.upstreamDNS[]')
  while IFS= read -r domain; do
    while IFS= read -r upstream; do printf 'server=/%s/%s@eth0\n' "$domain" "$upstream"; done < <(value '.clusterDNS[]')
  done < <(value '[.clusterDomain,.localDomains[]] | unique[]')
  if [[ $(value '.dnssec') == true ]]; then
    printf 'dnssec\nconf-file=%s\n' "${PODROUTE_TRUST_ANCHORS:-/usr/share/dnsmasq/trust-anchors.conf}"
  fi
} > "$STATE/dnsmasq.conf"
dnsmasq --test --conf-file="$STATE/dnsmasq.conf"
exec dnsmasq --keep-in-foreground --conf-file="$STATE/dnsmasq.conf"