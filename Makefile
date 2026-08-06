-include local.env
export

SWIFTC     ?= swiftc
SWIFTFLAGS ?= -O

MACOS_MIN                = 15.0
MACOSX_DEPLOYMENT_TARGET = $(MACOS_MIN)
SWIFT_TARGET             ?= $(shell uname -m)-apple-macosx$(MACOS_MIN)
LDFLAGS     = -framework CoreGraphics -framework CoreFoundation \
              -framework ApplicationServices -framework AppKit \
              -framework ServiceManagement

SRCS       = $(wildcard App/*.swift)
BIN        = spacerabbit
APP_NAME   = Space Rabbit
APP_BUNDLE = $(APP_NAME).app
DMG_NAME   = Space-Rabbit.dmg
Q_BUNDLE   = "$(APP_BUNDLE)"
Q_DMG      = "$(DMG_NAME)"
ICNS       = Tools/Icon/AppIcon.icns

# Localization tables, one <lang>.lproj per supported language. English is the
# development language and defines the reference key set; every other language
# must declare exactly the same keys or `make build` fails.
LPROJ_DIR  = App/Resources
LPROJS     = $(wildcard $(LPROJ_DIR)/*.lproj)
LPROJ_SRCS = $(wildcard $(LPROJ_DIR)/*.lproj/*)

# DMG window layout — must stay in sync with Tools/Dmg/CreateBackground.swift
DMG_BACKGROUND ?= Tools/Dmg/Background.tiff
# Custom installer artwork: drop a 1400x920 px PNG here and `make assets`
# uses it instead of the drawn placeholder (wildcard = no error when absent)
DMG_BACKGROUND_PNG ?= $(wildcard Tools/Dmg/BaseBackground.png)
# Scratch space for `make dmg` (both git-ignored, removed when the build ends)
DMG_STAGING    = Tools/Dmg/_staging
DMG_RW         = Tools/Dmg/_writable.dmg
DMG_VOLNAME    = Space Rabbit $(VERSION)
DMG_WIN_W      = 700
DMG_WIN_H      = 460
DMG_ICON_SIZE  = 128
DMG_APP_X      = 185
DMG_APP_Y      = 250
DMG_DROP_X     = 515
DMG_DROP_Y     = 250

SIGN_ID          ?=
APPLE_ID         ?=
APPLE_TEAM_ID    ?=
APPLE_APP_PASSWORD ?=

VERSION   ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')

.PHONY: build assets app app-dev dmg notarize release clean \
        verify-macos-min verify-localizations

build: $(BIN) verify-macos-min verify-localizations

$(BIN): $(SRCS) Makefile
	$(SWIFTC) $(SWIFTFLAGS) -target $(SWIFT_TARGET) -o $@ $(SRCS) $(LDFLAGS)

$(ICNS): Tools/Icon/CreateIcon.swift
	@echo "==> Generating $(ICNS)..."
	@swift Tools/Icon/CreateIcon.swift
	@mv AppIcon.icns $(ICNS)
	@echo "==> Generated $(ICNS)"

$(DMG_BACKGROUND): Tools/Dmg/CreateBackground.swift $(DMG_BACKGROUND_PNG)
	@echo "==> Generating $(DMG_BACKGROUND)..."
	@swift Tools/Dmg/CreateBackground.swift $(DMG_BACKGROUND_PNG)
	@mv Background.tiff $(DMG_BACKGROUND)
	@echo "==> Generated $(DMG_BACKGROUND)"

verify-macos-min: $(BIN)
	@actual_min="$$(otool -l $(BIN) | awk '/LC_BUILD_VERSION/ { found = 1; next } found && /minos/ { print $$2; exit }')"; \
	if [ "$$actual_min" != "$(MACOS_MIN)" ]; then \
	  echo "==> ERROR: $(BIN) was built for macOS $$actual_min, expected $(MACOS_MIN)."; \
	  echo "==> Check MACOS_MIN/SWIFT_TARGET and rebuild before packaging."; \
	  exit 1; \
	fi

# Fails the build on any localization gap: a key used by the code but not
# declared, a declared key nobody uses, a key missing from one language, or a
# translation whose format specifiers do not match English
verify-localizations: $(LPROJ_SRCS) $(SRCS) Tools/Localization/Validate.swift
	@swift Tools/Localization/Validate.swift $(LPROJ_DIR) App

assets: $(ICNS) $(DMG_BACKGROUND)

app: build $(ICNS)
	@echo "==> Building $(APP_BUNDLE)..."
	@rm -rf $(Q_BUNDLE)
	@mkdir -p $(Q_BUNDLE)/Contents/MacOS
	@mkdir -p $(Q_BUNDLE)/Contents/Resources
	@cp $(BIN) $(Q_BUNDLE)/Contents/MacOS/$(BIN)
	@cp $(ICNS) $(Q_BUNDLE)/Contents/Resources/AppIcon.icns
	@# The .lproj directories must land in Resources before signing, so the
	@# code signature seals them
	@cp -R $(LPROJS) $(Q_BUNDLE)/Contents/Resources/
	@sed 's/__VERSION__/$(VERSION)/g;s/__MACOS_MIN__/$(MACOS_MIN)/g' App/Info.plist > $(Q_BUNDLE)/Contents/Info.plist
	@sign_id="$(SIGN_ID)"; \
	if [ -z "$$sign_id" ]; then \
	  printf "==> Enter signing identity (SIGN_ID) [ENTER to skip]: "; \
	  read sign_id; \
	fi; \
	if [ -z "$$sign_id" ]; then \
	  echo "==> WARNING: No signing identity provided, skipping code signing."; \
	else \
	  codesign --force --deep --options runtime --sign "$$sign_id" $(Q_BUNDLE); \
	fi
	@echo "==> Built $(APP_BUNDLE)"

app-dev: app
	@echo "==> Restarting $(APP_BUNDLE)..."
	@pkill -x "$(BIN)" 2>/dev/null || true
	@sleep 0.5
	@open $(Q_BUNDLE)
	@echo "==> Restarted $(APP_BUNDLE)"

dmg: app $(DMG_BACKGROUND)
	@echo "==> Creating $(DMG_NAME)..."
	@rm -f $(Q_DMG) $(DMG_RW)
	@rm -rf $(DMG_STAGING)
	@mkdir -p $(DMG_STAGING)/.background
	@cp -R $(Q_BUNDLE) $(DMG_STAGING)/
	@ln -s /Applications $(DMG_STAGING)/Applications
	@cp $(DMG_BACKGROUND) $(DMG_STAGING)/.background/background.tiff
	@# A leftover volume of the same name would make macOS mount ours under a
	@# suffixed name, and the Finder layout script would target the wrong disk
	@for vol in "/Volumes/$(DMG_VOLNAME)"*; do \
	  [ -d "$$vol" ] && hdiutil detach "$$vol" -force >/dev/null 2>&1 || true; \
	done
	@echo "==> Building writable image..."
	@size_mb=$$(( $$(du -sm $(DMG_STAGING) | cut -f1) + 50 )); \
	hdiutil create -quiet \
	    -volname "$(DMG_VOLNAME)" \
	    -srcfolder $(DMG_STAGING) \
	    -size $${size_mb}m \
	    -fs HFS+ -format UDRW -ov \
	    $(DMG_RW)
	@echo "==> Applying window layout..."
	@mount_point=$$(hdiutil attach $(DMG_RW) -readwrite -nobrowse -noautoopen \
	    | grep -E '^/dev/' | sed -n 's/.*\(\/Volumes\/.*\)$$/\1/p' | head -1); \
	if [ -z "$$mount_point" ]; then echo "==> ERROR: failed to mount $(DMG_RW)"; exit 1; fi; \
	trap 'hdiutil detach "$$mount_point" -force >/dev/null 2>&1 || true' EXIT; \
	osascript Tools/Dmg/Layout.applescript "$$(basename "$$mount_point")" \
	    $(DMG_WIN_W) $(DMG_WIN_H) $(DMG_ICON_SIZE) \
	    $(DMG_APP_X) $(DMG_APP_Y) $(DMG_DROP_X) $(DMG_DROP_Y) \
	    "$(APP_BUNDLE)"; \
	cp $(ICNS) "$$mount_point/.VolumeIcon.icns"; \
	SetFile -a C "$$mount_point" 2>/dev/null || true; \
	chmod -Rf go-w "$$mount_point" 2>/dev/null || true; \
	sync; \
	trap - EXIT; \
	hdiutil detach "$$mount_point" -force >/dev/null
	@echo "==> Compressing..."
	@hdiutil convert $(DMG_RW) -quiet -format UDZO -imagekey zlib-level=9 -o $(Q_DMG)
	@rm -f $(DMG_RW)
	@rm -rf $(DMG_STAGING)
	@echo "==> Created $(DMG_NAME)"

notarize:
	@echo "==> Notarizing $(DMG_NAME)..."
	@apple_id="$(APPLE_ID)"; \
	apple_team_id="$(APPLE_TEAM_ID)"; \
	apple_app_password="$(APPLE_APP_PASSWORD)"; \
	if [ -z "$$apple_id" ]; then \
	  printf "==> Enter Apple ID (email): "; \
	  read apple_id; \
	fi; \
	if [ -z "$$apple_team_id" ]; then \
	  printf "==> Enter Apple Team ID: "; \
	  read apple_team_id; \
	fi; \
	if [ -z "$$apple_app_password" ]; then \
	  printf "==> Enter Apple app-specific password: "; \
	  read -s apple_app_password; \
	  echo; \
	fi; \
	xcrun notarytool submit $(Q_DMG) \
	    --apple-id "$$apple_id" \
	    --team-id "$$apple_team_id" \
	    --password "$$apple_app_password" \
	    --wait
	@echo "==> Stapling notarization ticket..."
	@xcrun stapler staple $(Q_DMG)
	@echo "==> Notarized and stapled $(DMG_NAME)"

release: dmg notarize

clean:
	rm -f $(BIN) $(ICNS) $(DMG_BACKGROUND) $(DMG_RW)
	rm -rf AppIcon.iconset $(Q_BUNDLE) $(Q_DMG) $(DMG_STAGING)
