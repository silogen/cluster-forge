package configloader

import (
	"testing"

	"github.com/silogen/cluster-forge/cmd/utils"
)

func TestLoadConfig_oneapp(t *testing.T) {
	gitops := utils.GitopsParameters{Url: "testurl", Branch: "testbranch", PathPrefix: "testpath"}
	nonInteractive := true

	result, err := LoadConfig("test-resources/oneapp.yaml", "test-resources/testdefaults.yaml", gitops, nonInteractive)
	if err != nil {
		t.Errorf("Error %v", err)
	}
	if len(result) != 1 {
		t.Errorf("Number of tools should be 1, was %d", len(result))
	}
	tool, ok := result["test1"]
	if !ok {
		t.Error("test1 should be present in toolset")
	}
	if tool.Name != "test1" {
		t.Errorf("Name should be test1, was %v", tool.Name)
	}
	if tool.Namespace != "testnamespace" {
		t.Errorf("Name should be testnamespace, was %v", tool.Namespace)
	}
	// From defaults
	if tool.ManifestURL != "https://test1.yaml" {
		t.Errorf("Name should be testnamespace, was %v", tool.ManifestURL)
	}

}

func TestLoadConfig_collection(t *testing.T) {
	gitops := utils.GitopsParameters{Url: "testurl", Branch: "testbranch", PathPrefix: "testpath"}
	nonInteractive := true

	result, err := LoadConfig("test-resources/collection.yaml", "test-resources/testdefaults.yaml", gitops, nonInteractive)
	if err != nil {
		t.Errorf("Error %v", err)
	}
	if len(result) != 3 {
		t.Errorf("Number of tools should be 3, was %d", len(result))
	}
	tool, ok := result["test1"]
	if !ok {
		t.Error("test1 should be present in toolset")
	}
	if tool.Namespace != "testnamespace" {
		// Collection should not override explicit values
		t.Errorf("Name should be testnamespace, was %v", tool.Namespace)
	}
	if _, ok := result["test2"]; !ok {
		t.Error("test2 should be present in toolset")
	}
	if _, ok := result["test3"]; !ok {
		t.Error("test3 should be present in toolset")
	}
}

func TestLoadConfig_notindefaults(t *testing.T) {
	// Tool should not need to be in defaults
	gitops := utils.GitopsParameters{Url: "testurl", Branch: "testbranch", PathPrefix: "testpath"}
	nonInteractive := true

	result, err := LoadConfig("test-resources/notindefaults.yaml", "test-resources/testdefaults.yaml", gitops, nonInteractive)
	if err != nil {
		t.Errorf("Error %v", err)
	}
	if len(result) != 1 {
		t.Errorf("Number of tools should be 1, was %d", len(result))
	}
	tool, ok := result["test5"]
	if !ok {
		t.Error("test5 should be present in toolset")
	}
	if tool.Name != "test5" {
		t.Errorf("Name should be test5, was %v", tool.Name)
	}
	if tool.Namespace != "testnamespace5" {
		t.Errorf("Name should be testnamespace5, was %v", tool.Namespace)
	}
}
