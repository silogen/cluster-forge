package main

import (
	"reflect"
	"sort"
	"strings"
	"testing"

	"helm.sh/helm/v3/pkg/chartutil"
	"helm.sh/helm/v3/pkg/engine"
	"sigs.k8s.io/yaml"
)

// The secrets.demo probe must look for the Secrets that the package makes. A
// customer who brings their own Secrets relies on the probe to take the
// package out of the profile.
func TestTheDemoSecretsProbeNamesTheSecretsOfThePackage(t *testing.T) {
	c, err := loadChart("aiwb-demo-secrets")
	if err != nil {
		t.Fatal(err)
	}
	vals, err := chartutil.ToRenderValues(c, c.Values,
		chartutil.ReleaseOptions{Name: "aiwb-demo-secrets", Namespace: "aiwb"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := engine.Render(c, vals)
	if err != nil {
		t.Fatal(err)
	}
	made := map[string][]string{}
	for _, manifest := range rendered {
		for _, doc := range strings.Split(manifest, "\n---") {
			var obj struct {
				Kind     string `json:"kind"`
				Metadata struct {
					Name      string `json:"name"`
					Namespace string `json:"namespace"`
				} `json:"metadata"`
			}
			if err := yaml.Unmarshal([]byte(doc), &obj); err != nil {
				t.Fatal(err)
			}
			if obj.Kind == "Secret" {
				made[obj.Metadata.Namespace] = append(made[obj.Metadata.Namespace], obj.Metadata.Name)
			}
		}
	}
	want := map[string][]string{}
	for namespace, names := range demoSecrets {
		want[namespace] = append([]string(nil), names...)
		sort.Strings(want[namespace])
	}
	for namespace := range made {
		sort.Strings(made[namespace])
	}
	if !reflect.DeepEqual(made, want) {
		t.Errorf("the package makes %v, the probe looks for %v", made, want)
	}

	raw, err := assets.ReadFile("assets/capabilities.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var caps map[string]struct {
		Probe string `json:"probe"`
	}
	if err := yaml.Unmarshal(raw, &caps); err != nil {
		t.Fatal(err)
	}
	shell := caps["secrets.demo"].Probe
	for namespace, names := range demoSecrets {
		for _, name := range names {
			if !strings.Contains(shell, name) || !strings.Contains(shell, "-n "+namespace) {
				t.Errorf("the shell probe of secrets.demo does not look for %s/%s", namespace, name)
			}
		}
	}
}
