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

func TestInferenceDemoExtendsInferenceInOrder(t *testing.T) {
	base, err := loadProfile("inference", nil)
	if err != nil {
		t.Fatal(err)
	}
	demo, err := loadProfile("inference-demo", map[string]string{
		"domain": "example.com", "gatewayServiceType": "ClusterIP", "gatewayExternalIP": "10.0.0.1",
	})
	if err != nil {
		t.Fatal(err)
	}
	for i, entry := range base.Packages {
		if demo.Packages[i].Name != entry.Name {
			t.Fatalf("package %d of inference-demo is %s, the base has %s",
				i, demo.Packages[i].Name, entry.Name)
		}
	}
	if len(demo.Packages) <= len(base.Packages) {
		t.Fatal("inference-demo adds no package of its own")
	}
}

func TestARequiredVariableWithoutAValueStops(t *testing.T) {
	if _, err := loadProfile("inference-demo", nil); err == nil {
		t.Fatal("inference-demo loaded without the domain variable")
	}
}

func TestAnUndeclaredVariableStops(t *testing.T) {
	if _, err := loadProfile("inference", map[string]string{"nowhere": "x"}); err == nil {
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
		"inference": {Packages: []string{"kyverno", "kserve"}},
		"inference-demo":          {Packages: []string{"kyverno", "kserve", "aiwb"}},
	}
	keep := packagesOfOtherProfiles(record, "inference-demo")
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

func TestOverlappingProfile(t *testing.T) {
	base := []string{"kyverno", "kserve"}
	record := map[string]recordEntry{"inference": {Packages: base}}

	if other, _ := overlappingProfile(record, "inference", "", base); other != "" {
		t.Error("an install of the same profile is an upgrade, not an overlap")
	}
	if other, _ := overlappingProfile(record, "inference-demo", "inference",
		[]string{"kyverno", "kserve", "aiwb"}); other != "" {
		t.Error("a profile that extends the installed one is not an overlap")
	}
	other, shared := overlappingProfile(record, "inference-gpu", "",
		[]string{"kyverno", "kserve", "amd-gpu-operator"})
	if other != "inference" || len(shared) != 2 {
		t.Errorf("two profiles over the same packages gave %q %v", other, shared)
	}
	if other, _ := overlappingProfile(record, "other", "", []string{"nothing"}); other != "" {
		t.Error("a profile with no shared package is not an overlap")
	}
}

func TestLoadProfileKeepsExtends(t *testing.T) {
	p, err := loadProfile("inference-demo", map[string]string{
		"domain": "example.com", "gatewayServiceType": "ClusterIP", "gatewayExternalIP": "10.0.0.1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if p.Extends != "inference" {
		t.Errorf("inference-demo extends %q", p.Extends)
	}
}

func TestASharedCRDOfAKeptPackageIsProtected(t *testing.T) {
	// envoy-gateway of inference-demo ships the Gateway API CRDs in a subchart, and
	// gateway-api-crds of inference ships the same names. The
	// uninstall of inference-demo must leave them to the profile that stays.
	base := chartCRDNames("gateway-api-crds")
	if len(base) == 0 {
		t.Fatal("gateway-api-crds ships no CRD, the fixture is wrong")
	}
	demo := map[string]bool{}
	for _, name := range chartCRDNames("envoy-gateway") {
		demo[name] = true
	}
	var shared []string
	for _, name := range base {
		if demo[name] {
			shared = append(shared, name)
		}
	}
	if len(shared) == 0 {
		t.Skip("envoy-gateway no longer ships the Gateway API CRDs")
	}

	protected := protectedCRDNames([]string{"gateway-api-crds"})
	for _, name := range shared {
		if !protected[name] {
			t.Errorf("%s is shared with a package that stays, it is not protected", name)
		}
	}
}
