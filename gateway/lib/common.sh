#!/usr/bin/env bash

set -euo pipefail

PODROUTE_HOME=${PODROUTE_HOME:-/usr/local/lib/podroute}
STATE=${PODROUTE_STATE_DIR:-/run/podroute}
IPTABLES=${PODROUTE_IPTABLES:-iptables}
IP6TABLES=${PODROUTE_IP6TABLES:-ip6tables}

fail() { printf 'podroute: %s\n' "$*" >&2; exit 1; }
log() { printf 'podroute: %s\n' "$*" >&2; }
value() { jq -r "$1" <<< "$CONFIG"; }

load_config() {
  local input=${PODROUTE_CONFIG:-}
  if [[ -z "$input" ]]; then
    [[ -r "${PODROUTE_CONFIG_FILE:-/etc/podroute/network.json}" ]] || fail 'set PODROUTE_CONFIG or PODROUTE_CONFIG_FILE'
    input=$(< "${PODROUTE_CONFIG_FILE:-/etc/podroute/network.json}")
  fi
  (( ${#input} <= 32768 )) || fail 'network profile exceeds 32 KiB'
  CONFIG=$(jq -ce -f "$PODROUTE_HOME/lib/config.jq" <<< "$input") || fail 'invalid network profile'
  OVERLAY=$(value '.overlayCIDR')
  NETWORK=${OVERLAY%.*}
  OVERLAY_GATEWAY=$NETWORK.1
  VXLAN_ID=$(value '.vxlanID')
  VXLAN_PORT=$(value '.vxlanPort')
  VPN_IF=$(value '.vpnInterface')
  RETRY=$(value '.retrySeconds')
  export OVERLAY NETWORK OVERLAY_GATEWAY VXLAN_ID VXLAN_PORT VPN_IF RETRY
}

effective_mtu() {
  local underlay=$1 requested=$2
  [[ "$underlay" =~ ^[0-9]+$ && "$requested" =~ ^[0-9]+$ ]] || fail 'MTU must be numeric'
  local result=$((underlay - 50))
  if (( requested > 0 && requested < result )); then result=$requested; fi
  (( result >= 576 )) || fail 'underlay MTU is too small'
  printf '%s\n' "$result"
}

restore_filter() { "$IPTABLES"-restore -w 5 --noflush; }
ensure_jump() {
  local table=$1 builtin=$2 chain=$3
  if ! "$IPTABLES" -w 5 -t "$table" -C "$builtin" -j "$chain" 2>/dev/null; then
    "$IPTABLES" -w 5 -t "$table" -I "$builtin" 1 -j "$chain"
  fi
}

guard_ipv6() {
  "$IP6TABLES"-restore -w 5 --noflush <<'RULES'
*filter
:PR6_OUT - [0:0]
:PR6_FWD - [0:0]
-F PR6_OUT
-F PR6_FWD
-A PR6_OUT -o lo -j ACCEPT
-A PR6_OUT -j DROP
-A PR6_FWD -j DROP
COMMIT
RULES
  local chain builtin
  for builtin in OUTPUT FORWARD; do
    chain=PR6_OUT; [[ "$builtin" != FORWARD ]] || chain=PR6_FWD
    if ! "$IP6TABLES" -w 5 -C "$builtin" -j "$chain" 2>/dev/null; then "$IP6TABLES" -w 5 -I "$builtin" 1 -j "$chain"; fi
  done
}

client_guard() {
  local gateway=${1:-} cidr upstream
  mkdir -p "$STATE"
  export XTABLES_LOCKFILE=$STATE/xtables.lock
  {
    printf '*filter\n:PR_CLIENT - [0:0]\n-F PR_CLIENT\n'
    printf '%s\n' '-A PR_CLIENT -o lo -j ACCEPT' '-A PR_CLIENT -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT'
    printf '%s\n' '-A PR_CLIENT -o vxlan0 -j ACCEPT'
    printf -- '-A PR_CLIENT -o eth0 -d %s -j DROP\n' "$OVERLAY"
    if [[ -n "$gateway" ]]; then printf -- '-A PR_CLIENT -o eth0 -d %s -p udp --dport %s -j ACCEPT\n' "$gateway" "$VXLAN_PORT"; fi
    while IFS= read -r upstream; do
      printf -- '-A PR_CLIENT -o eth0 -d %s -p udp --dport 53 -j ACCEPT\n' "$upstream"
      printf -- '-A PR_CLIENT -o eth0 -d %s -p tcp --dport 53 -j ACCEPT\n' "$upstream"
    done < <(value '.clusterDNS[]')
    while IFS= read -r cidr; do printf -- '-A PR_CLIENT -o eth0 -d %s -j ACCEPT\n' "$cidr"; done < <(value '.clientBypassCIDRs[]')
    printf '%s\n' '-A PR_CLIENT -j DROP' COMMIT
  } | restore_filter
  ensure_jump filter OUTPUT PR_CLIENT
  guard_ipv6
}

underlay_route() {
  local destination=$1 gateway=$2
  if [[ -n "$(ip -4 route show exact "$destination" scope link dev eth0)" ]]; then return; fi
  ip -4 route replace "$destination" via "$gateway" dev eth0
}

underlay_routes() {
  mkdir -p "$STATE"
  local gateway cidr upstream
  gateway=$(ip -4 route show default dev eth0 | awk '/via/ {print $3; exit}')
  if [[ -n "$gateway" ]]; then printf '%s\n' "$gateway" > "$STATE/underlay-gateway"; fi
  [[ -s "$STATE/underlay-gateway" ]] || fail 'no original eth0 default gateway found'
  gateway=$(< "$STATE/underlay-gateway")
  ip -4 route replace "$gateway/32" dev eth0 scope link
  while IFS= read -r cidr; do underlay_route "$cidr" "$gateway"; done < <(value '.clientBypassCIDRs[]')
  while IFS= read -r upstream; do underlay_route "$upstream/32" "$gateway"; done < <(value '.clusterDNS[]')
}

resolve_gateway() {
  local host upstream result
  host=$(value '.gatewayHost')
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then printf '%s\n' "$host"; return; fi
  while IFS= read -r upstream; do
    result=$(timeout 4 dig +time=1 +tries=1 +short A "$host" "@$upstream" | jq -Rsc 'split("\n") | map(select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))) | unique') || continue
    if [[ $(jq 'length' <<< "$result") == 1 ]]; then jq -r '.[0]' <<< "$result"; return; fi
  done < <(value '.clusterDNS[]')
  return 1
}

create_vxlan() {
  local remote=${1:-} mtu
  if ip link show dev vxlan0 >/dev/null 2>&1; then
    if [[ -z "$remote" ]]; then
      ip -j -d link show dev vxlan0 | jq -e --argjson id "$VXLAN_ID" --argjson port "$VXLAN_PORT" '.[0].linkinfo | .info_kind == "vxlan" and .info_data.id == $id and .info_data.port == $port' >/dev/null || fail 'existing vxlan0 does not match profile'
      return
    fi
    ip link delete dev vxlan0
  fi
  local -a args=(type vxlan id "$VXLAN_ID" dev eth0 dstport "$VXLAN_PORT")
  if [[ -n "$remote" ]]; then args+=(remote "$remote"); fi
  ip link add vxlan0 "${args[@]}"
  if [[ -n "$remote" ]]; then
    if [[ -s "$STATE/vxlan-mac" ]]; then
      ip link set dev vxlan0 address "$(< "$STATE/vxlan-mac")"
    else
      ip -j link show dev vxlan0 | jq -r '.[0].address' > "$STATE/vxlan-mac"
    fi
  fi
  mtu=$(effective_mtu "$(< "${PODROUTE_SYS_NET:-/sys/class/net}/eth0/mtu")" "$(value '.mtu')")
  ip link set dev vxlan0 mtu "$mtu" up
}

gateway_guard() {
  local cidr upstream protocol port address target external
  mkdir -p "$STATE"
  export XTABLES_LOCKFILE=$STATE/xtables.lock
  {
    printf '*filter\n:PR_G_OUT - [0:0]\n:PR_G_FWD - [0:0]\n:PR_G_IN - [0:0]\n-F PR_G_OUT\n-F PR_G_FWD\n-F PR_G_IN\n'
    printf '%s\n' '-A PR_G_OUT -o lo -j ACCEPT' '-A PR_G_OUT -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT'
    printf -- '-A PR_G_OUT -o %s -j ACCEPT\n' "$VPN_IF"
    printf '%s\n' '-A PR_G_OUT -o vxlan0 -j ACCEPT'
    printf -- '-A PR_G_OUT -o eth0 -p udp --dport %s -j ACCEPT\n' "$VXLAN_PORT"
    protocol=$(value '.vpnProtocol'); port=$(value '.vpnPort')
    if [[ $(value '.vpnEndpointCIDRs | length') == 0 ]]; then
      printf -- '-A PR_G_OUT -o eth0 -p %s --dport %s -j ACCEPT\n' "$protocol" "$port"
    else
      while IFS= read -r cidr; do printf -- '-A PR_G_OUT -o eth0 -d %s -p %s --dport %s -j ACCEPT\n' "$cidr" "$protocol" "$port"; done < <(value '.vpnEndpointCIDRs[]')
    fi
    while IFS= read -r upstream; do
      printf -- '-A PR_G_OUT -o eth0 -d %s -p udp --dport 53 -j DROP\n' "$upstream"
      printf -- '-A PR_G_OUT -o eth0 -d %s -p tcp --dport 53 -j DROP\n' "$upstream"
    done < <(value '.upstreamDNS[]')
    while IFS= read -r upstream; do
      printf -- '-A PR_G_OUT -o eth0 -d %s -p udp --dport 53 -j ACCEPT\n' "$upstream"
      printf -- '-A PR_G_OUT -o eth0 -d %s -p tcp --dport 53 -j ACCEPT\n' "$upstream"
    done < <(value '.clusterDNS[]')
    while IFS= read -r cidr; do
      printf -- '-A PR_G_OUT -o eth0 -d %s -j ACCEPT\n' "$cidr"
      printf -- '-A PR_G_FWD -i vxlan0 -o eth0 -d %s -j ACCEPT\n' "$cidr"
    done < <(value '.gatewayBypassCIDRs[]')
    printf '%s\n' '-A PR_G_OUT -j DROP' '-A PR_G_FWD -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT'
    printf -- '-A PR_G_FWD -i vxlan0 -o %s -j ACCEPT\n' "$VPN_IF"
    while IFS=$'\t' read -r address protocol external target; do
      [[ -n "$address" ]] || continue
      printf -- '-A PR_G_FWD -i %s -o vxlan0 -d %s -p %s --dport %s -j ACCEPT\n' "$VPN_IF" "$address" "$protocol" "$target"
    done < <(jq -r '.staticClients[] | .address as $ip | .ports[]? | [$ip,.protocol,.externalPort,.targetPort] | @tsv' <<< "$CONFIG")
    printf '%s\n' '-A PR_G_FWD -j DROP'
    printf -- '-A PR_G_IN -i eth0 -p udp --dport %s -j ACCEPT\n' "$VXLAN_PORT"
    printf '%s\n' '-A PR_G_IN -i vxlan0 -p udp --sport 68 --dport 67 -j ACCEPT' '-A PR_G_IN -i vxlan0 -p udp --dport 53 -j ACCEPT' '-A PR_G_IN -i vxlan0 -p tcp --dport 53 -j ACCEPT'
    printf -- '-A PR_G_IN -i %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n' "$VPN_IF"
    printf -- '-A PR_G_IN -i %s -j DROP\n' "$VPN_IF"
    printf '%s\n' '-A PR_G_IN -j RETURN' COMMIT
  } | restore_filter
  ensure_jump filter OUTPUT PR_G_OUT
  ensure_jump filter FORWARD PR_G_FWD
  ensure_jump filter INPUT PR_G_IN
  guard_ipv6
}

gateway_nat() {
  local address protocol external target cidr
  {
    printf '*nat\n:PR_SNAT - [0:0]\n:PR_DNAT - [0:0]\n-F PR_SNAT\n-F PR_DNAT\n'
    printf -- '-A PR_SNAT -s %s -o %s -j MASQUERADE\n' "$OVERLAY" "$VPN_IF"
    while IFS= read -r cidr; do printf -- '-A PR_SNAT -s %s -o eth0 -d %s -j MASQUERADE\n' "$OVERLAY" "$cidr"; done < <(value '.gatewayBypassCIDRs[]')
    while IFS=$'\t' read -r address protocol external target; do
      [[ -n "$address" ]] || continue
      printf -- '-A PR_DNAT -i %s -p %s --dport %s -j DNAT --to-destination %s:%s\n' "$VPN_IF" "$protocol" "$external" "$address" "$target"
    done < <(jq -r '.staticClients[] | .address as $ip | .ports[]? | [$ip,.protocol,.externalPort,.targetPort] | @tsv' <<< "$CONFIG")
    printf 'COMMIT\n'
  } | "$IPTABLES"-restore -w 5 --noflush
  ensure_jump nat POSTROUTING PR_SNAT
  ensure_jump nat PREROUTING PR_DNAT
}