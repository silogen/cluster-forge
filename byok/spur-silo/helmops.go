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
func installPackage(c *cluster, name, namespace string, values map[string]interface{}) error {
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
			_, lastErr = install.RunWithContext(context.Background(), chart, merged)
		} else {
			upgrade := action.NewUpgrade(cfg)
			upgrade.Namespace = namespace
			upgrade.Wait = true
			upgrade.Timeout = helmTimeout
			_, lastErr = upgrade.RunWithContext(context.Background(), name, chart, merged)
		}
		if lastErr == nil {
			return nil
		}
		if attempt == 3 {
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

// removePackage uninstalls one release. purge also deletes the CRDs of the
// release, the PVCs of the namespace and the namespace itself.
func removePackage(ctx context.Context, c *cluster, name, namespace string, purge bool) error {
	cfg, err := helmConfig(c, namespace)
	if err != nil {
		return err
	}
	var crds []string
	if purge {
		if rel, err := releaseStatus(c, name, namespace); err == nil && rel != nil {
			crds = crdNamesOf(rel.Manifest)
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
	pvcs := c.typed.CoreV1().PersistentVolumeClaims(namespace)
	if err := pvcs.DeleteCollection(ctx, metav1.DeleteOptions{}, listAll); err != nil && !isNotFound(err) {
		return err
	}
	if err := c.typed.CoreV1().Namespaces().Delete(ctx, namespace, metav1.DeleteOptions{}); err != nil && !isNotFound(err) {
		return err
	}
	return nil
}

// crdNamesOf reads the CustomResourceDefinition names out of a release
// manifest. A CRD that the chart ships in its crds/ directory is not in the
// manifest, so helm never owned it and this does not remove it.
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
