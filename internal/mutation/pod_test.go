package mutation

import (
	"context"
	kwhmodel "github.com/slok/kubewebhook/v2/pkg/model"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"podroute/internal/config"
	"reflect"
	"testing"
)

func TestMutation(t *testing.T) {
	for _, native := range []bool{false, true} {
		t.Run(map[bool]string{false: "regular", true: "native"}[native], func(t *testing.T) {
			profile := config.Defaults()
			profile.HelperImage = "podroute-gateway:local"
			profile.Namespaces = []string{"vpn"}
			profile.NativeSidecar = native
			profile.Network.GatewayHost = "gateway.vpn-gateway.svc"
			profile.Network.ClusterDNS = []string{"10.43.0.10"}
			mutate, err := New(profile)
			if err != nil {
				t.Fatal(err)
			}
			pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: "app"}, Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "app", Image: "app"}}, InitContainers: []corev1.Container{{Name: "app-init", Image: "init"}}}}
			original := pod.DeepCopy()
			review := &kwhmodel.AdmissionReview{Namespace: "vpn", Operation: kwhmodel.OperationCreate}
			result, err := mutate(context.Background(), review, pod)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(pod, original) {
				t.Fatal("mutated caller's pod")
			}
			actual := result.MutatedObject.(*corev1.Pod)
			if actual.Spec.InitContainers[0].Name != "podroute-init" || !reflect.DeepEqual(actual.Spec.Containers[0], pod.Spec.Containers[0]) {
				t.Fatal("application changed or guard not first")
			}
			if actual.Spec.DNSConfig.Searches[0] != "vpn.svc.cluster.local" {
				t.Fatal("namespace fallback failed")
			}
			if native && actual.Spec.InitContainers[1].RestartPolicy == nil {
				t.Fatal("missing native sidecar policy")
			}
			again, err := mutate(context.Background(), review, actual)
			if err != nil || again.MutatedObject != nil {
				t.Fatalf("not idempotent: %+v %v", again, err)
			}
			actual.Spec.InitContainers[0].Image = "conflict"
			if _, err := mutate(context.Background(), review, actual); err == nil {
				t.Fatal("accepted conflict")
			}
			pod.Spec.HostNetwork = true
			if _, err := mutate(context.Background(), review, pod); err == nil {
				t.Fatal("accepted host networking")
			}
			pod.Namespace = "other"
			result, err = mutate(context.Background(), review, pod)
			if err != nil || result.MutatedObject != nil {
				t.Fatal("mutated unselected namespace")
			}
			result, err = mutate(context.Background(), review, &corev1.ConfigMap{})
			if err != nil || result.MutatedObject != nil {
				t.Fatal("mutated non-Pod")
			}
		})
	}
}
