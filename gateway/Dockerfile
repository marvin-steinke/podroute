FROM docker.io/library/alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS runtime
RUN apk add --no-cache bash jq iproute2 iptables ip6tables dnsmasq-dnssec bind-tools iputils coreutils
COPY gateway /usr/local/lib/podroute
COPY --chmod=755 gateway/bin/entrypoint.sh /usr/local/bin/podroute
COPY LICENSE NOTICE /usr/share/licenses/podroute/
RUN chmod 755 /usr/local/lib/podroute/bin/*.sh && mkdir -p /run/podroute
ENTRYPOINT ["/usr/local/bin/podroute"]

FROM runtime AS test
RUN apk add --no-cache wireguard-tools curl tcpdump busybox-extras && busybox-extras --list | grep -qx httpd
COPY tests/network /opt/podroute-tests
ENTRYPOINT ["bash", "/opt/podroute-tests/isolated.sh"]