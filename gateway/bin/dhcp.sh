#!/usr/bin/env bash
set -euo pipefail
source "${PODROUTE_HOME:-/usr/local/lib/podroute}/lib/common.sh"
load_config
[[ ${interface:-} == vxlan0 ]] || fail 'unexpected DHCP interface'
case ${1:-} in
  bound|renew)
    jq -ne --arg address "${ip:-}" --arg network "$NETWORK" --argjson start "$(value '.dhcpStart')" \
      '$address | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$") and startswith($network + ".") and (split(".")[3] | tonumber >= $start and tonumber <= 254)' >/dev/null || fail 'DHCP address outside configured pool'
    ip -4 addr replace "$ip/24" dev vxlan0
    ip -4 route replace default via "$OVERLAY_GATEWAY" dev vxlan0
    duration=${lease:-3600}
    if [[ ! "$duration" =~ ^[0-9]+$ ]] || (( duration < 60 || duration > 2147483647 )); then fail 'invalid DHCP lease duration'; fi
    printf '%s\n' "$(($(date +%s) + duration / 2))" > "$STATE/renew-at"
    ;;
  deconfig|nak|leasefail) ;;
  *) fail 'unexpected DHCP event' ;;
esac