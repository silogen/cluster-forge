package main

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/yaml"
)

const (
	smokeNamespace = "aims-test"
	smokeTimeout   = 15 * time.Minute
)

// smokeTest deploys the dummy model of the release and waits until aim-engine
// reports it ready. It proves the whole serving path: the admission mutation,
// the CRDs, the aim-engine controller and KServe. The chat request of
// byok/tests/smoke.sh needs a port-forward and stays in that script.
func smokeTest(ctx context.Context, c *cluster, profileName string) error {
	raw, err := assets.ReadFile("assets/tests/aimservice-dummy.yaml")
	if err != nil {
		return err
	}
	var obj unstructured.Unstructured
	if err := yaml.Unmarshal(raw, &obj.Object); err != nil {
		return err
	}
	obj.SetNamespace(smokeNamespace)
	name := obj.GetName()

	infof("smoke test: deploy %s into namespace %s", name, smokeNamespace)
	namespaces := c.typed.CoreV1().Namespaces()
	if _, err := namespaces.Get(ctx, smokeNamespace, metav1.GetOptions{}); isNotFound(err) {
		ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: smokeNamespace}}
		if _, err := namespaces.Create(ctx, ns, metav1.CreateOptions{}); err != nil && !isAlreadyExists(err) {
			return err
		}
	}

	services := c.dynamic.Resource(gvr("aim.eai.amd.com", "v1alpha1", "aimservices")).Namespace(smokeNamespace)
	if _, err := services.Create(ctx, &obj, metav1.CreateOptions{}); err != nil {
		if !isAlreadyExists(err) {
			return err
		}
	}

	deadline := time.Now().Add(smokeTimeout)
	for time.Now().Before(deadline) {
		live, err := services.Get(ctx, name, metav1.GetOptions{})
		if err == nil && conditionTrue(live, "Ready") {
			infof("smoke test passed for profile %s", profileName)
			_ = services.Delete(ctx, name, metav1.DeleteOptions{})
			return nil
		}
		time.Sleep(15 * time.Second)
	}
	return fmt.Errorf("smoke test: %s did not become ready in %s, it stays in %s for a look",
		name, smokeTimeout, smokeNamespace)
}

func conditionTrue(obj *unstructured.Unstructured, want string) bool {
	conditions, found, err := unstructured.NestedSlice(obj.Object, "status", "conditions")
	if err != nil || !found {
		return false
	}
	for _, item := range conditions {
		condition, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		if condition["type"] == want && condition["status"] == "True" {
			return true
		}
	}
	return false
}
