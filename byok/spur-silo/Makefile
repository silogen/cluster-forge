# Builds the spur-silo binary with every chart of the release inside it.
#
# `make assets` needs helm and network access once: it resolves the chart
# dependencies of every package. `make build` needs neither, and the binary
# needs neither at run time.
BYOK := ..
ASSETS := assets
REF ?= $(shell git rev-parse --abbrev-ref HEAD)
GOFLAGS ?=

.PHONY: all assets build test clean

all: assets build

# The file:// dependencies of a package point at byok/../sources, so the
# archives are built in place and copied after.
assets:
	for dir in $(BYOK)/packages/*/; do \
	  helm dependency build "$$dir" >/dev/null || exit 1; \
	done
	rm -rf $(ASSETS)
	mkdir -p $(ASSETS)/tests
	cp $(BYOK)/capabilities.yaml $(ASSETS)/
	cp -r $(BYOK)/profiles $(ASSETS)/profiles
	cp -r $(BYOK)/packages $(ASSETS)/packages
	cp $(BYOK)/tests/aimservice-dummy.yaml $(ASSETS)/tests/
	find $(ASSETS)/packages -name 'Chart.lock' -delete
	find $(ASSETS)/packages -name 'tmpcharts*' -prune -exec rm -rf {} +

build:
	go build $(GOFLAGS) -ldflags "-X main.version=$(REF)" -o spur-silo .

test:
	go test ./...

clean:
	rm -rf $(ASSETS) spur-silo
