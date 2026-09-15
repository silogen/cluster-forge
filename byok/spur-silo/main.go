// spur-silo installs an AMD Enterprise AI profile on the Kubernetes cluster
// that Spur manages. Spur runs it as `spur silo ...` when it is on PATH; it
// also works when it is called directly. Every chart it installs is inside the
// binary, so it needs no helm, kubectl, yq, jq or git, and no network access to
// GitHub.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/yaml"
)

const (
	pullSecretName      = "aim-pull"
	pullSecretNamespace = "aim-system"
)

// version is the cluster-forge ref the binary was built from. The Makefile
// sets it.
var version = "dev"

type options struct {
	kubeconfig string
	pullSecret string
	vars       map[string]string
	noGPU      bool
	keepData   bool
	smokeTest  bool
}

func main() {
	// An operator that stops the command expects helm to stop with it.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		usage(os.Stdout)
		return nil
	}
	command := args[0]
	target, opts, err := parseArgs(args[1:])
	if err != nil {
		return err
	}

	switch command {
	case "install":
		if target == "" {
			return fmt.Errorf("a profile name is needed")
		}
		return cmdInstall(ctx, target, opts)
	case "uninstall":
		if target == "" {
			return fmt.Errorf("a profile name is needed")
		}
		return cmdUninstall(ctx, target, opts)
	case "validate":
		if target == "" {
			return fmt.Errorf("a profile name is needed")
		}
		return cmdValidate(ctx, target, opts)
	case "status":
		return cmdStatus(ctx, opts)
	case "list":
		return cmdList()
	case "version":
		fmt.Printf("spur-silo %s\n", version)
		return nil
	case "help", "-h", "--help":
		usage(os.Stdout)
		return nil
	default:
		usage(os.Stderr)
		return fmt.Errorf("unknown command: %s", command)
	}
}

func parseArgs(args []string) (string, options, error) {
	opts := options{vars: map[string]string{}}
	target := ""
	for i := 0; i < len(args); i++ {
		needsValue := func() (string, error) {
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s needs a value", args[i])
			}
			i++
			return args[i], nil
		}
		var err error
		switch args[i] {
		case "--kubeconfig":
			opts.kubeconfig, err = needsValue()
		case "--pull-secret":
			opts.pullSecret, err = needsValue()
		case "--var":
			var pair string
			if pair, err = needsValue(); err == nil {
				name, value, found := strings.Cut(pair, "=")
				if !found {
					return "", opts, fmt.Errorf("--var needs name=value, got %s", pair)
				}
				opts.vars[name] = value
			}
		case "--no-gpu":
			opts.noGPU = true
		case "--keep-data":
			opts.keepData = true
		case "--smoke-test":
			opts.smokeTest = true
		case "-h", "--help":
			usage(os.Stdout)
			os.Exit(0)
		default:
			if strings.HasPrefix(args[i], "-") {
				return "", opts, fmt.Errorf("unknown flag: %s", args[i])
			}
			if target != "" {
				return "", opts, fmt.Errorf("only one profile is allowed, got %s and %s", target, args[i])
			}
			target = args[i]
		}
		if err != nil {
			return "", opts, err
		}
	}
	return target, opts, nil
}

func usage(w *os.File) {
	fmt.Fprint(w, `Usage:
  spur silo install   <profile> [--var name=value]... [--kubeconfig <path>]
                      [--pull-secret <docker-config.json>] [--no-gpu] [--smoke-test]
  spur silo uninstall <profile> [--keep-data]
  spur silo status
  spur silo list
  spur silo validate  <profile> [--var name=value]...
  spur silo version

Options:
  --var name=value     Fill a variable that the profile declares. Repeat it
                       for every variable. There is no auto-fill.
  --kubeconfig <path>  Use this kubeconfig instead of asking Spur for one.
                       Without it the binary asks Spur, then Spur under sudo,
                       then a local k0s.
  --pull-secret <file> A docker config json. The binary makes the Secret
                       aim-pull in the namespace aim-system from it. The
                       images are public; a secret only lifts the Docker Hub
                       rate limit.
  --no-gpu             Do not select the GPU profile on a cluster that has
                       AMD Instinct GPUs.
  --smoke-test         Run the smoke test of the profile after the install.
  --keep-data          Keep the PVCs and the CRDs of the profile.

The charts of this release are inside the binary. An upgrade is an install
from a newer binary; there is no upgrade command and no --ref.

Environment:
  KUBECONFIG           Used when --kubeconfig is not given.
  PULL_SECRET_JSON     Same content as --pull-secret, as a string.
  SPUR_BIN             The spur binary to ask for a kubeconfig and for the
                       node GRES. Spur sets it for a plugin.
`)
}

func infof(format string, v ...interface{}) {
	fmt.Printf("%s\n", fmt.Sprintf(format, v...))
}

func yamlUnmarshal(data []byte, out interface{}) error { return yaml.Unmarshal(data, out) }

func isAlreadyExists(err error) bool { return apierrors.IsAlreadyExists(err) }

func cmdList() error {
	names, err := profileNames()
	if err != nil {
		return err
	}
	fmt.Printf("Profiles of cluster-forge %s:\n", version)
	for _, name := range names {
		p, err := loadProfileHead(name)
		if err != nil {
			return err
		}
		description := "no variables"
		if len(p) > 0 {
			sort.Strings(p)
			description = "variables: " + strings.Join(p, ", ")
		}
		fmt.Printf("  %-26s %s\n", name, description)
	}
	return nil
}

// loadProfileHead gives the variable names a profile declares, with no value
// needed.
func loadProfileHead(name string) ([]string, error) {
	raw, err := readProfile(name)
	if err != nil {
		return nil, err
	}
	var head struct {
		Vars map[string]*string `json:"vars"`
	}
	if err := yaml.Unmarshal(raw, &head); err != nil {
		return nil, err
	}
	names := make([]string, 0, len(head.Vars))
	for name := range head.Vars {
		names = append(names, name)
	}
	return names, nil
}

func cmdValidate(ctx context.Context, name string, opts options) error {
	c, err := connect(opts.kubeconfig)
	if err != nil {
		return err
	}
	defer c.close()
	p, err := loadProfile(name, opts.vars)
	if err != nil {
		return err
	}
	return validateProfile(context.Background(), c, p)
}

// validateProfile holds every `requires` of a package to an earlier package of
// the profile or to a live cluster probe.
func validateProfile(ctx context.Context, c *cluster, p *profile) error {
	provided := map[string]bool{}
	for _, entry := range p.Packages {
		meta, err := loadPackageMeta(entry.Name)
		if err != nil {
			return err
		}
		for _, capability := range meta.Requires {
			if provided[capability] || probe(ctx, c, capability) {
				continue
			}
			providers, err := providersOf(capability)
			if err != nil {
				return err
			}
			return fmt.Errorf("package %s needs capability %s\n"+
				"  no earlier package in the profile provides it and the cluster probe failed\n"+
				"  packages that provide it: %s",
				entry.Name, capability, strings.Join(providers, " "))
		}
		for _, capability := range meta.Provides {
			provided[capability] = true
		}
	}
	infof("validation passed for profile %s", p.Name)
	return nil
}

func providersOf(capability string) ([]string, error) {
	names, err := allPackageNames()
	if err != nil {
		return nil, err
	}
	var providers []string
	for _, name := range names {
		meta, err := loadPackageMeta(name)
		if err != nil {
			continue
		}
		for _, provided := range meta.Provides {
			if provided == capability {
				providers = append(providers, name)
			}
		}
	}
	return providers, nil
}

func cmdInstall(ctx context.Context, name string, opts options) error {
	c, err := connect(opts.kubeconfig)
	if err != nil {
		return err
	}
	defer c.close()

	if name == "scalable-inference" && !opts.noGPU {
		if nodes := instinctNodes(); len(nodes) > 0 {
			infof("detected AMD GPUs on nodes %s, using profile scalable-inference-gpu",
				strings.Join(nodes, ","))
			name = "scalable-inference-gpu"
		}
	}

	p, err := loadProfile(name, opts.vars)
	if err != nil {
		return err
	}
	if err := refuseOverlappingProfile(ctx, c, p); err != nil {
		return err
	}
	if err := validateProfile(ctx, c, p); err != nil {
		return err
	}
	if err := ensurePullSecret(ctx, c, opts); err != nil {
		return err
	}

	var installed []string
	for _, entry := range p.Packages {
		meta, err := loadPackageMeta(entry.Name)
		if err != nil {
			return err
		}
		infof("install %s into namespace %s", meta.Name, meta.Namespace)
		if err := installPackage(ctx, c, meta.Name, meta.Namespace, entry.Values); err != nil {
			return err
		}
		installed = append(installed, meta.Name)
	}

	if err := writeRecord(ctx, c, p.Name, newEntry(version, opts.vars, installed)); err != nil {
		return err
	}
	infof("install record written for profile %s", p.Name)
	if p.Notes != "" {
		fmt.Printf("\n%s\n", p.Notes)
	}
	infof("install finished")

	if opts.smokeTest {
		return smokeTest(ctx, c, p.Name)
	}
	return nil
}

func cmdUninstall(ctx context.Context, name string, opts options) error {
	c, err := connect(opts.kubeconfig)
	if err != nil {
		return err
	}
	defer c.close()

	// The package names need no variable value, so an uninstall asks for none.
	p, err := loadProfileForRemoval(name)
	if err != nil {
		return err
	}
	record, err := readRecord(ctx, c)
	if err != nil {
		return err
	}

	// What the install recorded wins: it is what really went onto the cluster.
	packages := record[p.Name].Packages
	if len(packages) == 0 {
		for _, entry := range p.Packages {
			packages = append(packages, entry.Name)
		}
	}
	keep := packagesOfOtherProfiles(record, p.Name)
	purge := !opts.keepData

	var emptied []string
	stays := map[string]bool{}
	for i := len(packages) - 1; i >= 0; i-- {
		pkg := packages[i]
		meta, err := loadPackageMeta(pkg)
		if err != nil {
			return err
		}
		if keep[pkg] {
			infof("keep %s, another installed profile holds it", pkg)
			stays[meta.Namespace] = true
			continue
		}
		if !isInstalled(c, meta.Name, meta.Namespace) {
			infof("skip %s, it is not installed", pkg)
			continue
		}
		if err := refuseWhenNeeded(ctx, c, meta); err != nil {
			return err
		}
		if err := removePackage(ctx, c, meta.Name, meta.Namespace, purge); err != nil {
			return err
		}
		emptied = append(emptied, meta.Namespace)
	}

	if purge {
		done := map[string]bool{}
		for _, namespace := range emptied {
			if done[namespace] || stays[namespace] {
				continue
			}
			done[namespace] = true
			if err := purgeNamespace(ctx, c, namespace); err != nil {
				return err
			}
		}
	}
	if err := forgetRecord(ctx, c, p.Name); err != nil {
		return err
	}
	infof("profile %s removed", p.Name)
	return nil
}

// refuseOverlappingProfile stops an install that would put a second name on
// packages another profile already holds. An install of the same profile is an
// upgrade and goes through. A profile that only extends the installed one, and
// adds packages to it, goes through too.
func refuseOverlappingProfile(ctx context.Context, c *cluster, p *profile) error {
	record, err := readRecord(ctx, c)
	if err != nil {
		return err
	}
	names := make([]string, 0, len(p.Packages))
	for _, entry := range p.Packages {
		names = append(names, entry.Name)
	}
	other, shared := overlappingProfile(record, p.Name, p.Extends, names)
	if other == "" {
		return nil
	}
	return fmt.Errorf("profile %s is installed and holds %d of the packages of %s: %s\n"+
		"  two profiles over the same packages cannot be removed one at a time\n"+
		"  uninstall %s first, or install %s again to upgrade it",
		other, len(shared), p.Name, strings.Join(shared, " "), other, other)
}

// overlappingProfile names a recorded profile that shares packages with the
// one that goes on now. An install of the same profile is an upgrade, and a
// profile that says `extends` the recorded one is the documented way to add to
// it, so neither is an overlap. Two profiles that only happen to share
// packages, such as the CPU and the GPU build of one profile, are: the second
// install writes its own values over the charts of the first.
func overlappingProfile(record map[string]recordEntry, name, extends string, packages []string) (string, []string) {
	mine := map[string]bool{}
	for _, pkg := range packages {
		mine[pkg] = true
	}
	for _, other := range recordedProfileNames(record) {
		if other == name || other == extends {
			continue
		}
		theirs := record[other].Packages
		var shared []string
		for _, pkg := range theirs {
			if mine[pkg] {
				shared = append(shared, pkg)
			}
		}
		if len(shared) == 0 {
			continue
		}
		return other, shared
	}
	return "", nil
}

// refuseWhenNeeded stops a removal that would take a capability away from a
// package that is still installed.
func refuseWhenNeeded(ctx context.Context, c *cluster, meta *packageMeta) error {
	if len(meta.Provides) == 0 {
		return nil
	}
	names, err := allPackageNames()
	if err != nil {
		return err
	}
	for _, other := range names {
		if other == meta.Name {
			continue
		}
		otherMeta, err := loadPackageMeta(other)
		if err != nil {
			continue
		}
		for _, capability := range meta.Provides {
			if !contains(otherMeta.Requires, capability) {
				continue
			}
			if isInstalled(c, otherMeta.Name, otherMeta.Namespace) {
				return fmt.Errorf("%s is installed and needs %s from %s",
					otherMeta.Name, capability, meta.Name)
			}
		}
	}
	return nil
}

func contains(list []string, want string) bool {
	for _, item := range list {
		if item == want {
			return true
		}
	}
	return false
}

// loadProfileForRemoval resolves extends but gives every declared variable an
// empty value, because a removal reads the package names only.
func loadProfileForRemoval(name string) (*profile, error) {
	declared, err := loadProfileHead(name)
	if err != nil {
		return nil, err
	}
	vars := map[string]string{}
	for _, v := range declared {
		vars[v] = ""
	}
	return loadProfile(name, vars)
}

func cmdStatus(ctx context.Context, opts options) error {
	c, err := connect(opts.kubeconfig)
	if err != nil {
		return err
	}
	defer c.close()

	record, err := readRecord(ctx, c)
	if err != nil {
		return err
	}
	if len(record) == 0 {
		fmt.Println("No profile is recorded on this cluster.")
	} else {
		fmt.Println("Installed profiles:")
		for _, name := range recordedProfileNames(record) {
			entry := record[name]
			fmt.Printf("  %s\n    ref:       %s\n    installed: %s\n    variables: %s\n",
				name, entry.Ref, entry.Installed, varsLine(entry.Vars))
		}
	}

	fmt.Println()
	fmt.Println("Capabilities on the cluster:")
	for _, capability := range capabilityNames() {
		answer := "no"
		if probe(ctx, c, capability) {
			answer = "yes"
		}
		fmt.Printf("  %-32s %s\n", capability, answer)
	}
	return nil
}

func varsLine(vars map[string]string) string {
	if len(vars) == 0 {
		return "none"
	}
	names := make([]string, 0, len(vars))
	for name := range vars {
		names = append(names, name)
	}
	sort.Strings(names)
	pairs := make([]string, 0, len(names))
	for _, name := range names {
		pairs = append(pairs, fmt.Sprintf("%s=%s", name, vars[name]))
	}
	return strings.Join(pairs, ", ")
}

func ensurePullSecret(ctx context.Context, c *cluster, opts options) error {
	content := os.Getenv("PULL_SECRET_JSON")
	if opts.pullSecret != "" {
		b, err := os.ReadFile(opts.pullSecret)
		if err != nil {
			return fmt.Errorf("no such pull secret file: %s", opts.pullSecret)
		}
		content = string(b)
	}
	if content == "" {
		return nil
	}

	infof("make the Secret %s in the namespace %s", pullSecretName, pullSecretNamespace)
	namespaces := c.typed.CoreV1().Namespaces()
	if _, err := namespaces.Get(ctx, pullSecretNamespace, metav1.GetOptions{}); isNotFound(err) {
		ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: pullSecretNamespace}}
		if _, err := namespaces.Create(ctx, ns, metav1.CreateOptions{}); err != nil && !isAlreadyExists(err) {
			return err
		}
	}
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: pullSecretName, Namespace: pullSecretNamespace},
		Type:       corev1.SecretTypeDockerConfigJson,
		Data:       map[string][]byte{corev1.DockerConfigJsonKey: []byte(content)},
	}
	secrets := c.typed.CoreV1().Secrets(pullSecretNamespace)
	if _, err := secrets.Create(ctx, secret, metav1.CreateOptions{}); err != nil {
		if !isAlreadyExists(err) {
			return err
		}
		if _, err := secrets.Update(ctx, secret, metav1.UpdateOptions{}); err != nil {
			return err
		}
	}
	return nil
}
