// spur-inference installs an AMD Enterprise AI profile on the Kubernetes cluster
// that Spur manages. Spur runs it as `spur inference ...` when it is on PATH;
// it also works when it is called directly. Every chart it installs is inside
// the binary, so it needs no helm, kubectl, yq, jq or git, and no network access
// to GitHub.
package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
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
	yes        bool
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

	// A blank name is the default profile, and --no-gpu names its CPU twin.
	// Both rules apply here, so that install and validate agree on the name.
	if command == "install" || command == "validate" {
		if target == "" {
			target = "default"
		}
		if opts.noGPU {
			if strings.HasSuffix(target, "-cpu") {
				return fmt.Errorf("profile %s already ends with -cpu, --no-gpu is not needed", target)
			}
			target += "-cpu"
		}
	}

	switch command {
	case "install":
		return cmdInstall(ctx, target, opts)
	case "uninstall":
		return cmdUninstall(ctx, target, opts)
	case "validate":
		return cmdValidate(ctx, target, opts)
	case "status":
		return cmdStatus(ctx, opts)
	case "list":
		return cmdList()
	case "version":
		fmt.Printf("spur-inference %s\n", version)
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
		case "--yes":
			opts.yes = true
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
  spur inference install   [<profile>] [--var name=value]... [--kubeconfig <path>]
                           [--pull-secret <docker-config.json>] [--no-gpu] [--smoke-test]
  spur inference uninstall [<profile>] [--keep-data] [--yes] [--kubeconfig <path>]
  spur inference status    [--kubeconfig <path>]
  spur inference list
  spur inference validate  [<profile>] [--var name=value]... [--kubeconfig <path>]
  spur inference version

A blank profile name is default, the profile on AMD Instinct GPUs. For
uninstall a blank name is every recorded profile. An uninstall shows what
goes and asks before it removes anything.

Options:
  --var name=value     Fill a variable that the profile declares. Repeat it
                       for every variable. There is no auto-fill.
  --kubeconfig <path>  Use this kubeconfig instead of asking Spur for one.
                       Every command but list takes it.
                       Without it the binary asks Spur, then Spur under sudo,
                       then a local k0s.
  --pull-secret <file> A docker config json. The binary makes the Secret
                       aim-pull in the namespace aim-system from it. The
                       images are public; a secret only lifts the Docker Hub
                       rate limit.
  --no-gpu             Add -cpu to the profile name: install and validate
                       then use the profile with no AMD GPU operator. A
                       cluster with no GPU needs it.
  --smoke-test         Run the smoke test of the profile after the install.
  --keep-data          Keep the PVCs and the CRDs of the profile.
  --yes                Remove without the question. An uninstall whose stdin
                       is not a terminal needs it.

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
	warnAboutGPUs(p.Name)
	return validateProfile(p, c.probe(ctx))
}

// probe gives the capability check of this cluster as a function, so that a
// test can pass one that never asks a cluster.
func (c *cluster) probe(ctx context.Context) func(capability string) bool {
	return func(capability string) bool { return probe(ctx, c, capability) }
}

// installed says whether the release of a package is on this cluster.
func (c *cluster) installed(pkg string) bool {
	meta, err := loadPackageMeta(pkg)
	return err == nil && isInstalled(c, meta.Name, meta.Namespace)
}

// warnAboutGPUs tells the operator when the profile name and the GPUs that
// Spur reports do not go together. It never changes the name and never stops
// the command: the operator can know more than the scan, for example a node
// that Spur has not registered yet.
func warnAboutGPUs(name string) {
	nodes, err := gpuNodes()
	if err != nil {
		infof("no GPU check: %v", err)
		return
	}
	cpuProfile := strings.HasSuffix(name, "-cpu")
	var instinct []string
	for _, n := range nodes {
		switch classifyGPU(n.Type) {
		case gpuInstinct:
			instinct = append(instinct, n.Node)
		case gpuOtherAMD:
			infof("warning: node %s has the GPU %s, which is not an AMD Instinct GPU.\n"+
				"  The GPU profile supports Instinct only; the -cpu profile is the supported choice on this node.\n"+
				"  The node-feature-discovery rule of the GPU operator labels this node as an AMD GPU node too,\n"+
				"  so on the GPU profile the Instinct detector schedules onto it, and what it reports there is untested.",
				n.Node, n.Type)
		}
	}
	switch {
	case cpuProfile && len(instinct) > 0:
		infof("warning: profile %s does not use the AMD Instinct GPUs of nodes %s",
			name, strings.Join(instinct, ","))
	case !cpuProfile && len(nodes) == 0:
		infof("warning: Spur reports no GPU on this cluster, and profile %s installs the AMD GPU operator\n"+
			"  and the GPU detector. A cluster with no GPU needs --no-gpu, which selects profile %s-cpu.",
			name, name)
	}
}

// validateProfile holds every `requires` of a package to an earlier package of
// the profile or to the cluster probe.
func validateProfile(p *profile, probe func(capability string) bool) error {
	provided := map[string]bool{}
	for _, entry := range p.Packages {
		meta, err := loadPackageMeta(entry.Name)
		if err != nil {
			return err
		}
		for _, capability := range meta.Requires {
			if provided[capability] || probe(capability) {
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

	p, err := loadProfile(name, opts.vars)
	if err != nil {
		return err
	}
	warnAboutGPUs(p.Name)
	if err := refuseOverlappingProfile(ctx, c, p); err != nil {
		return err
	}
	if err := validateProfile(p, c.probe(ctx)); err != nil {
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
			// The packages that did go on are on the cluster whatever happens
			// next. Without a record, `uninstall` cannot know which they are.
			partial := newEntry(version, opts.vars, append(installed, meta.Name))
			partial.Partial = true
			if writeErr := writeRecord(ctx, c, p.Name, partial); writeErr != nil {
				infof("the install record of the packages that went on could not be written: %v", writeErr)
			}
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
	// A pipe is never a yes: a script gives --yes. Say so before any work.
	if !opts.yes && !stdinIsTerminal() {
		return fmt.Errorf("stdin is not a terminal, give --yes to remove without the question")
	}
	c, err := connect(opts.kubeconfig)
	if err != nil {
		return err
	}
	defer c.close()

	record, err := readRecord(ctx, c)
	if err != nil {
		return err
	}
	names := []string{name}
	if name == "" {
		if len(record) == 0 {
			fmt.Println("No profile is recorded on this cluster.")
			return nil
		}
		names, err = removalOrder(record)
		if err != nil {
			return err
		}
	}

	// The package names need no variable value, so an uninstall asks for none.
	profiles := make([]*profile, 0, len(names))
	for _, name := range names {
		p, err := loadProfileForRemoval(name)
		if err != nil {
			return err
		}
		profiles = append(profiles, p)
	}

	// Every profile of the run is planned before the first removal, so that
	// the question shows the whole run. The record loses each profile as it
	// is planned, or a base would keep every package of the child that goes
	// before it.
	purge := !opts.keepData
	mine := packagesOfRun(record, profiles...)
	planned := map[string]recordEntry{}
	for name, entry := range record {
		planned[name] = entry
	}
	plans := make([]*removal, 0, len(profiles))
	for _, p := range profiles {
		plan, err := planRemoval(planned, p, purge, c.installed, mine)
		if err != nil {
			return err
		}
		delete(planned, p.Name)
		plans = append(plans, plan)
	}

	printRemoval(os.Stdout, plans)
	if err := confirm(opts.yes); err != nil {
		return err
	}
	for _, plan := range plans {
		if err := executeRemoval(ctx, c, plan, purge); err != nil {
			return err
		}
	}
	return nil
}

// removalOrder gives every recorded profile, a profile that extends another
// recorded profile before its base.
func removalOrder(record map[string]recordEntry) ([]string, error) {
	var children, rest []string
	for _, name := range recordedProfileNames(record) {
		p, err := loadProfileForRemoval(name)
		if err != nil {
			return nil, err
		}
		if _, recorded := record[p.Extends]; p.Extends != "" && recorded {
			children = append(children, name)
			continue
		}
		rest = append(rest, name)
	}
	return append(children, rest...), nil
}

func printRemoval(w io.Writer, plans []*removal) {
	for _, plan := range plans {
		fmt.Fprintf(w, "Profile %s\n", plan.Profile)
		fmt.Fprintf(w, "  remove:     %s\n", listOrNone(plan.Remove))
		if len(plan.Keep) > 0 {
			fmt.Fprintf(w, "  keep:       %s (another installed profile holds them)\n", strings.Join(plan.Keep, " "))
		}
		if len(plan.Skip) > 0 {
			fmt.Fprintf(w, "  skip:       %s (not installed)\n", strings.Join(plan.Skip, " "))
		}
		if len(plan.Namespaces) > 0 {
			fmt.Fprintf(w, "  namespaces: %s (the purge deletes them with their PVCs)\n", strings.Join(plan.Namespaces, " "))
		}
	}
}

func listOrNone(list []string) string {
	if len(list) == 0 {
		return "nothing"
	}
	return strings.Join(list, " ")
}

// confirm asks `Remove? [y/N]` on the terminal.
func confirm(yes bool) error {
	if yes {
		return nil
	}
	fmt.Print("Remove? [y/N] ")
	line, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil && line == "" {
		return fmt.Errorf("no answer, nothing was removed")
	}
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "y", "yes":
		return nil
	}
	return fmt.Errorf("nothing was removed")
}

func stdinIsTerminal() bool {
	info, err := os.Stdin.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

// removal is what the uninstall of one profile takes off the cluster, and
// what it leaves there.
type removal struct {
	Profile string
	// Remove holds the packages in removal order: the last package first.
	Remove []string
	// Keep holds the packages that stay because another recorded profile
	// holds them.
	Keep []string
	// Skip holds the packages of the profile that are not installed.
	Skip []string
	// Namespaces holds the namespaces that the purge deletes, in order.
	Namespaces []string
}

// packagesOfRun gives every package that this uninstall run owns: what the
// profile declares and what its record names. Everything in it goes away in
// this run, so one of these packages never holds another one back. A failed
// install leaves a release that the record does not name, and without this
// the profile could not be removed at all.
func packagesOfRun(record map[string]recordEntry, profiles ...*profile) map[string]bool {
	mine := map[string]bool{}
	for _, p := range profiles {
		for _, entry := range p.Packages {
			mine[entry.Name] = true
		}
		for _, pkg := range record[p.Name].Packages {
			mine[pkg] = true
		}
	}
	return mine
}

// planRemoval decides what the uninstall of one profile takes off the cluster.
// installed says whether the release of a package is on the cluster, and mine
// holds the packages of every profile of this run.
func planRemoval(record map[string]recordEntry, p *profile, purge bool,
	installed func(pkg string) bool, mine map[string]bool) (*removal, error) {
	// What the install recorded wins: it is what really went onto the cluster.
	// After an install that stopped in the middle, the profile wins instead:
	// the failed package can have left objects that the record does not name,
	// and a package that never went on is skipped anyway.
	packages := record[p.Name].Packages
	if record[p.Name].Partial || len(packages) == 0 {
		packages = nil
		for _, entry := range p.Packages {
			packages = append(packages, entry.Name)
		}
	}
	keep := packagesOfOtherProfiles(record, p.Name)

	plan := &removal{Profile: p.Name}
	stays := map[string]bool{}
	var emptied []string
	for i := len(packages) - 1; i >= 0; i-- {
		pkg := packages[i]
		meta, err := loadPackageMeta(pkg)
		if err != nil {
			return nil, err
		}
		if keep[pkg] {
			plan.Keep = append(plan.Keep, pkg)
			stays[meta.Namespace] = true
			continue
		}
		if !installed(pkg) {
			plan.Skip = append(plan.Skip, pkg)
			continue
		}
		if err := refuseWhenNeeded(meta, mine, installed); err != nil {
			return nil, err
		}
		plan.Remove = append(plan.Remove, pkg)
		emptied = append(emptied, meta.Namespace)
	}
	if purge {
		done := map[string]bool{}
		for _, namespace := range emptied {
			if done[namespace] || stays[namespace] {
				continue
			}
			done[namespace] = true
			plan.Namespaces = append(plan.Namespaces, namespace)
		}
	}
	return plan, nil
}

func executeRemoval(ctx context.Context, c *cluster, plan *removal, purge bool) error {
	// A chart can ship a CRD that a package of another profile ships too. That
	// CRD must stay, or the profile that stays loses a capability.
	protected := map[string]bool{}
	if purge {
		protected = protectedCRDNames(plan.Keep)
		for _, pkg := range plan.Keep {
			meta, err := loadPackageMeta(pkg)
			if err != nil {
				continue
			}
			for _, crd := range packageCRDs(c, pkg, meta.Namespace) {
				protected[crd] = true
			}
		}
	}

	for _, pkg := range plan.Remove {
		meta, err := loadPackageMeta(pkg)
		if err != nil {
			return err
		}
		if err := removePackage(ctx, c, meta.Name, meta.Namespace, purge, protected); err != nil {
			return err
		}
	}
	for _, namespace := range plan.Namespaces {
		if err := purgeNamespace(ctx, c, namespace); err != nil {
			return err
		}
	}
	if err := forgetRecord(ctx, c, plan.Profile); err != nil {
		return err
	}
	infof("profile %s removed", plan.Profile)
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
// package that is still installed. A package of the profile that goes away is
// not one of those: it goes away in the same run.
func refuseWhenNeeded(meta *packageMeta, mine map[string]bool, installed func(pkg string) bool) error {
	if len(meta.Provides) == 0 {
		return nil
	}
	names, err := allPackageNames()
	if err != nil {
		return err
	}
	for _, other := range names {
		if other == meta.Name || mine[other] {
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
			if installed(other) {
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
			if entry.Partial {
				fmt.Printf("    state:     the install stopped after %d packages, `uninstall %s` removes them\n",
					len(entry.Packages), name)
			}
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
