SIMULATOR ?= iPhone 17 Pro
DESTINATION ?= platform=iOS Simulator,name=$(SIMULATOR)
PROJECT = ios/Peard.xcodeproj
XCODEBUILD = xcodebuild -project $(PROJECT) -scheme Peard
BUILT_APP = ios/build/Build/Products/Debug-iphonesimulator/Peard.app

.PHONY: server migrate app app-release run project test test-app test-integration \
        test-all icons lint clean

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
project:
	cd ios && xcodegen generate --spec project.yml

$(PROJECT): ios/project.yml
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

# Redraws the app icon (light, dark and tinted) into AppIcon.appiconset.
# Only needed after editing ios/Tools/GenerateAppIcon.swift; the PNGs are
# committed.
icons:
	swift ios/Tools/GenerateAppIcon.swift

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

lint:
	cd server && go vet ./...
	cd ios && xcodegen generate --spec project.yml --use-cache

clean:
	rm -rf server/pb_data server/peard-server ios/build ios/Peard.xcodeproj
	cd ios/PeardCore && swift package clean
