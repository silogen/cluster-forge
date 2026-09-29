package main

import (
	"context"
	"fmt"
	"strings"
	"time"

	"helm.sh/helm/v3/pkg/action"
	"helm.sh/helm/v3/pkg/chartutil"
	"helm.sh/helm/v3/pkg/release"
	"helm.sh/helm/v3/pkg/storage/driver"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
)

const helmTimeout = 10 * time.Minute

func helmConfig(c *cluster, namespace string) (*action.Configuration, error) {
	cfg := new(action.Configuration)
	err := cfg.Init(c.restClientGetter(namespace), namespace, "secret", func(format string, v ...interface{}) {
		// Helm's own progress lines are noise next to the per-package lines.
	})
	return cfg, err
}

func releaseStatus(c *cluster, name, namespace string) (*release.Release, error) {
	cfg, err := helmConfig(c, namespace)
	if err != nil {
		return nil, err
	}
	rel, err := action.NewStatus(cfg).Run(name)
	if err == driver.ErrReleaseNotFound {
		return nil, nil
	}
	return rel, err
}

func isInstalled(c *cluster, name, namespace string) bool {
	rel, err := releaseStatus(c, name, namespace)
	return err == nil && rel != nil
}

// installPackage runs the equivalent of `helm upgrade --install --wait`.
//
// A chart that holds both a webhook and objects that the webhook validates
// fails on the first pass, because the webhook server starts later. ArgoCD
// retries such a sync; helm does not, so retry here.
func installPackage(ctx context.Context, c *cluster, name, namespace string, values map[string]interface{}) error {
	chart, err := loadChart(name)
	if err != nil {
		return err
	}
	merged, err := chartutil.CoalesceValues(chart, values)
	if err != nil {
		return err
	}

	var lastErr error
	for attempt := 1; attempt <= 3; attempt++ {
		cfg, err := helmConfig(c, namespace)
		if err != nil {
			return err
		}
		rel, err := releaseStatus(c, name, namespace)
		if err != nil {
			return err
		}
		if rel == nil {
			install := action.NewInstall(cfg)
			install.ReleaseName = name
			install.Namespace = namespace
			install.CreateNamespace = true
			install.Wait = true
			install.Timeout = helmTimeout
			_, lastErr = install.RunWithContext(ctx, chart, merged)
		} else {
			upgrade := action.NewUpgrade(cfg)
			upgrade.Namespace = namespace
			upgrade.Wait = true
			upgrade.Timeout = helmTimeout
			_, lastErr = upgrade.RunWithContext(ctx, name, chart, merged)
		}
		if lastErr == nil {
			return nil
		}
		if reason := whyPodsFail(ctx, c, namespace); reason != "" {
			return fmt.Errorf("install of %s failed: %w\n  %s", name, lastErr, reason)
		}
		if attempt == 3 || ctx.Err() != nil {
			break
		}
		// A first install that fails leaves a release that upgrade cannot use.
		// A deployed release stays: an uninstall would remove its objects, and
		// a namespace among them takes everything in it away.
		if rel, err := releaseStatus(c, name, namespace); err == nil && rel != nil &&
			rel.Version == 1 && rel.Info.Status != release.StatusDeployed {
			cfg, cfgErr := helmConfig(c, namespace)
			if cfgErr == nil {
				uninstall := action.NewUninstall(cfg)
				uninstall.Wait = true
				uninstall.Timeout = helmTimeout
				_, _ = uninstall.Run(name)
			}
		}
		infof("attempt %d for %s failed: %v, wait 20s and try again", attempt, name, lastErr)
		time.Sleep(20 * time.Second)
	}
	return fmt.Errorf("install of %s failed after 3 attempts: %w", name, lastErr)
}

// removePackage uninstalls one release. purge also deletes the CRDs that the
// release owns. The namespace is not touched here: more than one package of a
// profile can live in the same namespace, and a namespace that goes away takes
// the releases of its other packages with it. purgeNamespace does that step
// after the last package of the namespace is gone.
func removePackage(ctx context.Context, c *cluster, name, namespace string, purge bool, protected map[string]bool) error {
	cfg, err := helmConfig(c, namespace)
	if err != nil {
		return err
	}
	var crds []string
	if purge {
		for _, crd := range packageCRDs(c, name, namespace) {
			if protected[crd] {
				infof("keep the CRD %s, a package that stays owns it too", crd)
				continue
			}
			crds = append(crds, crd)
		}
	}

	// A CR whose controller is already gone keeps its finalizer for ever, and
	// the deletion of its CRD then never ends. Clear the CRs first, while the
	// controller of this release still runs.
	for _, crd := range crds {
		if err := clearCustomResources(ctx, c, crd); err != nil {
			return err
		}
	}

	infof("uninstall %s from namespace %s", name, namespace)
	uninstall := action.NewUninstall(cfg)
	uninstall.Wait = true
	uninstall.Timeout = helmTimeout
	if _, err := uninstall.Run(name); err != nil && err != driver.ErrReleaseNotFound {
		return err
	}
	if !purge {
		return nil
	}

	crdClient := c.dynamic.Resource(gvr("apiextensions.k8s.io", "v1", "customresourcedefinitions"))
	for _, crd := range crds {
		if err := crdClient.Delete(ctx, crd, metav1.DeleteOptions{}); err != nil && !isNotFound(err) {
			return err
		}
	}
	return nil
}

// purgeNamespace deletes the PVCs of a namespace and the namespace itself.
func purgeNamespace(ctx context.Context, c *cluster, namespace string) error {
	pvcs := c.typed.CoreV1().PersistentVolumeClaims(namespace)
	if err := pvcs.DeleteCollection(ctx, metav1.DeleteOptions{}, listAll); err != nil && !isNotFound(err) {
		return err
	}
	infof("delete namespace %s", namespace)
	if err := c.typed.CoreV1().Namespaces().Delete(ctx, namespace, metav1.DeleteOptions{}); err != nil && !isNotFound(err) {
		return err
	}
	return nil
}

// packageCRDs names every CRD a package owns: the ones in its release manifest
// and the ones its chart ships in a crds/ directory, which helm never owns.
func packageCRDs(c *cluster, name, namespace string) []string {
	var crds []string
	if rel, err := releaseStatus(c, name, namespace); err == nil && rel != nil {
		crds = append(crds, crdNamesOf(rel.Manifest)...)
	}
	return append(crds, chartCRDNames(name)...)
}

// chartCRDNames gives the CRDs a chart ships in its crds/ directory. helm never
// owns those, and more than one chart can ship the same name.
func chartCRDNames(pkg string) []string {
	chart, err := loadChart(pkg)
	if err != nil {
		return nil
	}
	var names []string
	for _, object := range chart.CRDObjects() {
		names = append(names, crdNamesOf(string(object.File.Data))...)
	}
	return names
}

// protectedCRDNames gives the CRDs that the packages which stay on the cluster
// ship. An uninstall must leave those, whichever release also ships them.
func protectedCRDNames(packages []string) map[string]bool {
	names := map[string]bool{}
	for _, pkg := range packages {
		for _, crd := range chartCRDNames(pkg) {
			names[crd] = true
		}
	}
	return names
}

// clearCustomResources deletes every object of a CRD and takes the finalizers
// off the ones that do not go away on their own.
func clearCustomResources(ctx context.Context, c *cluster, crdName string) error {
	crds := c.dynamic.Resource(gvr("apiextensions.k8s.io", "v1", "customresourcedefinitions"))
	crd, err := crds.Get(ctx, crdName, metav1.GetOptions{})
	if err != nil {
		if isNotFound(err) {
			return nil
		}
		return err
	}
	group, _, _ := unstructured.NestedString(crd.Object, "spec", "group")
	plural, _, _ := unstructured.NestedString(crd.Object, "spec", "names", "plural")
	versions, _, _ := unstructured.NestedSlice(crd.Object, "spec", "versions")
	if group == "" || plural == "" || len(versions) == 0 {
		return nil
	}
	version := ""
	for _, item := range versions {
		entry, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		if served, _ := entry["served"].(bool); served {
			version, _ = entry["name"].(string)
			break
		}
	}
	if version == "" {
		return nil
	}

	client := c.dynamic.Resource(gvr(group, version, plural))
	list, err := client.List(ctx, metav1.ListOptions{})
	if err != nil {
		if isNotFound(err) {
			return nil
		}
		return err
	}
	const noFinalizers = `{"metadata":{"finalizers":null}}`
	for i := range list.Items {
		item := &list.Items[i]
		objects := client.Namespace(item.GetNamespace())
		if err := objects.Delete(ctx, item.GetName(), metav1.DeleteOptions{}); err != nil && !isNotFound(err) {
			return err
		}
		if len(item.GetFinalizers()) == 0 {
			continue
		}
		_, err := objects.Patch(ctx, item.GetName(), types.MergePatchType,
			[]byte(noFinalizers), metav1.PatchOptions{})
		if err != nil && !isNotFound(err) {
			return err
		}
	}
	return nil
}

// crdNamesOf reads the CustomResourceDefinition names out of a release
// manifest. A CRD that the chart ships in its crds/ directory is not in the
// manifest, so helm never owned it and this does not remove it.
// whyPodsFail names a pod of the namespace that cannot start for a reason that
// a retry does not change. helm reports only `context deadline exceeded`, which
// says nothing about the missing Secret or the image that is not there.
func whyPodsFail(ctx context.Context, c *cluster, namespace string) string {
	terminal := map[string]bool{
		"CreateContainerConfigError": true,
		"CreateContainerError":       true,
		"ErrImagePull":               true,
		"ImagePullBackOff":           true,
		"InvalidImageName":           true,
		"CrashLoopBackOff":           true,
	}
	pods, err := c.typed.CoreV1().Pods(namespace).List(ctx, listAll)
	if err != nil {
		return ""
	}
	for i := range pods.Items {
		pod := &pods.Items[i]
		for _, status := range pod.Status.ContainerStatuses {
			waiting := status.State.Waiting
			if waiting == nil || !terminal[waiting.Reason] {
				continue
			}
			return fmt.Sprintf("pod %s/%s is in %s: %s",
				namespace, pod.Name, waiting.Reason, strings.TrimSpace(waiting.Message))
		}
	}
	return ""
}

func crdNamesOf(manifest string) []string {
	var names []string
	for _, doc := range strings.Split(manifest, "\n---") {
		if !strings.Contains(doc, "kind: CustomResourceDefinition") {
			continue
		}
		var obj struct {
			Kind     string `json:"kind"`
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
		}
		if err := yamlUnmarshal([]byte(doc), &obj); err != nil {
			continue
		}
		if obj.Kind == "CustomResourceDefinition" && obj.Metadata.Name != "" {
			names = append(names, obj.Metadata.Name)
		}
	}
	return names
}
