PREFIX   ?= $(HOME)/.local
BINDIR    = $(PREFIX)/bin
AGENTDIR  = $(HOME)/Library/LaunchAgents
PLIST     = com.noswoop.agent.plist

CC       ?= clang
CFLAGS   ?= -Wall -Wextra -O2
LDFLAGS   = -framework CoreGraphics -framework CoreFoundation -framework ApplicationServices -framework AppKit -F/System/Library/PrivateFrameworks -weak_framework SkyLight

SRC       = noswoop.m
BIN       = noswoop

VERSION  ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
REPO      = tahul/noswoop

.PHONY: build install uninstall clean release

build: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: build
	@mkdir -p $(BINDIR)
	cp $(BIN) $(BINDIR)/$(BIN)
	@chmod +x $(BINDIR)/$(BIN)
	@echo "Installed $(BINDIR)/$(BIN)"
	@mkdir -p $(AGENTDIR)
	@sed 's|__BINPATH__|$(BINDIR)/$(BIN)|g' $(PLIST) > $(AGENTDIR)/$(PLIST)
	@echo "Installed $(AGENTDIR)/$(PLIST)"
	launchctl bootout gui/$$(id -u) $(AGENTDIR)/$(PLIST) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(AGENTDIR)/$(PLIST)
	@echo "LaunchAgent loaded. Run 'launchctl kickstart gui/$$(id -u)/com.noswoop.agent' to run now."

uninstall:
	launchctl bootout gui/$$(id -u)/com.noswoop.agent 2>/dev/null || true
	rm -f $(AGENTDIR)/$(PLIST)
	rm -f $(BINDIR)/$(BIN)
	@echo "Uninstalled noswoop"

clean:
	rm -f $(BIN)

# Usage: make release V=0.3.0
release:
ifndef V
	$(error Usage: make release V=x.y.z)
endif
	@echo "==> Tagging v$(V)..."
	git tag v$(V)
	git push origin main --tags
	@echo "==> Fetching tarball SHA..."
	$(eval SHA := $(shell curl -sL https://github.com/$(REPO)/archive/refs/tags/v$(V).tar.gz | shasum -a 256 | cut -d' ' -f1))
	@echo "==> SHA: $(SHA)"
	@echo "==> Updating formula..."
	sed -i '' 's|archive/refs/tags/v.*\.tar\.gz|archive/refs/tags/v$(V).tar.gz|' Formula/noswoop.rb
	sed -i '' 's|sha256 ".*"|sha256 "$(SHA)"|' Formula/noswoop.rb
	git add Formula/noswoop.rb
	git commit -m "chore: update formula for v$(V)"
	git tag -f v$(V)
	git push origin main --tags --force
	@echo "==> Released v$(V)"
