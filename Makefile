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
ICNS       = Icon/AppIcon.icns

# DMG window layout — must stay in sync with Dmg/CreateBackground.swift
DMG_BACKGROUND ?= Dmg/Background.tiff
DMG_VOLNAME    = Space Rabbit $(VERSION)
DMG_WIN_W      = 700
DMG_WIN_H      = 460
DMG_ICON_SIZE  = 128
DMG_APP_X      = 185
DMG_APP_Y      = 215
DMG_DROP_X     = 515
DMG_DROP_Y     = 215

SIGN_ID          ?=
APPLE_ID         ?=
APPLE_TEAM_ID    ?=
APPLE_APP_PASSWORD ?=

VERSION   ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')

.PHONY: build icon background app app-dev dmg notarize release clean verify-macos-min

build: $(BIN) verify-macos-min

$(BIN): $(SRCS) Makefile
	$(SWIFTC) $(SWIFTFLAGS) -target $(SWIFT_TARGET) -o $@ $(SRCS) $(LDFLAGS)

verify-macos-min: $(BIN)
	@actual_min="$$(otool -l $(BIN) | awk '/LC_BUILD_VERSION/ { found = 1; next } found && /minos/ { print $$2; exit }')"; \
	if [ "$$actual_min" != "$(MACOS_MIN)" ]; then \
	  echo "==> ERROR: $(BIN) was built for macOS $$actual_min, expected $(MACOS_MIN)."; \
	  echo "==> Check MACOS_MIN/SWIFT_TARGET and rebuild before packaging."; \
	  exit 1; \
	fi

icon: $(ICNS)

$(ICNS): Icon/CreateIcon.swift
	@echo "==> Generating $(ICNS)..."
	@swift Icon/CreateIcon.swift
	@mv AppIcon.icns $(ICNS)
	@echo "==> Generated $(ICNS)"

app: build $(ICNS)
	@echo "==> Building $(APP_BUNDLE)..."
	@rm -rf $(Q_BUNDLE)
	@mkdir -p $(Q_BUNDLE)/Contents/MacOS
	@mkdir -p $(Q_BUNDLE)/Contents/Resources
	@cp $(BIN) $(Q_BUNDLE)/Contents/MacOS/$(BIN)
	@cp $(ICNS) $(Q_BUNDLE)/Contents/Resources/AppIcon.icns
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

background: $(DMG_BACKGROUND)

Dmg/Background.tiff: Dmg/CreateBackground.swift
	@echo "==> Generating Dmg/Background.tiff..."
	@swift Dmg/CreateBackground.swift
	@mv Background.tiff Dmg/Background.tiff
	@echo "==> Generated Dmg/Background.tiff"

dmg: app $(DMG_BACKGROUND)
	@echo "==> Creating $(DMG_NAME)..."
	@rm -f $(Q_DMG) _dmg_rw.dmg
	@rm -rf _dmg_staging
	@mkdir -p _dmg_staging/.background
	@cp -R $(Q_BUNDLE) _dmg_staging/
	@ln -s /Applications _dmg_staging/Applications
	@cp $(DMG_BACKGROUND) _dmg_staging/.background/background.tiff
	@# A leftover volume of the same name would make macOS mount ours under a
	@# suffixed name, and the Finder layout script would target the wrong disk
	@for vol in "/Volumes/$(DMG_VOLNAME)"*; do \
	  [ -d "$$vol" ] && hdiutil detach "$$vol" -force >/dev/null 2>&1 || true; \
	done
	@echo "==> Building writable image..."
	@size_mb=$$(( $$(du -sm _dmg_staging | cut -f1) + 50 )); \
	hdiutil create -quiet \
	    -volname "$(DMG_VOLNAME)" \
	    -srcfolder _dmg_staging \
	    -size $${size_mb}m \
	    -fs HFS+ -format UDRW -ov \
	    _dmg_rw.dmg
	@echo "==> Applying window layout..."
	@mount_point=$$(hdiutil attach _dmg_rw.dmg -readwrite -nobrowse -noautoopen \
	    | grep -E '^/dev/' | sed -n 's/.*\(\/Volumes\/.*\)$$/\1/p' | head -1); \
	if [ -z "$$mount_point" ]; then echo "==> ERROR: failed to mount _dmg_rw.dmg"; exit 1; fi; \
	trap 'hdiutil detach "$$mount_point" -force >/dev/null 2>&1 || true' EXIT; \
	osascript Dmg/Layout.applescript "$$(basename "$$mount_point")" \
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
	@hdiutil convert _dmg_rw.dmg -quiet -format UDZO -imagekey zlib-level=9 -o $(Q_DMG)
	@rm -f _dmg_rw.dmg
	@rm -rf _dmg_staging
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
	rm -f $(BIN) $(ICNS) Dmg/Background.tiff _dmg_rw.dmg
	rm -rf AppIcon.iconset $(Q_BUNDLE) $(Q_DMG) _dmg_staging
