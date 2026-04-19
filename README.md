# 🐇 Space Rabbit

Instant space switching on macOS.

Space Rabbit removes animations when switching macOS Spaces. Reclaim hours of your time every month!

⬇️ **[Download Space Rabbit for macOS here](https://space-rabbit.app)**

## Features

- ✅ **Instant space switch** - your keyboard shortcut switches spaces with zero animation
- ✅ **Auto-follow on Cmd+Tab** - switching to an app on another space takes you there instantly
- ✅ **Reads your shortcuts** - picks up your bindings from System Settings automatically
- ✅ **No SIP changes needed** - just classic accessibility permissions

## Screenshots

![space-rabbit-menu](https://github.com/user-attachments/assets/d094a99b-2cf6-4894-8606-bcee7f4470fe)

![space-rabbit-settings](https://github.com/user-attachments/assets/e648db8d-cf67-4f7e-b854-a7cc4f07f9d5)

## Install

Download the latest release from [GitHub Releases](https://github.com/Tahul/space-rabbit/releases) and drag **Space Rabbit.app** into your Applications folder.

Alternatively, you can also [download Space Rabbit from our website](https://space-rabbit.app).

👉 **Grant Accessibility access when prompted** (System Settings → Privacy & Security → Accessibility).

## Setup

For the best experience, also enable **Instant Dock hide** in Space Rabbit's Preferences. This makes the Dock hide animation instant, eliminating a residual flash when switching spaces. It is not enabled by default because it modifies a global macOS setting — but it has no effect when Space Rabbit is disabled.

## Uninstall

1. Quit Space Rabbit from the menu bar.
2. Delete **Space Rabbit.app** from your Applications folder.
3. Remove the login item in **System Settings → General → Login Items** if you had enabled it.

> **If you had "Instant Dock hide" enabled:** Space Rabbit writes a setting directly to macOS's Dock preferences to make the Dock hide animation instant. Deleting the app does not revert this change. To restore the original Dock behavior, run the following command in Terminal:
>
> ```bash
> defaults delete com.apple.dock autohide-time-modifier && killall Dock
> ```

## Build from source

```bash
make app
```

Requires Xcode command line tools and a valid Developer ID for signing.

If you don't, you will be asked for your signature key identifier when building the app. 

## Release & notarize

👉 _This procedure is only used by repository maintainers to release new versions of Space Rabbit._

Prior to distributing a release, create a new Git tag so that the new version is picked up during build. Tags should be formatted as such: `v1.0.0`.

Once tagged, you can build `Space Rabbit.app`:

```bash
make app
```

You can configure your signing key by creating a `local.env` file with eg.:

```bash
export SIGN_ID=Developer ID Application: Your Developer Name (IDENTIFIER_HERE)
```

Finally, it needs to be packaged and notarized into `Space-Rabbit.dmg` as such:

```bash
make release
```

When the final DMG has been packaged and notarized, simply draft a new release on [space-rabbit/releases](https://github.com/Tahul/space-rabbit/releases) and upload `Space-Rabbit.dmg`.

The website does not need to be updated, since the download button points to the `Space-Rabbit.dmg` file from the latest release.

## How it works

Posts synthetic high-velocity DockSwipe gesture events. The Dock processes these as a completed trackpad swipe and switches instantly.

This is based on the technique from [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher).

## Known limitations

- Trackpad swipe gestures still animate (they bypass the event tap)
- May break on future macOS updates (uses undocumented CGEvent fields)
