package configloader

import (
	"testing"

	"github.com/silogen/cluster-forge/cmd/utils"
)

func TestMakeToolset_one_app(t *testing.T) {
	// Just check that it basically works
	result, _, err := makeToolset("test-resources/oneapp.yaml", utils.GitopsParameters{})
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
}
func TestMakeToolset_gitops(t *testing.T) {
	// Just check that it basically works
	gitops := utils.GitopsParameters{Url: "testurl", Branch: "testbranch", PathPrefix: "testpath"}
	result, _, err := makeToolset("test-resources/oneapp.yaml", gitops)
	if err != nil {
		t.Errorf("Error %v", err)
	}
	tool, ok := result["test1"]
	if !ok {
		t.Error("test1 should be present in toolset")
	}
	if tool.GitopsUrl != gitops.Url {
		t.Errorf("GitopsUrl should be %v, was %v", gitops.Url, tool.GitopsUrl)
	}
	if tool.GitopsBranch != gitops.Branch {
		t.Errorf("GitopsBranch should be %v, was %v", gitops.Branch, tool.GitopsBranch)
	}
	if tool.GitopsPathPrefix != gitops.PathPrefix {
		t.Errorf("GitopsPathPrefix should be %v, was %v", gitops.PathPrefix, tool.GitopsPathPrefix)
	}
}
