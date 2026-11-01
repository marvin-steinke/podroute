package mutation

import (
	"context"
	"fmt"
	"reflect"
	"slices"

	"podroute/internal/config"

	kwhmodel "github.com/slok/kubewebhook/v2/pkg/model"
	kwhmutating "github.com/slok/kubewebhook/v2/pkg/webhook/mutating"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const ClientIDAnnotation = "podroute.io/client-id"
const stateVolume = "podroute-state"

func New(profile config.Profile) (kwhmutating.MutatorFunc, error) {
	if err := profile.Validate(); err != nil {
		return nil, err
	}
	return func(_ context.Context, review *kwhmodel.AdmissionReview, object metav1.Object) (*kwhmutating.MutatorResult, error) {
		pod, ok := object.(*corev1.Pod)
		if !ok {
			return &kwhmutating.MutatorResult{}, nil
		}
		namespace := pod.Namespace
		if namespace == "" && review != nil {
			namespace = review.Namespace
		}
		if !slices.Contains(profile.Namespaces, namespace) {
			return &kwhmutating.MutatorResult{}, nil
		}
		if pod.Spec.HostNetwork {
			return nil, fmt.Errorf("PodRoute cannot safely route hostNetwork pods")
		}
		if review != nil && review.Operation != "" && review.Operation != kwhmodel.OperationCreate {
			return &kwhmutating.MutatorResult{}, nil
		}
		clientID := pod.Annotations[ClientIDAnnotation]
		if clientID != "" && !slices.ContainsFunc(profile.Network.StaticClients, func(client config.StaticClient) bool { return client.ID == clientID }) {
			return nil, fmt.Errorf("unknown static client ID %q", clientID)
		}
		init := helper(profile, "podroute-init", "client-init", clientID)
		monitor := helper(profile, "podroute-monitor", "client-sidecar", clientID)
		if profile.NativeSidecar {
			policy := corev1.ContainerRestartPolicyAlways
			monitor.RestartPolicy = &policy
		}
		volume := corev1.Volume{Name: stateVolume, VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}}
		foundInit, foundMonitor, foundVolume := false, false, false
		for groupIndex, group := range [][]corev1.Container{pod.Spec.InitContainers, pod.Spec.Containers} {
			for _, container := range group {
				switch container.Name {
				case init.Name:
					if foundInit || groupIndex != 0 || !reflect.DeepEqual(container, init) {
						return nil, fmt.Errorf("conflicting container %q", init.Name)
					}
					foundInit = true
				case monitor.Name:
					expectedGroup := 1
					if profile.NativeSidecar {
						expectedGroup = 0
					}
					if foundMonitor || groupIndex != expectedGroup || !reflect.DeepEqual(container, monitor) {
						return nil, fmt.Errorf("conflicting container %q", monitor.Name)
					}
					foundMonitor = true
				}
				for _, mount := range container.VolumeMounts {
					if mount.Name == stateVolume && container.Name != init.Name && container.Name != monitor.Name {
						return nil, fmt.Errorf("reserved volume %q mounted by application", stateVolume)
					}
				}
			}
		}
		for _, ephemeral := range pod.Spec.EphemeralContainers {
			if ephemeral.Name == init.Name || ephemeral.Name == monitor.Name {
				return nil, fmt.Errorf("reserved ephemeral container name %q", ephemeral.Name)
			}
		}
		for _, existing := range pod.Spec.Volumes {
			if existing.Name == stateVolume {
				if foundVolume || !reflect.DeepEqual(existing, volume) {
					return nil, fmt.Errorf("conflicting volume %q", stateVolume)
				}
				foundVolume = true
			}
		}
		if (foundInit || foundMonitor || foundVolume) && !(foundInit && foundMonitor && foundVolume) {
			return nil, fmt.Errorf("incomplete existing PodRoute injection")
		}
		mutated := pod.DeepCopy()
		if !foundInit {
			prefix := []corev1.Container{init}
			if profile.NativeSidecar {
				prefix = append(prefix, monitor)
			} else {
				mutated.Spec.Containers = append(mutated.Spec.Containers, monitor)
			}
			mutated.Spec.InitContainers = append(prefix, mutated.Spec.InitContainers...)
			mutated.Spec.Volumes = append(mutated.Spec.Volumes, volume)
		}
		dns := &corev1.PodDNSConfig{}
		if mutated.Spec.DNSConfig != nil {
			dns = mutated.Spec.DNSConfig.DeepCopy()
		}
		dns.Nameservers = []string{profile.Network.GatewayIP()}
		domain := profile.Network.ClusterDomain
		searches := []string{namespace + ".svc." + domain, "svc." + domain, domain}
		for _, search := range dns.Searches {
			if search != "." && search != "" && !slices.Contains(searches, search) {
				searches = append(searches, search)
			}
		}
		if len(searches) > 32 {
			return nil, fmt.Errorf("too many DNS search domains")
		}
		dns.Searches = searches
		mutated.Spec.DNSPolicy, mutated.Spec.DNSConfig = corev1.DNSNone, dns
		if reflect.DeepEqual(pod.Spec, mutated.Spec) {
			return &kwhmutating.MutatorResult{}, nil
		}
		return &kwhmutating.MutatorResult{MutatedObject: mutated}, nil
	}, nil
}

func helper(profile config.Profile, name, role, clientID string) corev1.Container {
	root, no, yes := int64(0), false, true
	return corev1.Container{
		Name: name, Image: profile.HelperImage, ImagePullPolicy: corev1.PullIfNotPresent,
		Command: []string{"/usr/local/bin/podroute"}, Args: []string{role},
		Env:                    []corev1.EnvVar{{Name: "PODROUTE_CONFIG", Value: profile.Network.JSON()}, {Name: "PODROUTE_CLIENT_ID", Value: clientID}},
		VolumeMounts:           []corev1.VolumeMount{{Name: stateVolume, MountPath: "/run/podroute"}},
		TerminationMessagePath: "/dev/termination-log", TerminationMessagePolicy: corev1.TerminationMessageReadFile,
		SecurityContext: &corev1.SecurityContext{RunAsUser: &root, RunAsNonRoot: &no, AllowPrivilegeEscalation: &no, ReadOnlyRootFilesystem: &yes, Capabilities: &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}, Add: []corev1.Capability{"NET_ADMIN", "NET_RAW"}}},
	}
}
