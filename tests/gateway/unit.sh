#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export PODROUTE_HOME=$ROOT/gateway
source "$PODROUTE_HOME/lib/common.sh"
[[ $(effective_mtu 1500 1420) == 1420 ]]
[[ $(effective_mtu 1500 1500) == 1450 ]]
[[ $(effective_mtu 1500 0) == 1450 ]]
if (effective_mtu broken 1420) 2>/dev/null; then exit 1; fi
export PODROUTE_CONFIG='{"gatewayHost":"gateway.example","clusterDNS":["10.43.0.10"]}'
load_config
[[ "$OVERLAY_GATEWAY" == 172.16.1.1 ]]
[[ "$VXLAN_PORT" == 4789 ]]
for invalid in '{"gatewayHost":"gateway","clusterDNS":[]}' \
  '{"gatewayHost":"gateway","clusterDNS":["172.16.1.1"]}' \
  '{"gatewayHost":"gateway","clusterDNS":["10.43.0.10"],"vxlanPort":0}' \
  '{"gatewayHost":"gateway","clusterDNS":["10.43.0.10"],"typo":true}' \
  '{"gatewayHost":"gateway","clusterDNS":["10.43.0.10"],"staticClients":[{"id":"app","address":"172.16.1.255"}]}' \
  '{"gatewayHost":"gateway","clusterDNS":["10.43.0.10"],"clientBypassCIDRs":["0.0.0.0/0"]}'; do
  if (PODROUTE_CONFIG=$invalid; load_config) 2>/dev/null; then printf 'accepted invalid config: %s\n' "$invalid" >&2; exit 1; fi
done
printf 'Gateway configuration and MTU tests passed.\n'