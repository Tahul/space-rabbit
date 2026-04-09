# noswoop

Instant space switching on macOS.

No animation, no delay, no lost focus.

## Features

- ⚡ **Instant space switch** - your keyboard shortcut switches spaces with zero animation
- 👁️ **Auto-follow on Cmd+Tab** - switching to an app on another space takes you there instantly
- ⌨️ **Reads your shortcuts** - picks up your bindings from System Settings automatically
- 🛡️ **No SIP changes needed** - just classic accessibility permissions

## Install

```bash
brew tap tahul/noswoop https://github.com/tahul/noswoop.git
brew install noswoop
brew services start noswoop
```

Grant Accessibility access when prompted (System Settings → Privacy & Security → Accessibility).

## Setup

For the Cmd+Tab feature, turn off macOS's built-in animated space switching:

> **System Settings → Desktop & Dock** → disable **"When switching to an application, switch to a Space with open windows for the application"**

## Uninstall

```bash
brew services stop noswoop
brew uninstall noswoop
brew untap tahul/noswoop
```

## How it works

Posts synthetic high-velocity DockSwipe gesture events.

The Dock processes these as a completed trackpad swipe and switches instantly.

Based on the technique from [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher).

## Known limitations

- Trackpad swipe gestures still animate (they bypass the event tap)
- While it skips apps present in Cmd+Tab list, it will still animate to first space when selecting Finder without opened windows, it's a native behavior we can't bypass
- Cmd+Tab to fullscreen apps may briefly flicker
- May break on future macOS updates (uses undocumented CGEvent fields)
