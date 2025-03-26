package utils

import (
	"errors"
	"io"
	"os"
	"testing"
)

type MockHelmExecutor struct {
	RunFunc func(args []string, stdout io.Writer, stderr io.Writer) error
}

func (m *MockHelmExecutor) RunHelmCommand(args []string, stdout io.Writer, stderr io.Writer) error {
	return m.RunFunc(args, stdout, stderr)
}

func TestTemplatehelm(t *testing.T) {
	tempFile := "test_output.yaml"
	defer os.Remove(tempFile)

	mockExecutor := &MockHelmExecutor{
		RunFunc: func(args []string, stdout io.Writer, stderr io.Writer) error {
			if args[0] != "template" {
				return errors.New("unexpected command")
			}
			stdout.Write([]byte("mock helm output"))
			return nil
		},
	}

	// Valid configuration test case
	t.Run("Valid configuration", func(t *testing.T) {
		config := Config{
			Name:          "test",
			HelmURL:       "https://example.com/repo",
			HelmChartName: "example-chart",
			HelmName:      "example",
			Values:        "values.yaml",
			Namespace:     "test",
			Filename:      tempFile,
		}

		err := Templatehelm(config, mockExecutor)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}

		output, err := os.ReadFile(tempFile)
		if err != nil {
			t.Fatalf("failed to read output file: %v", err)
		}

		if string(output) != "mock helm output" {
			t.Errorf("unexpected output: %s", string(output))
		}
	})

	// Failing configuration test case (Missing HelmURL)
	t.Run("Missing HelmURL (should fail)", func(t *testing.T) {
		config := Config{
			Name:      "test",
			Namespace: "testnamespace",
			HelmURL:   "example-url",
			HelmName:  "example",
			Values:    "values.yaml",
			Filename:  tempFile,
		}

		err := Templatehelm(config, mockExecutor)
		expectedError := "invalid configuration: at least one of HelmChartName, ManifestPath, or ManifestURL must be provided"

		if err == nil || err.Error() != expectedError {
			t.Errorf("expected error: %q, got: %v", expectedError, err)
		}
	})
}
