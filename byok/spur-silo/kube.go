package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"k8s.io/cli-runtime/pkg/genericclioptions"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

type cluster struct {
	kubeconfig string // path, kept at mode 0600 for the run
	temporary  bool
	rest       *rest.Config
	typed      *kubernetes.Clientset
	dynamic    dynamic.Interface
	discovery  discovery.DiscoveryInterface
}

// connect finds a cluster-admin kubeconfig. Order: the given path, KUBECONFIG,
// Spur over gRPC, the same call under sudo, then a local k0s. A cluster with no
// accounting knows no administrator but root, so the sudo step is what answers
// on a node that is not the control plane.
func connect(kubeconfigArg string) (*cluster, error) {
	path, temporary, err := findKubeconfig(kubeconfigArg)
	if err != nil {
		return nil, err
	}
	c := &cluster{kubeconfig: path, temporary: temporary}
	cfg, err := clientcmd.BuildConfigFromFlags("", path)
	if err != nil {
		return nil, fmt.Errorf("kubeconfig %s: %w", path, err)
	}
	// The API server repeats a deprecation warning for every request. One line
	// per warning is enough for the operator.
	cfg.WarningHandler = rest.NewWarningWriter(os.Stderr, rest.WarningWriterOptions{Deduplicate: true})
	c.rest = cfg
	if c.typed, err = kubernetes.NewForConfig(cfg); err != nil {
		return nil, err
	}
	if c.dynamic, err = dynamic.NewForConfig(cfg); err != nil {
		return nil, err
	}
	c.discovery = c.typed.Discovery()
	if _, err := c.typed.CoreV1().Nodes().List(context.Background(), listAll); err != nil {
		return nil, fmt.Errorf("the kubeconfig does not reach the cluster: %w", err)
	}
	return c, nil
}

func (c *cluster) close() {
	if c != nil && c.temporary && c.kubeconfig != "" {
		os.Remove(c.kubeconfig)
	}
}

func (c *cluster) restClientGetter(namespace string) genericclioptions.RESTClientGetter {
	flags := genericclioptions.NewConfigFlags(false)
	flags.KubeConfig = &c.kubeconfig
	flags.Namespace = &namespace
	return flags
}

func findKubeconfig(given string) (string, bool, error) {
	if given != "" {
		if _, err := os.Stat(given); err != nil {
			return "", false, fmt.Errorf("no such kubeconfig: %s", given)
		}
		return given, false, nil
	}
	if env := os.Getenv("KUBECONFIG"); env != "" {
		return env, false, nil
	}

	spur := os.Getenv("SPUR_BIN")
	if spur == "" {
		spur = "spur"
	}
	attempts := [][]string{
		{spur, "k8s", "kubeconfig", "--admin"},
		{"sudo", "-n", spur, "k8s", "kubeconfig", "--admin"},
		{"sudo", "-n", "k0s", "kubeconfig", "admin"},
	}
	for _, argv := range attempts {
		out, err := exec.Command(argv[0], argv[1:]...).Output()
		if err != nil || !strings.Contains(string(out), "server:") {
			continue
		}
		f, err := os.CreateTemp("", "spur-silo-kubeconfig-*")
		if err != nil {
			return "", false, err
		}
		if err := f.Chmod(0o600); err != nil {
			return "", false, err
		}
		if _, err := f.Write(out); err != nil {
			f.Close()
			return "", false, err
		}
		f.Close()
		infof("admin kubeconfig from %s", strings.Join(argv, " "))
		return f.Name(), true, nil
	}
	return "", false, fmt.Errorf("cannot get the admin kubeconfig. Give --kubeconfig, " +
		"or set [cluster] allow_admin_kubeconfig = true in spur.conf, " +
		"or run this on the control-plane node")
}

// instinctNodes asks Spur which nodes report an AMD Instinct GPU. Radeon is
// never selected: the GPU profile supports Instinct only.
func instinctNodes() []string {
	spur := os.Getenv("SPUR_BIN")
	if spur == "" {
		spur = "spur"
	}
	out, err := exec.Command(spur, "show", "node").Output()
	if err != nil {
		return nil
	}
	var nodes []string
	var current string
	for _, line := range strings.Split(string(out), "\n") {
		trimmed := strings.TrimSpace(line)
		if name, ok := strings.CutPrefix(line, "NodeName="); ok {
			current = strings.Fields(name)[0]
			continue
		}
		if gres, ok := strings.CutPrefix(trimmed, "Gres="); ok && current != "" {
			if hasInstinct(gres) {
				nodes = append(nodes, current)
			}
		}
	}
	return nodes
}

// A Spur GPU type of an Instinct card is mi<digits>, for example mi300x.
func hasInstinct(gres string) bool {
	for _, entry := range strings.Split(gres, ",") {
		parts := strings.Split(entry, ":")
		if len(parts) < 2 || parts[0] != "gpu" {
			continue
		}
		model := strings.ToLower(parts[1])
		if rest, ok := strings.CutPrefix(model, "mi"); ok && rest != "" && rest[0] >= '0' && rest[0] <= '9' {
			return true
		}
	}
	return false
}
