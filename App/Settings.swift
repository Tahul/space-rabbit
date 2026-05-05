/*
 * Settings.swift — Preferences window with General and About tabs
 *
 * The settings window uses a toolbar-style NSTabViewController with two tabs:
 *
 *   General — Launch at Login toggle, feature toggles, sounds, Dock instant-hide
 *   About   — App icon, version, authors, update notice
 *
 * All UI is built programmatically (no nibs or storyboards) using
 * Auto Layout and NSStackView for consistent, resizable layouts.
 */

import AppKit
import ServiceManagement

// MARK: - Layout Constants

/// Centralizes all layout values used across the settings UI.
/// Keeps spacing, sizing, and padding consistent and easy to tweak.
private enum Layout {
    static let windowWidth:       CGFloat = 480
    static let windowMinHeight:   CGFloat = 200
    static let outerPadding:      CGFloat = 20
    static let topPadding:        CGFloat = 16
    static let bottomPadding:     CGFloat = 16
    static let sectionSpacing:    CGFloat = 6
    static let groupGapSpacing:   CGFloat = 14
    static let rowHorizontalPad:  CGFloat = 8
    static let rowVerticalPad:    CGFloat = 12
    static let rowIconSize:       CGFloat = 24
    static let iconSymbolSize:    CGFloat = 11
    static let iconCornerRadius:  CGFloat = 6
    static let groupCornerRadius: CGFloat = 8
    static let groupBorderWidth:  CGFloat = 0.5
    static let aboutTopPadding:   CGFloat = 24
    static let aboutBottomPad:    CGFloat = 24
    static let aboutIconSize:     CGFloat = 80
    static let aboutSpacing:      CGFloat = 20
}

// MARK: - Tab View Controller

/// Manages the toolbar tabs and resizes the window to fit each tab's content.
///
/// When the user switches tabs, the window smoothly resizes to match the
/// new tab's intrinsic content size, keeping the title bar anchored at the top.
final class PreferencesTabViewController: NSTabViewController {

    override func viewDidAppear() {
        super.viewDidAppear()
        let item = tabViewItems[selectedTabViewItemIndex]
        applyWindowSize(for: item, animate: false)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let item = tabViewItem else { return }
        applyWindowSize(for: item, animate: true)
    }

    /// Re-applies the window size for the current tab.
    ///
    /// Call this after showing/hiding dynamic content (e.g. warning banners)
    /// so the window adjusts to the new content height.
    ///
    /// - Parameter animate: Whether to animate the resize transition.
    func resizeCurrent(animate: Bool = true) {
        let item = tabViewItems[selectedTabViewItemIndex]
        applyWindowSize(for: item, animate: animate)
    }

    /// Resizes the window to fit the given tab's content, keeping the
    /// title bar anchored at the top (origin.y shifts to compensate).
    private func applyWindowSize(for item: NSTabViewItem, animate: Bool) {
        guard let viewController = item.viewController,
              let window = view.window else { return }

        viewController.view.layoutSubtreeIfNeeded()
        window.title = item.label

        let contentSize = viewController.view.fittingSize
        let contentRect = NSRect(origin: .zero, size: contentSize)
        let newHeight   = window.frameRect(forContentRect: contentRect).height

        // Anchor the top edge: shift origin down by the height difference
        // so the window grows/shrinks from the bottom
        var frame         = window.frame
        frame.origin.y   += frame.height - newHeight
        frame.size.height = newHeight
        window.setFrame(frame, display: true, animate: animate)
    }
}

// MARK: - Settings Window Controller

/// Singleton that owns and shows the preferences window.
///
/// The window is created lazily on first `show()` call and reused
/// for subsequent invocations. It is not released when closed, so
/// user selections (active tab) are preserved.
final class SettingsWindowController: NSObject, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    /// Shows the settings window, creating it on first call.
    func show() {
        if window == nil { window = makeWindow() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Constructs the preferences window with its tab view controller.
    private func makeWindow() -> NSWindow {
        let tabVC = PreferencesTabViewController()
        tabVC.tabStyle = .toolbar

        // General tab: launch at login, feature toggles, sounds, Dock settings
        let generalItem = NSTabViewItem(viewController: GeneralViewController())
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "togglepower",
                                    accessibilityDescription: nil)
        tabVC.addTabViewItem(generalItem)

        // About tab: app info, version, authors, update notice
        let aboutItem = NSTabViewItem(viewController: AboutViewController())
        aboutItem.label = "About"
        aboutItem.image = NSImage(systemSymbolName: "hare",
                                  accessibilityDescription: nil)
        tabVC.addTabViewItem(aboutItem)

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = tabVC
        return window
    }
}

// MARK: - General Tab

/// The "General" preferences tab with all runtime settings.
///
/// Organized into four groups:
///   1. Auto-start — Launch at Login
///   2. Features   — Instant space switch, Auto-follow
///   3. Interface  — Sounds
///   4. Advanced   — Dock instant-hide
final class GeneralViewController: NSViewController {

    /// When `true`, the launch-at-login row will flash on next appearance.
    /// Set by the menu bar warning banner to draw attention to the setting.
    static var pendingLaunchAtLoginAlert = false

    // MARK: Controls

    private var instantSwitchControl:   NSSwitch!
    private var autoFollowControl:      NSSwitch!
    private var soundsControl:          NSSwitch!
    private var launchAtLoginControl:   NSSwitch!
    private var launchStatusLabel:      NSTextField!
    private var launchWarningBanner:    NSView!
    private var instantDockHideControl: NSSwitch!
    private var dockResetDivider:       NSView!
    private var dockResetRow:           NSView!

    override func loadView() { view = NSView() }

    // MARK: View Setup

    override func viewDidLoad() {
        super.viewDidLoad()

        // Create all toggle switches wired to their respective actions
        instantSwitchControl   = makeSwitch(gInstantSwitchEnabled, #selector(toggleInstantSwitch))
        autoFollowControl      = makeSwitch(gAutoFollowEnabled,    #selector(toggleAutoFollow))
        soundsControl          = makeSwitch(gSoundsEnabled,        #selector(toggleSounds))
        launchAtLoginControl   = makeSwitch(false,                 #selector(toggleLaunchAtLogin))

        // Status label shown below the launch-at-login toggle when there's an issue
        launchStatusLabel = NSTextField(wrappingLabelWithString: "")
        launchStatusLabel.font                    = .systemFont(ofSize: 11)
        launchStatusLabel.textColor               = .secondaryLabelColor
        launchStatusLabel.preferredMaxLayoutWidth = 240
        launchStatusLabel.isHidden                = true

        // --- Group 1: Launch at Login ---
        let autoStartGroup = groupContainer()
        autoStartGroup.addArrangedSubview(settingsRow(
            symbol:  "gearshape.2.fill",
            color:   NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1),
            label:   "Launch at login",
            control: launchAtLoginControl,
            subtitle: launchStatusLabel
        ))

        // --- Group 2: Feature Toggles ---
        let featuresGroup = groupContainer()
        featuresGroup.addArrangedSubview(settingsRow(
            symbol:  "arrow.left.arrow.right",
            color:   NSColor(red: 0.20, green: 0.55, blue: 1.00, alpha: 1),
            label:   "Instant Space switch",
            control: instantSwitchControl
        ))
        featuresGroup.addArrangedSubview(rowDivider())
        featuresGroup.addArrangedSubview(settingsRow(
            symbol:  "scope",
            color:   NSColor(red: 0.35, green: 0.75, blue: 0.40, alpha: 1),
            label:   "Instant App switch",
            control: autoFollowControl
        ))

        // --- Group 3: Interface ---
        let interfaceGroup = groupContainer()
        interfaceGroup.addArrangedSubview(settingsRow(
            symbol:  "speaker.wave.2.fill",
            color:   NSColor(red: 0.60, green: 0.35, blue: 0.85, alpha: 1),
            label:   "Enable sounds",
            control: soundsControl
        ))

        // Warning banner shown when launch-at-login is not enabled
        launchWarningBanner = makeLaunchWarningBanner()

        // --- Group 4: Advanced (Dock instant-hide) ---
        let advancedGroup = buildAdvancedGroup()

        // --- Assemble the outer layout ---
        let outerStack = buildOuterStack(
            autoStartGroup: autoStartGroup,
            featuresGroup:  featuresGroup,
            interfaceGroup: interfaceGroup,
            advancedGroup:  advancedGroup
        )

        view.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: view.topAnchor,
                                            constant: Layout.topPadding),
            outerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                                constant: Layout.outerPadding),
            outerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                                 constant: -Layout.outerPadding),
            outerStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor,
                                               constant: -Layout.bottomPadding),
            view.widthAnchor.constraint(equalToConstant: Layout.windowWidth),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.windowMinHeight),
        ])

        updateLaunchAtLoginUI()
    }

    /// Builds the "Advanced" group containing the Dock instant-hide toggle
    /// and a conditional "Reset to system default" link.
    private func buildAdvancedGroup() -> NSStackView {
        let dockSubtitle = NSTextField(wrappingLabelWithString:
            "This changes a global macOS setting.")
        dockSubtitle.font                    = .systemFont(ofSize: 11)
        dockSubtitle.textColor               = .secondaryLabelColor
        dockSubtitle.preferredMaxLayoutWidth = 240

        instantDockHideControl = makeSwitch(
            isDockInstantHideEnabled(),
            #selector(toggleDockInstantHide)
        )

        // "Reset to system default" link button (only visible when overridden)
        let resetBtn = LinkButton(title: "", target: self, action: #selector(resetDockToDefault))
        resetBtn.isBordered = false
        resetBtn.attributedTitle = NSAttributedString(string: "Reset to system default", attributes: [
            .font:            NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
        ])

        let resetIcon = NSImageView()
        resetIcon.image = NSImage(systemSymbolName: "arrow.clockwise",
                                  accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular))
        resetIcon.contentTintColor = .linkColor

        let resetStack = NSStackView(views: [resetIcon, resetBtn])
        resetStack.orientation = .horizontal
        resetStack.spacing     = 2
        resetStack.alignment   = .centerY
        resetStack.translatesAutoresizingMaskIntoConstraints = false

        let resetRowView = NSView()
        resetRowView.addSubview(resetStack)
        NSLayoutConstraint.activate([
            resetStack.trailingAnchor.constraint(equalTo: resetRowView.trailingAnchor,
                                                 constant: -Layout.rowHorizontalPad),
            resetStack.topAnchor.constraint(equalTo: resetRowView.topAnchor, constant: 4),
            resetStack.bottomAnchor.constraint(equalTo: resetRowView.bottomAnchor, constant: -7),
        ])

        dockResetRow     = resetRowView
        dockResetDivider = rowDivider()

        // Hidden by default; viewWillAppear sets the correct visibility
        dockResetDivider.isHidden = true
        dockResetRow.isHidden     = true

        let group = groupContainer()
        group.addArrangedSubview(settingsRow(
            symbol:   "dock.rectangle",
            color:    NSColor(red: 0.85, green: 0.50, blue: 0.15, alpha: 1),
            label:    "Instant Dock hide",
            control:  instantDockHideControl,
            subtitle: dockSubtitle
        ))
        group.addArrangedSubview(dockResetDivider)
        group.addArrangedSubview(dockResetRow)
        return group
    }

    /// Assembles the outer vertical stack with all section titles and groups.
    private func buildOuterStack(autoStartGroup: NSStackView,
                                 featuresGroup: NSStackView,
                                 interfaceGroup: NSStackView,
                                 advancedGroup: NSStackView) -> NSStackView {
        let outerStack = NSStackView()
        outerStack.orientation = .vertical
        outerStack.alignment   = .leading
        outerStack.spacing     = Layout.sectionSpacing
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        outerStack.addArrangedSubview(launchWarningBanner)
        outerStack.setCustomSpacing(Layout.groupGapSpacing, after: launchWarningBanner)
        outerStack.addArrangedSubview(sectionTitle("Auto-start"))
        outerStack.addArrangedSubview(autoStartGroup)
        outerStack.setCustomSpacing(Layout.groupGapSpacing, after: autoStartGroup)
        outerStack.addArrangedSubview(sectionTitle("Features"))
        outerStack.addArrangedSubview(featuresGroup)
        outerStack.setCustomSpacing(Layout.groupGapSpacing, after: featuresGroup)
        outerStack.addArrangedSubview(sectionTitle("Interface"))
        outerStack.addArrangedSubview(interfaceGroup)
        outerStack.setCustomSpacing(Layout.groupGapSpacing, after: interfaceGroup)
        outerStack.addArrangedSubview(sectionTitle("Advanced"))
        outerStack.addArrangedSubview(advancedGroup)

        // Make all groups stretch to the full width of the outer stack
        for subview in [launchWarningBanner!, autoStartGroup, featuresGroup,
                        interfaceGroup, advancedGroup] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            outerStack.addConstraint(
                subview.trailingAnchor.constraint(equalTo: outerStack.trailingAnchor)
            )
        }

        return outerStack
    }

    // MARK: View Lifecycle

    override func viewWillAppear() {
        super.viewWillAppear()

        // Refresh all toggle states — they may have been changed via the menu bar
        // while the settings window was closed
        instantSwitchControl.state   = gInstantSwitchEnabled      ? .on : .off
        autoFollowControl.state      = gAutoFollowEnabled         ? .on : .off
        soundsControl.state          = gSoundsEnabled             ? .on : .off
        instantDockHideControl.state = isDockInstantHideEnabled() ? .on : .off
        updateDockResetLink()
        updateLaunchAtLoginUI()

        // If the user arrived here from the menu bar warning banner,
        // flash the banner to draw attention to the launch-at-login setting
        if GeneralViewController.pendingLaunchAtLoginAlert {
            GeneralViewController.pendingLaunchAtLoginAlert = false
            flashLaunchWarningBanner()
        }
    }

    /// Plays a brief fade-out/fade-in animation on the launch warning banner.
    private func flashLaunchWarningBanner() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            launchWarningBanner.animator().alphaValue = 0.2
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                self.launchWarningBanner.animator().alphaValue = 1.0
            }
        }
    }

    // MARK: - Row Builder Helpers

    /// Creates a standard settings row: colored icon | label (+ optional subtitle) | control.
    ///
    /// The row uses horizontal stack layout with the control pushed to the
    /// trailing edge via a flexible spacer.
    ///
    /// - Parameters:
    ///   - symbol: SF Symbol name for the row icon.
    ///   - color: Background color for the icon's rounded square.
    ///   - label: Primary text label for the setting.
    ///   - control: The interactive control (typically an `NSSwitch`).
    ///   - subtitle: Optional secondary label shown below the primary label.
    /// - Returns: A configured `NSView` ready to add to a group container.
    private func settingsRow(symbol: String, color: NSColor, label: String,
                             control: NSView, subtitle: NSTextField? = nil) -> NSView {
        let icon = makeIconView(symbol: symbol, color: color)

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.spacing     = 2
        textStack.alignment   = .leading
        textStack.addArrangedSubview(labelField)
        if let subtitle = subtitle { textStack.addArrangedSubview(subtitle) }

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing     = 10
        row.alignment   = .centerY
        row.edgeInsets  = NSEdgeInsets(top: Layout.rowVerticalPad, left: Layout.rowHorizontalPad,
                                       bottom: Layout.rowVerticalPad, right: Layout.rowHorizontalPad)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())   // Flexible spacer pushes the control to the right
        row.addArrangedSubview(control)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Layout.rowIconSize),
            icon.heightAnchor.constraint(equalToConstant: Layout.rowIconSize),
        ])
        return row
    }

    /// Creates a rounded, bordered container for grouping related settings rows.
    ///
    /// Uses a subtle background tint and thin border that adapts to light/dark mode.
    private func groupContainer() -> NSStackView {
        let isDark  = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark ? NSColor(white: 1, alpha: 0.02) : NSColor(white: 0, alpha: 0.02)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing     = 0
        stack.wantsLayer  = true
        stack.layer?.cornerRadius    = Layout.groupCornerRadius
        stack.layer?.borderWidth     = Layout.groupBorderWidth
        stack.layer?.borderColor     = NSColor.separatorColor.cgColor
        stack.layer?.backgroundColor = bgColor.cgColor
        return stack
    }

    /// Creates a small colored square with an SF Symbol icon inside.
    ///
    /// These are the rounded-rect badges shown to the left of each settings row,
    /// similar to the icon style used in Apple's System Settings.
    ///
    /// - Parameters:
    ///   - symbol: SF Symbol name.
    ///   - color: Background color for the rounded square.
    /// - Returns: A fixed-size view containing the centered icon.
    private func makeIconView(symbol: String, color: NSColor) -> NSView {
        let container = NSView()
        container.wantsLayer               = true
        container.layer?.backgroundColor   = color.cgColor
        container.layer?.cornerRadius      = Layout.iconCornerRadius

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: Layout.iconSymbolSize,
                                                       weight: .medium)
        let imageView = NSImageView()
        imageView.image            = NSImage(systemSymbolName: symbol,
                                             accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        imageView.contentTintColor = .white
        imageView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// Creates an uppercase section title label (e.g. "FEATURES", "ADVANCED").
    private func sectionTitle(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font      = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                           constant: Layout.rowHorizontalPad),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// Creates a horizontal separator line between settings rows.
    private func rowDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// Creates a mini `NSSwitch` pre-configured with the given state and action.
    ///
    /// - Parameters:
    ///   - state: Initial on/off state.
    ///   - action: Selector to call when the switch is toggled.
    /// - Returns: A configured `NSSwitch` targeting `self`.
    private func makeSwitch(_ state: Bool, _ action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.controlSize = .mini
        toggle.state       = state ? .on : .off
        toggle.target      = self
        toggle.action      = action
        return toggle
    }

    /// Creates the orange warning banner shown when launch-at-login is disabled.
    ///
    /// The banner includes a warning icon and explanatory text, styled with
    /// an orange tint to draw attention.
    private func makeLaunchWarningBanner() -> NSView {
        let container = NSView()
        container.wantsLayer             = true
        container.layer?.cornerRadius    = Layout.groupCornerRadius
        container.layer?.borderWidth     = Layout.groupBorderWidth
        container.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.05).cgColor
        container.layer?.borderColor     = NSColor.systemOrange.withAlphaComponent(0.20).cgColor

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                 accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        iconView.contentTintColor = .systemOrange
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString:
            "Space Rabbit is not set to launch at login. Enable \u{201C}Launch at login\u{201D} below so it starts automatically.")
        label.font      = .systemFont(ofSize: 12)
        label.textColor = NSColor.systemOrange
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(iconView)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    // MARK: - Launch at Login

    /// Updates the launch-at-login switch, status label, and warning banner
    /// to reflect the current `SMAppService` registration state.
    ///
    /// - Parameter errorMessage: Optional error text to display below the toggle.
    ///   When `nil`, the status label is hidden unless the system reports
    ///   `requiresApproval` status.
    private func updateLaunchAtLoginUI(errorMessage: String? = nil) {
        let status = SMAppService.mainApp.status

        launchAtLoginControl.state     = (status == .enabled) ? .on : .off
        launchAtLoginControl.isEnabled = true
        launchWarningBanner?.isHidden  = (status == .enabled)

        // Resize the window to accommodate the banner appearing/disappearing
        (parent as? PreferencesTabViewController)?.resizeCurrent()

        if let msg = errorMessage {
            launchStatusLabel.stringValue = msg
            launchStatusLabel.isHidden    = false
        } else if status == .requiresApproval {
            launchStatusLabel.stringValue = "Approval needed — check Login Items in System Settings."
            launchStatusLabel.isHidden    = false
        } else {
            launchStatusLabel.isHidden = true
        }
    }

    // MARK: - Toggle Actions

    @objc private func toggleInstantSwitch() {
        gInstantSwitchEnabled = instantSwitchControl.state == .on
        UserDefaults.standard.set(gInstantSwitchEnabled, forKey: Defaults.instantSwitch)
        gMenu?.syncMenuItems()
    }

    @objc private func toggleAutoFollow() {
        gAutoFollowEnabled = autoFollowControl.state == .on
        UserDefaults.standard.set(gAutoFollowEnabled, forKey: Defaults.autoFollow)
        gMenu?.syncMenuItems()
    }

    @objc private func toggleSounds() {
        gSoundsEnabled = soundsControl.state == .on
        UserDefaults.standard.set(gSoundsEnabled, forKey: Defaults.sounds)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginControl.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            updateLaunchAtLoginUI()
        } catch {
            let msg = "Could not update login item: \(error.localizedDescription)"
            fputs("Space Rabbit: launch at login: \(error)\n", stderr)
            updateLaunchAtLoginUI(errorMessage: msg)
        }
    }

    // MARK: - Dock Instant-Hide
    //
    // macOS supports a hidden preference `autohide-time-modifier` on com.apple.dock
    // that controls the Dock show/hide animation speed. Setting it to 0.0 makes the
    // Dock appear and disappear instantly (no animation). Removing the key restores
    // the system default behavior.
    //
    // Changes require a Dock restart to take effect (`killall Dock`).

    /// The Dock preference key that controls autohide animation duration.
    private let dockAutohideKey  = "autohide-time-modifier" as CFString

    /// The Dock's preference domain identifier.
    private let dockBundleID     = "com.apple.dock" as CFString

    /// Checks whether the Dock's autohide animation is set to instant (0.0 seconds).
    private func isDockInstantHideEnabled() -> Bool {
        let value = CFPreferencesCopyAppValue(dockAutohideKey, dockBundleID)
        return (value as? NSNumber)?.doubleValue == 0.0
    }

    /// Sets the Dock's autohide animation duration, or removes the override entirely.
    ///
    /// - Parameter value: Duration in seconds, or `nil` to remove the override
    ///   and restore system default behavior.
    private func setDockAutohideModifier(_ value: Double?) {
        let cfValue: CFPropertyList? = value.map { NSNumber(value: $0) }
        CFPreferencesSetAppValue(dockAutohideKey, cfValue, dockBundleID)
        CFPreferencesAppSynchronize(dockBundleID)
    }

    /// Shows or hides the "Reset to system default" link based on whether
    /// the Dock autohide modifier is currently overridden.
    private func updateDockResetLink() {
        let hasOverride = CFPreferencesCopyAppValue(dockAutohideKey, dockBundleID) != nil
        dockResetDivider.isHidden = !hasOverride
        dockResetRow.isHidden     = !hasOverride
        (parent as? PreferencesTabViewController)?.resizeCurrent()
    }

    /// Prompts the user to restart the Dock so the autohide change takes effect.
    ///
    /// The Dock must be restarted for preference changes to be picked up.
    /// This shows an alert with "Restart Dock Now" and "Later" buttons.
    private func promptDockRestart() {
        let alert = NSAlert()
        alert.messageText     = "Restart Dock to apply changes?"
        alert.informativeText = "The Dock needs to restart for this setting to take effect. "
                              + "Your Dock will briefly disappear and reappear."
        alert.addButton(withTitle: "Restart Dock Now")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            let task = Process()
            task.launchPath = "/usr/bin/killall"
            task.arguments  = ["Dock"]
            try? task.run()
        }
    }

    @objc private func toggleDockInstantHide() {
        let enabled = instantDockHideControl.state == .on
        setDockAutohideModifier(enabled ? 0.0 : nil)
        updateDockResetLink()
        promptDockRestart()
    }

    @objc private func resetDockToDefault() {
        setDockAutohideModifier(nil)
        instantDockHideControl.state = .off
        updateDockResetLink()
        promptDockRestart()
    }
}

// MARK: - About Tab

/// The "About" tab showing app info, version, authors, and update notice.
///
/// Displays the app icon, name, version, copyright, website link,
/// author links, and a notice about manual updates.
final class AboutViewController: NSViewController {

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()

        let appInfoStack  = buildAppInfoStack()
        let authorsStack  = buildAuthorsStack()
        let updateBox     = buildUpdateNoticeBox()

        // --- Final layout ---
        let outerStack = NSStackView(views: [appInfoStack, authorsStack, updateBox])
        outerStack.orientation = .vertical
        outerStack.alignment   = .centerX
        outerStack.spacing     = Layout.aboutSpacing
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.setCustomSpacing(Layout.aboutSpacing, after: appInfoStack)

        view.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: view.topAnchor,
                                            constant: Layout.aboutTopPadding),
            outerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            outerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                                constant: Layout.outerPadding),
            outerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                                 constant: -Layout.outerPadding),
            outerStack.bottomAnchor.constraint(equalTo: view.bottomAnchor,
                                               constant: -Layout.aboutBottomPad),
            updateBox.leadingAnchor.constraint(equalTo: outerStack.leadingAnchor),
            updateBox.trailingAnchor.constraint(equalTo: outerStack.trailingAnchor),
            view.widthAnchor.constraint(equalToConstant: Layout.windowWidth),
        ])
    }

    // MARK: Sub-Builders

    /// Builds the centered app info section: icon, name, version, copyright, website.
    private func buildAppInfoStack() -> NSStackView {
        // App icon
        let iconView = NSImageView()
        iconView.image        = NSImage(named: "NSApplicationIcon")
        iconView.imageScaling = .scaleProportionallyDown
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Layout.aboutIconSize),
            iconView.heightAnchor.constraint(equalToConstant: Layout.aboutIconSize),
        ])

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

        let nameLabel = NSTextField(labelWithString: "Space Rabbit")
        nameLabel.font      = .boldSystemFont(ofSize: 15)
        nameLabel.textColor = .labelColor

        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font      = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        let copyrightLabel = NSTextField(labelWithString: "\u{00A9} 2026 Ya\u{00EB}l Guilloux & Valerian Saliou")
        copyrightLabel.font      = .systemFont(ofSize: 11)
        copyrightLabel.textColor = .tertiaryLabelColor

        let websiteLink = makeClickableLink(name: "space-rabbit.app", url: "https://space-rabbit.app")
        websiteLink.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [iconView, nameLabel, versionLabel, copyrightLabel, websiteLink])
        stack.orientation = .vertical
        stack.alignment   = .centerX
        stack.spacing     = 5
        stack.setCustomSpacing(10, after: iconView)
        return stack
    }

    /// Builds the horizontal row of author links.
    private func buildAuthorsStack() -> NSStackView {
        let stack = NSStackView(views: [
            makeClickableLink(name: "Ya\u{00EB}l Guilloux",   url: "https://github.com/tahul"),
            makeClickableLink(name: "Valerian Saliou", url: "https://valeriansaliou.name"),
        ])
        stack.orientation = .horizontal
        stack.spacing     = 16
        return stack
    }

    /// Builds the info box explaining that updates are manual.
    private func buildUpdateNoticeBox() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "arrow.down.circle",
                             accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
        ])

        let text = NSTextField(wrappingLabelWithString:
            "Space Rabbit does not update automatically. Updates must be applied manually. "
          + "However, we will notify you when there is a new update available.")
        text.preferredMaxLayoutWidth = 340
        text.font      = .systemFont(ofSize: 11)
        text.textColor = .secondaryLabelColor

        let contentRow = NSStackView(views: [icon, text])
        contentRow.orientation = .horizontal
        contentRow.alignment   = .top
        contentRow.spacing     = 6

        // Rounded box container matching the group style
        let box = NSView()
        box.wantsLayer             = true
        box.layer?.cornerRadius    = Layout.groupCornerRadius
        box.layer?.borderWidth     = Layout.groupBorderWidth
        box.layer?.borderColor     = NSColor.separatorColor.cgColor

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        box.layer?.backgroundColor = (isDark ? NSColor(white: 1, alpha: 0.02)
                                             : NSColor(white: 0, alpha: 0.02)).cgColor

        contentRow.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(contentRow)
        NSLayoutConstraint.activate([
            contentRow.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            contentRow.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            contentRow.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            contentRow.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
        ])
        return box
    }

    // MARK: Helpers

    /// Creates a clickable link as an `NSTextField` with a URL attribute.
    ///
    /// - Parameters:
    ///   - name: Display text for the link.
    ///   - url: Destination URL string.
    /// - Returns: A text field that renders as a clickable hyperlink.
    private func makeClickableLink(name: String, url: String) -> NSTextField {
        let field = LinkTextField(labelWithString: "")
        field.isSelectable                = true
        field.allowsEditingTextAttributes = true
        field.attributedStringValue       = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .link: URL(string: url)!,
        ])
        return field
    }
}

// MARK: - Custom Controls

/// An `NSTextField` subclass that shows a pointing-hand cursor on hover.
/// Used for author/website links in the About tab.
final class LinkTextField: NSTextField {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// An `NSButton` subclass that shows a pointing-hand cursor on hover.
/// Used for the "Reset to system default" link in the General tab.
final class LinkButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
