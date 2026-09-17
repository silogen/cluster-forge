package main

import (
	"strings"
	"testing"
	"testing/fstest"
)

// The profiles under test replace the embedded ones for the run of one test.
func withProfiles(t *testing.T, files map[string]string) {
	t.Helper()
	saved := profileFiles
	mapped := fstest.MapFS{}
	for name, content := range files {
		mapped[name+".yaml"] = &fstest.MapFile{Data: []byte(content)}
	}
	profileFiles = mapped
	t.Cleanup(func() { profileFiles = saved })
}

// A cluster that gives no capability at all.
func noCapability(string) bool { return false }

func validate(name string, vars map[string]string) error {
	p, err := loadProfile(name, vars)
	if err != nil {
		return err
	}
	return validateProfile(p, noCapability)
}

func expectFailure(t *testing.T, label, want string, err error) {
	t.Helper()
	if err == nil {
		t.Fatalf("%s passed", label)
	}
	if !strings.Contains(err.Error(), want) {
		t.Errorf("%s does not name the cause %q: %v", label, want, err)
	}
}

func TestValidationStopsOnAMissingCapability(t *testing.T) {
	withProfiles(t, map[string]string{
		"bad": `name: bad
packages:
  - name: gateway-api-crds
  - name: aim-engine-crds
  - name: aim-engine
`,
	})
	err := validate("bad", nil)
	expectFailure(t, "a profile with a missing capability", "serving.kserve", err)
	if !strings.Contains(err.Error(), "kserve") {
		t.Errorf("the message does not name a provider package: %v", err)
	}
}

func TestTheProfileFormat(t *testing.T) {
	withProfiles(t, map[string]string{
		"base": `name: base
packages:
  - name: gateway-api-crds
`,
		"no-base": `name: no-base
extends: missing
packages: []
`,
		"chain-base": `name: chain-base
extends: base
packages: []
`,
		"chain": `name: chain
extends: chain-base
packages: []
`,
		"empty-var": `name: empty-var
vars:
  domain:
packages:
  - name: gateway-api-crds
    values:
      crds:
        domain: ${domain}
`,
		"undeclared": `name: undeclared
packages:
  - name: gateway-api-crds
    values:
      crds:
        domain: ${nowhere}
`,
		"child": `name: child
extends: base
vars:
  domain:
  optional: ""
packages:
  - name: gateway-api-crds
    values:
      crds:
        domain: ${domain}
        extra: "${optional}"
notes: |
  URL: https://ui.${domain}
`,
	})

	expectFailure(t, "extends of a missing base", "no such profile: missing", validate("no-base", nil))
	expectFailure(t, "an extends chain", "one level only", validate("chain", nil))
	expectFailure(t, "a required var without a value", "domain", validate("empty-var", nil))
	expectFailure(t, "an undeclared variable in the text", "nowhere", validate("undeclared", nil))
	expectFailure(t, "--var for a name that the profile does not declare", "does not declare",
		validate("base", map[string]string{"domain": "example.com"}))

	p, err := loadProfile("child", map[string]string{"domain": "example.com"})
	if err != nil {
		t.Fatalf("the good profile did not load: %v", err)
	}
	if err := validateProfile(p, noCapability); err != nil {
		t.Fatalf("the good profile did not validate: %v", err)
	}
	if p.Extends != "base" || len(p.Packages) != 1 {
		t.Errorf("extends was not resolved: %+v", p)
	}
	if !strings.Contains(p.Notes, "https://ui.example.com") {
		t.Errorf("the notes do not hold the variable value: %q", p.Notes)
	}
	values, _ := p.Packages[0].Values["crds"].(map[string]interface{})
	if values["domain"] != "example.com" {
		t.Errorf("the values do not hold the variable value: %v", values)
	}
	// An optional variable with an empty value must stay an empty string, not
	// become null: helm drops a null key and the chart default takes over.
	if extra, ok := values["extra"].(string); !ok || extra != "" {
		t.Errorf("the empty optional variable is %#v, want an empty string", values["extra"])
	}
}
