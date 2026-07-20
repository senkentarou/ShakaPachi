CODESIGN_IDENTITY ?= Developer ID Application: Masahiro Senda (U2H8U2TN85)

APP_NAME      := CmdTab
BUNDLE_DIR    := dist/$(APP_NAME).app
CONTENTS_DIR  := $(BUNDLE_DIR)/Contents
MACOS_DIR     := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources

.PHONY: build run release test clean

# Debug build: compile, assemble .app bundle, and sign.
build:
	swift build 2>&1
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	@cp .build/debug/$(APP_NAME) "$(MACOS_DIR)/$(APP_NAME)"
	@cp Resources/Info.plist "$(CONTENTS_DIR)/Info.plist"
	codesign --force --sign "$(CODESIGN_IDENTITY)" "$(BUNDLE_DIR)"

# Build then launch the app.
# WS_DEADMAN override: the DEBUG deadman defaults to 60s, which is too short for
# interactive testing (it disables the tap mid-session). Pass a longer value so
# the tap stays alive while testing; the safety net (and emergency stop) remain.
# Release builds ignore this entirely (the deadman is #if DEBUG only).
DEADMAN_SEC ?= 1800
run: build
	open "$(BUNDLE_DIR)" --env CMDTAB_DEADMAN_SEC=$(DEADMAN_SEC)

# Release build: compile with optimisations, assemble, and sign.
release:
	swift build -c release 2>&1
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	@cp .build/release/$(APP_NAME) "$(MACOS_DIR)/$(APP_NAME)"
	@cp Resources/Info.plist "$(CONTENTS_DIR)/Info.plist"
	codesign --force --sign "$(CODESIGN_IDENTITY)" "$(BUNDLE_DIR)"

# Run unit tests.
test:
	swift test 2>&1

# Remove build artefacts.
clean:
	rm -rf .build dist
