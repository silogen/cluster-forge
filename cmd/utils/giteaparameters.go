package utils

import (
	"fmt"
	"strings"
)

func NewGiteaParameters() GiteaParameters {
	return GiteaParameters{
		Allowed:    []string{"ephemeral", "persistent", "none"},
		Value:      "ephemeral",
		Persistent: false,
		Deploy:     true,
	}
}

type GiteaParameters struct {
	Allowed    []string
	Value      string
	Persistent bool
	Deploy     bool
}

func (a GiteaParameters) String() string {
	return a.Value
}

func (a *GiteaParameters) Set(p string) error {
	isIncluded := func(opts []string, val string) bool {
		for _, opt := range opts {
			if val == opt {
				return true
			}
		}
		return false
	}
	if !isIncluded(a.Allowed, p) {
		return fmt.Errorf("%s is not included in %s", p, strings.Join(a.Allowed, ","))
	}
	a.Value = p
	if a.Value == "ephemeral" {
		a.Persistent = false
		a.Deploy = true
	} else if a.Value == "persistent" {
		a.Persistent = true
		a.Deploy = true
	} else if a.Value == "none" {
		a.Persistent = false
		a.Deploy = false
	}
	return nil
}

func (a *GiteaParameters) Type() string {
	return "string"
}
