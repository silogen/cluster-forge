package main

import (
	"reflect"
	"testing"
)

func TestClassifyGPU(t *testing.T) {
	cases := []struct {
		typ  string
		want gpuKind
	}{
		{"mi300x", gpuInstinct},
		{"mi250x", gpuInstinct},
		{"MI308X", gpuInstinct},
		{"rx9070xt", gpuOtherAMD},
		{"amdgpu-0x1234", gpuOtherAMD},
		{"radeon-rx-7900-xtx", gpuOtherAMD},
		{"mi", gpuOtherAMD},
		{"", gpuNone},
	}
	for _, c := range cases {
		if got := classifyGPU(c.typ); got != c.want {
			t.Errorf("classifyGPU(%q) = %v, want %v", c.typ, got, c.want)
		}
	}
}

func TestGPUTypesOfAGresLine(t *testing.T) {
	cases := []struct {
		gres string
		want []string
	}{
		{"gpu:mi300x:1,gpu:mi300x:1", []string{"mi300x", "mi300x"}},
		{"gpu:rx9070xt:1", []string{"rx9070xt"}},
		{"cpu:64,mem:512G", nil},
		{"", nil},
	}
	for _, c := range cases {
		if got := gpuTypesOf(c.gres); !reflect.DeepEqual(got, c.want) {
			t.Errorf("gpuTypesOf(%q) = %v, want %v", c.gres, got, c.want)
		}
	}
}
