package main

import (
	"sort"
	"testing"

	"sigs.k8s.io/yaml"
)

// The yaml keeps the shell probes for bootstrap.sh and this file keeps the Go
// probes. A capability that only one of them knows is a capability that the
// two paths disagree about.
func TestEveryCapabilityOfTheYamlHasAGoProbe(t *testing.T) {
	raw, err := assets.ReadFile("assets/capabilities.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var fromYaml map[string]struct {
		Probe string `json:"probe"`
	}
	if err := yaml.Unmarshal(raw, &fromYaml); err != nil {
		t.Fatal(err)
	}

	var names []string
	for name := range fromYaml {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if _, ok := probes[name]; !ok {
			t.Errorf("capabilities.yaml declares %s, the binary has no probe for it", name)
		}
	}
	for name := range probes {
		if _, ok := fromYaml[name]; !ok {
			t.Errorf("the binary probes %s, capabilities.yaml does not declare it", name)
		}
	}
}

func TestProfilesLoadAndNameEveryPackage(t *testing.T) {
	names, err := profileNames()
	if err != nil {
		t.Fatal(err)
	}
	if len(names) == 0 {
		t.Fatal("no profile is embedded")
	}
	for _, name := range names {
		declared, err := loadProfileHead(name)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		vars := map[string]string{}
		for _, v := range declared {
			vars[v] = "x"
		}
		p, err := loadProfile(name, vars)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if p.Name == "" {
			t.Errorf("%s: the profile has no name", name)
		}
		if len(p.Packages) == 0 {
			t.Errorf("%s: the profile holds no package", name)
		}
		for _, entry := range p.Packages {
			if _, err := loadPackageMeta(entry.Name); err != nil {
				t.Errorf("%s: %v", name, err)
			}
			if _, err := loadChart(entry.Name); err != nil {
				t.Errorf("%s: chart of %s: %v", name, entry.Name, err)
			}
		}
	}
}

func TestAiwbDemoExtendsScalableInferenceInOrder(t *testing.T) {
	base, err := loadProfile("scalable-inference", nil)
	if err != nil {
		t.Fatal(err)
	}
	demo, err := loadProfile("aiwb-demo", map[string]string{
		"domain": "example.com", "gatewayServiceType": "ClusterIP", "gatewayExternalIP": "10.0.0.1",
	})
	if err != nil {
		t.Fatal(err)
	}
	for i, entry := range base.Packages {
		if demo.Packages[i].Name != entry.Name {
			t.Fatalf("package %d of aiwb-demo is %s, the base has %s",
				i, demo.Packages[i].Name, entry.Name)
		}
	}
	if len(demo.Packages) <= len(base.Packages) {
		t.Fatal("aiwb-demo adds no package of its own")
	}
}

func TestARequiredVariableWithoutAValueStops(t *testing.T) {
	if _, err := loadProfile("aiwb-demo", nil); err == nil {
		t.Fatal("aiwb-demo loaded without the domain variable")
	}
}

func TestAnUndeclaredVariableStops(t *testing.T) {
	if _, err := loadProfile("scalable-inference", map[string]string{"nowhere": "x"}); err == nil {
		t.Fatal("a variable that the profile does not declare was accepted")
	}
}

func TestInstinctDetection(t *testing.T) {
	cases := map[string]bool{
		"gpu:mi300x:1,gpu:mi300x:1": true,
		"gpu:mi250x:1":              true,
		"gpu:rx9070:1":              false,
		"gpu:amdgpu-0x1234:1":       false,
		"":                          false,
	}
	for gres, want := range cases {
		if got := hasInstinct(gres); got != want {
			t.Errorf("hasInstinct(%q) = %v, want %v", gres, got, want)
		}
	}
}

func TestPackagesOfOtherProfiles(t *testing.T) {
	record := map[string]recordEntry{
		"scalable-inference": {Packages: []string{"kyverno", "kserve"}},
		"aiwb-demo":          {Packages: []string{"kyverno", "kserve", "aiwb"}},
	}
	keep := packagesOfOtherProfiles(record, "aiwb-demo")
	if !keep["kyverno"] || !keep["kserve"] {
		t.Error("a package of another recorded profile was not kept")
	}
	if keep["aiwb"] {
		t.Error("a package of this profile only was kept")
	}
}

func TestCrdNamesOfAManifest(t *testing.T) {
	manifest := `apiVersion: v1
kind: Service
metadata:
  name: svc
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: things.example.com
`
	got := crdNamesOf(manifest)
	if len(got) != 1 || got[0] != "things.example.com" {
		t.Errorf("crdNamesOf gave %v", got)
	}
}
