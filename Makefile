# ============================================================
# BLE Monitor — Docker Build Makefile
# ============================================================

# ---- Config ------------------------------------------------
REGISTRY ?= ghcr.io

# Remote URL (may be https://github.com/OWNER/REPO(.git) or git@github.com:OWNER/REPO(.git))
GIT_REMOTE_URL := $(shell git config --get remote.origin.url 2>/dev/null)

# Parse OWNER
OWNER_FROM_HTTPS := $(shell echo "$(GIT_REMOTE_URL)" | cut -d/ -f4)
OWNER_FROM_SSH   := $(shell echo "$(GIT_REMOTE_URL)" | cut -d: -f2 | cut -d/ -f1)

# Parse REPO
REPO_FROM_HTTPS  := $(shell echo "$(GIT_REMOTE_URL)" | cut -d/ -f5 | sed 's/\.git$$//')
REPO_FROM_SSH    := $(shell echo "$(GIT_REMOTE_URL)" | cut -d/ -f2 | sed 's/\.git$$//')

# Allow manual override, otherwise detect
OWNER ?= $(if $(OWNER_FROM_HTTPS),$(OWNER_FROM_HTTPS),$(OWNER_FROM_SSH))
REPO  ?= $(if $(REPO_FROM_HTTPS),$(REPO_FROM_HTTPS),$(REPO_FROM_SSH))

# Final fallbacks
REPO  := $(if $(REPO),$(REPO),$(shell basename $(CURDIR)))
OWNER := $(if $(OWNER),$(OWNER),unknown)

IMAGE := $(REGISTRY)/$(OWNER)/$(REPO)

SOURCE_URL ?= $(shell \
  git config --get remote.origin.url 2>/dev/null | \
  sed -e 's|^git@github.com:|https://github.com/|' -e 's|\.git$$||' \
)

BUILD_DATE ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")


GIT_SHA  := $(shell git rev-parse --short HEAD)
TAG_DEV  := dev-$(GIT_SHA)
TAG_LATEST := dev-latest

DOCKER   ?= docker

# ---- Paths ------------------------------------------------
DOCKERFILE ?= docker/Dockerfile
CONTEXT    ?= .


# ---- Runtime ------------------------------------------------
CONTAINER_NAME ?= ble_monitor

# Host paths
LOCALTIME_MOUNT ?= /etc/localtime:/etc/localtime:ro
DBUS_MOUNT      ?= /run/dbus:/run/dbus:ro

# Repo-relative path to preferences (override if different)
MQTT_PREFS_PATH ?= ./ble-monitor/mqtt_preferences
MQTT_PREFS_MOUNT ?= $(MQTT_PREFS_PATH):/opt/monitor/mqtt_preferences:ro

# Env (override at runtime: `MQTT_ADDRESS=... make run`)
NODE_NAME  ?= $(shell hostname)
MQTT_ADDRESS ?= 127.0.0.1
MQTT_PORT    ?= 1883
MQTT_USERNAME ?=
MQTT_PASSWORD ?=
MQTT_TOPIC_PREFIX ?= presence/ble/raw

.PHONY: run stop logs sh ps rm

run:
	$(DOCKER) run -d --rm \
		--name $(CONTAINER_NAME) \
		--network host \
		--privileged \
		-v $(LOCALTIME_MOUNT) \
		-v $(DBUS_MOUNT) \
		-v $(MQTT_PREFS_MOUNT) \
		-e MQTT_ADDRESS="$(MQTT_ADDRESS)" \
		-e MQTT_PORT="$(MQTT_PORT)" \
		-e MQTT_USERNAME="$(MQTT_USERNAME)" \
		-e MQTT_PASSWORD="$(MQTT_PASSWORD)" \
		-e MQTT_PUBLISHER_IDENTITY="$(NODE_NAME)" \
		-e MQTT_TOPIC_PREFIX="$(MQTT_TOPIC_PREFIX)" \
		$(IMAGE):$(TAG_LATEST)

stop:
	-$(DOCKER) stop $(CONTAINER_NAME) 2>/dev/null || true

logs:
	$(DOCKER) logs -f $(CONTAINER_NAME)

sh:
	$(DOCKER) exec -it $(CONTAINER_NAME) sh

ps:
	$(DOCKER) ps --filter "name=$(CONTAINER_NAME)"

rm:
	-$(DOCKER) rm -f $(CONTAINER_NAME) 2>/dev/null || true

# ---- Targets ----------------------------------------------

.PHONY: help build build-dev build-latest build-all tag push login clean

help:
	@echo ""
	@echo "BLE Monitor — Docker Build"
	@echo ""
	@echo "Targets:"
	@echo "  build        Build image with dev-<sha> tag"
	@echo "  build-latest Build image with dev-latest tag"
	@echo "  build-all    Build both dev-<sha> and dev-latest"
	@echo "  tag          Tag dev-<sha> as dev-latest"
	@echo "  push         Push both tags to registry"
	@echo "  login        Docker login to GHCR"
	@echo "  clean        Remove local images"
	@echo ""

.PHONY: info
info:
	@echo "IMAGE=$(IMAGE)"
	@echo "TAG_DEV=$(TAG_DEV)"
	@echo "TAG_LATEST=$(TAG_LATEST)"
	@echo "SOURCE_URL=$(SOURCE_URL)"

# ---- Build ------------------------------------------------

build:
	$(DOCKER) build \
		-f $(DOCKERFILE) \
		-t $(IMAGE):$(TAG_DEV) \
		--label org.opencontainers.image.title="$(REPO)" \
		--label org.opencontainers.image.source="$(SOURCE_URL)" \
		--label org.opencontainers.image.revision="$(GIT_SHA)" \
		--label org.opencontainers.image.created="$(BUILD_DATE)" \
		$(CONTEXT)

build-latest:
	$(DOCKER) build \
		-f $(DOCKERFILE) \
		-t $(IMAGE):$(TAG_LATEST) \
		--label org.opencontainers.image.title="$(REPO)" \
		--label org.opencontainers.image.source="$(SOURCE_URL)" \
		--label org.opencontainers.image.revision="$(GIT_SHA)" \
		--label org.opencontainers.image.created="$(BUILD_DATE)" \
		$(CONTEXT)



build-all: build build-latest

# ---- Tagging ----------------------------------------------
.PHONY: tag-release push-release

VERSION ?= v0.1.0

tag-release:
	git tag $(VERSION)
	git push origin $(VERSION)

push-release:
	@echo "Release is CI-driven. Push a tag: make tag-release VERSION=vX.Y.Z"


tag:
	$(DOCKER) tag \
		$(IMAGE):$(TAG_DEV) \
		$(IMAGE):$(TAG_LATEST)

# ---- Push -------------------------------------------------

push:
	$(DOCKER) push $(IMAGE):$(TAG_DEV)
	$(DOCKER) push $(IMAGE):$(TAG_LATEST)

# ---- Auth -------------------------------------------------

login:
	@echo "Logging in to GHCR..."
	@echo $$GITHUB_TOKEN | $(DOCKER) login ghcr.io -u $$GITHUB_USER --password-stdin

# ---- Cleanup ----------------------------------------------

clean:
	-$(DOCKER) rmi $(IMAGE):$(TAG_DEV) $(IMAGE):$(TAG_LATEST) 2>/dev/null || true
