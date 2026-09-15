package main

import (
	"embed"
	"fmt"
	"io/fs"
	"path"
	"regexp"
	"sort"
	"strings"

	"helm.sh/helm/v3/pkg/chart"
	"helm.sh/helm/v3/pkg/chart/loader"
	"sigs.k8s.io/yaml"
)

// The packages, the profiles and the capability list of one release. `make
// assets` fills the directory from byok/ and runs `helm dependency build`, so
// every chart the binary installs is inside it.
//
//go:embed all:assets
var assets embed.FS

type profile struct {
	Name     string            `json:"name"`
	Extends  string            `json:"extends"`
	Vars     map[string]*string `json:"vars"`
	Packages []profilePackage  `json:"packages"`
	Notes    string            `json:"notes"`
}

type profilePackage struct {
	Name   string                 `json:"name"`
	Values map[string]interface{} `json:"values"`
}

type packageMeta struct {
	Name      string   `json:"name"`
	Namespace string   `json:"namespace"`
	Provides  []string `json:"provides"`
	Requires  []string `json:"requires"`
}

func profileNames() ([]string, error) {
	entries, err := fs.ReadDir(assets, "assets/profiles")
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".yaml") {
			names = append(names, strings.TrimSuffix(e.Name(), ".yaml"))
		}
	}
	sort.Strings(names)
	return names, nil
}

// loadProfile resolves `extends` and fills every declared variable. A variable
// that the profile declares as null needs a value in vars.
func loadProfile(name string, vars map[string]string) (*profile, error) {
	raw, err := readProfile(name)
	if err != nil {
		return nil, err
	}
	var head profile
	if err := yaml.Unmarshal(raw, &head); err != nil {
		return nil, fmt.Errorf("profile %s: %w", name, err)
	}
	if head.Extends != "" {
		base, err := readProfile(head.Extends)
		if err != nil {
			return nil, fmt.Errorf("profile %s extends %s: %w", name, head.Extends, err)
		}
		var baseProfile profile
		if err := yaml.Unmarshal(base, &baseProfile); err != nil {
			return nil, err
		}
		if baseProfile.Extends != "" {
			return nil, fmt.Errorf("profile %s itself extends another profile, one level only", head.Extends)
		}
		raw, err = mergeProfiles(base, raw)
		if err != nil {
			return nil, err
		}
	}
	filled, err := substituteVars(raw, vars)
	if err != nil {
		return nil, fmt.Errorf("profile %s: %w", name, err)
	}
	var p profile
	if err := yaml.Unmarshal(filled, &p); err != nil {
		return nil, fmt.Errorf("profile %s: %w", name, err)
	}
	return &p, nil
}

func readProfile(name string) ([]byte, error) {
	if !validName(name) {
		return nil, fmt.Errorf("no such profile: %s", name)
	}
	b, err := assets.ReadFile(path.Join("assets/profiles", name+".yaml"))
	if err != nil {
		return nil, fmt.Errorf("no such profile: %s", name)
	}
	return b, nil
}

var nameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

func validName(s string) bool { return nameRe.MatchString(s) }

// mergeProfiles keeps the order of the base packages. A child entry with the
// same name replaces the base entry in place, and child-only entries follow in
// child order. Every other key of the child wins.
func mergeProfiles(base, child []byte) ([]byte, error) {
	var b, c map[string]interface{}
	if err := yaml.Unmarshal(base, &b); err != nil {
		return nil, err
	}
	if err := yaml.Unmarshal(child, &c); err != nil {
		return nil, err
	}
	basePkgs := packageList(b["packages"])
	childPkgs := packageList(c["packages"])

	merged := make([]interface{}, 0, len(basePkgs)+len(childPkgs))
	seen := map[string]bool{}
	for _, bp := range basePkgs {
		name := packageName(bp)
		seen[name] = true
		if cp := findPackage(childPkgs, name); cp != nil {
			merged = append(merged, cp)
			continue
		}
		merged = append(merged, bp)
	}
	for _, cp := range childPkgs {
		if !seen[packageName(cp)] {
			merged = append(merged, cp)
		}
	}

	out := map[string]interface{}{}
	for k, v := range b {
		out[k] = v
	}
	for k, v := range c {
		out[k] = v
	}
	out["packages"] = merged
	delete(out, "extends")
	return yaml.Marshal(out)
}

func packageList(v interface{}) []interface{} {
	list, _ := v.([]interface{})
	return list
}

func packageName(v interface{}) string {
	m, _ := v.(map[string]interface{})
	name, _ := m["name"].(string)
	return name
}

func findPackage(list []interface{}, name string) interface{} {
	for _, p := range list {
		if packageName(p) == name {
			return p
		}
	}
	return nil
}

var varRe = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)\}`)

// substituteVars replaces ${name} with the value of every declared variable.
// A declared default of null means required; an empty string means optional.
func substituteVars(raw []byte, given map[string]string) ([]byte, error) {
	var head struct {
		Vars map[string]*string `json:"vars"`
	}
	if err := yaml.Unmarshal(raw, &head); err != nil {
		return nil, err
	}
	values := map[string]string{}
	for name, def := range head.Vars {
		if v, ok := given[name]; ok {
			values[name] = v
			continue
		}
		if def == nil {
			return nil, fmt.Errorf("the profile needs --var %s=<value>", name)
		}
		values[name] = *def
	}
	for name := range given {
		if _, ok := head.Vars[name]; !ok {
			return nil, fmt.Errorf("the profile does not declare the variable %s", name)
		}
	}

	var missing []string
	out := varRe.ReplaceAllStringFunc(string(raw), func(m string) string {
		name := varRe.FindStringSubmatch(m)[1]
		v, ok := values[name]
		if !ok {
			missing = append(missing, name)
			return m
		}
		return v
	})
	if len(missing) > 0 {
		sort.Strings(missing)
		return nil, fmt.Errorf("the profile uses variables that it does not declare: %s",
			strings.Join(missing, " "))
	}
	return []byte(out), nil
}

func loadPackageMeta(name string) (*packageMeta, error) {
	if !validName(name) {
		return nil, fmt.Errorf("unknown package: %s", name)
	}
	b, err := assets.ReadFile(path.Join("assets/packages", name, "package.yaml"))
	if err != nil {
		return nil, fmt.Errorf("unknown package: %s", name)
	}
	var m packageMeta
	if err := yaml.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("package %s: %w", name, err)
	}
	if m.Namespace == "" {
		return nil, fmt.Errorf("package %s declares no namespace", name)
	}
	return &m, nil
}

func allPackageNames() ([]string, error) {
	entries, err := fs.ReadDir(assets, "assets/packages")
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names, nil
}

// loadChart reads one embedded umbrella chart, its values and its dependency
// archives, so no chart is fetched at run time.
func loadChart(name string) (*chart.Chart, error) {
	root := path.Join("assets/packages", name)
	var files []*loader.BufferedFile
	err := fs.WalkDir(assets, root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := assets.ReadFile(p)
		if err != nil {
			return err
		}
		rel := strings.TrimPrefix(strings.TrimPrefix(p, root), "/")
		if rel == "package.yaml" {
			return nil
		}
		files = append(files, &loader.BufferedFile{Name: rel, Data: b})
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("package %s: %w", name, err)
	}
	c, err := loader.LoadFiles(files)
	if err != nil {
		return nil, fmt.Errorf("package %s: %w", name, err)
	}
	return c, nil
}
