/*
 * Space Rabbit — Disable macOS space-switching animation
 *
 * Features:
 *   1. Instant space switch via synthetic DockSwipe gestures
 *   2. Auto-follow on Cmd+Tab to app's space
 *   3. Menu bar icon with toggles and usage stats
 *   4. Settings window with Launch at Login toggle
 *
 * Requires Accessibility permissions (System Settings → Privacy → Accessibility).
 */

import AppKit
import CoreGraphics
import CoreFoundation
import ApplicationServices
import ServiceManagement
import Darwin

// MARK: - Private CGEvent field IDs

let kCGSEventTypeField            = CGEventField(rawValue:55)!
let kCGEventGestureHIDType        = CGEventField(rawValue:110)!
let kCGEventGestureScrollY        = CGEventField(rawValue:119)!
let kCGEventGestureSwipeMotion    = CGEventField(rawValue:123)!
let kCGEventGestureSwipeProgress  = CGEventField(rawValue:124)!
let kCGEventGestureSwipeVelocityX = CGEventField(rawValue:129)!
let kCGEventGestureSwipeVelocityY = CGEventField(rawValue:130)!
let kCGEventGesturePhase          = CGEventField(rawValue:132)!
let kCGEventScrollGestureFlagBits = CGEventField(rawValue:135)!
let kCGEventGestureZoomDeltaX     = CGEventField(rawValue:139)!

let kIOHIDEventTypeDockSwipe: Int64 = 23
let kCGSEventGesture:         Int64 = 29
let kCGSEventDockControl:     Int64 = 30
let kCGSGesturePhaseBegan:    Int64 = 1
let kCGSGesturePhaseEnded:    Int64 = 4

// MARK: - Private CGS API (resolved at runtime via dlsym)

typealias CGSConnectionID = Int32
typealias CGSSpaceID      = UInt64

private typealias FnMainConnection  = @convention(c) () -> CGSConnectionID
private typealias FnActiveSpace     = @convention(c) (CGSConnectionID) -> CGSSpaceID
private typealias FnDisplaySpaces   = @convention(c) (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?
private typealias FnSpacesForWindows = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?

// RTLD_DEFAULT = (void *)-2 on macOS
private let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2 as Int)

private func loadSym<T>(_ name: String) -> T? {
    guard let ptr = dlsym(rtldDefault, name) else { return nil }
    return unsafeBitCast(ptr, to: T.self)
}

private let _mainConnection:   FnMainConnection?   = loadSym("CGSMainConnectionID")
private let _activeSpace:      FnActiveSpace?      = loadSym("CGSGetActiveSpace")
private let _displaySpaces:    FnDisplaySpaces?    = loadSym("CGSCopyManagedDisplaySpaces")
private let _spacesForWindows: FnSpacesForWindows? = loadSym("SLSCopySpacesForWindows")

// MARK: - Global state

var gTap:                  CFMachPort?
var gEnabled:              Bool         = true
var gInstantSwitchEnabled: Bool         = true
var gAutoFollowEnabled:    Bool         = true
var gSoundsEnabled:        Bool         = false
var gSwitchCount:          Int          = 0
var gSwitchCountSaved:     Int          = 0
var gKeyLeft:              Int64        = 123
var gKeyRight:             Int64        = 124
var gModMask:              CGEventFlags = .maskControl
var gMenu:                 SwoopMenu?

// MARK: - Menu bar UI

private func formatTimeSaved(_ seconds: Int) -> String {
    switch seconds {
    case ..<60:
        return "\(seconds) sec"
    case ..<3600:
        return "\(seconds / 60) min"
    case ..<86400:
        let hr = seconds / 3600; let min = (seconds % 3600) / 60
        return min > 0 ? "\(hr) hr \(min) min" : "\(hr) hr"
    default:
        let days = seconds / 86400; let hr = (seconds % 86400) / 3600
        return hr > 0 ? "\(days) days \(hr) hr" : "\(days) days"
    }
}

final class SwoopMenu: NSObject {
    private let statusItem:            NSStatusItem
    private let enableItem:            NSMenuItem
    private let instantSwitchItem:     NSMenuItem
    private let autoFollowItem:        NSMenuItem
    private let statsItem:             NSMenuItem
    private let updateAvailableItem:   NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateAvailableSep:    NSMenuItem = .separator()
    private let launchWarningItem:     NSMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let launchWarningSep:      NSMenuItem = .separator()
    private var statusMenu:            NSMenu!
    private var updateDownloadURL:     String?

    override init() {
        let ud = UserDefaults.standard
        ud.register(defaults: [
            "spacerabbit.enabled":       true,
            "spacerabbit.instantSwitch": true,
            "spacerabbit.autoFollow":    true,
            "spacerabbit.sounds":        false,
            "spacerabbit.switchCount":   0,
        ])
        gEnabled              = ud.bool(forKey: "spacerabbit.enabled")
        gInstantSwitchEnabled = ud.bool(forKey: "spacerabbit.instantSwitch")
        gAutoFollowEnabled    = ud.bool(forKey: "spacerabbit.autoFollow")
        gSoundsEnabled        = ud.bool(forKey: "spacerabbit.sounds")
        gSwitchCount          = ud.integer(forKey: "spacerabbit.switchCount")
        gSwitchCountSaved     = gSwitchCount

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        enableItem        = NSMenuItem(title: "Enable Space Rabbit",
                                       action: #selector(toggleEnabled(_:)),
                                       keyEquivalent: "")
        instantSwitchItem = NSMenuItem(title: "Instant space switch",
                                       action: #selector(toggleInstantSwitch(_:)),
                                       keyEquivalent: "s")
        autoFollowItem    = NSMenuItem(title: "Auto-follow on \u{2318}\u{21E5}",
                                       action: #selector(toggleAutoFollow(_:)),
                                       keyEquivalent: "f")
        statsItem         = NSMenuItem(title: "", action: nil, keyEquivalent: "")

        super.init()

        updateAvailableItem.isHidden = true
        updateAvailableItem.target   = self
        updateAvailableItem.action   = #selector(openDownloadURL)
        updateAvailableSep.isHidden  = true

        launchWarningItem.target = self
        launchWarningItem.action = #selector(openSettingsForLaunchAtLogin)

        enableItem.target        = self
        instantSwitchItem.target = self
        instantSwitchItem.state  = gInstantSwitchEnabled ? .on : .off
        autoFollowItem.target    = self
        autoFollowItem.state     = gAutoFollowEnabled    ? .on : .off
        statsItem.isEnabled      = false

        // SF Symbol icons for configure items
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

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

        statusMenu = NSMenu()
        statusMenu.addItem(updateAvailableItem)
        statusMenu.addItem(updateAvailableSep)
        statusMenu.addItem(launchWarningItem)
        statusMenu.addItem(launchWarningSep)
        statusMenu.addItem(enableItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(menuHeader("Configure:"))
        statusMenu.addItem(instantSwitchItem)
        statusMenu.addItem(autoFollowItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(menuHeader("Statistics:"))
        statusMenu.addItem(statsItem)
        statusMenu.addItem(.separator())
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

        // Handle left and right clicks manually so right-click can toggle the switch
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateMenuBarIcon()
        updateEnableItem()
        updateStatsDisplay()
        updateLaunchWarning()
    }

    // MARK: - Click handling

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            setEnabled(!gEnabled)
        } else {
            updateLaunchWarning()
            statusItem.menu = statusMenu
            sender.performClick(nil)
            statusItem.menu = nil
        }
    }

    // MARK: - Icon helpers

    private func updateMenuBarIcon() {
        if let img = NSImage(systemSymbolName: "hare.fill",
                             accessibilityDescription: "Space Rabbit") {
            img.isTemplate = true
            statusItem.button?.image = img
        }
        statusItem.button?.alphaValue = gEnabled ? 1.0 : 0.25
    }

    private func updateEnableItem() {
        if gEnabled {
            enableItem.title = "Disable Space Rabbit"
            enableItem.image = tintedSymbol("xmark.circle.fill",
                                            color: NSColor(red: 0.94, green: 0.51, blue: 0.40, alpha: 1))
        } else {
            enableItem.title = "Enable Space Rabbit"
            enableItem.image = tintedSymbol("checkmark.circle.fill",
                                            color: NSColor(red: 0.19, green: 0.77, blue: 0.55, alpha: 1))
        }
    }

    private func tintedSymbol(_ name: String, color: NSColor, size: CGFloat = 16) -> NSImage? {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let innerColor: NSColor = isDark ? .black : .white
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [innerColor, color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        let canvas = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        canvas.isTemplate = false
        return canvas
    }

    // MARK: - Menu label helpers

    private func menuHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    private func greyLabel(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        setEnabled(!gEnabled)
    }

    private func setEnabled(_ enabled: Bool) {
        gEnabled = enabled
        UserDefaults.standard.set(gEnabled, forKey: "spacerabbit.enabled")
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

    private func updateLaunchWarning() {
        let notEnabled = SMAppService.mainApp.status != .enabled
        launchWarningItem.isHidden = !notEnabled
        launchWarningSep.isHidden  = !notEnabled
        if notEnabled {
            launchWarningItem.attributedTitle = NSAttributedString(
                string: "Not auto-launching  ·  Click to fix",
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

    func showUpdateBanner(downloadURL: String) {
        updateDownloadURL            = downloadURL
        updateAvailableItem.attributedTitle = NSAttributedString(
            string: "Update available  \u{00B7}  Click to download",
            attributes: [
                .font:            NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        updateAvailableItem.image   = tintedSymbol("arrow.down.circle.fill", color: .systemBlue)
        updateAvailableItem.isHidden = false
        updateAvailableSep.isHidden  = false
    }

    @objc private func openDownloadURL() {
        guard let urlStr = updateDownloadURL, let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Called by the settings window after it changes a feature toggle,
    /// so the menu items stay in sync.
    func syncMenuItems() {
        instantSwitchItem.state = gInstantSwitchEnabled ? .on : .off
        autoFollowItem.state    = gAutoFollowEnabled    ? .on : .off
    }

    @objc private func toggleInstantSwitch(_ sender: NSMenuItem) {
        gInstantSwitchEnabled.toggle()
        sender.state = gInstantSwitchEnabled ? .on : .off
        UserDefaults.standard.set(gInstantSwitchEnabled, forKey: "spacerabbit.instantSwitch")
    }

    @objc private func toggleAutoFollow(_ sender: NSMenuItem) {
        gAutoFollowEnabled.toggle()
        sender.state = gAutoFollowEnabled ? .on : .off
        UserDefaults.standard.set(gAutoFollowEnabled, forKey: "spacerabbit.autoFollow")
    }

    private func updateStatsDisplay() {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let countStr = fmt.string(from: NSNumber(value: gSwitchCount)) ?? "\(gSwitchCount)"
        statsItem.title = "\(countStr) switches  ·  \(formatTimeSaved(gSwitchCount)) saved"
    }

    func recordSwitch() {
        gSwitchCount += 1
        updateStatsDisplay()
    }
}

// MARK: - Settings Window

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

    func resizeCurrent(animate: Bool = true) {
        let item = tabViewItems[selectedTabViewItemIndex]
        applyWindowSize(for: item, animate: animate)
    }

    private func applyWindowSize(for item: NSTabViewItem, animate: Bool) {
        guard let vc = item.viewController, let window = view.window else { return }
        vc.view.layoutSubtreeIfNeeded()
        window.title = item.label
        let contentSize = vc.view.fittingSize
        var frame       = window.frame
        let newHeight   = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).height
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight
        window.setFrame(frame, display: true, animate: animate)
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil { window = makeWindow() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let tabVC = PreferencesTabViewController()
        tabVC.tabStyle = .toolbar

        let generalItem = NSTabViewItem(viewController: GeneralViewController())
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "togglepower", accessibilityDescription: nil)
        tabVC.addTabViewItem(generalItem)

        let aboutItem = NSTabViewItem(viewController: AboutViewController())
        aboutItem.label = "About"
        aboutItem.image = NSImage(systemSymbolName: "hare", accessibilityDescription: nil)
        tabVC.addTabViewItem(aboutItem)

        let w = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentViewController = tabVC
        return w
    }
}

// MARK: - General Tab

final class GeneralViewController: NSViewController {
    static var pendingLaunchAtLoginAlert = false

    private var instantSwitchControl: NSSwitch!
    private var autoFollowControl:    NSSwitch!
    private var soundsControl:        NSSwitch!
    private var launchAtLoginControl: NSSwitch!
    private var launchStatusLabel:    NSTextField!
    private var launchWarningBanner:  NSView!

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()

        instantSwitchControl = makeSwitch(gInstantSwitchEnabled, #selector(toggleInstantSwitch))
        autoFollowControl    = makeSwitch(gAutoFollowEnabled,    #selector(toggleAutoFollow))
        soundsControl        = makeSwitch(gSoundsEnabled,        #selector(toggleSounds))
        launchAtLoginControl = makeSwitch(false,                  #selector(toggleLaunchAtLogin))

        launchStatusLabel                         = NSTextField(wrappingLabelWithString: "")
        launchStatusLabel.font                    = .systemFont(ofSize: 11)
        launchStatusLabel.textColor               = .secondaryLabelColor
        launchStatusLabel.preferredMaxLayoutWidth = 240
        launchStatusLabel.isHidden                = true

        // Group 1: Launch at login
        let group1 = groupContainer()
        group1.addArrangedSubview(settingsRow(
            symbol: "gearshape.2.fill",
            color:  NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1),
            label:  "Launch at login",
            control: launchAtLoginControl,
            subtitle: launchStatusLabel
        ))

        // Group 2: Feature toggles
        let group2 = groupContainer()
        group2.addArrangedSubview(settingsRow(
            symbol: "arrow.left.arrow.right",
            color:  NSColor(red: 0.20, green: 0.55, blue: 1.00, alpha: 1),
            label:  "Instant space switch",
            control: instantSwitchControl
        ))
        group2.addArrangedSubview(rowDivider())
        group2.addArrangedSubview(settingsRow(
            symbol: "scope",
            color:  NSColor(red: 0.35, green: 0.75, blue: 0.40, alpha: 1),
            label:  "Auto-follow on \u{2318}\u{21E5}",
            control: autoFollowControl
        ))

        // Group 3: Interface
        let group3 = groupContainer()
        group3.addArrangedSubview(settingsRow(
            symbol: "speaker.wave.2.fill",
            color:  NSColor(red: 0.60, green: 0.35, blue: 0.85, alpha: 1),
            label:  "Enable sounds",
            control: soundsControl
        ))

        launchWarningBanner = makeLaunchWarningBanner()

        let outerStack = NSStackView()
        outerStack.orientation = .vertical
        outerStack.alignment   = .leading
        outerStack.spacing     = 6
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.addArrangedSubview(launchWarningBanner)
        outerStack.setCustomSpacing(14, after: launchWarningBanner)
        outerStack.addArrangedSubview(sectionTitle("Auto-start"))
        outerStack.addArrangedSubview(group1)
        outerStack.setCustomSpacing(14, after: group1)
        outerStack.addArrangedSubview(sectionTitle("Features"))
        outerStack.addArrangedSubview(group2)
        outerStack.setCustomSpacing(14, after: group2)
        outerStack.addArrangedSubview(sectionTitle("Interface"))
        outerStack.addArrangedSubview(group3)

        for sub in [launchWarningBanner!, group1, group2, group3] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            outerStack.addConstraint(
                sub.trailingAnchor.constraint(equalTo: outerStack.trailingAnchor)
            )
        }

        view.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            outerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            outerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            outerStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16),
            view.widthAnchor.constraint(equalToConstant: 480),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])

        updateLaunchAtLoginUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        instantSwitchControl.state = gInstantSwitchEnabled ? .on : .off
        autoFollowControl.state    = gAutoFollowEnabled    ? .on : .off
        soundsControl.state        = gSoundsEnabled        ? .on : .off
        updateLaunchAtLoginUI()
        if GeneralViewController.pendingLaunchAtLoginAlert {
            GeneralViewController.pendingLaunchAtLoginAlert = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                launchWarningBanner.animator().alphaValue = 0.2
            } completionHandler: {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.35
                    self.launchWarningBanner.animator().alphaValue = 1.0
                }
            }
        }
    }

    // MARK: - Row builder

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
        if let sub = subtitle { textStack.addArrangedSubview(sub) }

        let row = NSStackView()
        row.orientation  = .horizontal
        row.spacing      = 10
        row.alignment    = .centerY
        row.edgeInsets   = NSEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())   // flexible spacer
        row.addArrangedSubview(control)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])
        return row
    }

    private func groupContainer() -> NSStackView {
        let isDark  = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark ? NSColor(white: 1, alpha: 0.02) : NSColor(white: 0, alpha: 0.02)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing     = 0
        stack.wantsLayer  = true
        stack.layer?.cornerRadius    = 8
        stack.layer?.borderWidth     = 0.5
        stack.layer?.borderColor     = NSColor.separatorColor.cgColor
        stack.layer?.backgroundColor = bgColor.cgColor
        return stack
    }

    private func makeIconView(symbol: String, color: NSColor) -> NSView {
        let container = NSView()
        container.wantsLayer    = true
        container.layer?.backgroundColor = color.cgColor
        container.layer?.cornerRadius    = 6

        let cfg     = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let imgView = NSImageView()
        imgView.image              = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        imgView.contentTintColor   = .white
        imgView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imgView)
        NSLayoutConstraint.activate([
            imgView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imgView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func sectionTitle(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font      = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func rowDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func makeSwitch(_ state: Bool, _ action: Selector) -> NSSwitch {
        let s = NSSwitch()
        s.controlSize = .mini
        s.state       = state ? .on : .off
        s.target      = self
        s.action      = action
        return s
    }

    private func makeLaunchWarningBanner() -> NSView {
        let container = NSView()
        container.wantsLayer              = true
        container.layer?.cornerRadius     = 8
        container.layer?.borderWidth      = 0.5
        container.layer?.backgroundColor  = NSColor.systemOrange.withAlphaComponent(0.05).cgColor
        container.layer?.borderColor      = NSColor.systemOrange.withAlphaComponent(0.20).cgColor

        let cfg     = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let imgView = NSImageView()
        imgView.image            = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                           accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        imgView.contentTintColor = .systemOrange
        imgView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString:
            "Space Rabbit is not set to launch at login. Enable \u{201C}Launch at login\u{201D} below so it starts automatically.")
        label.font      = .systemFont(ofSize: 12)
        label.textColor = NSColor.systemOrange
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imgView)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            imgView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            imgView.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
            imgView.widthAnchor.constraint(equalToConstant: 15),
            imgView.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    // MARK: - Launch at Login

    private func updateLaunchAtLoginUI(errorMessage: String? = nil) {
        let status = SMAppService.mainApp.status
        launchAtLoginControl.state     = (status == .enabled) ? .on : .off
        launchAtLoginControl.isEnabled = true
        launchWarningBanner?.isHidden  = (status == .enabled)
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

    // MARK: - Actions

    @objc private func toggleInstantSwitch() {
        gInstantSwitchEnabled = instantSwitchControl.state == .on
        UserDefaults.standard.set(gInstantSwitchEnabled, forKey: "spacerabbit.instantSwitch")
        gMenu?.syncMenuItems()
    }

    @objc private func toggleAutoFollow() {
        gAutoFollowEnabled = autoFollowControl.state == .on
        UserDefaults.standard.set(gAutoFollowEnabled, forKey: "spacerabbit.autoFollow")
        gMenu?.syncMenuItems()
    }

    @objc private func toggleSounds() {
        gSoundsEnabled = soundsControl.state == .on
        UserDefaults.standard.set(gSoundsEnabled, forKey: "spacerabbit.sounds")
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
}

// MARK: - About Tab

final class LinkTextField: NSTextField {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class AboutViewController: NSViewController {
    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()

        let iconView = NSImageView()
        iconView.image        = NSImage(named: "NSApplicationIcon")
        iconView.imageScaling = .scaleProportionallyDown
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 80),
            iconView.heightAnchor.constraint(equalToConstant: 80),
        ])

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

        let nameLabel = NSTextField(labelWithString: "Space Rabbit")
        nameLabel.font      = .boldSystemFont(ofSize: 15)
        nameLabel.textColor = .labelColor

        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font      = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        let copyrightLabel = NSTextField(labelWithString: "© 2026 Yaël Guilloux & Valerian Saliou")
        copyrightLabel.font      = .systemFont(ofSize: 11)
        copyrightLabel.textColor = .tertiaryLabelColor

        let websiteLink = makeAuthorLink(name: "space-rabbit.app", url: "https://space-rabbit.app")
        websiteLink.font = .systemFont(ofSize: 11)

        let appStack = NSStackView(views: [iconView, nameLabel, versionLabel, copyrightLabel, websiteLink])
        appStack.orientation = .vertical
        appStack.alignment   = .centerX
        appStack.spacing     = 5
        appStack.setCustomSpacing(10, after: iconView)

        // Update notice box
        let updateIcon = NSImageView()
        updateIcon.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        updateIcon.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            updateIcon.widthAnchor.constraint(equalToConstant: 14),
            updateIcon.heightAnchor.constraint(equalToConstant: 14),
        ])

        let updateText = NSTextField(wrappingLabelWithString: "")
        updateText.preferredMaxLayoutWidth = 340
        updateText.stringValue  = "Space Rabbit does not update automatically. Updates must be applied manually. However, we will notify you when there is a new update available."
        updateText.font         = .systemFont(ofSize: 11)
        updateText.textColor    = .secondaryLabelColor

        let updateRow = NSStackView(views: [updateIcon, updateText])
        updateRow.orientation = .horizontal
        updateRow.alignment   = .top
        updateRow.spacing     = 6

        let updateBox = NSView()
        updateBox.wantsLayer              = true
        updateBox.layer?.cornerRadius     = 8
        updateBox.layer?.borderWidth      = 0.5
        updateBox.layer?.borderColor      = NSColor.separatorColor.cgColor
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        updateBox.layer?.backgroundColor  = (isDark ? NSColor(white: 1, alpha: 0.02)
                                                     : NSColor(white: 0, alpha: 0.02)).cgColor

        updateRow.translatesAutoresizingMaskIntoConstraints = false
        updateBox.addSubview(updateRow)
        NSLayoutConstraint.activate([
            updateRow.topAnchor.constraint(equalTo: updateBox.topAnchor, constant: 10),
            updateRow.leadingAnchor.constraint(equalTo: updateBox.leadingAnchor, constant: 12),
            updateRow.trailingAnchor.constraint(equalTo: updateBox.trailingAnchor, constant: -12),
            updateRow.bottomAnchor.constraint(equalTo: updateBox.bottomAnchor, constant: -10),
        ])

        let authorsStack = NSStackView(views: [
            makeAuthorLink(name: "Yaël Guilloux",   url: "https://github.com/tahul"),
            makeAuthorLink(name: "Valerian Saliou", url: "https://valeriansaliou.name"),
        ])
        authorsStack.orientation = .horizontal
        authorsStack.spacing     = 16

        let outerStack = NSStackView(views: [appStack, authorsStack, updateBox])
        outerStack.orientation = .vertical
        outerStack.alignment   = .centerX
        outerStack.spacing     = 20
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.setCustomSpacing(20, after: appStack)

        view.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            outerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            outerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            outerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            outerStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            updateBox.leadingAnchor.constraint(equalTo: outerStack.leadingAnchor),
            updateBox.trailingAnchor.constraint(equalTo: outerStack.trailingAnchor),
            view.widthAnchor.constraint(equalToConstant: 480),
        ])
    }

    private func makeAuthorLink(name: String, url: String) -> NSTextField {
        let field = LinkTextField(labelWithString: "")
        field.isSelectable              = true
        field.allowsEditingTextAttributes = true
        field.attributedStringValue     = NSAttributedString(string: name, attributes: [
            .font:  NSFont.systemFont(ofSize: 12),
            .link:  URL(string: url)!,
        ])
        return field
    }
}

// MARK: - Shortcut loading

private func carbonToCGFlags(_ carbon: Int64) -> CGEventFlags {
    var f = CGEventFlags()
    if carbon & 0x040000 != 0 { f.insert(.maskControl)   }
    if carbon & 0x020000 != 0 { f.insert(.maskShift)     }
    if carbon & 0x080000 != 0 { f.insert(.maskAlternate) }
    if carbon & 0x100000 != 0 { f.insert(.maskCommand)   }
    return f
}

private func readHotkey(from hotkeys: NSDictionary, key: String,
                        keycode: inout Int64, mods: inout CGEventFlags) {
    guard let entry = hotkeys[key] as? NSDictionary else { return }

    if let enabled = entry["enabled"] {
        if let b = enabled as? Bool,                     !b      { return }
        if let n = (enabled as? NSNumber)?.intValue, n == 0     { return }
    }

    guard let value  = entry["value"]      as? NSDictionary,
          let params = value["parameters"] as? NSArray,
          params.count >= 3 else { return }

    let newKeycode = (params[1] as? NSNumber)?.int64Value ?? 0
    let newMods    = (params[2] as? NSNumber)?.int64Value ?? 0

    if newKeycode != 65535 { keycode = newKeycode }
    if newMods    != 0     { mods    = carbonToCGFlags(newMods) }
}

func loadSpaceSwitchShortcuts() {
    guard let prefs = CFPreferencesCopyAppValue(
        "AppleSymbolicHotKeys" as CFString,
        "com.apple.symbolichotkeys" as CFString
    ) as? NSDictionary else { return }

    var leftMods  = CGEventFlags()
    var rightMods = CGEventFlags()
    readHotkey(from: prefs, key: "79", keycode: &gKeyLeft,  mods: &leftMods)
    readHotkey(from: prefs, key: "81", keycode: &gKeyRight, mods: &rightMods)

    if !leftMods.isEmpty       { gModMask = leftMods  }
    else if !rightMods.isEmpty { gModMask = rightMods }
}

// MARK: - Space list helpers

/// Returns the space IDs for the display that contains the active space,
/// plus the index of the active space within that list.
func getSpaceList() -> (ids: [CGSSpaceID], currentIdx: Int) {
    guard let mainConn = _mainConnection,
          let getActive = _activeSpace,
          let getDisplays = _displaySpaces else { return ([], -1) }

    let cid = mainConn()
    guard cid != 0 else { return ([], -1) }

    let active = getActive(cid)
    guard active != 0 else { return ([], -1) }

    guard let displays = getDisplays(cid, nil)?.takeRetainedValue() as? [[String: Any]]
    else { return ([], -1) }

    for display in displays {
        guard let curSD    = display["Current Space"] as? [String: Any],
              let curSID   = (curSD["id64"] as? NSNumber)?.uint64Value,
              curSID == active,
              let spaces   = display["Spaces"] as? [[String: Any]]
        else { continue }

        var ids        = [CGSSpaceID]()
        var currentIdx = -1
        for space in spaces {
            guard let sid = (space["id64"] as? NSNumber)?.uint64Value else { continue }
            if sid == active { currentIdx = ids.count }
            ids.append(sid)
        }
        return (ids, currentIdx)
    }
    return ([], -1)
}

/// Returns the "current space" ID for every display (for multi-monitor awareness).
private func getAllCurrentSpaces() -> [CGSSpaceID] {
    guard let mainConn = _mainConnection,
          let getDisplays = _displaySpaces else { return [] }

    let cid = mainConn()
    guard cid != 0 else { return [] }

    guard let displays = getDisplays(cid, nil)?.takeRetainedValue() as? [[String: Any]]
    else { return [] }

    return displays.compactMap { display -> CGSSpaceID? in
        guard let curSD = display["Current Space"] as? [String: Any],
              let sid   = (curSD["id64"] as? NSNumber)?.uint64Value,
              sid != 0  else { return nil }
        return sid
    }
}

/// Finds the space that contains the given PID's windows.
/// Returns 0 if the app is already visible on any display.
func findSpaceForPid(_ pid: pid_t) -> CGSSpaceID {
    guard let mainConn = _mainConnection,
          let spacesFor = _spacesForWindows else { return 0 }

    let cid = mainConn()
    guard cid != 0 else { return 0 }

    let currentSpaces = getAllCurrentSpaces()

    guard let winList = CGWindowListCopyWindowInfo(.optionAll, 0) as? [[String: Any]]
    else { return 0 }

    for win in winList {
        guard (win["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == pid else { continue }

        if let layer    = (win["kCGWindowLayer"]     as? NSNumber)?.int32Value, layer    != 0 { continue }
        if let onscreen = (win["kCGWindowIsOnscreen"] as? NSNumber)?.int32Value, onscreen == 0 { continue }

        guard let wid = (win[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }

        let widArr = [NSNumber(value: wid)] as CFArray
        guard let spaces = spacesFor(cid, 7, widArr)?.takeRetainedValue() as? [NSNumber],
              let spaceNum = spaces.first else { continue }

        let sid = spaceNum.uint64Value
        if sid != 0 && !currentSpaces.contains(sid) { return sid }
    }
    return 0
}

/// Switches to the display that contains targetSpace, moving the minimum number of steps.
func switchToSpace(_ targetSpace: CGSSpaceID) {
    guard let mainConn = _mainConnection,
          let getDisplays = _displaySpaces else { return }

    let cid = mainConn()
    guard cid != 0 else { return }

    guard let displays = getDisplays(cid, nil)?.takeRetainedValue() as? [[String: Any]]
    else { return }

    for display in displays {
        guard let curSD = display["Current Space"] as? [String: Any],
              let displayCurrent = (curSD["id64"] as? NSNumber)?.uint64Value,
              let spaces = display["Spaces"] as? [[String: Any]]
        else { continue }

        var sids       = [CGSSpaceID]()
        var currentIdx = -1
        var targetIdx  = -1

        for space in spaces {
            guard let val = (space["id64"] as? NSNumber)?.uint64Value else { continue }
            if val == displayCurrent { currentIdx = sids.count }
            if val == targetSpace    { targetIdx  = sids.count }
            sids.append(val)
        }

        guard targetIdx  >= 0              else { continue }  // not on this display
        guard targetIdx  != currentIdx     else { break }     // already there
        guard currentIdx >= 0, sids.count >= 2 else { break }

        let direction = targetIdx > currentIdx ? 1 : -1
        let steps     = abs(targetIdx - currentIdx)
        switchNSpaces(direction: direction, steps: steps)
        break
    }
}

// MARK: - Gesture posting

private func postGesturePair(flagDirection: Int64, phase: Int64,
                             progress: Double, velocity: Double) -> Bool {
    guard let gestureEv = CGEvent(source: nil),
          let dockEv    = CGEvent(source: nil) else { return false }

    gestureEv.setIntegerValueField(kCGSEventTypeField, value: kCGSEventGesture)

    dockEv.setIntegerValueField(kCGSEventTypeField,            value: kCGSEventDockControl)
    dockEv.setIntegerValueField(kCGEventGestureHIDType,        value: kIOHIDEventTypeDockSwipe)
    dockEv.setIntegerValueField(kCGEventGesturePhase,          value: phase)
    dockEv.setIntegerValueField(kCGEventScrollGestureFlagBits, value: flagDirection)
    dockEv.setIntegerValueField(kCGEventGestureSwipeMotion,    value: 1)
    dockEv.setDoubleValueField(kCGEventGestureScrollY,          value: 0)
    dockEv.setDoubleValueField(kCGEventGestureZoomDeltaX,       value: Double(Float.leastNonzeroMagnitude))

    if phase == kCGSGesturePhaseEnded {
        dockEv.setDoubleValueField(kCGEventGestureSwipeProgress,  value: progress)
        dockEv.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: velocity)
        dockEv.setDoubleValueField(kCGEventGestureSwipeVelocityY, value: 0)
    }

    dockEv.post(tap: .cgSessionEventTap)
    gestureEv.post(tap: .cgSessionEventTap)
    return true
}

private func postSwitchGesture(direction: Int) -> Bool {
    let isRight       = direction > 0
    let flagDirection: Int64 = isRight ? 1 : 0
    let progress      = isRight ? 2.0 : -2.0
    let velocity      = isRight ? 400.0 : -400.0

    return postGesturePair(flagDirection: flagDirection, phase: kCGSGesturePhaseBegan,
                           progress: 0, velocity: 0)
        && postGesturePair(flagDirection: flagDirection, phase: kCGSGesturePhaseEnded,
                           progress: progress, velocity: velocity)
}

func switchNSpaces(direction: Int, steps: Int) {
    for i in 0..<steps where !postSwitchGesture(direction: direction) {
        fputs("Space Rabbit: gesture failed at step \(i + 1)/\(steps)\n", stderr)
        break
    }
}

// MARK: - Feature 1: Instant space switch (event tap callback)

// Must be a global function — used as a C callback.
func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                      event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown, gEnabled, gInstantSwitchEnabled else {
        return Unmanaged.passUnretained(event)
    }

    let flags   = event.flags
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)

    let relevantMods: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
    guard flags.intersection(relevantMods) == gModMask else {
        return Unmanaged.passUnretained(event)
    }

    let direction: Int
    if      keycode == gKeyLeft  { direction = -1 }
    else if keycode == gKeyRight { direction = +1 }
    else                         { return Unmanaged.passUnretained(event) }

    let (spaceIDs, currentIdx) = getSpaceList()
    if currentIdx >= 0 {
        let targetIdx = currentIdx + direction
        guard targetIdx >= 0, targetIdx < spaceIDs.count else { return nil }
    }

    if postSwitchGesture(direction: direction) { gMenu?.recordSwitch() }
    return nil
}

// MARK: - Feature 2: Auto-follow on app activation

final class SwoopObserver: NSObject {
    @objc func appActivated(_ note: Notification) {
        guard gEnabled, gAutoFollowEnabled else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }

        let targetSpace = findSpaceForPid(app.processIdentifier)
        guard targetSpace != 0 else { return }

        switchToSpace(targetSpace)
        gMenu?.recordSwitch()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            app.activate(options: .activateAllWindows)
        }
    }
}

// MARK: - Update check

private func isNewerVersion(_ remote: String, than local: String) -> Bool {
    let strip = { (s: String) -> String in s.hasPrefix("v") ? String(s.dropFirst()) : s }
    let parts = { (s: String) -> [Int] in strip(s).split(separator: ".").compactMap { Int($0) } }
    let r = parts(remote), l = parts(local)
    for i in 0..<max(r.count, l.count) {
        let rv = i < r.count ? r[i] : 0
        let lv = i < l.count ? l[i] : 0
        if rv != lv { return rv > lv }
    }
    return false
}

func checkForUpdates() {
    guard let url = URL(string: "https://api.github.com/repos/Tahul/space-rabbit/releases/latest")
    else { return }
    URLSession.shared.dataTask(with: url) { data, _, _ in
        guard let data,
              let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag    = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let dmg    = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let dlURL  = dmg["browser_download_url"] as? String
        else { return }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard isNewerVersion(tag, than: current) else { return }
        DispatchQueue.main.async { gMenu?.showUpdateBanner(downloadURL: dlURL) }
    }.resume()
}

// MARK: - Persistence helpers

func flushSwitchCount() {
    guard gSwitchCount != gSwitchCountSaved else { return }
    UserDefaults.standard.set(gSwitchCount, forKey: "spacerabbit.switchCount")
    gSwitchCountSaved = gSwitchCount
}

// MARK: - Signal handler (must be a global C-compatible function)

func onSignal(_ sig: Int32) {
    DispatchQueue.main.async { NSApp.terminate(nil) }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Accessibility check
let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
guard AXIsProcessTrustedWithOptions(axOpts as CFDictionary) else {
    fputs("Space Rabbit: accessibility permission required\n", stderr)
    fputs("  Grant in: System Settings → Privacy & Security → Accessibility\n", stderr)
    exit(1)
}

loadSpaceSwitchShortcuts()

gMenu = SwoopMenu()

DispatchQueue.main.asyncAfter(deadline: .now() + 5) { checkForUpdates() }

Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
    flushSwitchCount()
}

// Event tap
let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
gTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                          options: .defaultTap, eventsOfInterest: eventMask,
                          callback: eventTapCallback, userInfo: nil)
guard let tap = gTap else {
    fputs("Space Rabbit: failed to create event tap\n", stderr)
    exit(1)
}

guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
    fputs("Space Rabbit: failed to create run loop source\n", stderr)
    exit(1)
}
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// App-activation observer
let observer = SwoopObserver()
NSWorkspace.shared.notificationCenter.addObserver(
    observer,
    selector: #selector(SwoopObserver.appActivated(_:)),
    name: NSWorkspace.didActivateApplicationNotification,
    object: nil
)

// Cleanup on exit
NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil, queue: .main
) { _ in
    flushSwitchCount()
    NSWorkspace.shared.notificationCenter.removeObserver(observer)
    CGEvent.tapEnable(tap: tap, enable: false)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
}

signal(SIGINT,  onSignal)
signal(SIGTERM, onSignal)

print("Space Rabbit: running")
app.run()
