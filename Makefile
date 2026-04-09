PREFIX   ?= $(HOME)/.local
BINDIR    = $(PREFIX)/bin
AGENTDIR  = $(HOME)/Library/LaunchAgents
PLIST     = com.noswoop.agent.plist

CC       ?= clang
CFLAGS   ?= -Wall -Wextra -O2
LDFLAGS   = -framework CoreGraphics -framework CoreFoundation -framework ApplicationServices -framework AppKit -F/System/Library/PrivateFrameworks -weak_framework SkyLight

SRC       = noswoop.m
BIN       = noswoop

.PHONY: build install uninstall clean

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
