#!/usr/bin/env bash
set -euo pipefail
source "${PODROUTE_HOME:-/usr/local/lib/podroute}/lib/common.sh"
load_config
child=
terminate() { if [[ -n "$child" ]]; then kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi; exit 0; }
trap terminate TERM INT
while true; do
  gateway=$(resolve_gateway) || gateway=
  previous=
  if [[ -s "$STATE/gateway-ip" ]]; then previous=$(< "$STATE/gateway-ip"); fi
  renew=0
  if [[ -z "${PODROUTE_CLIENT_ID:-}" && -s "$STATE/renew-at" ]]; then renew=$(< "$STATE/renew-at"); fi
  if [[ -z "$gateway" || "$gateway" != "$previous" ]] || { (( renew > 0 )) && (( $(date +%s) >= renew )); } || ! timeout 4 ping -n -c 1 -W 2 "$OVERLAY_GATEWAY" >/dev/null 2>&1; then
    rm -f "$STATE/ready"
    bash "$PODROUTE_HOME/bin/client-init.sh" & child=$!
    if ! wait "$child"; then log 'reconnection failed; retrying without underlay fallback'; fi
    child=
  fi
  sleep "$RETRY" & child=$!
  wait "$child"
  child=
done