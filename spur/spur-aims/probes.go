package main

import (
	"context"
	"sort"
	"strings"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

var listAll = metav1.ListOptions{}

// The Secrets that the aiwb-demo-secrets package makes, by namespace. A test
// holds this list to the rendered chart and to capabilities.yaml.
var demoSecrets = map[string][]string{
	"aiwb":     {"aiwb-cnpg-user", "aiwb-nextauth-secret", "aiwb-oidc-client-secret", "minio-credentials"},
	"dex":      {"dex-credentials"},
	"postgres": {"aiwb-db-user", "postgres-superuser"},
}

// Every capability of assets/capabilities.yaml, as a live check against the
// cluster. The yaml keeps a shell form of every probe, which documents what
// this map does and lets a test script run one by hand; a test holds the two
// lists to the same names.
var probes = map[string]func(context.Context, *cluster) bool{
	"gateway.api.crds": func(ctx context.Context, c *cluster) bool {
		return c.crdExists(ctx, "gateways.gateway.networking.k8s.io")
	},
	"gateway.api": func(ctx context.Context, c *cluster) bool {
		return c.exists(ctx, gvr("gateway.networking.k8s.io", "v1", "gatewayclasses"), "", "envoy-gateway")
	},
	"tls.cluster-cert": func(ctx context.Context, c *cluster) bool {
		return c.secretsExist(ctx, "envoy-gateway-system", "cluster-tls")
	},
	"gateway.https": func(ctx context.Context, c *cluster) bool {
		return c.exists(ctx, gvr("gateway.networking.k8s.io", "v1", "gateways"), "envoy-gateway-system", "https")
	},
	"policy.kyverno": func(ctx context.Context, c *cluster) bool {
		return c.crdExists(ctx, "clusterpolicies.kyverno.io")
	},
	"storage.access-mode-mutation": func(ctx context.Context, c *cluster) bool {
		return c.exists(ctx, gvr("kyverno.io", "v1", "clusterpolicies"), "", "local-path-access-mode-mutation")
	},
	"storage.default-class": func(ctx context.Context, c *cluster) bool {
		list, err := c.typed.StorageV1().StorageClasses().List(ctx, listAll)
		if err != nil {
			return false
		}
		for _, sc := range list.Items {
			if sc.Annotations["storageclass.kubernetes.io/is-default-class"] == "true" {
				return true
			}
		}
		return false
	},
	"certificates.cert-manager": func(ctx context.Context, c *cluster) bool {
		return c.crdExists(ctx, "certificates.cert-manager.io")
	},
	"serving.kserve.crds": func(ctx context.Context, c *cluster) bool {
		return c.crdExists(ctx, "inferenceservices.serving.kserve.io")
	},
	"serving.kserve": func(ctx context.Context, c *cluster) bool {
		// The CRDs alone are not enough, aim-engine needs a running controller.
		return c.crdExists(ctx, "inferenceservices.serving.kserve.io") &&
			c.deploymentNameContains(ctx, "kserve-controller-manager")
	},
	"inference.aim.crds": func(ctx context.Context, c *cluster) bool {
		return c.crdExists(ctx, "aimservices.aim.eai.amd.com")
	},
	"inference.aim": func(ctx context.Context, c *cluster) bool {
		return c.crdExists(ctx, "aimservices.aim.eai.amd.com") &&
			c.deploymentNameContains(ctx, "aim-engine-controller-manager")
	},
	"catalog.aim": func(ctx context.Context, c *cluster) bool {
		return c.any(ctx, gvr("aim.eai.amd.com", "v1alpha1", "aimclustermodelsources"))
	},
	"secrets.demo": func(ctx context.Context, c *cluster) bool {
		for namespace, names := range demoSecrets {
			if !c.secretsExist(ctx, namespace, names...) {
				return false
			}
		}
		return true
	},
	"database.postgres": func(ctx context.Context, c *cluster) bool {
		return c.serviceExists(ctx, "postgres", "postgres")
	},
	"telemetry.otel.crds": func(ctx context.Context, c *cluster) bool {
		return c.crdExists(ctx, "opentelemetrycollectors.opentelemetry.io")
	},
	"auth.oidc": func(ctx context.Context, c *cluster) bool {
		// Any OIDC issuer that the aiwb package values point at. The demo
		// probe looks for Dex.
		return c.serviceExists(ctx, "dex", "dex")
	},
	"workbench.ui": func(ctx context.Context, c *cluster) bool {
		return c.deploymentExists(ctx, "aiwb", "aiwb-ui")
	},
	"storage.s3.operator": func(ctx context.Context, c *cluster) bool {
		return c.crdExists(ctx, "seaweeds.seaweed.seaweedfs.com")
	},
	"storage.s3": func(ctx context.Context, c *cluster) bool {
		return c.any(ctx, gvr("seaweed.seaweedfs.com", "v1", "seaweeds"))
	},
	"gpu.amd.operator": func(ctx context.Context, c *cluster) bool {
		return c.crdExists(ctx, "deviceconfigs.amd.com")
	},
	"gpu.amd": func(ctx context.Context, c *cluster) bool {
		// The DeviceConfig alone is not enough, the device plugin must also
		// publish the GPUs of a node.
		nodes, err := c.typed.CoreV1().Nodes().List(ctx, listAll)
		if err != nil {
			return false
		}
		for _, n := range nodes.Items {
			if q, ok := n.Status.Capacity["amd.com/gpu"]; ok && !q.IsZero() {
				return true
			}
		}
		return false
	},
	"gpu.spur-sharing": func(ctx context.Context, c *cluster) bool {
		// A node that Spur shares with Kubernetes runs the AMD DRA driver,
		// not the device plugin. The node is ready when the driver publishes
		// its GPUs.
		nodes, err := c.typed.CoreV1().Nodes().List(ctx, metav1.ListOptions{LabelSelector: "spur.amd.com/gpu-sharing=true"})
		if err != nil {
			return false
		}
		slices := c.dynamic.Resource(gvr("resource.k8s.io", "v1", "resourceslices"))
		for _, n := range nodes.Items {
			list, err := slices.List(ctx, metav1.ListOptions{FieldSelector: "spec.driver=gpu.amd.com,spec.nodeName=" + n.Name})
			if err == nil && len(list.Items) > 0 {
				return true
			}
		}
		return false
	},
}

func capabilityNames() []string {
	names := make([]string, 0, len(probes))
	for name := range probes {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func probe(ctx context.Context, c *cluster, capability string) bool {
	check, ok := probes[capability]
	if !ok {
		return false
	}
	return check(ctx, c)
}

func gvr(group, version, resource string) schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: group, Version: version, Resource: resource}
}

func (c *cluster) crdExists(ctx context.Context, name string) bool {
	return c.exists(ctx, gvr("apiextensions.k8s.io", "v1", "customresourcedefinitions"), "", name)
}

func (c *cluster) exists(ctx context.Context, r schema.GroupVersionResource, namespace, name string) bool {
	var err error
	if namespace == "" {
		_, err = c.dynamic.Resource(r).Get(ctx, name, metav1.GetOptions{})
	} else {
		_, err = c.dynamic.Resource(r).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
	}
	return err == nil
}

func (c *cluster) any(ctx context.Context, r schema.GroupVersionResource) bool {
	list, err := c.dynamic.Resource(r).List(ctx, listAll)
	return err == nil && len(list.Items) > 0
}

func (c *cluster) secretsExist(ctx context.Context, namespace string, names ...string) bool {
	for _, name := range names {
		if _, err := c.typed.CoreV1().Secrets(namespace).Get(ctx, name, metav1.GetOptions{}); err != nil {
			return false
		}
	}
	return true
}

func (c *cluster) serviceExists(ctx context.Context, namespace, name string) bool {
	_, err := c.typed.CoreV1().Services(namespace).Get(ctx, name, metav1.GetOptions{})
	return err == nil
}

func (c *cluster) deploymentExists(ctx context.Context, namespace, name string) bool {
	_, err := c.typed.AppsV1().Deployments(namespace).Get(ctx, name, metav1.GetOptions{})
	return err == nil
}

func (c *cluster) deploymentNameContains(ctx context.Context, part string) bool {
	list, err := c.typed.AppsV1().Deployments("").List(ctx, listAll)
	if err != nil {
		return false
	}
	for _, d := range list.Items {
		if strings.Contains(d.Name, part) {
			return true
		}
	}
	return false
}

func isNotFound(err error) bool { return apierrors.IsNotFound(err) }
