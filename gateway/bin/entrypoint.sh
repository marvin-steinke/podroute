#!/usr/bin/env bash
set -euo pipefail
export PODROUTE_HOME=${PODROUTE_HOME:-/usr/local/lib/podroute}
case ${1:-} in
  client-init|client-sidecar|gateway-init|gateway-sidecar)
    role=$1; shift
    exec bash "$PODROUTE_HOME/bin/$role.sh" "$@"
    ;;
  *) printf 'usage: podroute {client-init|client-sidecar|gateway-init|gateway-sidecar}\n' >&2; exit 2 ;;
esac