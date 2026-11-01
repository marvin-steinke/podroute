SHELL := /usr/bin/env bash
CONTAINER ?= podman
IMAGE_VERSION ?= local
IMAGE_REVISION ?= local
IMAGE_SOURCE ?= https://github.com/marvin-steinke/podroute
IMAGE_LABELS = --label org.opencontainers.image.version=$(IMAGE_VERSION) --label org.opencontainers.image.revision=$(IMAGE_REVISION) --label org.opencontainers.image.source=$(IMAGE_SOURCE)

.PHONY: test lint build images test-network test-runtime
test:
	go test -race ./...
	bash tests/gateway/unit.sh

lint:
	test -z "$$(gofmt -l cmd internal)"
	go vet ./...
	shellcheck -x -P gateway gateway/bin/*.sh gateway/lib/*.sh tests/gateway/*.sh tests/network/*.sh
	@for script in gateway/bin/*.sh gateway/lib/*.sh tests/gateway/*.sh tests/network/*.sh; do bash -n "$$script" || exit; done

build:
	mkdir -p bin
	CGO_ENABLED=0 go build -trimpath -o bin/podroute-controller ./cmd/admission-controller

images:
	$(CONTAINER) build $(IMAGE_LABELS) --target runtime -f gateway/Dockerfile -t podroute-gateway:local .
	$(CONTAINER) build $(IMAGE_LABELS) -f controller/Dockerfile -t podroute-controller:local .

test-network:
	$(CONTAINER) build --target test -f gateway/Dockerfile -t podroute-network-test:local .
	$(CONTAINER) run --rm --privileged --network none podroute-network-test:local

test-runtime:
	CONTAINER=$(CONTAINER) bash tests/gateway/runtime.sh