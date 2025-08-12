/**
 * Copyright 2025 Advanced Micro Devices, Inc.  All rights reserved.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
**/

package utils

import (
	"fmt"
	"strings"
)

func NewGiteaParameters() GiteaParameters {
	return GiteaParameters{
		Allowed:    []string{"ephemeral", "persistent", "none"},
		Value:      "persistent",
		Persistent: true,
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
