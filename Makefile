# set the shell to bash always
SHELL         := /bin/bash

# set make and shell flags to exit on errors
MAKEFLAGS     += --warn-undefined-variables
.SHELLFLAGS   := -euo pipefail -c

ARCH = amd64
BUILD_ARGS ?=

DOCKER_BUILD_PLATFORMS = linux/amd64,linux/arm64
DOCKER_BUILDX_BUILDER ?= "mybuilder"

# default target is build
.DEFAULT_GOAL := all
.PHONY: all
all: $(addprefix build-,$(ARCH))

# Image registry for build/push image targets
IMAGE_REGISTRY ?= ghcr.io/indeedeng/cluster-config-maps

CRD_OPTIONS ?= "crd"
CRD_DIR     ?= deploy/crds

HELM_DIR    ?= deploy/charts/cluster-config-maps

OUTPUT_DIR  ?= bin

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# check if there are any existing `git tag` values
ifeq ($(shell git tag),)
# no tags found - default to initial tag `v0.0.0`
VERSION ?= $(shell echo "v0.0.0-$$(git rev-list HEAD --count)-g$$(git describe --dirty --always)" | sed 's/-/./2' | sed 's/-/./2')
else
# use tags
VERSION ?= $(shell git describe --dirty --always --tags --exclude 'helm*' | sed 's/-/./2' | sed 's/-/./2')
endif

# ====================================================================================
# Colors

BLUE         := $(shell printf "\033[34m")
YELLOW       := $(shell printf "\033[33m")
RED          := $(shell printf "\033[31m")
GREEN        := $(shell printf "\033[32m")
CNone        := $(shell printf "\033[0m")

# ====================================================================================
# Logger

TIME_LONG	= `date +%Y-%m-%d' '%H:%M:%S`
TIME_SHORT	= `date +%H:%M:%S`
TIME		= $(TIME_SHORT)

INFO	= echo ${TIME} ${BLUE}[ .. ]${CNone}
WARN	= echo ${TIME} ${YELLOW}[WARN]${CNone}
ERR		= echo ${TIME} ${RED}[FAIL]${CNone}
OK		= echo ${TIME} ${GREEN}[ OK ]${CNone}
FAIL	= (echo ${TIME} ${RED}[FAIL]${CNone} && false)

# ====================================================================================
# Conformance

# Ensure a PR is ready for review.
reviewable: generate helm.generate
	@go mod tidy

# Ensure branch is clean.
check-diff: reviewable
	@$(INFO) checking that branch is clean
	@test -z "$$(git status --porcelain)" || (echo "$$(git status --porcelain)" && $(FAIL))
	@$(OK) branch is clean

# ====================================================================================
# Golang

.PHONY: test
test: generate lint ## Run tests
	@$(INFO) go test unit-tests
	go test -race -v ./... -coverprofile cover.out
	@$(OK) go test unit-tests

.PHONY: build
build: $(addprefix build-,$(ARCH))

.PHONY: build-%
build-%: generate ## Build binary for the specified arch
	@$(INFO) go build $*
	@CGO_ENABLED=0 GOOS=linux GOARCH=$* \
		go build -o '$(OUTPUT_DIR)/ccm-csi-plugin-$*' ./cmd/ccm-csi-plugin/main.go
	@$(OK) go build $*

# Check install of golanci-lint
lint.check:
	@if ! golangci-lint --version > /dev/null 2>&1; then \
		echo -e "\033[0;33mgolangci-lint is not installed: run \`\033[0;32mmake lint.install\033[0m\033[0;33m\` or install it from https://golangci-lint.run\033[0m"; \
		exit 1; \
	fi

.PHONY: lint-install
lint-install: ## installs golangci-lint to the go bin dir
	@if ! golangci-lint --version > /dev/null 2>&1; then \
		echo "Installing golangci-lint"; \
		curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(BIN_DIR) v1.43.0; \
	fi

lint: lint.check ## run golangci-lint
	@if ! golangci-lint run; then \
		echo -e "\033[0;33mgolangci-lint failed: some checks can be fixed with \`\033[0;32mmake fmt\033[0m\033[0;33m\`\033[0m"; \
		exit 1; \
	fi

fmt: lint.check ## ensure consistent code style
	@go mod tidy
	@go fmt ./...
	@golangci-lint run --fix > /dev/null 2>&1 || true
	@$(OK) Ensured consistent code style

generate: ## Generate code and crds
	@go run sigs.k8s.io/controller-tools/cmd/controller-gen object:headerFile="hack/boilerplate.go.txt" paths="./..."
	@go run sigs.k8s.io/controller-tools/cmd/controller-gen $(CRD_OPTIONS) paths="./..." output:crd:artifacts:config=$(CRD_DIR)
	@$(OK) Finished generating deepcopy and crds


# ====================================================================================
# Local Testing

.PHONY: hack
hack: ## run cluster config maps in a kind cluster demo
	./hack/hack.sh

# ====================================================================================
# Local Utility

# This is for running out-of-cluster locally, and is for convenience.
# For more control, try running the binary directly with different arguments.
run: generate
	go run ./cmd/ccm-csi-plugin/main.go

# Generate manifests from helm chart
manifests: helm.generate
	mkdir -p $(OUTPUT_DIR)/deploy/manifests
	helm template cluster-config-maps $(HELM_DIR) -f deploy/manifests/helm-values.yaml > $(OUTPUT_DIR)/deploy/manifests/cluster-config-maps.yaml

# Install CRDs into a cluster. This is for convenience.
crds.install: generate
	kubectl apply -f $(CRD_DIR)

# Uninstall CRDs from a cluster. This is for convenience.
crds.uninstall:
	kubectl delete -f $(CRD_DIR)

# ====================================================================================
# Helm Chart

helm.docs: ## Generate helm docs
	@cd $(HELM_DIR); \
	docker run --rm -v $(shell pwd)/$(HELM_DIR):/helm-docs -u $(shell id -u) jnorwood/helm-docs:v1.5.0

HELM_VERSION ?= $(shell helm show chart $(HELM_DIR) | grep 'version:' | sed 's/version: //g')

helm.build: helm.generate ## Build helm chart
	@$(INFO) helm package
	@helm package $(HELM_DIR) --dependency-update --destination $(OUTPUT_DIR)/chart
	@mv $(OUTPUT_DIR)/chart/cluster-config-maps-$(HELM_VERSION).tgz $(OUTPUT_DIR)/chart/cluster-config-maps.tgz
	@$(OK) helm package

# Copy crds to helm chart directory
helm.generate: helm.docs
	@cp $(CRD_DIR)/*.yaml $(HELM_DIR)/templates/crds/
# Add helm if statement for controlling the install of CRDs
	@for i in $(HELM_DIR)/templates/crds/*.yaml; do \
		cp "$$i" "$$i.bkp" && \
		echo "{{- if .Values.installCRDs }}" > "$$i" && \
		cat "$$i.bkp" >> "$$i" && \
		echo "{{- end }}" >> "$$i" && \
		rm "$$i.bkp"; \
	done
	@$(OK) Finished generating helm chart files

# ====================================================================================
# Documentation
.PHONY: docs
docs: generate
	$(MAKE) -C ./hack/api-docs build

.PHONY: serve-docs
serve-docs:
	$(MAKE) -C ./hack/api-docs serve

# ====================================================================================
# Build Artifacts

build.all: docker.build helm.build

docker.build: $(addprefix build-,$(ARCH)) ## Build the docker image
	@$(INFO) docker build
	@docker build . $(BUILD_ARGS) -t $(IMAGE_REGISTRY):$(VERSION)
	@$(OK) docker build

docker.push:
	@$(INFO) docker push
	@docker push $(IMAGE_REGISTRY):$(VERSION)
	@$(OK) docker push

docker.buildx.setup:
	@$(INFO) docker buildx setup
	@docker buildx ls 2>/dev/null | grep -q $(DOCKER_BUILDX_BUILDER) || docker buildx create --name $(DOCKER_BUILDX_BUILDER) --driver docker-container --bootstrap --use
	@$(OK) docker buildx setup

docker.buildx: docker.buildx.setup
	@$(INFO) docker buildx
	@docker buildx build --platform $(DOCKER_BUILD_PLATFORMS) -t $(IMAGE_REGISTRY):$(VERSION) $(BUILD_ARGS) --push .
	@$(OK) docker buildx

# RELEASE_TAG is tag to promote. Default is promoting to main branch, but can be overriden
# to promote a tag to a specific version.
RELEASE_TAG ?= main
SOURCE_TAG ?= $(VERSION)

docker.promote:
	@$(INFO) promoting $(SOURCE_TAG) to $(RELEASE_TAG)
	docker manifest inspect $(IMAGE_REGISTRY):$(SOURCE_TAG) > .tagmanifest
	for digest in $$(jq -r '.manifests[].digest' < .tagmanifest); do \
		docker pull $(IMAGE_REGISTRY)@$$digest; \
	done
	docker manifest create $(IMAGE_REGISTRY):$(RELEASE_TAG) \
		$$(jq -j '"--amend $(IMAGE_REGISTRY)@" + .manifests[].digest + " "' < .tagmanifest)
	docker manifest push $(IMAGE_REGISTRY):$(RELEASE_TAG)
	@$(OK) docker push $(RELEASE_TAG) \

# ====================================================================================
# Help

# only comments after make target name are shown as help text
help: ## displays this help message
	@echo -e "$$(grep -hE '^\S+:.*##' $(MAKEFILE_LIST) | sed -e 's/:.*##\s*/:/' -e 's/^\(.\+\):\(.*\)/\\x1b[36m\1\\x1b[m:\2/' | column -c2 -t -s : | sort)"
