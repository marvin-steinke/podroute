FROM docker.io/library/alpine:3.24.4@sha256:93b41ef40b1677fce8fcc64ff4af09daddfacf5040afde618bc46c1e2d1cc7d4 AS runtime
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