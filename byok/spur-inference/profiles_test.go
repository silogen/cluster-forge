package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"sigs.k8s.io/yaml"
)

// A -cpu profile is a full copy of its GPU twin, not an extends child, because
// the GPU operator must install before aim-engine and extends cannot take a
// package out of the base list. The copies can drift apart, and the drift
// shows only at install time. These tests read the source files in
// ../profiles, so they need no `make assets`.

const aimEngineChart = "aim-engine-chart"

// The packages that only the GPU profiles hold.
var gpuPackages = map[string]bool{"amd-gpu-operator": true, "amd-gpu-operator-config": true}

var demoOnlyKeys = map[string]interface{}{
	aimEngineChart + ".crd.enable":                                   false,
	aimEngineChart + ".clusterRuntimeConfig.enable":                  false,
	aimEngineChart + ".scaleFromZero.gatewayMetricsCollector.enable": false,
}

func TestACPUProfileIsItsGPUTwinWithoutTheGPUPackages(t *testing.T) {
	for _, pair := range [][2]string{{"default", "default-cpu"}, {"demo", "demo-cpu"}} {
		gpu, cpu := sourceProfile(t, pair[0]), sourceProfile(t, pair[1])
		var gpuNames []string
		for _, entry := range gpu.Packages {
			if !gpuPackages[entry.Name] {
				gpuNames = append(gpuNames, entry.Name)
			}
		}
		if !reflect.DeepEqual(gpuNames, packageNames(cpu)) {
			t.Errorf("%s without the GPU packages holds %v, %s holds %v",
				pair[0], gpuNames, pair[1], packageNames(cpu))
		}

		// The GPU profile runs the Instinct detector and not the CPU one. The
		// CPU profile runs no detector, because it has no node-feature-discovery
		// to read the result.
		gpuLeaves, cpuLeaves := valueLeaves(gpu), valueLeaves(cpu)
		gpuWant := map[string]interface{}{
			"aim-catalog/aim-cluster-model-source.hardwareFamilies":            []interface{}{"instinct"},
			"aim-engine/" + aimEngineChart + ".acceleratorDetector.enable":     true,
			"aim-engine/" + aimEngineChart + ".acceleratorDetector.cpu.enable": false,
		}
		for key, value := range gpuWant {
			if !reflect.DeepEqual(gpuLeaves[key], value) {
				t.Errorf("%s: %s is %v, want %v", pair[0], key, gpuLeaves[key], value)
			}
			delete(gpuLeaves, key)
		}
		cpuWant := map[string]interface{}{
			"aim-catalog/aim-cluster-model-source.hardwareFamilies":        []interface{}{"epyc"},
			"aim-engine/" + aimEngineChart + ".acceleratorDetector.enable": false,
		}
		for key, value := range cpuWant {
			if !reflect.DeepEqual(cpuLeaves[key], value) {
				t.Errorf("%s: %s is %v, want %v", pair[1], key, cpuLeaves[key], value)
			}
			delete(cpuLeaves, key)
		}
		if !reflect.DeepEqual(gpuLeaves, cpuLeaves) {
			t.Errorf("the values of %s and %s differ beyond the three allowed keys:\n  %v\n  %v",
				pair[0], pair[1], gpuLeaves, cpuLeaves)
		}
	}
}

// mergeProfiles replaces a package entry as a whole, so the aim-engine entry
// of a demo must restate every value of the base entry.
func TestADemoRestatesTheAimEngineValuesOfItsBase(t *testing.T) {
	for _, pair := range [][2]string{{"default", "demo"}, {"default-cpu", "demo-cpu"}} {
		base, demo := rawProfile(t, pair[0]), rawProfile(t, pair[1])
		if demo.Extends != pair[0] {
			t.Errorf("%s extends %q, want %s", pair[1], demo.Extends, pair[0])
		}
		want := map[string]interface{}{}
		leaves("", packageValues(base, "aim-engine"), want)
		for key, value := range demoOnlyKeys {
			if _, taken := want[key]; taken {
				t.Errorf("%s already sets %s, the demo cannot add it", pair[0], key)
			}
			want[key] = value
		}
		got := map[string]interface{}{}
		leaves("", packageValues(demo, "aim-engine"), got)
		if !reflect.DeepEqual(got, want) {
			t.Errorf("the aim-engine values of %s are not those of %s plus the three demo keys:\n  got  %v\n  want %v",
				pair[1], pair[0], got, want)
		}
	}
}

// rawProfile reads one source file as it is, with extends unresolved.
func rawProfile(t *testing.T, name string) *profile {
	t.Helper()
	var p profile
	if err := yaml.Unmarshal(readSourceProfile(t, name), &p); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return &p
}

// sourceProfile reads one source file with extends resolved.
func sourceProfile(t *testing.T, name string) *profile {
	t.Helper()
	raw := readSourceProfile(t, name)
	head := rawProfile(t, name)
	if head.Extends != "" {
		var err error
		if raw, err = mergeProfiles(readSourceProfile(t, head.Extends), raw); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}
	var p profile
	if err := yaml.Unmarshal(raw, &p); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return &p
}

func readSourceProfile(t *testing.T, name string) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "profiles", name+".yaml"))
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func packageNames(p *profile) []string {
	var names []string
	for _, entry := range p.Packages {
		names = append(names, entry.Name)
	}
	return names
}

func packageValues(p *profile, name string) map[string]interface{} {
	for _, entry := range p.Packages {
		if entry.Name == name {
			return entry.Values
		}
	}
	return nil
}

// valueLeaves flattens the values of every package but the GPU packages to
// <package>/<dotted key>.
func valueLeaves(p *profile) map[string]interface{} {
	out := map[string]interface{}{}
	for _, entry := range p.Packages {
		if !gpuPackages[entry.Name] {
			leaves(entry.Name+"/", entry.Values, out)
		}
	}
	return out
}

func leaves(prefix string, values map[string]interface{}, out map[string]interface{}) {
	for key, value := range values {
		full := prefix + key
		if nested, ok := value.(map[string]interface{}); ok {
			leaves(full+".", nested, out)
			continue
		}
		out[full] = value
	}
}
