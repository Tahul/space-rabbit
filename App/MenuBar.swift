/*
 * MenuBar.swift — Menu bar status item and dropdown menu
 *
 * Manages the rabbit icon in the macOS menu bar and its dropdown menu.
 * The menu provides:
 *   - Enable/disable toggle (also available via right-click on the icon)
 *   - Feature toggles (instant switch, auto-follow)
 *   - Usage statistics (switch count + estimated time saved)
 *   - Access to the settings window
 *   - Update availability banner
 *   - Launch-at-login warning
 */

import AppKit
import ServiceManagement

// MARK: - Constants

/// Colors used in the enable/disable toggle button icons.
private enum ToggleColors {
    /// Coral red — used for the "Disable" button icon.
    static let disable = NSColor(red: 0.94, green: 0.51, blue: 0.40, alpha: 1)

    /// Teal green — used for the "Enable" button icon.
    static let enable  = NSColor(red: 0.19, green: 0.77, blue: 0.55, alpha: 1)
}

/// Alpha applied to the menu bar icon when the app is disabled.
private let kDisabledIconAlpha: CGFloat = 0.25

/// Size (in points) for tinted SF Symbol icons used in menu items.
private let kMenuIconSize: CGFloat = 16

// MARK: - Time Formatting

/// Formats a number of seconds into a human-readable "time saved" string.
///
/// Each space switch saves roughly 1 second of animation time, so the
/// input is treated as both "switch count" and "seconds saved".
///
/// - Parameter seconds: Total seconds (= switch count) to format.
/// - Returns: A compact time string like "42 sec", "3 min", "1 hr 20 min", "2 days 5 hr".
private func formatTimeSaved(_ seconds: Int) -> String {
    switch seconds {
    case ..<60:
        return "\(seconds) sec"
    case ..<3600:
        return "\(seconds / 60) min"
    case ..<86400:
        let hours   = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return minutes > 0 ? "\(hours) hr \(minutes) min" : "\(hours) hr"
    default:
        let days  = seconds / 86400
        let hours = (seconds % 86400) / 3600
        return hours > 0 ? "\(days) days \(hours) hr" : "\(days) days"
    }
}

// MARK: - SwoopMenu

/// Manages the menu bar status item (rabbit icon) and its dropdown menu.
///
/// Responsibilities:
///   - Renders the rabbit icon with enabled/disabled state
///   - Dispatches left-click (open menu) vs right-click (quick toggle)
///   - Provides feature toggles and statistics in the dropdown
///   - Shows banners for update availability and launch-at-login warnings
///   - Records space switches and updates the statistics display
final class SwoopMenu: NSObject {

    // MARK: Menu Items

    private let statusItem:          NSStatusItem
    private let enableItem:          NSMenuItem
    private let instantSwitchItem:   NSMenuItem
    private let autoFollowItem:      NSMenuItem
    private let statsItem:           NSMenuItem

    /// Banner shown at the top of the menu when an update is available.
    private let updateAvailableItem: NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateAvailableSep:  NSMenuItem = .separator()

    /// Banner shown when the app is not set to launch at login.
    private let launchWarningItem:   NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let launchWarningSep:    NSMenuItem = .separator()

    private let checkUpdatesItem:     NSMenuItem = NSMenuItem(title: "Check for Updates\u{2026}",
                                                                   action: nil,
                                                                   keyEquivalent: "")
    private var statusMenu:          NSMenu!
    private var updateDownloadURL:   String?

    // MARK: Initialization

    override init() {
        // Register default preference values (used on first launch before
        // the user has toggled anything)
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Defaults.enabled:       true,
            Defaults.instantSwitch: true,
            Defaults.autoFollow:    true,
            Defaults.sounds:        false,
            Defaults.switchCount:   0,
        ])

        // Load persisted state from UserDefaults into the global variables
        // that drive runtime behavior
        gEnabled              = defaults.bool(forKey: Defaults.enabled)
        gInstantSwitchEnabled = defaults.bool(forKey: Defaults.instantSwitch)
        gAutoFollowEnabled    = defaults.bool(forKey: Defaults.autoFollow)
        gSoundsEnabled        = defaults.bool(forKey: Defaults.sounds)
        gSwitchCount          = defaults.integer(forKey: Defaults.switchCount)
        gSwitchCountSaved     = gSwitchCount

        // Create the status bar item (variable width to accommodate the icon)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Create the main menu items with keyboard shortcuts
        enableItem        = NSMenuItem(title: "Enable Space Rabbit",
                                       action: #selector(toggleEnabled(_:)),
                                       keyEquivalent: "")
        instantSwitchItem = NSMenuItem(title: "Instant Space Switch \u{2303}\u{2194}",
                                       action: #selector(toggleInstantSwitch(_:)),
                                       keyEquivalent: "s")
        autoFollowItem    = NSMenuItem(title: "Instant App Switch \u{2318}\u{21E5}",
                                       action: #selector(toggleAutoFollow(_:)),
                                       keyEquivalent: "f")
        statsItem         = NSMenuItem(title: "", action: nil, keyEquivalent: "")

        super.init()

        configureUpdateBanner()
        configureLaunchWarningBanner()
        configureMenuItemTargets()
        assignMenuItemIcons()
        buildMenu()
        configureStatusItemButton()

        // Set initial UI state
        updateMenuBarIcon()
        updateEnableItem()
        updateStatsDisplay()
        updateLaunchWarning()
    }

    // MARK: - Init Helpers

    /// Configures the update-available banner (hidden until an update is found).
    private func configureUpdateBanner() {
        updateAvailableItem.isHidden = true
        updateAvailableItem.target   = self
        updateAvailableItem.action   = #selector(openDownloadURL)
        updateAvailableSep.isHidden  = true
    }

    /// Configures the launch-at-login warning banner.
    private func configureLaunchWarningBanner() {
        launchWarningItem.target = self
        launchWarningItem.action = #selector(openSettingsForLaunchAtLogin)
    }

    /// Wires up targets and initial toggle states for all menu items.
    private func configureMenuItemTargets() {
        enableItem.target         = self
        instantSwitchItem.target  = self
        instantSwitchItem.state   = gInstantSwitchEnabled ? .on : .off
        autoFollowItem.target     = self
        autoFollowItem.state      = gAutoFollowEnabled    ? .on : .off
        statsItem.isEnabled       = false  // Non-interactive display item
        checkUpdatesItem.target   = self
        checkUpdatesItem.action   = #selector(handleCheckForUpdates)
    }

    /// Assigns SF Symbol icons to the feature toggle and stats menu items.
    private func assignMenuItemIcons() {
        if let img = NSImage(systemSymbolName: "arrow.left.arrow.right",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            instantSwitchItem.image = img
        }
        if let img = NSImage(systemSymbolName: "scope",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            autoFollowItem.image = img
        }
        if let img = NSImage(systemSymbolName: "timer",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            statsItem.image = img
        }
        if let img = NSImage(systemSymbolName: "arrow.down.circle",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            checkUpdatesItem.image = img
        }
    }

    /// Assembles the dropdown menu structure.
    private func buildMenu() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

        statusMenu = NSMenu()

        // Conditional banners (hidden when not applicable)
        statusMenu.addItem(updateAvailableItem)
        statusMenu.addItem(updateAvailableSep)
        statusMenu.addItem(launchWarningItem)
        statusMenu.addItem(launchWarningSep)

        // Master toggle
        statusMenu.addItem(enableItem)
        statusMenu.addItem(.separator())

        // Feature toggles section
        statusMenu.addItem(menuHeader("Configure:"))
        statusMenu.addItem(instantSwitchItem)
        statusMenu.addItem(autoFollowItem)
        statusMenu.addItem(.separator())

        // Statistics section
        statusMenu.addItem(menuHeader("Statistics:"))
        statusMenu.addItem(statsItem)
        statusMenu.addItem(.separator())

        // Footer: version, preferences, quit
        statusMenu.addItem(greyLabel("Version \(version)"))

        let settings = NSMenuItem(title: "Preferences\u{2026}",
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        if let img = NSImage(systemSymbolName: "gear",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            settings.image = img
        }
        // Help submenu
        let helpMenu = NSMenu()
        let websiteItem = NSMenuItem(title: "Open Website",
                                     action: #selector(openWebsite),
                                     keyEquivalent: "")
        websiteItem.target = self
        if let img = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) {
            img.isTemplate = true
            websiteItem.image = img
        }
        helpMenu.addItem(websiteItem)
        helpMenu.addItem(.separator())
        helpMenu.addItem(checkUpdatesItem)

        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        if let img = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil) {
            img.isTemplate = true
            helpItem.image = img
        }
        helpItem.submenu = helpMenu
        statusMenu.addItem(helpItem)

        statusMenu.addItem(settings)
        statusMenu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        if let img = NSImage(systemSymbolName: "xmark.rectangle",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            quit.image = img
        }
        statusMenu.addItem(quit)
    }

    /// Configures the status item button for both left-click and right-click handling.
    private func configureStatusItemButton() {
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Click Handling

    /// Dispatches left-click (open menu) vs right-click (toggle enable).
    ///
    /// Right-click provides a quick way to toggle the master switch without
    /// opening the full dropdown menu.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click: quick toggle without opening the menu
            setEnabled(!gEnabled)
        } else {
            // Left-click: refresh dynamic items and show the dropdown menu.
            // We temporarily assign the menu, perform the click, then remove
            // it so right-click continues to work (NSStatusItem only supports
            // either a menu OR an action, not both simultaneously).
            updateLaunchWarning()
            statusItem.menu = statusMenu
            sender.performClick(nil)
            statusItem.menu = nil
        }
    }

    // MARK: - Menu Bar Icon

    /// Updates the menu bar icon appearance based on the enabled state.
    ///
    /// When enabled, the rabbit icon is fully opaque. When disabled, it fades
    /// to 25% opacity to visually indicate the inactive state.
    private func updateMenuBarIcon() {
        if let img = NSImage(systemSymbolName: "hare.fill",
                             accessibilityDescription: "Space Rabbit") {
            img.isTemplate = true
            statusItem.button?.image = img
        }
        statusItem.button?.alphaValue = gEnabled ? 1.0 : kDisabledIconAlpha
    }

    /// Updates the enable/disable menu item text and icon color.
    ///
    /// Shows "Disable Space Rabbit" with a red X when enabled,
    /// or "Enable Space Rabbit" with a green checkmark when disabled.
    private func updateEnableItem() {
        if gEnabled {
            enableItem.title = "Disable Space Rabbit"
            enableItem.image = tintedSymbol("xmark.circle.fill", color: ToggleColors.disable)
        } else {
            enableItem.title = "Enable Space Rabbit"
            enableItem.image = tintedSymbol("checkmark.circle.fill", color: ToggleColors.enable)
        }
    }

    /// Creates a two-tone SF Symbol image suitable for use as a menu item icon.
    ///
    /// Uses the palette rendering mode: the inner shape gets white (light mode)
    /// or black (dark mode), and the background gets the specified color.
    /// The result is rendered into a fixed-size canvas to avoid layout jitter.
    ///
    /// - Parameters:
    ///   - name: SF Symbol name.
    ///   - color: Background/accent color for the symbol.
    ///   - size: Point size for the symbol (defaults to `kMenuIconSize`).
    /// - Returns: A non-template image, or `nil` if the symbol doesn't exist.
    private func tintedSymbol(_ name: String, color: NSColor,
                              size: CGFloat = kMenuIconSize) -> NSImage? {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let innerColor: NSColor = isDark ? .black : .white

        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [innerColor, color]))

        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }

        // Render into a fixed-size canvas to prevent layout jitter
        // when the symbol's intrinsic size varies between states
        let canvas = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        canvas.isTemplate = false
        return canvas
    }

    // MARK: - Menu Label Helpers

    /// Creates a small, grey section header for the dropdown menu.
    ///
    /// - Parameter title: The header text (rendered in small secondary-color font).
    /// - Returns: A non-interactive menu item styled as a section header.
    private func menuHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font:            NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    /// Creates a non-interactive grey label (e.g. for the version string).
    ///
    /// - Parameter title: The label text.
    /// - Returns: A disabled menu item with secondary label styling.
    private func greyLabel(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font:            NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        setEnabled(!gEnabled)
    }

    /// Sets the master enabled state, persists it, and updates the UI.
    ///
    /// - Parameter enabled: The new enabled state.
    private func setEnabled(_ enabled: Bool) {
        gEnabled = enabled
        UserDefaults.standard.set(gEnabled, forKey: Defaults.enabled)

        // Play a sound effect when re-enabling (if sounds are turned on)
        if enabled, gSoundsEnabled { NSSound(named: .init("Bottle"))?.play() }

        updateMenuBarIcon()
        updateEnableItem()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openSettingsForLaunchAtLogin() {
        GeneralViewController.pendingLaunchAtLoginAlert = true
        SettingsWindowController.shared.show()
    }

    // MARK: - Launch Warning Banner

    /// Shows or hides the "not auto-launching" warning in the dropdown menu.
    ///
    /// Checks the current `SMAppService` status and updates the banner
    /// accordingly. Called each time the menu is about to open.
    private func updateLaunchWarning() {
        let notEnabled = SMAppService.mainApp.status != .enabled
        launchWarningItem.isHidden = !notEnabled
        launchWarningSep.isHidden  = !notEnabled

        if notEnabled {
            launchWarningItem.attributedTitle = NSAttributedString(
                string: "Not Auto-Launching  \u{00B7}  Click to Fix",
                attributes: [
                    .font:            NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.systemOrange,
                ]
            )
            launchWarningItem.image = tintedSymbol(
                "exclamationmark.triangle.fill",
                color: NSColor.systemOrange
            )
        }
    }

    // MARK: - Update Banner

    /// Shows the "Update available" banner at the top of the dropdown menu.
    ///
    /// Called by the update checker when a newer version is found on GitHub.
    ///
    /// - Parameter downloadURL: Direct download URL for the DMG asset.
    func showUpdateBanner(downloadURL: String) {
        updateDownloadURL = downloadURL
        updateAvailableItem.attributedTitle = NSAttributedString(
            string: "Update Available  \u{00B7}  Click to Install",
            attributes: [
                .font:            NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        updateAvailableItem.image    = tintedSymbol("arrow.down.circle.fill", color: .systemBlue)
        updateAvailableItem.isHidden = false
        updateAvailableSep.isHidden  = false
    }

    @objc private func openWebsite() {
        if let url = URL(string: "https://space-rabbit.app") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Triggers the automatic update flow for the available download URL.
    @objc private func openDownloadURL() {
        guard let urlStr = updateDownloadURL else { return }
        startUpdate(downloadURL: urlStr)
    }

    /// Manually checks GitHub for a newer release, then prompts the user.
    @objc private func handleCheckForUpdates() {
        checkUpdatesItem.title     = "Checking for Updates…"
        checkUpdatesItem.isEnabled = false

        checkForUpdatesManually(
            onFound: { [weak self] downloadURL in
                guard let self else { return }
                self.checkUpdatesItem.title     = "Check for Updates\u{2026}"
                self.checkUpdatesItem.isEnabled = true

                // Show the tray banner so it persists after the dialog is dismissed
                self.showUpdateBanner(downloadURL: downloadURL)

                let alert = NSAlert()
                alert.messageText     = "Update Available"
                alert.informativeText = "A new version of Space Rabbit is available. Download and install it now?"
                alert.addButton(withTitle: "Install Now")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    startUpdate(downloadURL: downloadURL)
                }
            },
            onUpToDate: { [weak self] in
                guard let self else { return }
                self.checkUpdatesItem.title     = "Check for Updates\u{2026}"
                self.checkUpdatesItem.isEnabled = true

                let alert = NSAlert()
                alert.messageText     = "You're Up to Date"
                alert.informativeText = "Space Rabbit is already running the latest version."
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            },
            onError: { [weak self] in
                guard let self else { return }
                self.checkUpdatesItem.title     = "Check for Updates\u{2026}"
                self.checkUpdatesItem.isEnabled = true

                let alert = NSAlert()
                alert.messageText     = "Could Not Check for Updates"
                alert.informativeText = "Please check your internet connection and try again."
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        )
    }

    // MARK: - Feature Toggle Sync

    /// Synchronizes the menu item checkmarks with the current global state.
    ///
    /// Called by the settings window after it changes a feature toggle,
    /// so the dropdown menu stays consistent.
    func syncMenuItems() {
        instantSwitchItem.state = gInstantSwitchEnabled ? .on : .off
        autoFollowItem.state    = gAutoFollowEnabled    ? .on : .off
    }

    @objc private func toggleInstantSwitch(_ sender: NSMenuItem) {
        gInstantSwitchEnabled.toggle()
        sender.state = gInstantSwitchEnabled ? .on : .off
        UserDefaults.standard.set(gInstantSwitchEnabled, forKey: Defaults.instantSwitch)
    }

    @objc private func toggleAutoFollow(_ sender: NSMenuItem) {
        gAutoFollowEnabled.toggle()
        sender.state = gAutoFollowEnabled ? .on : .off
        UserDefaults.standard.set(gAutoFollowEnabled, forKey: Defaults.autoFollow)
    }

    // MARK: - Statistics

    /// Updates the stats menu item with the current switch count and estimated time saved.
    private func updateStatsDisplay() {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let countStr = formatter.string(from: NSNumber(value: gSwitchCount)) ?? "\(gSwitchCount)"
        statsItem.title = "\(countStr) switches  \u{00B7}  \(formatTimeSaved(gSwitchCount)) saved"
    }

    /// Increments the switch counter and refreshes the stats display.
    ///
    /// Called by both the event tap (instant switch) and the auto-follow
    /// observer whenever a space switch is performed.
    func recordSwitch() {
        gSwitchCount += 1
        updateStatsDisplay()
    }
}
