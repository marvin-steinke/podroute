package webhook

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"podroute/internal/config"
	"strings"
	"testing"

	jsonpatch "github.com/evanphx/json-patch/v5"
	corev1 "k8s.io/api/core/v1"
)

func TestAdmission(t *testing.T) {
	profile := config.Defaults()
	profile.HelperImage = "podroute-gateway:local"
	profile.Namespaces = []string{"vpn"}
	profile.Network.GatewayHost = "gateway.vpn-gateway.svc"
	profile.Network.ClusterDNS = []string{"10.43.0.10"}
	handler, err := Handler(profile)
	if err != nil {
		t.Fatal(err)
	}
	for _, dryRun := range []bool{false, true} {
		payload := map[string]any{"apiVersion": "admission.k8s.io/v1", "kind": "AdmissionReview", "request": map[string]any{"uid": "test-uid", "namespace": "vpn", "operation": "CREATE", "dryRun": dryRun, "kind": map[string]string{"group": "", "version": "v1", "kind": "Pod"}, "resource": map[string]string{"group": "", "version": "v1", "resource": "pods"}, "object": map[string]any{"apiVersion": "v1", "kind": "Pod", "metadata": map[string]string{"name": "app"}, "spec": map[string]any{"containers": []any{map[string]string{"name": "app", "image": "app"}}}}}}
		encoded, _ := json.Marshal(payload)
		request := httptest.NewRequest(http.MethodPost, "/mutate", bytes.NewReader(encoded))
		request.Header.Set("Content-Type", "application/json")
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		var review struct {
			Response struct {
				UID       string `json:"uid"`
				Allowed   bool   `json:"allowed"`
				Patch     string `json:"patch"`
				PatchType string `json:"patchType"`
			} `json:"response"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &review); err != nil {
			t.Fatalf("%s: %v", response.Body.String(), err)
		}
		patch, err := base64.StdEncoding.DecodeString(review.Response.Patch)
		if err != nil || !review.Response.Allowed || review.Response.UID != "test-uid" || review.Response.PatchType != "JSONPatch" || !bytes.Contains(patch, []byte("client-init")) {
			t.Fatalf("invalid review: %s", response.Body.String())
		}
		operations, err := jsonpatch.DecodePatch(patch)
		if err != nil {
			t.Fatal(err)
		}
		admission := payload["request"].(map[string]any)
		original, _ := json.Marshal(admission["object"])
		mutated, err := operations.Apply(original)
		if err != nil {
			t.Fatal(err)
		}
		var pod corev1.Pod
		if err := json.Unmarshal(mutated, &pod); err != nil || len(pod.Spec.InitContainers) != 2 || pod.Spec.DNSConfig.Nameservers[0] != "172.16.1.1" || pod.Spec.Containers[0].Name != "app" {
			t.Fatalf("invalid mutated Pod: %s (%v)", mutated, err)
		}
		admission["object"] = json.RawMessage(mutated)
		encoded, _ = json.Marshal(payload)
		request = httptest.NewRequest(http.MethodPost, "/mutate", bytes.NewReader(encoded))
		request.Header.Set("Content-Type", "application/json")
		response = httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		review.Response.Patch = ""
		if err := json.Unmarshal(response.Body.Bytes(), &review); err != nil || !review.Response.Allowed {
			t.Fatalf("reinvocation changed Pod: %s (%v)", response.Body.String(), err)
		}
		repeated, err := base64.StdEncoding.DecodeString(review.Response.Patch)
		if err != nil || string(repeated) != "[]" {
			t.Fatalf("reinvocation has nonempty operations: %s (%v)", repeated, err)
		}
		pod.Spec.HostNetwork = true
		admission["object"] = pod
		encoded, _ = json.Marshal(payload)
		request = httptest.NewRequest(http.MethodPost, "/mutate", bytes.NewReader(encoded))
		request.Header.Set("Content-Type", "application/json")
		response = httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code == 200 {
			if err := json.Unmarshal(response.Body.Bytes(), &review); err != nil || review.Response.Allowed {
				t.Fatalf("unsafe pod accepted: %s (%v)", response.Body.String(), err)
			}
		}
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest("GET", "/healthz", nil))
	if response.Code != 200 {
		t.Fatal(response.Code)
	}
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest("POST", "/mutate", strings.NewReader("broken")))
	if response.Code == 200 {
		t.Fatal("accepted malformed request")
	}
}

func TestTLS(t *testing.T) {
	seed := httptest.NewTLSServer(http.NotFoundHandler())
	defer seed.Close()
	pair := seed.TLS.Certificates[0]
	key, err := x509.MarshalPKCS8PrivateKey(pair.PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	certificateFile, keyFile := filepath.Join(directory, "tls.crt"), filepath.Join(directory, "tls.key")
	if err := os.WriteFile(certificateFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: pair.Certificate[0]}), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key}), 0600); err != nil {
		t.Fatal(err)
	}
	server, err := NewServer("127.0.0.1:0", http.NotFoundHandler(), certificateFile, keyFile, false)
	if err != nil || server.TLSConfig.MinVersion != tls.VersionTLS12 {
		t.Fatalf("invalid TLS config: %v", err)
	}
	fixture := httptest.NewUnstartedServer(server.Handler)
	fixture.TLS = server.TLSConfig.Clone()
	fixture.StartTLS()
	defer fixture.Close()
	response, err := fixture.Client().Get(fixture.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatal(response.StatusCode)
	}
}

func TestServerSafety(t *testing.T) {
	for _, test := range []struct {
		address, cert, key string
		insecure           bool
	}{{":8443", "", "", false}, {":8080", "", "", true}, {"127.0.0.1:0", "missing", "missing", false}, {"127.0.0.1:0", "missing", "", true}} {
		if _, err := NewServer(test.address, http.NotFoundHandler(), test.cert, test.key, test.insecure); err == nil {
			t.Fatalf("unsafe options accepted: %+v", test)
		}
	}
	server, err := NewServer("127.0.0.1:0", http.NotFoundHandler(), "", "", true)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := Run(ctx, server); err != nil {
		t.Fatal(err)
	}
}
