SIMULATOR ?= iPhone 17 Pro
DESTINATION ?= platform=iOS Simulator,name=$(SIMULATOR)
PROJECT = ios/Peard.xcodeproj
XCODEBUILD = xcodebuild -project $(PROJECT) -scheme Peard
BUILT_APP = ios/build/Build/Products/Debug-iphonesimulator/Peard.app

.PHONY: server migrate app app-release run project test test-app test-integration \
        test-all icons lint fmt hooks clean \
        docker-build docker-up docker-up-tls docker-up-cloudflared docker-down docker-logs

# --- git hooks ---

# .git/hooks is not versioned, so pre-commit installs both stages from
# .pre-commit-config.yaml. Wired into `project` — which every iOS target already
# depends on — because a hook nobody remembered to install is a hook that
# prevents nothing, which is the whole failure mode being fixed here.
#
# A missing pre-commit binary is a warning, not an error: it must not stop
# somebody building the app, and the failure it would cause (`make app` refusing
# to run on a fresh machine) is worse than the one it prevents.
hooks:
	@if ! command -v pre-commit >/dev/null 2>&1; then \
		echo "pre-commit not installed — hooks inactive (brew install pre-commit)"; \
	elif [ ! -f .git/hooks/pre-push ]; then \
		pre-commit install; \
	fi

# --- server ---

server:
	cd server && go run . serve --http=127.0.0.1:8090

# Applies pending Go migrations to server/pb_data (also happens automatically
# when the server is started with `go run`).
migrate:
	cd server && go run . migrate up

# --- project generation ---

# ios/Peard.xcodeproj is generated from ios/project.yml and is NOT committed.
# Every iOS target depends on this, so a fresh clone builds without a manual
# step and a renamed file never needs a project edit.
project: hooks
	cd ios && xcodegen generate --spec project.yml

# Regenerated when the spec changes, and also when a source directory's mtime
# changes — which is what adding or removing a file does. Depending on the spec
# alone meant a brand-new file was simply absent from the project: the build then
# failed with "cannot find X in scope" for a type whose file is plainly on disk,
# or worse, succeeded while quietly leaving the new code out. Directories rather
# than files on purpose: editing a file needs no regeneration, adding one does.
#
# Asset catalogues are pruned rather than watched. xcodegen references an
# .xcassets as a single directory, so a PNG added inside one needs no
# regeneration — and their subdirectories are the one place here with spaces in
# their names ("iMessage App Icon.stickersiconset"), which make splits into
# three prerequisites it then cannot find. Correctness and robustness happen to
# want the same prune.
SOURCE_DIRS := $(shell find ios/Peard ios/PearWidget ios/PearMessages ios/PeardTests \
                        ios/PeardCore/Sources ios/PeardCore/Tests ios/Shared \
                        -name '*.xcassets' -prune -o -type d -print 2>/dev/null)

# `| hooks` is order-only on purpose. hooks is .PHONY, and a phony *normal*
# prerequisite would make this file target perpetually out of date — xcodegen
# would then run on every single build.
$(PROJECT): ios/project.yml $(SOURCE_DIRS) | hooks
	cd ios && xcodegen generate --spec project.yml

# --- iOS app ---

# Builds Peard.app + the PearWidget extension for the simulator.
# Code signing is left ON: the simulator signs ad-hoc (no team or provisioning
# profile needed), and disabling it would drop the entitlements, which takes
# the Keychain and the App Group with it — an app that cannot sign in.
app: $(PROJECT)
	$(XCODEBUILD) -configuration Debug -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath ios/build build

app-release: $(PROJECT)
	$(XCODEBUILD) -configuration Release -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath ios/build build

# Boots the simulator, installs and launches the app.
run: $(PROJECT)
	xcrun simctl boot "$(SIMULATOR)" 2>/dev/null || true
	open -a Simulator
	$(XCODEBUILD) -configuration Debug -destination '$(DESTINATION)' \
		-derivedDataPath ios/build build
	xcrun simctl install "$(SIMULATOR)" $(BUILT_APP)
	xcrun simctl launch "$(SIMULATOR)" com.peard.app

# --- assets ---

# Redraws the app icon (light, dark and tinted) into AppIcon.appiconset, then
# derives the iMessage extension's icon set from it. Only needed after editing
# either generator; the PNGs are committed.
#
# Order matters: GenerateMessagesIcon reads AppIcon-1024.png rather than
# redrawing the pear, so it has to run second.
icons:
	swift ios/Tools/GenerateAppIcon.swift
	swift ios/Tools/GenerateMessagesIcon.swift

# --- tests ---

# PeardCore unit tests; no simulator required, so this is the fast loop.
test:
	cd ios/PeardCore && swift test

# App-target tests (HomeModel's quick-send flow, AppModel's routing). These need
# a simulator because the types they cover are @MainActor and import UIKit.
test-app: $(PROJECT)
	$(XCODEBUILD) -configuration Debug -destination '$(DESTINATION)' \
		-derivedDataPath ios/build test

test-all: test test-app
	cd server && go test ./...

# Requires a running server (make server) and its superuser credentials.
test-integration:
	cd ios/PeardCore && PEARD_TEST_SERVER_URL=$(or $(PEARD_TEST_SERVER_URL),http://127.0.0.1:8090) \
		swift test --filter LocalServerIntegrationTests

# --- checks ---

# Mirrors what CI checks, so a green `make lint` means a green pipeline. gofmt
# was missing here while CI enforced it, which is a lint target that lets exactly
# the failure it exists to prevent through to the pipeline.
lint:
	cd server && go vet ./...
	@cd server && unformatted=$$(gofmt -l .); \
		if [ -n "$$unformatted" ]; then \
			echo "These files are not gofmt'd (run: make fmt):"; \
			echo "$$unformatted"; \
			exit 1; \
		fi
	cd ios && xcodegen generate --spec project.yml --use-cache

fmt:
	cd server && gofmt -w .

# --- docker ---

# Prefer the Compose v2 plugin, fall back to the standalone binary. Homebrew
# installs the plugin under /opt/homebrew/lib/docker/cli-plugins, which is not on
# Docker's default search path, so `docker compose` can be missing on a machine
# that has a perfectly good `docker-compose`.
COMPOSE := $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo docker-compose)
COMPOSE_TLS = $(COMPOSE) -f docker-compose.yml -f docker-compose.tls.yml
COMPOSE_CF = $(COMPOSE) -f docker-compose.yml -f docker-compose.cloudflared.yml

# PEARD_COMMIT is stamped into the binary and reported by GET /api/peard/status,
# so a deploy can be identified without shelling into the host. Exported for
# every compose target below rather than just one, because the useful property
# is that it is always right, not that it is available when remembered.
#
# Empty rather than "unknown" when there is no git here: the build reads the
# revision out of .git itself in that case, which is how a deploy that clones
# and builds gets an accurate answer. Passing a literal stops it looking.
export PEARD_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null)

docker-build:
	$(COMPOSE) build

# Plain HTTP on $$PEARD_HTTP_PORT (default 8090); expects a reverse proxy in
# front. Note this collides with `make server` if both run on one machine.
docker-up:
	$(COMPOSE) up -d --build

# PocketBase manages its own Let's Encrypt certificate and owns 80 + 443.
docker-up-tls:
	$(COMPOSE_TLS) up -d --build

# No host port at all; a cloudflared tunnel reaches the container over the shared
# network named by PEARD_CLOUDFLARED_NETWORK, which must already exist.
docker-up-cloudflared:
	$(COMPOSE_CF) up -d --build

# Stops and removes the container, keeping the pb_data volume. There is no
# target that passes -v on purpose: that deletes the databases, the uploaded
# media and the certificate.
docker-down:
	$(COMPOSE) down

docker-logs:
	$(COMPOSE) logs -f --tail=100

clean:
	rm -rf server/pb_data server/peard-server ios/build ios/Peard.xcodeproj
	cd ios/PeardCore && swift package clean
