# 🐇 Space Rabbit

Instant space switching on macOS.

Space Rabbit removes animations when switching macOS Spaces. Reclaim hours of your time every month!

⬇️ **[Download Space Rabbit for macOS here](https://space-rabbit.app)**

## Features

- ✅ **Instant space switch** - your keyboard shortcut switches spaces with zero animation
- ✅ **Configurable space cycling** - assign Fn/Globe, an F-key, or a global shortcut and wrap back to the first Space
- ✅ **Auto-follow on Cmd+Tab** - switching to an app on another space takes you there instantly
- ✅ **Instant trackpad swipe** - your trackpad swipe switches spaces with zero animation too
- ✅ **Instant Mission Control** - optionally enter and leave Mission Control with no transition animation
- ✅ **Reads your shortcuts** - picks up your bindings from System Settings automatically
- ✅ **Tiny native macOS app** - 2MB binary size, 12MB memory usage, zero CPU usage
- ✅ **No system changes needed** - just classic accessibility permissions

## Demo video

First, you'll see default macOS space switching. Then, we'll enable Space Rabbit for instant switching:

https://github.com/user-attachments/assets/ba73cabe-2443-4cf2-87aa-f1f7841e6c21

## Screenshots

![space-rabbit-menu](https://github.com/user-attachments/assets/64f35b7e-9d67-413a-b186-f9aff6374507)

![space-rabbit-settings](https://github.com/user-attachments/assets/bff6faf8-4f66-4391-96f1-00fd5c4ba5df)

## Install

* Download the latest release from [GitHub Releases](https://github.com/Tahul/space-rabbit/releases) and drag **Space Rabbit.app** into your Applications folder.

* Install the latest version from [Homebrew](https://brew.sh):

`brew install space-rabbit`

* You can also download Space Rabbit from our [website](https://space-rabbit.app).

👉 **Grant Accessibility access when prompted** (System Settings → Privacy & Security → Accessibility).

## Configure

For the best experience, also enable **Instant Dock hide** in Space Rabbit's Preferences.

This makes the Dock hide animation instant, eliminating a residual transition of the Dock when switching spaces. It is not enabled by default because it modifies a global macOS setting — but it has no effect when Space Rabbit is disabled.

![instant-dock](https://github.com/user-attachments/assets/a8b18b0c-aebb-42fe-a52d-fa5a0d346907)

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

Requires Xcode Command Line Tools (`xcode-select --install`). No third-party dependencies.

```bash
# Clone the repo
git clone https://github.com/Tahul/space-rabbit.git && cd space-rabbit

# Build Space Rabbit.app in the project root
make app

# Build and launch immediately (kills any running instance first, used for development)
make app-dev

# Clean all build artefacts
make clean
```

## Release & notarize

👉 This procedure is only used by repository maintainers to release new versions of Space Rabbit.

1. Prior to distributing a release, create a new Git tag so that the new version is picked up during build. Tags should be formatted as such: `v1.0.0`.

2. Once tagged, you can build `Space Rabbit.app`:

```bash
make app
```

3. Finally, it needs to be packaged and notarized into `Space-Rabbit.dmg` as such:

```bash
make release
```

4. When the final DMG has been packaged and notarized, simply draft a new release on [space-rabbit/releases](https://github.com/Tahul/space-rabbit/releases) and upload `Space-Rabbit.dmg`.

👉 The website does not need to be updated, since the download button points to the `Space-Rabbit.dmg` file from the latest release.

👉 You can configure your signing key by creating a `local.env` file with eg.:

```bash
export SIGN_ID=Developer ID Application: Your Developer Name (IDENTIFIER_HERE)
```

## Help translate

This app supports localization. The base language is English (`en`). It is translated in languages such as French (`fr`), German (`de`), Spanish (`es`) and more.

If your spoken language is missing, you can add it by asking your AI coding agent to auto-translate from English. To check it, build the app for yourself and manually check all localized strings. Then, you may submit a Pull Request.

## Credits

Space Rabbit relies on a hack, that posts synthetic high-velocity DockSwipe gesture events. This is based on a technique from [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher).

The "Instant Trackpad Swipe" feature — intercepting real trackpad swipes and replacing them with instant switches — is ported from [iss](https://github.com/joshuarli/iss) by [@joshuarli](https://github.com/joshuarli).

The vertical DockSwipe state machine used by "Instant Mission Control" is based on [FasterSwiper](https://github.com/mgbowen/FasterSwiper) by [@mgbowen](https://github.com/mgbowen).
