-include local.env
export

SWIFTC     ?= swiftc
SWIFTFLAGS ?= -O
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
SIGN_ID          ?=
APPLE_ID         ?=
APPLE_TEAM_ID    ?=
APPLE_APP_PASSWORD ?=

VERSION   ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')

.PHONY: build icon app app-dev dmg notarize release clean

build: $(BIN)

$(BIN): $(SRCS)
	$(SWIFTC) $(SWIFTFLAGS) -o $@ $(SRCS) $(LDFLAGS)

icon: $(ICNS)

$(ICNS): Icon/CreateIcon.swift
	@echo "==> Generating $(ICNS)..."
	@swift Icon/CreateIcon.swift
	@mv AppIcon.icns $(ICNS)
	@echo "==> Generated $(ICNS)"

app: $(BIN) $(ICNS)
	@echo "==> Building $(APP_BUNDLE)..."
	@rm -rf $(Q_BUNDLE)
	@mkdir -p $(Q_BUNDLE)/Contents/MacOS
	@mkdir -p $(Q_BUNDLE)/Contents/Resources
	@cp $(BIN) $(Q_BUNDLE)/Contents/MacOS/$(BIN)
	@cp $(ICNS) $(Q_BUNDLE)/Contents/Resources/AppIcon.icns
	@sed 's/__VERSION__/$(VERSION)/g' App/Info.plist > $(Q_BUNDLE)/Contents/Info.plist
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
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@sleep 0.5
	@open $(Q_BUNDLE)
	@echo "==> Restarted $(APP_BUNDLE)"

dmg: app
	@echo "==> Creating $(DMG_NAME)..."
	@rm -f $(Q_DMG)
	@mkdir -p _dmg_staging
	@cp -r $(Q_BUNDLE) _dmg_staging/
	@ln -sf /Applications _dmg_staging/Applications
	@hdiutil create \
	    -volname "Space Rabbit $(VERSION)" \
	    -srcfolder _dmg_staging \
	    -ov -format UDZO \
	    $(Q_DMG)
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
	rm -f $(BIN) $(ICNS)
	rm -rf AppIcon.iconset $(Q_BUNDLE) $(Q_DMG)
