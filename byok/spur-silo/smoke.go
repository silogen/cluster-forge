package main

import (
	"context"
	"fmt"
	"strings"
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
	if err := copyPullSecret(ctx, c); err != nil {
		return err
	}

	if err := dropMissingPullSecrets(ctx, c, &obj); err != nil {
		return err
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
		if err == nil {
			if conditionTrue(live, "Ready") {
				infof("smoke test passed for profile %s", profileName)
				_ = services.Delete(ctx, name, metav1.DeleteOptions{})
				return nil
			}
			// aim-engine gives up on its own. Waiting out the timeout after
			// that tells the operator nothing new.
			if status, _, _ := unstructured.NestedString(live.Object, "status", "status"); status == "Failed" {
				return fmt.Errorf("smoke test: %s failed: %s, it stays in %s for a look",
					name, notReadyReasons(live), smokeNamespace)
			}
		}
		time.Sleep(15 * time.Second)
	}
	return fmt.Errorf("smoke test: %s did not become ready in %s, it stays in %s for a look",
		name, smokeTimeout, smokeNamespace)
}

// copyPullSecret puts the pull secret of the install into the test namespace.
// aim-engine fails a model that names a secret which is not there, so without
// the secret the reference goes off the object instead.
func copyPullSecret(ctx context.Context, c *cluster) error {
	secrets := c.typed.CoreV1().Secrets(smokeNamespace)
	if _, err := secrets.Get(ctx, pullSecretName, metav1.GetOptions{}); err == nil {
		return nil
	}
	source, err := c.typed.CoreV1().Secrets(pullSecretNamespace).Get(ctx, pullSecretName, metav1.GetOptions{})
	if err != nil {
		return nil
	}
	copied := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: pullSecretName, Namespace: smokeNamespace},
		Type:       source.Type,
		Data:       source.Data,
	}
	if _, err := secrets.Create(ctx, copied, metav1.CreateOptions{}); err != nil && !isAlreadyExists(err) {
		return err
	}
	infof("smoke test: the Secret %s is copied into namespace %s", pullSecretName, smokeNamespace)
	return nil
}

// dropMissingPullSecrets takes off every imagePullSecrets entry whose Secret is
// not in the test namespace.
func dropMissingPullSecrets(ctx context.Context, c *cluster, obj *unstructured.Unstructured) error {
	entries, found, err := unstructured.NestedSlice(obj.Object, "spec", "imagePullSecrets")
	if err != nil || !found {
		return nil
	}
	var kept []interface{}
	for _, item := range entries {
		entry, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		name, _ := entry["name"].(string)
		if name == "" {
			continue
		}
		if _, err := c.typed.CoreV1().Secrets(smokeNamespace).Get(ctx, name, metav1.GetOptions{}); err == nil {
			kept = append(kept, item)
			continue
		}
		infof("smoke test: the Secret %s is not in namespace %s, the reference goes off",
			name, smokeNamespace)
	}
	if len(kept) == 0 {
		unstructured.RemoveNestedField(obj.Object, "spec", "imagePullSecrets")
		return nil
	}
	return unstructured.SetNestedSlice(obj.Object, kept, "spec", "imagePullSecrets")
}

// notReadyReasons names the conditions that hold the object back.
func notReadyReasons(obj *unstructured.Unstructured) string {
	conditions, found, err := unstructured.NestedSlice(obj.Object, "status", "conditions")
	if err != nil || !found {
		return "no condition is reported"
	}
	var reasons []string
	for _, item := range conditions {
		condition, ok := item.(map[string]interface{})
		if !ok || condition["status"] == "True" {
			continue
		}
		reason, _ := condition["reason"].(string)
		name, _ := condition["type"].(string)
		if reason != "" {
			reasons = append(reasons, name+"="+reason)
		}
	}
	if len(reasons) == 0 {
		return "no condition names a reason"
	}
	return strings.Join(reasons, " ")
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
