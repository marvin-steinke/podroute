#!/usr/bin/env bash
set -euo pipefail
source "${PODROUTE_HOME:-/usr/local/lib/podroute}/lib/common.sh"
load_config
child=
terminate() { if [[ -n "$child" ]]; then kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi; exit 143; }
trap terminate TERM INT
client_guard
mkdir -p "$STATE"
rm -f "$STATE/ready"
underlay_routes
gateway=$(resolve_gateway) || fail 'gateway discovery failed; direct Internet egress remains blocked'
client_guard "$gateway"
ip -4 route replace "$gateway/32" via "$(< "$STATE/underlay-gateway")" dev eth0
if ip -4 route show default dev eth0 | grep -q .; then ip -4 route del default dev eth0; fi
create_vxlan "$gateway"
if [[ -n "${PODROUTE_CLIENT_ID:-}" ]]; then
  address=$(jq -er --arg id "$PODROUTE_CLIENT_ID" '.staticClients[] | select(.id == $id) | .address' <<< "$CONFIG") || fail 'unknown static client ID'
  ip -4 addr replace "$address/24" dev vxlan0
  ip -4 route replace default via "$OVERLAY_GATEWAY" dev vxlan0
else
  timeout 25 udhcpc --foreground --quit --now --retries 3 --timeout 3 --interface vxlan0 \
    --pidfile "$STATE/udhcpc.pid" --script "$PODROUTE_HOME/bin/dhcp.sh" & child=$!
  wait "$child"
  child=
fi
timeout 4 ping -n -c 1 -W 2 "$OVERLAY_GATEWAY" >/dev/null || fail 'overlay gateway unreachable; egress remains blocked'
printf '%s\n' "$gateway" > "$STATE/gateway-ip"
touch "$STATE/ready"
log "client connected through $gateway ($OVERLAY_GATEWAY)"