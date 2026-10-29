# Reclaim — development, packaging and installation tasks.
# Run `make` or `make help` to list them.

APP_NAME := Reclaim
APP_DIR  ?= /Applications
BIN_DIR  ?= /usr/local/bin
VERSION  ?= $(shell git describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)
DIST_APP := dist/$(APP_NAME).app
ARGS     ?=

# Use sudo only for destinations the current user cannot write to.
APP_SUDO := $(shell [ -w "$(APP_DIR)" ] || echo sudo)
BIN_SUDO := $(shell [ -w "$(BIN_DIR)" ] || echo sudo)

.DEFAULT_GOAL := help
.PHONY: help build release test run cli dev app install uninstall open xcode clean

help: ## Show this list
	@echo "Usage: make <target>"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

# --- Development -------------------------------------------------------------

build: ## Debug build of the app, CLI and core library
	swift build

release: ## Optimized build
	swift build -c release

test: ## Run the test suite
	swift test

run: ## Run the app straight from source (debug build)
	swift run ReclaimApp

cli: ## Run the CLI from source, e.g. make cli ARGS="analyze ~/Downloads"
	swift run reclaim $(ARGS)

dev: ## Build a debug Reclaim.app bundle and open it (behaves like the installed app)
	CONFIGURATION=debug ./scripts/build-app.sh
	open "$(DIST_APP)"

xcode: ## Open the package in Xcode
	open Package.swift

# --- Packaging & installation --------------------------------------------------

app: ## Build a release Reclaim.app and a zip of it in dist/
	VERSION=$(VERSION) ./scripts/build-app.sh

install: app ## Install Reclaim.app into APP_DIR and the `reclaim` command into BIN_DIR
	@pkill -x $(APP_NAME) 2>/dev/null || true
	$(APP_SUDO) rm -rf "$(APP_DIR)/$(APP_NAME).app"
	$(APP_SUDO) ditto "$(DIST_APP)" "$(APP_DIR)/$(APP_NAME).app"
	$(BIN_SUDO) mkdir -p "$(BIN_DIR)"
	$(BIN_SUDO) ln -sf "$(APP_DIR)/$(APP_NAME).app/Contents/Resources/reclaim" "$(BIN_DIR)/reclaim"
	@echo "Installed $(APP_DIR)/$(APP_NAME).app and $(BIN_DIR)/reclaim"
	open "$(APP_DIR)/$(APP_NAME).app"

uninstall: ## Remove the installed app and command
	@pkill -x $(APP_NAME) 2>/dev/null || true
	$(APP_SUDO) rm -rf "$(APP_DIR)/$(APP_NAME).app"
	$(BIN_SUDO) rm -f "$(BIN_DIR)/reclaim"
	@echo "Removed $(APP_DIR)/$(APP_NAME).app and $(BIN_DIR)/reclaim"

open: ## Launch the installed app
	open "$(APP_DIR)/$(APP_NAME).app"

clean: ## Remove build products
	rm -rf .build dist
