/*
 * MenuBar.swift — Menu bar status item and dropdown menu
 *
 * Manages the rabbit icon in the macOS menu bar and its dropdown menu.
 * The menu provides:
 *   - Header row with the app name and a native switch for the master
 *     on/off toggle (also available via right-click on the icon)
 *   - Feature toggles (instant switch, auto-follow)
 *   - Usage statistics (switch count + estimated time saved)
 *   - Access to the settings window
 *   - Update availability banner
 *   - Launch-at-login warning
 */

import AppKit
import ServiceManagement

// MARK: - Constants

/// Alpha applied to the menu bar icon when the app is disabled.
private let kDisabledIconAlpha: CGFloat = 0.25

/// Size (in points) for tinted SF Symbol icons used in menu items.
private let kMenuIconSize: CGFloat = 16

/// Height (in points) of the header row hosting the master enable switch.
private let kEnableRowHeight: CGFloat = 28

/// Horizontal content inset (in points) for the header row, aligning it
/// with the text of regular menu items.
private let kEnableRowInset: CGFloat = 14

// MARK: - Menu Key Appearance

/// Menu item container view that forces the menu's backing window into its
/// key-appearance state.
///
/// As an accessory (`LSUIElement`) app we are usually inactive when the
/// dropdown opens, and the menu's window never becomes key — so AppKit draws
/// hosted controls (the header row's `NSSwitch`) in their inactive graphite
/// style instead of the system accent color. Calling `becomeKeyWindow()`
/// directly flips AppKit's internal key-appearance flag without any actual
/// focus change: the frontmost app keeps focus, but controls in the menu
/// render active. (Same technique Klack uses for its menu header switch.)
private final class MenuKeyAppearanceView: NSView {

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Fires every time the menu opens (the item view is re-hosted in the
        // menu's window each time); nil when the view is removed on close.
        // (`becomeKey()` is Swift's bridged name for `-becomeKeyWindow`.)
        window?.becomeKey()
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

    private let statusItem:            NSStatusItem
    private let instantSwitchItem:     NSMenuItem
    private let autoFollowItem:        NSMenuItem
    private let threeFingerSwipeItem:  NSMenuItem
    private let statsItem:             NSMenuItem

    /// Header row at the top of the menu: app name + master enable switch.
    private let enableSwitchItem:    NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var enableSwitch:        NSSwitch!

    /// Banner shown at the top of the menu when an update is available.
    private let updateAvailableItem: NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateAvailableSep:  NSMenuItem = .separator()

    /// Banner shown when the app is not set to launch at login.
    private let launchWarningItem:   NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let launchWarningSep:    NSMenuItem = .separator()

    private var statusMenu:          NSMenu!
    private var updateDownloadURL:   String?

    // MARK: Initialization

    override init() {
        // Register default preference values (used on first launch before
        // the user has toggled anything)
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Defaults.enabled:          true,
            Defaults.instantSwitch:    true,
            Defaults.autoFollow:       true,
            Defaults.threeFingerSwipe: false,   // opt-in — swallows a real gesture
            Defaults.switchSpeed:      1.0,
            Defaults.switchCount:      0,
            Defaults.showMenuBarIcon:  true,
        ])

        // Load persisted state from UserDefaults into the global variables
        // that drive runtime behavior
        gEnabled                 = defaults.bool(forKey: Defaults.enabled)
        gInstantSwitchEnabled    = defaults.bool(forKey: Defaults.instantSwitch)
        gAutoFollowEnabled       = defaults.bool(forKey: Defaults.autoFollow)
        gThreeFingerSwipeEnabled = defaults.bool(forKey: Defaults.threeFingerSwipe)
        gSwitchSpeed             = defaults.double(forKey: Defaults.switchSpeed)
        gSwitchCount             = defaults.integer(forKey: Defaults.switchCount)
        gSwitchCountSaved        = gSwitchCount

        // Create the status bar item (variable width to accommodate the icon)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = defaults.bool(forKey: Defaults.showMenuBarIcon)

        // Create the main menu items with keyboard shortcuts
        instantSwitchItem = NSMenuItem(title: L("menu.instantSpaceSwitch"),
                                       action: #selector(toggleInstantSwitch(_:)),
                                       keyEquivalent: "s")
        autoFollowItem    = NSMenuItem(title: L("menu.instantAppSwitch"),
                                       action: #selector(toggleAutoFollow(_:)),
                                       keyEquivalent: "f")
        threeFingerSwipeItem = NSMenuItem(title: L("menu.instantThreeFingerSwipe"),
                                          action: #selector(toggleThreeFingerSwipe(_:)),
                                          keyEquivalent: "3")
        statsItem         = NSMenuItem(title: "", action: nil, keyEquivalent: "")

        super.init()

        configureEnableSwitchRow()
        configureUpdateBanner()
        configureLaunchWarningBanner()
        configureMenuItemTargets()
        assignMenuItemIcons()
        buildMenu()
        configureStatusItemButton()

        // Set initial UI state
        updateMenuBarIcon()
        updateStatsDisplay()
        updateLaunchWarning()
    }

    // MARK: - Init Helpers

    /// Builds the header row shown at the very top of the menu: the app name
    /// in bold next to a native switch bound to the master enabled state.
    private func configureEnableSwitchRow() {
        let label = NSTextField(labelWithString: L("app.name"))
        label.font      = NSFont.systemFont(ofSize: 13, weight: .bold)
        label.textColor = .labelColor

        enableSwitch             = NSSwitch()
        enableSwitch.controlSize = .small
        enableSwitch.target      = self
        enableSwitch.action      = #selector(enableSwitchChanged(_:))
        enableSwitch.state       = gEnabled ? .on : .off

        // The container is stretched to the menu's width via its autoresizing
        // mask; the initial frame just avoids transient constraint conflicts.
        // MenuKeyAppearanceView (vs a plain NSView) keeps the switch tinted
        // with the accent color while the app is inactive.
        let container = MenuKeyAppearanceView(frame: NSRect(x: 0, y: 0,
                                                            width: 240, height: kEnableRowHeight))
        container.autoresizingMask = [.width]

        label.translatesAutoresizingMaskIntoConstraints        = false
        enableSwitch.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(enableSwitch)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                           constant: kEnableRowInset),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            enableSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                   constant: -kEnableRowInset),
            enableSwitch.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            enableSwitch.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor,
                                                  constant: 16),
        ])

        enableSwitchItem.view = container
    }

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
        instantSwitchItem.target    = self
        instantSwitchItem.state     = gInstantSwitchEnabled    ? .on : .off
        autoFollowItem.target       = self
        autoFollowItem.state        = gAutoFollowEnabled       ? .on : .off
        threeFingerSwipeItem.target = self
        threeFingerSwipeItem.state  = gThreeFingerSwipeEnabled ? .on : .off
        statsItem.isEnabled         = false  // Non-interactive display item
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
        if let img = NSImage(systemSymbolName: "rectangle.and.hand.point.up.left.filled",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            threeFingerSwipeItem.image = img
        }
        if let img = NSImage(systemSymbolName: "timer",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            statsItem.image = img
        }
    }

    /// Assembles the dropdown menu structure.
    private func buildMenu() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

        statusMenu = NSMenu()

        // Header row: app name + master enable switch
        statusMenu.addItem(enableSwitchItem)
        statusMenu.addItem(.separator())

        // Conditional banners (hidden when not applicable)
        statusMenu.addItem(updateAvailableItem)
        statusMenu.addItem(updateAvailableSep)
        statusMenu.addItem(launchWarningItem)
        statusMenu.addItem(launchWarningSep)

        // Feature toggles section
        statusMenu.addItem(menuHeader(L("menu.section.configure")))
        statusMenu.addItem(instantSwitchItem)
        statusMenu.addItem(autoFollowItem)
        statusMenu.addItem(threeFingerSwipeItem)
        statusMenu.addItem(.separator())

        // Statistics section
        statusMenu.addItem(menuHeader(L("menu.section.statistics")))
        statusMenu.addItem(statsItem)
        statusMenu.addItem(.separator())

        // Footer: version, preferences, quit
        statusMenu.addItem(greyLabel(L("common.version", version)))

        let settings = NSMenuItem(title: L("menu.preferences"),
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        if let img = NSImage(systemSymbolName: "gear",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            settings.image = img
        }
        statusMenu.addItem(settings)
        statusMenu.addItem(.separator())

        let quit = NSMenuItem(title: L("menu.quit"),
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

    /// Whether the rabbit icon is currently shown in the menu bar.
    var isMenuBarIconVisible: Bool { statusItem.isVisible }

    /// Shows or hides the menu bar icon and persists the preference.
    ///
    /// When hidden, Space Rabbit keeps running; Preferences can be opened
    /// again by launching the app from Spotlight or the Applications folder.
    ///
    /// - Parameter visible: `true` to show the icon, `false` to hide it.
    func setMenuBarIconVisible(_ visible: Bool) {
        statusItem.isVisible = visible
        UserDefaults.standard.set(visible, forKey: Defaults.showMenuBarIcon)
    }

    /// Updates the menu bar icon appearance based on the enabled state.
    ///
    /// When enabled, the rabbit icon is fully opaque. When disabled, it fades
    /// to 25% opacity to visually indicate the inactive state.
    private func updateMenuBarIcon() {
        if let img = NSImage(systemSymbolName: "hare.fill",
                             accessibilityDescription: L("app.name")) {
            img.isTemplate = true
            statusItem.button?.image = img
        }
        statusItem.button?.alphaValue = gEnabled ? 1.0 : kDisabledIconAlpha
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

    /// Builds a banner title: an emphasized leading part followed by a
    /// regular-weight "Click to …" call to action, joined by a middle dot.
    ///
    /// Used by every actionable banner in the dropdown so they all share
    /// the same emphasis pattern.
    ///
    /// - Parameters:
    ///   - emphasized: The leading status text (rendered at `weight`).
    ///   - action: The call-to-action text (always regular weight).
    ///   - color: Text color applied to the whole title.
    ///   - weight: Font weight for the emphasized part.
    /// - Returns: The composed attributed title.
    private func bannerTitle(_ emphasized: String, action: String,
                             color: NSColor,
                             weight: NSFont.Weight) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: emphasized,
            attributes: [
                .font:            NSFont.systemFont(ofSize: 13, weight: weight),
                .foregroundColor: color,
            ]
        )
        title.append(NSAttributedString(
            string: "  \u{00B7}  \(action)",
            attributes: [
                .font:            NSFont.systemFont(ofSize: 13),
                .foregroundColor: color,
            ]
        ))
        return title
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

    @objc private func enableSwitchChanged(_ sender: NSSwitch) {
        setEnabled(sender.state == .on)
    }

    /// Sets the master enabled state, persists it, and updates the UI.
    ///
    /// - Parameter enabled: The new enabled state.
    private func setEnabled(_ enabled: Bool) {
        gEnabled = enabled
        UserDefaults.standard.set(gEnabled, forKey: Defaults.enabled)

        updateMenuBarIcon()
        enableSwitch.state = gEnabled ? .on : .off

        // The swipe-intercept tap (Feature 3) only runs while the master
        // switch is on — create or tear it down to match
        updateSwipeTap()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openSettingsForLaunchAtLogin() {
        AutoStartPaneController.pendingLaunchAtLoginAlert = true
        SettingsWindowController.shared.show(pane: .autoStart)
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
            launchWarningItem.attributedTitle = bannerTitle(
                L("menu.banner.notAutoLaunching"), action: L("menu.banner.clickToFix"),
                color: .systemOrange, weight: .medium
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

        // Only the "Update Available" part is emphasized; the call to action stays regular
        updateAvailableItem.attributedTitle = bannerTitle(
            L("update.available.title"), action: L("menu.banner.clickToInstall"),
            color: .labelColor, weight: .semibold
        )
        updateAvailableItem.image    = tintedSymbol("arrow.down.circle.fill", color: .systemBlue)
        updateAvailableItem.isHidden = false
        updateAvailableSep.isHidden  = false
    }

    /// Triggers the automatic update flow for the available download URL.
    @objc private func openDownloadURL() {
        guard let urlStr = updateDownloadURL else { return }
        startUpdate(downloadURL: urlStr)
    }

    // MARK: - Feature Toggle Sync

    /// Synchronizes the menu item checkmarks with the current global state.
    ///
    /// Called by the settings window after it changes a feature toggle,
    /// so the dropdown menu stays consistent.
    func syncMenuItems() {
        instantSwitchItem.state    = gInstantSwitchEnabled    ? .on : .off
        autoFollowItem.state       = gAutoFollowEnabled       ? .on : .off
        threeFingerSwipeItem.state = gThreeFingerSwipeEnabled ? .on : .off
    }

    @objc private func toggleInstantSwitch(_ sender: NSMenuItem) {
        gInstantSwitchEnabled.toggle()
        sender.state = gInstantSwitchEnabled ? .on : .off
        UserDefaults.standard.set(gInstantSwitchEnabled, forKey: Defaults.instantSwitch)
        SettingsWindowController.shared.syncPanes()
    }

    @objc private func toggleAutoFollow(_ sender: NSMenuItem) {
        gAutoFollowEnabled.toggle()
        sender.state = gAutoFollowEnabled ? .on : .off
        UserDefaults.standard.set(gAutoFollowEnabled, forKey: Defaults.autoFollow)
        SettingsWindowController.shared.syncPanes()
    }

    @objc private func toggleThreeFingerSwipe(_ sender: NSMenuItem) {
        gThreeFingerSwipeEnabled.toggle()
        sender.state = gThreeFingerSwipeEnabled ? .on : .off
        UserDefaults.standard.set(gThreeFingerSwipeEnabled, forKey: Defaults.threeFingerSwipe)
        updateSwipeTap()
        SettingsWindowController.shared.syncPanes()
    }

    // MARK: - Statistics

    /// Updates the stats menu item with the current switch count and estimated
    /// time saved (each space switch saves roughly one second of animation,
    /// so the count doubles as a number of seconds).
    private func updateStatsDisplay() {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let countStr = formatter.string(from: NSNumber(value: gSwitchCount)) ?? "\(gSwitchCount)"

        // The count is passed twice: once to pick the plural form, once
        // pre-formatted with the locale's grouping separator for display
        let switchesStr = L("stats.switches", gSwitchCount, countStr)

        statsItem.title = L("menu.stats.line", switchesStr, localizedDuration(gSwitchCount))
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
