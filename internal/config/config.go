package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/netip"
	"regexp"
	"strings"
)

type Port struct {
	Protocol     string `json:"protocol"`
	ExternalPort int    `json:"externalPort"`
	TargetPort   int    `json:"targetPort"`
}

type StaticClient struct {
	ID      string `json:"id"`
	Address string `json:"address"`
	Ports   []Port `json:"ports,omitempty"`
}

type Network struct {
	GatewayHost        string         `json:"gatewayHost"`
	OverlayCIDR        string         `json:"overlayCIDR"`
	VXLANID            int            `json:"vxlanID"`
	VXLANPort          int            `json:"vxlanPort"`
	VPNInterface       string         `json:"vpnInterface"`
	VPNProtocol        string         `json:"vpnProtocol"`
	VPNPort            int            `json:"vpnPort"`
	VPNEndpointCIDRs   []string       `json:"vpnEndpointCIDRs,omitempty"`
	ClientBypassCIDRs  []string       `json:"clientBypassCIDRs,omitempty"`
	GatewayBypassCIDRs []string       `json:"gatewayBypassCIDRs,omitempty"`
	ClusterDNS         []string       `json:"clusterDNS"`
	UpstreamDNS        []string       `json:"upstreamDNS"`
	LocalDomains       []string       `json:"localDomains,omitempty"`
	ClusterDomain      string         `json:"clusterDomain"`
	DNSSEC             bool           `json:"dnssec"`
	DHCPStart          int            `json:"dhcpStart"`
	MTU                int            `json:"mtu,omitempty"`
	RetrySeconds       int            `json:"retrySeconds"`
	StaticClients      []StaticClient `json:"staticClients,omitempty"`
}

type Profile struct {
	HelperImage   string   `json:"helperImage"`
	Namespaces    []string `json:"namespaces"`
	NativeSidecar bool     `json:"nativeSidecar"`
	Network       Network  `json:"network"`
}

func Defaults() Profile {
	return Profile{NativeSidecar: true, Network: Network{
		OverlayCIDR: "172.16.1.0/24", VXLANID: 42, VXLANPort: 4789,
		VPNInterface: "wg0", VPNProtocol: "udp", VPNPort: 51820,
		ClusterDomain: "cluster.local", DHCPStart: 20, RetrySeconds: 10, DNSSEC: true, UpstreamDNS: []string{"1.1.1.1", "9.9.9.9"},
	}}
}

func Decode(reader io.Reader) (Profile, error) {
	profile := Defaults()
	decoder := json.NewDecoder(io.LimitReader(reader, 65537))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&profile); err != nil {
		return Profile{}, fmt.Errorf("configuration: %w", err)
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return Profile{}, fmt.Errorf("configuration must contain one JSON object")
	}
	return profile, profile.Validate()
}

var identifier = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{0,62}$`)
var namespaceName = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)
var hostname = regexp.MustCompile(`^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.?$`)
var numericAddress = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$`)
var nic = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,14}$`)

func (profile Profile) Validate() error {
	if strings.TrimSpace(profile.HelperImage) == "" || strings.ContainsAny(profile.HelperImage, " \t\r\n") {
		return fmt.Errorf("helperImage is required and cannot contain whitespace")
	}
	if len(profile.Namespaces) == 0 {
		return fmt.Errorf("namespaces must explicitly select at least one application namespace")
	}
	seen := map[string]bool{}
	for _, namespace := range profile.Namespaces {
		if !namespaceName.MatchString(namespace) || namespace == "default" || strings.HasPrefix(namespace, "kube-") || seen[namespace] {
			return fmt.Errorf("invalid, duplicate or protected namespace %q", namespace)
		}
		seen[namespace] = true
	}
	return profile.Network.Validate()
}

func (network Network) Validate() error {
	overlay, err := netip.ParsePrefix(network.OverlayCIDR)
	if err != nil || !overlay.Addr().Is4() || overlay.Bits() != 24 || overlay.Masked() != overlay {
		return fmt.Errorf("overlayCIDR must be an IPv4 /24 network")
	}
	if len(network.GatewayHost) > 253 || !hostname.MatchString(network.GatewayHost) {
		return fmt.Errorf("gatewayHost must be an IPv4 address or DNS hostname")
	}
	if numericAddress.MatchString(network.GatewayHost) {
		address, err := netip.ParseAddr(network.GatewayHost)
		if err != nil || !address.Is4() || !address.IsGlobalUnicast() || overlay.Contains(address) {
			return fmt.Errorf("gatewayHost must name an underlay unicast IPv4 address")
		}
	}
	if !nic.MatchString(network.VPNInterface) || network.VPNInterface == "eth0" || network.VPNInterface == "vxlan0" || network.VPNInterface == "lo" {
		return fmt.Errorf("vpnInterface must name a dedicated VPN interface")
	}
	if network.VXLANID < 1 || network.VXLANID > 16777215 || network.VXLANPort < 1 || network.VXLANPort > 65535 {
		return fmt.Errorf("invalid VXLAN ID or UDP port")
	}
	if network.VPNProtocol != "udp" && network.VPNProtocol != "tcp" {
		return fmt.Errorf("vpnProtocol must be udp or tcp")
	}
	if network.VPNPort < 1 || network.VPNPort > 65535 || network.DHCPStart < 3 || network.DHCPStart > 254 || network.RetrySeconds < 1 || network.RetrySeconds > 300 {
		return fmt.Errorf("invalid VPN port, DHCP start or retry interval")
	}
	if network.MTU != 0 && (network.MTU < 576 || network.MTU > 9000) {
		return fmt.Errorf("mtu must be zero (automatic) or 576..9000")
	}
	for _, cidrs := range [][]string{network.ClientBypassCIDRs, network.GatewayBypassCIDRs, network.VPNEndpointCIDRs} {
		for _, cidr := range cidrs {
			prefix, err := netip.ParsePrefix(cidr)
			if err != nil || !prefix.Addr().Is4() || prefix.Bits() == 0 || prefix.Masked() != prefix {
				return fmt.Errorf("invalid IPv4 CIDR %q (default-route bypass forbidden)", cidr)
			}
		}
	}
	if len(network.ClusterDomain) > 253 || !hostname.MatchString(network.ClusterDomain) {
		return fmt.Errorf("invalid clusterDomain")
	}
	for _, domain := range network.LocalDomains {
		if len(domain) > 253 || !hostname.MatchString(domain) {
			return fmt.Errorf("invalid local DNS domain %q", domain)
		}
	}
	if len(network.UpstreamDNS) == 0 {
		return fmt.Errorf("upstreamDNS requires explicit VPN-routed IPv4 resolvers")
	}
	seenDNS := map[string]bool{}
	for _, upstream := range network.UpstreamDNS {
		address, err := netip.ParseAddr(upstream)
		if err != nil || !address.Is4() || overlay.Contains(address) || !address.IsGlobalUnicast() && !address.IsLinkLocalUnicast() || seenDNS[upstream] {
			return fmt.Errorf("invalid upstreamDNS address %q", upstream)
		}
		seenDNS[upstream] = true
		for _, local := range network.ClusterDNS {
			if local == upstream {
				return fmt.Errorf("public and cluster DNS must be distinct")
			}
		}
	}
	if len(network.ClusterDNS) == 0 {
		return fmt.Errorf("clusterDNS requires explicit IPv4 upstreams")
	}
	for _, upstream := range network.ClusterDNS {
		address, err := netip.ParseAddr(upstream)
		if err != nil || !address.Is4() || overlay.Contains(address) || !address.IsGlobalUnicast() && !address.IsLinkLocalUnicast() || seenDNS[upstream] {
			return fmt.Errorf("invalid or recursive clusterDNS address %q", upstream)
		}
		seenDNS[upstream] = true
	}
	ids, addresses, ports := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for _, client := range network.StaticClients {
		address, err := netip.ParseAddr(client.Address)
		if err != nil || !address.Is4() || !overlay.Contains(address) {
			return fmt.Errorf("static client %q is outside overlay", client.ID)
		}
		host := int(address.As4()[3])
		if !identifier.MatchString(client.ID) || host < 2 || host >= network.DHCPStart || ids[client.ID] || addresses[client.Address] {
			return fmt.Errorf("duplicate/invalid static client %q; static addresses must be below DHCP range", client.ID)
		}
		ids[client.ID], addresses[client.Address] = true, true
		for _, port := range client.Ports {
			key := fmt.Sprintf("%s:%d", port.Protocol, port.ExternalPort)
			if (port.Protocol != "tcp" && port.Protocol != "udp") || port.ExternalPort < 1 || port.ExternalPort > 65535 || port.TargetPort < 1 || port.TargetPort > 65535 || ports[key] {
				return fmt.Errorf("invalid/duplicate forwarding port %s", key)
			}
			ports[key] = true
		}
	}
	encoded, _ := json.Marshal(network)
	if len(encoded) > 32768 {
		return fmt.Errorf("network configuration exceeds 32 KiB")
	}
	return nil
}

func (network Network) GatewayIP() string {
	prefix, _ := netip.ParsePrefix(network.OverlayCIDR)
	return prefix.Addr().Next().String()
}

func (network Network) JSON() string {
	var output bytes.Buffer
	_ = json.NewEncoder(&output).Encode(network)
	return strings.TrimSpace(output.String())
}
