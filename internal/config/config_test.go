package config

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestDecode(t *testing.T) {
	valid := `{"helperImage":"podroute-gateway:local","namespaces":["vpn"],"network":{"gatewayHost":"gateway.vpn-gateway.svc.cluster.local","clusterDNS":["10.43.0.10"]}}`
	profile, err := Decode(strings.NewReader(valid))
	if err != nil {
		t.Fatal(err)
	}
	if profile.Network.GatewayIP() != "172.16.1.1" || !profile.NativeSidecar {
		t.Fatal("defaults not applied")
	}
	for _, input := range []string{valid + ` {}`, strings.Replace(valid, `"helperImage"`, `"typo"`, 1), strings.Replace(valid, `"vpn"`, `"kube-system"`, 1), strings.Replace(valid, `10.43.0.10`, `172.16.1.1`, 1)} {
		if _, err := Decode(strings.NewReader(input)); err == nil {
			t.Fatalf("accepted invalid profile %s", input)
		}
	}
}

func TestNetworkValidation(t *testing.T) {
	valid := Defaults().Network
	valid.GatewayHost, valid.ClusterDNS = "gateway.example", []string{"10.43.0.10"}
	for _, test := range []struct {
		name   string
		change func(*Network)
	}{
		{"CIDR", func(n *Network) { n.OverlayCIDR = "172.16.1.1/24" }},
		{"port", func(n *Network) { n.VXLANPort = 0 }},
		{"interface", func(n *Network) { n.VPNInterface = "eth0" }},
		{"bypass", func(n *Network) { n.ClientBypassCIDRs = []string{"0.0.0.0/0"} }},
		{"canonical bypass", func(n *Network) { n.ClientBypassCIDRs = []string{"10.1.2.3/8"} }},
		{"gateway", func(n *Network) { n.GatewayHost = "999.1.1.1" }},
		{"domain", func(n *Network) { n.ClusterDomain = "cluster..local" }},
		{"duplicate DNS", func(n *Network) { n.ClusterDNS = []string{"10.43.0.10", "10.43.0.10"} }},
		{"loopback DNS", func(n *Network) { n.ClusterDNS = []string{"127.0.0.1"} }},
		{"DHCP", func(n *Network) { n.DHCPStart = 255 }},
		{"static", func(n *Network) { n.StaticClients = []StaticClient{{ID: "app", Address: "172.16.1.20"}} }},
		{"duplicate ports", func(n *Network) {
			n.StaticClients = []StaticClient{{ID: "app", Address: "172.16.1.10", Ports: []Port{{"tcp", 80, 80}, {"tcp", 80, 8080}}}}
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			network := valid
			test.change(&network)
			if network.Validate() == nil {
				t.Fatal("accepted invalid config")
			}
			if err := runtimeValidate(network); err == nil {
				t.Fatal("shell runtime accepted invalid config")
			}
		})
	}
	if err := runtimeValidate(valid); err != nil {
		t.Fatalf("runtime rejected valid profile: %v", err)
	}
}

func runtimeValidate(network Network) error {
	command := exec.Command("jq", "-ce", "-f", "../../gateway/lib/config.jq")
	command.Stdin = strings.NewReader(network.JSON())
	return command.Run()
}

func TestExampleProfile(t *testing.T) {
	file, err := os.Open("../../examples/controller.json")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	profile, err := Decode(file)
	if err != nil {
		t.Fatal(err)
	}
	if err := runtimeValidate(profile.Network); err != nil {
		t.Fatalf("gateway rejected example network: %v", err)
	}
}
