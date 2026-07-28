SIMULATOR ?= iPhone 17 Pro
XCODEBUILD = xcodebuild -project ios/Peard.xcodeproj -scheme Peard
BUILT_APP = ios/build/Build/Products/Debug-iphonesimulator/Peard.app

.PHONY: server migrate app app-release run test test-integration icons clean

# --- server ---

server:
	cd server && go run . serve --http=127.0.0.1:8090

# Applies pending Go migrations to server/pb_data (also happens automatically
# when the server is started with `go run`).
migrate:
	cd server && go run . migrate up

# --- iOS app ---

# Builds Peard.app + the PearWidget extension for the simulator.
app:
	$(XCODEBUILD) -configuration Debug -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath ios/build CODE_SIGNING_ALLOWED=NO build

app-release:
	$(XCODEBUILD) -configuration Release -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath ios/build CODE_SIGNING_ALLOWED=NO build

# Boots the simulator, installs and launches the app.
run:
	xcrun simctl boot "$(SIMULATOR)" 2>/dev/null || true
	open -a Simulator
	$(XCODEBUILD) -configuration Debug -destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
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

# PeardCore unit tests; no simulator required.
test:
	cd ios/PeardCore && swift test

# Requires a running server (make server) and its superuser credentials.
test-integration:
	cd ios/PeardCore && PEARD_TEST_SERVER_URL=$(or $(PEARD_TEST_SERVER_URL),http://127.0.0.1:8090) \
		swift test --filter LocalServerIntegrationTests

clean:
	rm -rf server/pb_data server/peard-server ios/build
	cd ios/PeardCore && swift package clean
