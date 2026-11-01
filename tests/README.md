# Tests

PodRoute tests configuration validation, admission mutation, container startup,
and routing through an isolated local WireGuard tunnel. The shell suites live
here; Go tests live beside their packages under `internal/`.

## Running the Suites

Run these commands from the repository root:

```sh
make test                 # Go tests with the race detector, then shell unit tests
make lint                 # Go formatting/vet, ShellCheck, and Bash syntax checks
make images               # Build both local runtime images
make test-runtime         # Smoke-test the images built above
make test-network         # Build and run the isolated networking test image
```

The container engine defaults to Podman. To use Docker:

```sh
make images test-runtime test-network CONTAINER=docker
```

Local checks require Go 1.25+, Bash, and jq; lint also requires ShellCheck.
The Go configuration tests invoke jq, so even `go test` needs it on `PATH`.
Container tests require a Linux engine with VXLAN, WireGuard, IPv6 netfilter,
and network namespace support. On macOS, these run in the engine's Linux VM.
Building images or downloading dependencies may require network access.

`make test` does not run either container suite. Shell assertions stop the script
on failure; the networking suite also prints namespace diagnostics and recent logs.

## CI And Release Tests

[CI](../.github/workflows/ci.yml) runs for every PR, including forks and
documentation-only changes, and for pushes to `main`. `Unit And Lint` runs
`make test lint build`; `Containers` runs both image builds and both container
suites on an ephemeral Ubuntu x64 runner. `Automation` tests the release helpers,
validates workflow syntax with actionlint, and validates the Renovate configuration.
`CI Gate` succeeds only if all three jobs succeed; failures, skips and cancellations
do not satisfy it. Repository protection must require this check.

Run the release-helper tests locally with Node.js 22+ and jq:

```sh
node --test .github/scripts/release.test.cjs
```

These tests use temporary Git repositories and mocked GitHub, registry and Docker
operations. They cover bot identity, human-change pauses, numeric versions,
tag allocation collisions, dispatch retries, image provenance and partial-push
recovery; they do not create remote tags or publish anything. Workflow validation
uses actionlint 1.7.12 with only its unsupported `concurrency.queue` diagnostic
excluded; a focused helper test checks the required `queue: max` configuration.

The release workflow retests the exact tagged source and publishes the same local
runtime images it tested, without rebuilding them after the container checks.
See [workflow and release operations](../.github/workflows/README.md) for setup.

## Go Tests

Run all Go tests with `go test -race ./...`, or one package with, for example,
`go test -race ./internal/config`.

### Configuration

Source: [internal/config/config_test.go](../internal/config/config_test.go).

| Test | Cases and assertions |
| --- | --- |
| `TestDecode` | Accepts a minimal valid profile; defaults the overlay gateway to `172.16.1.1` and enables native sidecars. Rejects trailing JSON, unknown fields, the `kube-system` workload namespace, and cluster DNS overlapping the overlay. |
| `TestNetworkValidation` | Rejects an overlay CIDR with host bits, VXLAN port zero, VPN interface `eth0`, a default-route bypass, a noncanonical bypass CIDR, an invalid gateway IP, a malformed cluster domain, duplicate or loopback DNS addresses, DHCP start `255`, a static address in the DHCP pool, and duplicate external TCP ports. Each invalid case must fail both Go validation and the jq runtime validator; the valid baseline must pass jq. |
| `TestExampleProfile` | Decodes the checked-in example controller profile and validates its network settings with jq. |

### Pod Mutation

Source: [internal/mutation/pod_test.go](../internal/mutation/pod_test.go).

`TestMutation` runs the same cases for regular and native sidecars:

- Leaves the caller's Pod unchanged and preserves its application container.
- Inserts `podroute-init` before the existing application init container.
- Uses the admission namespace for the `vpn.svc.cluster.local` DNS search suffix
  when the Pod has no namespace set.
- Checks that the native sidecar has a restart policy when native mode is enabled.
- Returns no mutation when reinvoked on an already injected Pod.
- Rejects a conflicting injected init image and host-networked selected Pods.
- Leaves Pods in unselected namespaces and non-Pod objects unchanged.

### Webhook and Server

Source: [internal/webhook/server_test.go](../internal/webhook/server_test.go).

| Test | Cases and assertions |
| --- | --- |
| `TestAdmission` | Exercises ordinary and dry-run CREATE requests. Checks an allowed response with the original UID and a base64-encoded JSONPatch containing `client-init`; applies the patch and verifies two init containers, overlay DNS, and the preserved application container. Reinvocation returns an empty patch, and host-networked Pods are not accepted. Also checks `/healthz` returns 200 and malformed admission input returns a non-200 response. |
| `TestTLS` | Loads a temporary certificate/key pair, checks the minimum TLS version is TLS 1.2, and completes an HTTPS request to a test server using that TLS configuration. |
| `TestServerSafety` | Rejects missing TLS credentials in secure mode, a non-loopback insecure listener, missing certificate files, and a partial certificate/key configuration. Accepts explicit insecure loopback mode and checks clean shutdown with an already canceled context. |

## Gateway Shell Unit Tests

Source: [gateway/unit.sh](gateway/unit.sh). Run with
`bash tests/gateway/unit.sh` or as part of `make test`.

- **MTU selection:** `1500/1420` produces `1420`; `1500/1500` and `1500/0`
  produce `1450`, accounting for VXLAN overhead. A nonnumeric underlay MTU fails.
- **Configuration defaults:** a minimal configuration loads with overlay gateway
  `172.16.1.1` and VXLAN port `4789`.
- **Invalid configuration:** rejects empty cluster DNS, DNS overlapping the
  overlay, VXLAN port zero, unknown fields, a static broadcast address, and a
  client bypass of `0.0.0.0/0`.

## Container Runtime Smoke Tests

Source: [gateway/runtime.sh](gateway/runtime.sh). Run `make images` first,
then `make test-runtime`.

The gateway container has no external network, a read-only root filesystem, a
writable `/run/podroute` tmpfs, and all capabilities dropped except `NET_ADMIN`,
`NET_RAW`, `NET_BIND_SERVICE`, and `SETGID`. IPv4 forwarding is enabled.

- Creates a dummy underlay interface and runs gateway initialization.
- Creates a WireGuard interface and runs the gateway sidecar for two seconds.
  Expects timeout exit code `124`, proving the process stayed running, and checks
  dnsmasq startup and DNSSEC-enabled log messages.
- Invokes `podroute` without a role and expects usage exit code `2`.
- Runs the controller image's help command successfully as its configured
  non-root user, with no network, a read-only filesystem, and no capabilities.

The DNSSEC assertion checks startup configuration, not signed-answer validation.

## Isolated Networking Tests

Source: [network/isolated.sh](network/isolated.sh). Run `make test-network`.

The target builds the gateway Dockerfile's `test` stage and runs it privileged
with `--network none`, no host mounts, and no engine socket. The fixture creates
gateway, VPN peer, dynamic-client, and static-client network namespaces connected
by a local underlay bridge. HTTP and DNS endpoints and generated WireGuard keys
are synthetic and local; no VPN provider or Kubernetes cluster is required.

| Case | What is checked |
| --- | --- |
| Kernel prerequisites | VXLAN and WireGuard links can be created; IPv4/IPv6 firewall access and network namespace creation work. |
| Before VPN startup | The initialized gateway cannot reach the synthetic Internet HTTP endpoint directly. |
| VPN egress | DHCP and static clients both receive the `VPN` response through a real local WireGuard tunnel, and the gateway records a handshake. The direct-underlay endpoint at the same destination returns `LEAK`, distinguishing the paths. |
| Bypass and ingress replies | The dynamic client reaches both a directly bypassed LAN address and a gateway-bypassed LAN address. An underlay request to the static client's HTTP service succeeds. |
| Conditional DNS | A cluster-domain lookup resolves through cluster DNS; `vpn.test` resolves through the VPN-side upstream DNS server. |
| Static inbound forwarding | The VPN peer reaches the static client through TCP `18080 -> 8080` and UDP `18081 -> 8053`, checking both HTTP and DNS responses. |
| MTU ceiling | An IPv4 ping with a 1392-byte payload succeeds at MTU 1420; a 1393-byte payload with fragmentation forbidden fails. |
| Repeat initialization | Running gateway initialization again leaves firewall rules unchanged. Reinitializing the dynamic client preserves its recorded VXLAN MAC and working VPN egress. |
| Gateway discovery failure | With cluster DNS paused and the client's VXLAN removed, client initialization fails and direct fallback stays blocked. Resuming DNS allows initialization and VPN egress to recover. |
| DHCP renewal | Forcing the recorded renewal time into the past causes the client monitor to update it; VPN egress still works afterward. |
| Gateway address change | With secondary-address promotion explicitly disabled, replaces the old gateway underlay address, verifies the replacement exists, and updates DNS. The client monitor must rediscover the address and restore working egress. |
| VPN outage and recovery | With WireGuard down and an underlay default route restored, client and gateway direct IPv4 egress fail, client IPv6 egress fails, and permitted LAN access still works. Restoring WireGuard restores VPN egress. |
| Cleartext capture | The underlay packet capture contains zero packets to the synthetic IPv4 Internet HTTP endpoint on TCP port 8080. This is a targeted leak check, not a capture of all possible traffic. |

An exit trap terminates fixture processes and removes its namespaces and bridge.
These are local Linux integration tests, not Kubernetes API-server, deployment,
external VPN-provider, or production performance tests.