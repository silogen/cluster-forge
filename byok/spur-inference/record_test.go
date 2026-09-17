package main

import (
	"reflect"
	"strings"
	"testing"
)

// The base of demo and the packages that only demo adds, in install order.
var (
	basePackages = []string{"kyverno", "kyverno-policies-storage-local-path", "cert-manager",
		"amd-gpu-operator", "amd-gpu-operator-config", "kserve-crds", "kserve",
		"gateway-api-crds", "aim-engine-crds", "aim-engine", "aim-catalog"}
	demoOnly = []string{"envoy-gateway", "selfsigned-tls", "envoy-gateway-config",
		"opentelemetry-crds", "aiwb-demo-secrets", "postgres", "dex", "aiwb"}
)

func recordOf(entries map[string][]string) map[string]recordEntry {
	record := map[string]recordEntry{}
	for name, packages := range entries {
		record[name] = newEntry("test", nil, packages)
	}
	return record
}

func installedSet(packages ...string) func(string) bool {
	set := map[string]bool{}
	for _, pkg := range packages {
		set[pkg] = true
	}
	return func(pkg string) bool { return set[pkg] }
}

func reversed(list []string) []string {
	out := make([]string, 0, len(list))
	for i := len(list) - 1; i >= 0; i-- {
		out = append(out, list[i])
	}
	return out
}

func concat(lists ...[]string) []string {
	var out []string
	for _, list := range lists {
		out = append(out, list...)
	}
	return out
}

func mustLoadForRemoval(t *testing.T, name string) *profile {
	t.Helper()
	p, err := loadProfileForRemoval(name)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestTheSharedBaseStaysWhenBothProfilesAreRecorded(t *testing.T) {
	record := recordOf(map[string][]string{
		"demo":    concat(basePackages, demoOnly),
		"default": basePackages,
	})
	p := mustLoadForRemoval(t, "demo")
	installed := installedSet(concat(basePackages, demoOnly)...)

	plan, err := planRemoval(record, p, true, installed, packagesOfRun(record, p))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(plan.Remove, reversed(demoOnly)) {
		t.Errorf("the removal is %v, want the demo packages last first %v", plan.Remove, reversed(demoOnly))
	}
	if !reflect.DeepEqual(plan.Keep, reversed(basePackages)) {
		t.Errorf("the plan keeps %v, want every package of default", plan.Keep)
	}
	if len(plan.Skip) != 0 {
		t.Errorf("the plan skips %v, every package is installed", plan.Skip)
	}
}

func TestTheWholeProfileGoesWhenOnlyTheChildIsRecorded(t *testing.T) {
	all := concat(basePackages, demoOnly)
	record := recordOf(map[string][]string{"demo": all})
	p := mustLoadForRemoval(t, "demo")

	plan, err := planRemoval(record, p, true, installedSet(all...), packagesOfRun(record, p))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(plan.Remove, reversed(all)) {
		t.Errorf("the removal is %v, want every package in reverse install order", plan.Remove)
	}
	if len(plan.Keep) != 0 {
		t.Errorf("the plan keeps %v, no other profile is recorded", plan.Keep)
	}
	if len(plan.Namespaces) == 0 {
		t.Error("a purge deletes no namespace")
	}
	for _, namespace := range []string{"aiwb", "aim-system", "kyverno"} {
		if !contains(plan.Namespaces, namespace) {
			t.Errorf("the purge does not delete namespace %s: %v", namespace, plan.Namespaces)
		}
	}
}

func TestTheProfileFileGivesThePackagesWithoutARecord(t *testing.T) {
	p := mustLoadForRemoval(t, "default-cpu")
	var declared []string
	for _, entry := range p.Packages {
		declared = append(declared, entry.Name)
	}
	record := map[string]recordEntry{}

	plan, err := planRemoval(record, p, false, installedSet(declared...), packagesOfRun(record, p))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(plan.Remove, reversed(declared)) {
		t.Errorf("the removal is %v, want the profile file in reverse order %v", plan.Remove, reversed(declared))
	}
	if len(plan.Namespaces) != 0 {
		t.Errorf("--keep-data deletes namespaces %v", plan.Namespaces)
	}
}

func TestAPackageThatIsNotInstalledIsSkipped(t *testing.T) {
	record := recordOf(map[string][]string{"default-cpu": basePackages})
	p := mustLoadForRemoval(t, "default-cpu")

	plan, err := planRemoval(record, p, true, installedSet(), packagesOfRun(record, p))
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Remove) != 0 {
		t.Errorf("the plan removes %v, nothing is installed", plan.Remove)
	}
	if !reflect.DeepEqual(plan.Skip, reversed(basePackages)) {
		t.Errorf("the plan skips %v, want every recorded package", plan.Skip)
	}
	if len(plan.Namespaces) != 0 {
		t.Errorf("the purge deletes namespaces %v of packages that are not installed", plan.Namespaces)
	}
}

func TestAnInstalledPackageOutsideTheRecordKeepsItsProvider(t *testing.T) {
	p := mustLoadForRemoval(t, "default-cpu")
	record := map[string]recordEntry{}
	// aiwb is on the cluster but no record names it. It needs inference.aim
	// from aim-engine, so aim-engine must stay.
	installed := installedSet(concat(basePackages, []string{"aiwb"})...)

	_, err := planRemoval(record, p, true, installed, packagesOfRun(record, p))
	if err == nil {
		t.Fatal("the base profile went away under an installed aiwb")
	}
	if !strings.Contains(err.Error(), "aiwb is installed and needs") {
		t.Errorf("the message does not name the package that still needs the capability: %v", err)
	}

	meta, err := loadPackageMeta("aim-engine")
	if err != nil {
		t.Fatal(err)
	}
	if err := refuseWhenNeeded(meta, packagesOfRun(record, p), installed); err == nil {
		t.Error("refuseWhenNeeded let aim-engine go under an installed aiwb")
	}
	if err := refuseWhenNeeded(meta, packagesOfRun(record, p), installedSet(basePackages...)); err != nil {
		t.Errorf("refuseWhenNeeded held aim-engine back with no aiwb installed: %v", err)
	}
}
