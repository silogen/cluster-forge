package main

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const (
	recordNamespace = "silo-system"
	recordName      = "install-record"
)

// One installed profile, as the ConfigMap keeps it.
type recordEntry struct {
	Ref       string            `json:"ref"`
	Installed string            `json:"installed"`
	Vars      map[string]string `json:"vars"`
	Packages  []string          `json:"packages"`
	// Partial says the install stopped before the last package of the profile.
	Partial bool `json:"partial,omitempty"`
}

func readRecord(ctx context.Context, c *cluster) (map[string]recordEntry, error) {
	cm, err := c.typed.CoreV1().ConfigMaps(recordNamespace).Get(ctx, recordName, metav1.GetOptions{})
	if err != nil {
		if isNotFound(err) {
			return map[string]recordEntry{}, nil
		}
		return nil, err
	}
	out := map[string]recordEntry{}
	for name, value := range cm.Data {
		var entry recordEntry
		if err := json.Unmarshal([]byte(value), &entry); err != nil {
			return nil, fmt.Errorf("the install record of profile %s is not readable: %w", name, err)
		}
		out[name] = entry
	}
	return out, nil
}

func writeRecord(ctx context.Context, c *cluster, profileName string, entry recordEntry) error {
	namespaces := c.typed.CoreV1().Namespaces()
	if _, err := namespaces.Get(ctx, recordNamespace, metav1.GetOptions{}); isNotFound(err) {
		ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: recordNamespace}}
		if _, err := namespaces.Create(ctx, ns, metav1.CreateOptions{}); err != nil && !isAlreadyExists(err) {
			return err
		}
	}
	value, err := json.Marshal(entry)
	if err != nil {
		return err
	}

	maps := c.typed.CoreV1().ConfigMaps(recordNamespace)
	cm, err := maps.Get(ctx, recordName, metav1.GetOptions{})
	if isNotFound(err) {
		cm = &corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{Name: recordName, Namespace: recordNamespace},
			Data:       map[string]string{profileName: string(value)},
		}
		_, err = maps.Create(ctx, cm, metav1.CreateOptions{})
		return err
	}
	if err != nil {
		return err
	}
	if cm.Data == nil {
		cm.Data = map[string]string{}
	}
	cm.Data[profileName] = string(value)
	_, err = maps.Update(ctx, cm, metav1.UpdateOptions{})
	return err
}

func forgetRecord(ctx context.Context, c *cluster, profileName string) error {
	maps := c.typed.CoreV1().ConfigMaps(recordNamespace)
	cm, err := maps.Get(ctx, recordName, metav1.GetOptions{})
	if isNotFound(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if _, ok := cm.Data[profileName]; !ok {
		return nil
	}
	delete(cm.Data, profileName)
	_, err = maps.Update(ctx, cm, metav1.UpdateOptions{})
	return err
}

// packagesOfOtherProfiles gives the packages that must stay when one profile
// goes away.
func packagesOfOtherProfiles(record map[string]recordEntry, profileName string) map[string]bool {
	keep := map[string]bool{}
	for name, entry := range record {
		if name == profileName {
			continue
		}
		for _, pkg := range entry.Packages {
			keep[pkg] = true
		}
	}
	return keep
}

func recordedProfileNames(record map[string]recordEntry) []string {
	names := make([]string, 0, len(record))
	for name := range record {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func newEntry(ref string, vars map[string]string, packages []string) recordEntry {
	if vars == nil {
		vars = map[string]string{}
	}
	return recordEntry{
		Ref:       ref,
		Installed: time.Now().UTC().Format(time.RFC3339),
		Vars:      vars,
		Packages:  packages,
	}
}
