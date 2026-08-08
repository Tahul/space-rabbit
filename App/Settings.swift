/*
 * Settings.swift — Preferences window with sidebar navigation
 *
 * The settings window uses a native sidebar layout (NSSplitViewController
 * with a source-list sidebar item, like System Settings): the sidebar on
 * the left selects one of five panes shown on the right:
 *
 *   Auto-Start — Launch at Login toggle (+ warning banner)
 *   Features   — Instant space switch, Auto-follow, gestures, Transition speed
 *   Advanced   — Dock instant-hide, menu bar icon visibility
 *   Updates    — Manual update check + manual-update notice
 *   About      — App icon, version, authors
 *
 * Styling deliberately sticks to native AppKit primitives: the sidebar is
 * a real NSSplitViewItem sidebar (rounded source-list selection, sidebar
 * material), setting groups are NSBox containers, and all controls use
 * the user's system accent color.
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
    static let contentWidth:      CGFloat = 480
    static let windowMinHeight:   CGFloat = 320
    static let sidebarWidth:      CGFloat = 165
    static let sidebarTopInset:   CGFloat = 10
    static let sidebarRowHeight:  CGFloat = 32
    static let sidebarSymbolSize: CGFloat = 13
    static let paneTopPadding:    CGFloat = 30
    static let outerPadding:      CGFloat = 20
    static let bottomPadding:     CGFloat = 20
    static let headerFontSize:    CGFloat = 17
    static let groupGapSpacing:   CGFloat = 14
    static let rowHorizontalPad:  CGFloat = 14
    static let rowVerticalPad:    CGFloat = 12
    static let groupCornerRadius: CGFloat = 10
    static let aboutIconSize:     CGFloat = 80
    static let aboutSpacing:      CGFloat = 20
    static let speedSliderWidth:  CGFloat = 140
    static let speedTailSpacing:  CGFloat = 3
}

// MARK: - Panes

/// Identifies each pane in the settings sidebar, in display order.
enum SettingsPane: Int, CaseIterable {
    case autoStart
    case features
    case advanced
    case updates
    case about

    /// Title shown in the sidebar row and as the pane header.
    var title: String {
        switch self {
        case .autoStart: return L("settings.pane.autoStart")
        case .features:  return L("settings.pane.features")
        case .advanced:  return L("settings.pane.advanced")
        case .updates:   return L("settings.pane.updates")
        case .about:     return L("settings.pane.about")
        }
    }

    /// SF Symbol shown in the sidebar row (plain template glyph — the
    /// system tints it, including the selected-row emphasis).
    var symbol: String {
        switch self {
        case .autoStart: return "power"
        case .features:  return "bolt"
        case .advanced:  return "gearshape"
        case .updates:   return "arrow.down.circle"
        case .about:     return "hare"
        }
    }

    /// Instantiates the view controller for this pane.
    @MainActor
    func makeController() -> NSViewController {
        switch self {
        case .autoStart: return AutoStartPaneController()
        case .features:  return FeaturesPaneController()
        case .advanced:  return AdvancedPaneController()
        case .updates:   return UpdatesPaneController()
        case .about:     return AboutPaneController()
        }
    }
}

// MARK: - Settings Window Controller

/// Singleton that owns and shows the preferences window.
///
/// The window is created lazily on first `show()` call and reused
/// for subsequent invocations. It is not released when closed, so
/// user selections (active pane) are preserved.
final class SettingsWindowController: NSObject, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var rootController: SettingsRootViewController?

    /// Shows the settings window, creating it on first call.
    ///
    /// - Parameter pane: Optional pane to select before showing. When `nil`,
    ///   the previously selected pane is kept.
    func show(pane: SettingsPane? = nil) {
        if window == nil { window = makeWindow() }
        guard let window = window else { return }

        if let pane = pane { rootController?.select(pane) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Refreshes the open window's panes from the global state.
    ///
    /// Called when a setting is changed outside the settings window (the menu
    /// bar dropdown), so a visible pane updates live instead of waiting for
    /// the next pane swap. No-op when the window was never created.
    func syncPanes() {
        rootController?.syncPanes()
    }

    /// Constructs the preferences window with its sidebar + pane layout.
    private func makeWindow() -> NSWindow {
        let root = SettingsRootViewController()
        rootController = root

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The sidebar extends into the title bar area; each pane shows its
        // own header instead of a window title
        window.title                       = L("settings.window.title")
        window.titleVisibility             = .hidden
        window.titlebarAppearsTransparent  = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed        = false
        window.delegate                    = self
        window.contentViewController       = root

        // Note: `.moveToActiveSpace` is deliberately NOT set here — it makes
        // the window server re-insert the window at the back of the stacking
        // order on every space transition, so the window resurfaces behind
        // other apps' windows when returning to its space. Without it, a
        // window left open on another space pulls the user back there when
        // re-shown (platform default, same as e.g. Klack).
        return window
    }
}

// MARK: - Root View Controller (Sidebar + Content)

/// Native split-view layout: a source-list sidebar item on the left and the
/// selected pane on the right. Resizes the window to fit each pane's content.
final class SettingsRootViewController: NSSplitViewController {

    private let sidebarController = SettingsSidebarController()
    private let contentHost       = ContentHostController()
    private var paneControllers: [SettingsPane: NSViewController] = [:]
    private var currentPane:     NSViewController?

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.dividerStyle = .thin

        sidebarController.onSelect = { [weak self] pane in
            self?.showPane(pane, animate: true)
        }

        // Real sidebar split item: sidebar material, safe-area handling
        // under the title bar, and the native rounded row selection
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.canCollapse            = false
        sidebarItem.minimumThickness       = Layout.sidebarWidth
        sidebarItem.maximumThickness       = Layout.sidebarWidth
        sidebarItem.allowsFullHeightLayout = true
        addSplitViewItem(sidebarItem)

        addSplitViewItem(NSSplitViewItem(viewController: contentHost))

        sidebarController.select(.autoStart)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The window may not exist yet during viewDidLoad; size it now
        resizeToFitCurrentPane(animate: false)
    }

    /// Refreshes every instantiated pane from the global state.
    ///
    /// All cached panes are refreshed, not just the visible one: an offscreen
    /// pane's `viewWillAppear` no longer re-reads the globals for it.
    func syncPanes() {
        for controller in paneControllers.values {
            (controller as? SettingsPaneViewController)?.syncFromGlobals()
        }
    }

    /// Selects the given pane in the sidebar and shows it.
    func select(_ pane: SettingsPane) {
        sidebarController.select(pane)
    }

    /// Swaps the given pane's view into the content host.
    ///
    /// Pane controllers are created lazily on first selection and kept
    /// alive afterwards, so their state persists across switches.
    private func showPane(_ pane: SettingsPane, animate: Bool) {
        let controller: NSViewController
        if let existing = paneControllers[pane] {
            controller = existing
        } else {
            controller = pane.makeController()
            paneControllers[pane] = controller
            contentHost.addChild(controller)
        }
        guard controller !== currentPane else { return }

        currentPane?.view.removeFromSuperview()
        currentPane = controller

        let container = contentHost.view
        let paneView  = controller.view
        paneView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(paneView)

        // Fixed width instead of a trailing pin: the split view sizes the
        // container by frame, which can briefly disagree during resizes
        let width = paneView.widthAnchor.constraint(equalToConstant: Layout.contentWidth)
        width.priority = .init(999)
        NSLayoutConstraint.activate([
            paneView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            paneView.topAnchor.constraint(equalTo: container.topAnchor),
            paneView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            width,
        ])

        resizeToFitCurrentPane(animate: animate)
    }

    /// Resizes the window so the content area exactly fits the current pane,
    /// keeping the title bar anchored at the top (origin.y shifts to
    /// compensate).
    ///
    /// Call this after showing/hiding dynamic content (e.g. warning banners)
    /// so the window adjusts to the new content height.
    ///
    /// - Parameter animate: Whether to animate the resize transition.
    func resizeToFitCurrentPane(animate: Bool = true) {
        guard let window = view.window, let pane = currentPane else { return }

        pane.view.layoutSubtreeIfNeeded()

        let height      = max(pane.view.fittingSize.height, Layout.windowMinHeight)
        let width       = Layout.sidebarWidth + splitView.dividerThickness
                        + Layout.contentWidth
        let contentSize = NSSize(width: width, height: height)
        let frameSize   = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize)
        ).size

        // Anchor the top edge: shift origin down by the height difference
        // so the window grows/shrinks from the bottom
        var frame       = window.frame
        frame.origin.y += frame.height - frameSize.height
        frame.size      = frameSize
        window.setFrame(frame, display: true, animate: animate)
    }
}

/// Plain container for the selected pane's view (right split-view side).
private final class ContentHostController: NSViewController {
    override func loadView() { view = NSView() }
}

// MARK: - Sidebar Controller

/// The source-list sidebar: the main panes anchored at the top, and the
/// Updates + About panes pinned to the bottom edge, visually separate from
/// the rest.
///
/// Implemented as two coordinated source-list tables sharing one selection:
/// selecting a row in one deselects the other.
final class SettingsSidebarController: NSViewController {

    /// Called whenever a pane is selected (by click or programmatically).
    var onSelect: ((SettingsPane) -> Void)?

    /// Panes pinned to the bottom of the sidebar, in display order.
    private let bottomPanes: [SettingsPane] = [.updates, .about]

    /// Panes shown in the top list (everything not pinned to the bottom).
    private var mainPanes: [SettingsPane] {
        SettingsPane.allCases.filter { !bottomPanes.contains($0) }
    }

    private var mainTable:   NSTableView!
    private var bottomTable: NSTableView!

    private var mainTop:      NSLayoutConstraint!
    private var mainHeight:   NSLayoutConstraint!
    private var bottomHeight: NSLayoutConstraint!

    override func loadView() {
        mainTable   = makeTable()
        bottomTable = makeTable()

        // The tables are hosted directly (no NSScrollView): both lists always
        // fit entirely, and a scroll view would let their rows scroll out of
        // the fixed frame and clip
        let container = NSView()
        mainTable.translatesAutoresizingMaskIntoConstraints   = false
        bottomTable.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mainTable)
        container.addSubview(bottomTable)

        view = container
        mainTable.reloadData()
        bottomTable.reloadData()

        // Small fixed inset from the sidebar panel's top. On macOS 26+ the
        // split view already places the sidebar panel below the traffic
        // lights, so no title-bar clearance is needed (the safe area
        // over-clears and pushes the list way down). On earlier systems the
        // panel extends under the transparent title bar instead —
        // viewDidLayout adds the clearance there, and compensates for the
        // table's internal padding above its first row.
        mainTop      = mainTable.topAnchor.constraint(equalTo: container.topAnchor,
                                                      constant: Layout.sidebarTopInset)
        mainHeight   = mainTable.heightAnchor.constraint(equalToConstant: contentHeight(of: mainTable))
        bottomHeight = bottomTable.heightAnchor.constraint(equalToConstant: contentHeight(of: bottomTable))

        NSLayoutConstraint.activate([
            mainTop,
            mainTable.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainTable.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainHeight,

            bottomTable.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomTable.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomTable.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                                constant: -8),
            bottomHeight,
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        // The source-list style's real row metrics only resolve once the
        // tables are in a window, so the heights measured during loadView
        // can be short (clipping the last row). Re-measure here; the guards
        // avoid a layout loop.
        let mainFit   = contentHeight(of: mainTable)
        let bottomFit = contentHeight(of: bottomTable)
        if abs(mainHeight.constant - mainFit) > 0.5 { mainHeight.constant = mainFit }
        if abs(bottomHeight.constant - bottomFit) > 0.5 { bottomHeight.constant = bottomFit }

        // Cancel out the style's internal padding above the first row so
        // the first row's visual top sits exactly at the intended inset.
        // Pre-macOS 26 the sidebar panel is not offset below the title bar
        // by the split view, so clear the title-bar height manually — the
        // traffic lights would otherwise overlap the first row.
        if mainTable.numberOfRows > 0 {
            var clearance: CGFloat = 0
            if #unavailable(macOS 26.0), let window = view.window {
                clearance = window.frame.height - window.contentLayoutRect.height
            }
            let topFit = clearance + Layout.sidebarTopInset
                       - mainTable.rect(ofRow: 0).minY
            if abs(mainTop.constant - topFit) > 0.5 { mainTop.constant = topFit }
        }
    }

    /// Selects the given pane's row in whichever list owns it (fires `onSelect`).
    func select(_ pane: SettingsPane) {
        let (table, row) = bottomPanes.contains(pane)
            ? (bottomTable!, bottomPanes.firstIndex(of: pane) ?? 0)
            : (mainTable!, mainPanes.firstIndex(of: pane) ?? 0)

        if table.selectedRow != row {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            onSelect?(pane)
        }
    }

    // MARK: Builders

    private func makeTable() -> NSTableView {
        let table = NSTableView()
        table.style                = .sourceList
        table.headerView           = nil
        table.rowHeight            = Layout.sidebarRowHeight
        table.backgroundColor      = .clear
        table.allowsEmptySelection = true   // the other list may hold the selection
        table.focusRingType        = .none
        table.dataSource           = self
        table.delegate             = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane")))
        return table
    }

    /// Exact content height of a fully-loaded table (bottom edge of its
    /// last row), so the fixed frame fits every row with no scrolling.
    private func contentHeight(of table: NSTableView) -> CGFloat {
        guard table.numberOfRows > 0 else { return 0 }
        let measured = table.rect(ofRow: table.numberOfRows - 1).maxY
        // Fallback arithmetic in case row geometry isn't available yet
        let computed = CGFloat(table.numberOfRows)
                     * (table.rowHeight + table.intercellSpacing.height)
        return max(measured, computed)
    }

    /// Maps a row of one of the two tables back to its pane.
    private func pane(for table: NSTableView, row: Int) -> SettingsPane? {
        let panes = (table === bottomTable) ? bottomPanes : mainPanes
        return panes.indices.contains(row) ? panes[row] : nil
    }
}

extension SettingsSidebarController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === bottomTable ? bottomPanes.count : mainPanes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let pane = pane(for: tableView, row: row) else { return nil }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: pane.symbol,
                             accessibilityDescription: pane.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: Layout.sidebarSymbolSize, weight: .medium))

        let label = NSTextField(labelWithString: pane.title)
        label.font          = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail

        // Assigning imageView/textField lets the cell apply the native
        // selection emphasis (white text/glyph on the accent-colored row)
        let cell = NSTableCellView()
        cell.imageView = icon
        cell.textField = label
        cell.addSubview(icon)
        cell.addSubview(label)

        icon.translatesAutoresizingMaskIntoConstraints  = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor,
                                            constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView,
                   selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        // Prevent a click on the empty area from clearing the selection
        proposedSelectionIndexes.isEmpty ? tableView.selectedRowIndexes
                                         : proposedSelectionIndexes
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView,
              table.selectedRow >= 0,   // deselection echoes are ignored
              let pane = pane(for: table, row: table.selectedRow) else { return }

        // Single selection across both lists: clear the other one
        let other = (table === mainTable) ? bottomTable! : mainTable!
        other.deselectAll(nil)

        onSelect?(pane)
    }
}

// MARK: - Pane Base Class

/// Base class for settings panes shown to the right of the sidebar.
///
/// Provides the bold pane header, the outer stack assembly, and the shared
/// row/group/switch builders used by all panes.
class SettingsPaneViewController: NSViewController {

    /// Subclasses override to name the pane (shown as the bold header).
    var paneTitle: String { "" }

    override func loadView() { view = NSView() }

    /// Subclasses build and return their stacked content views (groups,
    /// banners). Called once from `viewDidLoad`; every returned view is
    /// stretched to the pane's full content width.
    func buildContent() -> [NSView] { [] }

    /// Subclasses override to refresh their controls from the global state.
    ///
    /// Called when the pane is about to appear and whenever the same setting
    /// is changed elsewhere (the menu bar dropdown) while the pane is visible.
    func syncFromGlobals() {}

    override func viewWillAppear() {
        super.viewWillAppear()
        syncFromGlobals()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let header = NSTextField(labelWithString: paneTitle)
        header.font = .systemFont(ofSize: Layout.headerFontSize, weight: .bold)

        let outerStack = NSStackView()
        outerStack.orientation = .vertical
        outerStack.alignment   = .leading
        outerStack.spacing     = Layout.groupGapSpacing
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        outerStack.addArrangedSubview(header)

        let contentViews = buildContent()
        for content in contentViews {
            content.translatesAutoresizingMaskIntoConstraints = false
            outerStack.addArrangedSubview(content)
        }

        view.addSubview(outerStack)

        var constraints = [
            outerStack.topAnchor.constraint(equalTo: view.topAnchor,
                                            constant: Layout.paneTopPadding),
            outerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                                constant: Layout.outerPadding),
            outerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                                 constant: -Layout.outerPadding),
            outerStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor,
                                               constant: -Layout.bottomPadding),
            view.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
        ]
        // Make all content views (not the header label) span the full width
        constraints += contentViews.map {
            $0.trailingAnchor.constraint(equalTo: outerStack.trailingAnchor)
        }
        NSLayoutConstraint.activate(constraints)
    }

    /// Asks the window to resize so the pane's current content fits.
    ///
    /// Call after showing/hiding dynamic content (banners, reset links).
    ///
    /// - Parameter animate: Whether to animate the resize transition.
    func resizePaneToFit(animate: Bool = true) {
        (view.window?.contentViewController as? SettingsRootViewController)?
            .resizeToFitCurrentPane(animate: animate)
    }

    // MARK: Row Builder Helpers

    /// Creates a standard settings row: label (+ optional subtitle below)
    /// with the control pushed to the trailing edge via a flexible spacer.
    ///
    /// - Parameters:
    ///   - label: Primary text label for the setting.
    ///   - control: The interactive control (typically an `NSSwitch`).
    ///   - subtitle: Optional secondary label shown below the primary label.
    /// - Returns: A configured `NSView` ready to add to a group box.
    func settingsRow(label: String, control: NSView,
                     subtitle: NSTextField? = nil) -> NSView {
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
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())   // Flexible spacer pushes the control to the right
        row.addArrangedSubview(control)
        return row
    }

    /// Wraps the given views in a rounded, subtly-filled group card
    /// (an `NSBox`, the native grouping primitive — its fill adapts to
    /// light/dark mode automatically).
    ///
    /// - Parameter views: Rows (and dividers) stacked top to bottom.
    /// - Returns: The group box, ready to return from `buildContent()`.
    func groupBox(_ views: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing     = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for subview in views {
            subview.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(subview)
        }

        let box = NSBox()
        box.boxType            = .custom
        box.titlePosition      = .noTitle
        box.cornerRadius       = Layout.groupCornerRadius
        box.borderWidth        = 0
        box.borderColor        = .clear
        box.fillColor          = .quaternarySystemFill
        box.contentViewMargins = .zero

        if let content = box.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
            // Stretch every row to the group's full width
            NSLayoutConstraint.activate(views.map {
                $0.widthAnchor.constraint(equalTo: stack.widthAnchor)
            })
        }
        return box
    }

    /// Creates a horizontal separator line between settings rows,
    /// inset to match the rows' text padding.
    func rowDivider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor,
                                          constant: Layout.rowHorizontalPad),
            line.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor,
                                           constant: -Layout.rowHorizontalPad),
            line.topAnchor.constraint(equalTo: wrapper.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    /// Creates an `NSSwitch` pre-configured with the given state and action.
    ///
    /// - Parameters:
    ///   - state: Initial on/off state.
    ///   - action: Selector to call when the switch is toggled.
    /// - Returns: A configured `NSSwitch` targeting `self`.
    func makeSwitch(_ state: Bool, _ action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.controlSize = .regular
        toggle.state       = state ? .on : .off
        toggle.target      = self
        toggle.action      = action
        return toggle
    }
}

// MARK: - Auto-Start Pane

/// The "Auto-Start" pane: Launch at Login toggle and its warning banner.
final class AutoStartPaneController: SettingsPaneViewController {

    /// When `true`, the launch warning banner will flash on next appearance.
    /// Set by the menu bar warning banner to draw attention to the setting.
    static var pendingLaunchAtLoginAlert = false

    override var paneTitle: String { SettingsPane.autoStart.title }

    private var launchAtLoginControl: NSSwitch!
    private var launchStatusLabel:    NSTextField!
    private var launchWarningBanner:  NSView!

    override func buildContent() -> [NSView] {
        launchAtLoginControl = makeSwitch(false, #selector(toggleLaunchAtLogin))

        // Status label shown below the toggle when there's an issue
        launchStatusLabel = NSTextField(wrappingLabelWithString: "")
        launchStatusLabel.font                    = .systemFont(ofSize: 11)
        launchStatusLabel.textColor               = .secondaryLabelColor
        launchStatusLabel.preferredMaxLayoutWidth = 240
        launchStatusLabel.isHidden                = true

        // Warning banner shown when launch-at-login is not enabled
        launchWarningBanner = makeLaunchWarningBanner()

        let group = groupBox([settingsRow(
            label:    L("settings.autoStart.launchAtLogin"),
            control:  launchAtLoginControl,
            subtitle: launchStatusLabel
        )])
        return [launchWarningBanner, group]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateLaunchAtLoginUI()
    }

    override func syncFromGlobals() {
        updateLaunchAtLoginUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()

        // If the user arrived here from the menu bar warning banner,
        // flash the banner to draw attention to the launch-at-login setting
        if Self.pendingLaunchAtLoginAlert {
            Self.pendingLaunchAtLoginAlert = false
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

    /// Creates the orange warning banner shown when launch-at-login is disabled.
    ///
    /// The banner includes a warning icon and explanatory text, styled with
    /// an orange tint to draw attention.
    private func makeLaunchWarningBanner() -> NSView {
        let box = NSBox()
        box.boxType            = .custom
        box.titlePosition      = .noTitle
        box.cornerRadius       = Layout.groupCornerRadius
        box.borderWidth        = 0
        box.borderColor        = .clear
        box.fillColor          = NSColor.systemOrange.withAlphaComponent(0.08)
        box.contentViewMargins = .zero

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                 accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        iconView.contentTintColor = .systemOrange
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: L("settings.autoStart.warning"))
        label.font      = .systemFont(ofSize: 12)
        label.textColor = NSColor.systemOrange
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = box.contentView ?? box
        content.addSubview(iconView)
        content.addSubview(label)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 11),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -11),
        ])
        return box
    }

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
        resizePaneToFit()

        if let msg = errorMessage {
            launchStatusLabel.stringValue = msg
            launchStatusLabel.isHidden    = false
        } else if status == .requiresApproval {
            launchStatusLabel.stringValue = L("settings.autoStart.approvalNeeded")
            launchStatusLabel.isHidden    = false
        } else {
            launchStatusLabel.isHidden = true
        }
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
            let msg = L("settings.autoStart.error", error.localizedDescription)
            fputs("Space Rabbit: launch at login: \(error)\n", stderr)
            updateLaunchAtLoginUI(errorMessage: msg)
        }
    }
}

// MARK: - Features Pane

/// The "Features" pane: instant switching features and transition speed.
final class FeaturesPaneController: SettingsPaneViewController {

    override var paneTitle: String { SettingsPane.features.title }

    private var instantSwitchControl:    NSSwitch!
    private var autoFollowControl:       NSSwitch!
    private var trackpadSwipeControl:    NSSwitch!
    private var missionControlControl:   NSSwitch!
    private var speedSlider:             NSSlider!
    private var speedValueLabel:         NSTextField!
    private var speedBoltIcon:           NSImageView!

    override func buildContent() -> [NSView] {
        instantSwitchControl    = makeSwitch(gInstantSwitchEnabled,    #selector(toggleInstantSwitch))
        autoFollowControl       = makeSwitch(gAutoFollowEnabled,       #selector(toggleAutoFollow))
        trackpadSwipeControl    = makeSwitch(gTrackpadSwipeEnabled,    #selector(toggleTrackpadSwipe))
        missionControlControl = makeSwitch(gInstantMissionControlEnabled,
                                           #selector(toggleInstantMissionControl))

        let togglesGroup = groupBox([
            settingsRow(label: L("settings.features.instantSpaceSwitch"),
                        control: instantSwitchControl),
            rowDivider(),
            settingsRow(label: L("settings.features.instantAppSwitch"),
                        control: autoFollowControl),
            rowDivider(),
            settingsRow(label: L("settings.features.instantTrackpadSwipe"),
                        control: trackpadSwipeControl),
            rowDivider(),
            settingsRow(label: L("settings.features.instantMissionControl"),
                        control: missionControlControl),
        ])
        let speedGroup = groupBox([
            settingsRow(label: L("settings.features.transitionSpeed"),
                        control: makeSpeedControl()),
        ])
        return [togglesGroup, speedGroup]
    }

    override func syncFromGlobals() {
        // Refresh all toggle states — they may have been changed via the
        // menu bar, whether or not this pane was visible at the time
        instantSwitchControl.state    = gInstantSwitchEnabled    ? .on : .off
        autoFollowControl.state       = gAutoFollowEnabled       ? .on : .off
        trackpadSwipeControl.state    = gTrackpadSwipeEnabled    ? .on : .off
        missionControlControl.state   = gInstantMissionControlEnabled ? .on : .off
        speedSlider.doubleValue       = gSwitchSpeed
        updateSpeedDisplay()
    }

    /// Builds the transition-speed control: a 5-tick slider with a trailing
    /// value label. Ticks map to Normal (macOS's native animation — Space
    /// Rabbit stands down entirely), Fast, Faster, Fastest (synthetic
    /// gestures at increasing velocity), and Instant (the right end cap).
    private func makeSpeedControl() -> NSView {
        speedSlider = NSSlider(value: gSwitchSpeed, minValue: 0, maxValue: 1,
                               target: self, action: #selector(speedChanged))
        speedSlider.controlSize  = .small
        speedSlider.isContinuous = true
        speedSlider.numberOfTickMarks         = 5
        speedSlider.allowsTickMarkValuesOnly  = true
        speedSlider.translatesAutoresizingMaskIntoConstraints = false

        speedValueLabel = NSTextField(labelWithString: "")
        speedValueLabel.font = .systemFont(ofSize: 11)

        // Thunder bolt shown only at the "Instant" end cap
        speedBoltIcon = NSImageView()
        speedBoltIcon.image = NSImage(systemSymbolName: "bolt.fill",
                                      accessibilityDescription: L("settings.features.speed.instant"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))

        // Bolt + label hug each other and anchor to the trailing edge of a
        // fixed-width wrapper, so the text stays flush right (and the slider
        // stays put) without dead space opening up between icon and text.
        let tail = NSStackView(views: [speedBoltIcon, speedValueLabel])
        tail.orientation = .horizontal
        tail.spacing     = Layout.speedTailSpacing
        tail.alignment   = .centerY
        tail.translatesAutoresizingMaskIntoConstraints = false

        let tailWrapper = NSView()
        tailWrapper.translatesAutoresizingMaskIntoConstraints = false
        tailWrapper.addSubview(tail)

        let stack = NSStackView(views: [speedSlider, tailWrapper])
        stack.orientation = .horizontal
        stack.spacing     = 8
        stack.alignment   = .centerY

        NSLayoutConstraint.activate([
            speedSlider.widthAnchor.constraint(equalToConstant: Layout.speedSliderWidth),
            tailWrapper.widthAnchor.constraint(equalToConstant: speedTailWidth()),
            tailWrapper.heightAnchor.constraint(equalTo: tail.heightAnchor),
            tail.trailingAnchor.constraint(equalTo: tailWrapper.trailingAnchor),
            tail.centerYAnchor.constraint(equalTo: tailWrapper.centerYAnchor),
        ])

        updateSpeedDisplay()
        return stack
    }

    /// Refreshes the speed value label and bolt icon for the current setting.
    /// At "Instant" the text turns primary (white in dark mode) and the
    /// thunder bolt appears, tinted to match; other ticks show dimmed text.
    private func updateSpeedDisplay() {
        let isInstant = gSwitchSpeed >= 1.0
        speedValueLabel.stringValue = speedDescription()
        speedValueLabel.textColor   = isInstant ? .labelColor : .secondaryLabelColor
        speedBoltIcon.contentTintColor = .labelColor
        speedBoltIcon.isHidden         = !isInstant
    }

    /// Localized names of the five slider ticks, slowest first — "Normal" being
    /// macOS's native animation (no synthetic gestures) and "Instant" the right
    /// end cap.
    ///
    /// The keys are spelled out as literals rather than looped over an array of
    /// key strings, so the build-time localization validator can see them (it
    /// scans the sources for `L("…")` textually).
    private func speedTickNames() -> [String] {
        [
            L("settings.features.speed.normal"),
            L("settings.features.speed.fast"),
            L("settings.features.speed.faster"),
            L("settings.features.speed.fastest"),
            L("settings.features.speed.instant"),
        ]
    }

    /// Index into `speedTickNames()` of the tick the slider currently rests on.
    private func speedTickIndex() -> Int {
        guard gSwitchSpeed < 1.0 else { return 4 }
        switch gSwitchSpeed {
        case ..<0.25: return 0
        case ..<0.50: return 1
        case ..<0.75: return 2
        default:      return 3
        }
    }

    /// Human-readable name for the current transition-speed tick.
    private func speedDescription() -> String {
        speedTickNames()[speedTickIndex()]
    }

    /// Width the trailing value column has to reserve.
    ///
    /// Measured from the actual localized tick names instead of hardcoded: they
    /// differ enormously between languages ("Fast" against "Instantánea" or
    /// "Мгновенная"), and because the column's content is pinned to its trailing
    /// edge, a label wider than the column overflows *leftwards* and draws on top
    /// of the slider. Sizing to the widest name keeps the slider clear of the text
    /// and stops it shifting as the value changes.
    ///
    /// - Returns: The width in points, including the bolt icon and its spacing
    ///   for the "Instant" tick — the only tick that shows it.
    private func speedTailWidth() -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: speedValueLabel.font ?? .systemFont(ofSize: 11)
        ]
        let boltAllowance = (speedBoltIcon.image?.size.width ?? 0) + Layout.speedTailSpacing

        let names = speedTickNames()
        let widest = names.indices.map { index -> CGFloat in
            let textWidth = (names[index] as NSString).size(withAttributes: attributes).width
            // The bolt is only ever shown on the last ("Instant") tick
            return index == names.count - 1 ? textWidth + boltAllowance : textWidth
        }.max() ?? 0

        return ceil(widest)
    }

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

    @objc private func toggleTrackpadSwipe() {
        gTrackpadSwipeEnabled = trackpadSwipeControl.state == .on
        UserDefaults.standard.set(gTrackpadSwipeEnabled, forKey: Defaults.trackpadSwipe)
        updateSwipeTap()
        gMenu?.syncMenuItems()
    }

    @objc private func toggleInstantMissionControl() {
        gInstantMissionControlEnabled = missionControlControl.state == .on
        UserDefaults.standard.set(gInstantMissionControlEnabled,
                                  forKey: Defaults.instantMissionControl)
        updateSwipeTap()
        gMenu?.syncMenuItems()
    }

    @objc private func speedChanged() {
        gSwitchSpeed = speedSlider.doubleValue
        UserDefaults.standard.set(gSwitchSpeed, forKey: Defaults.switchSpeed)
        updateSpeedDisplay()
    }
}

// MARK: - Advanced Pane

/// The "Advanced" pane: Dock instant-hide and menu bar icon visibility.
///
/// macOS supports a hidden preference `autohide-time-modifier` on com.apple.dock
/// that controls the Dock show/hide animation speed. Setting it to 0.0 makes the
/// Dock appear and disappear instantly (no animation). Removing the key restores
/// the system default behavior.
///
/// Changes require a Dock restart to take effect (`killall Dock`).
final class AdvancedPaneController: SettingsPaneViewController {

    override var paneTitle: String { SettingsPane.advanced.title }

    private var instantDockHideControl: NSSwitch!
    private var showMenuBarIconControl: NSSwitch!
    private var menuBarSubtitle:        NSTextField!
    private var dockResetDivider:       NSView!
    private var dockResetRow:           NSView!

    /// The Dock preference key that controls autohide animation duration.
    private let dockAutohideKey = "autohide-time-modifier" as CFString

    /// The Dock's preference domain identifier.
    private let dockBundleID    = "com.apple.dock" as CFString

    override func buildContent() -> [NSView] {
        let dockSubtitle = NSTextField(wrappingLabelWithString:
            L("settings.advanced.dockSubtitle"))
        dockSubtitle.font                    = .systemFont(ofSize: 11)
        dockSubtitle.textColor               = .secondaryLabelColor
        dockSubtitle.preferredMaxLayoutWidth = 240

        instantDockHideControl = makeSwitch(
            isDockInstantHideEnabled(),
            #selector(toggleDockInstantHide)
        )

        showMenuBarIconControl = makeSwitch(
            UserDefaults.standard.bool(forKey: Defaults.showMenuBarIcon),
            #selector(toggleShowMenuBarIcon)
        )

        menuBarSubtitle = NSTextField(wrappingLabelWithString: "")
        menuBarSubtitle.font                    = .systemFont(ofSize: 11)
        menuBarSubtitle.textColor               = .secondaryLabelColor
        menuBarSubtitle.preferredMaxLayoutWidth = 240
        updateMenuBarSubtitle()

        // "Reset to system default" link button (only visible when overridden)
        let resetBtn = LinkButton(title: "", target: self, action: #selector(resetDockToDefault))
        resetBtn.isBordered = false
        resetBtn.attributedTitle = NSAttributedString(string: L("settings.advanced.resetToDefault"), attributes: [
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
            resetStack.bottomAnchor.constraint(equalTo: resetRowView.bottomAnchor, constant: -9),
        ])

        dockResetRow     = resetRowView
        dockResetDivider = rowDivider()

        // Hidden by default; viewWillAppear sets the correct visibility
        dockResetDivider.isHidden = true
        dockResetRow.isHidden     = true

        let dockGroup = groupBox([
            settingsRow(
                label:    L("settings.advanced.instantDockHide"),
                control:  instantDockHideControl,
                subtitle: dockSubtitle
            ),
            dockResetDivider,
            dockResetRow,
        ])
        let menuBarGroup = groupBox([
            settingsRow(
                label:    L("settings.advanced.showMenuBarIcon"),
                control:  showMenuBarIconControl,
                subtitle: menuBarSubtitle
            ),
        ])
        return [dockGroup, menuBarGroup]
    }

    override func syncFromGlobals() {
        instantDockHideControl.state = isDockInstantHideEnabled() ? .on : .off
        let menuBarVisible = gMenu?.isMenuBarIconVisible
            ?? UserDefaults.standard.bool(forKey: Defaults.showMenuBarIcon)
        showMenuBarIconControl.state = menuBarVisible ? .on : .off
        updateMenuBarSubtitle()
        updateDockResetLink()
    }

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
        resizePaneToFit()
    }

    /// Prompts the user to restart the Dock so the autohide change takes effect.
    ///
    /// The Dock must be restarted for preference changes to be picked up.
    /// This shows an alert with "Restart Dock Now" and "Later" buttons.
    private func promptDockRestart() {
        let alert = NSAlert()
        alert.messageText     = L("settings.advanced.dockRestart.title")
        alert.informativeText = L("settings.advanced.dockRestart.message")
        alert.addButton(withTitle: L("settings.advanced.dockRestart.confirm"))
        alert.addButton(withTitle: L("common.later"))
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

    /// Updates the menu bar row's subtitle to match the toggle state:
    /// what flipping it off will do while the icon is visible, and how to
    /// reach Preferences again once it is hidden.
    private func updateMenuBarSubtitle() {
        menuBarSubtitle.stringValue = showMenuBarIconControl.state == .on
            ? L("settings.advanced.menuBarSubtitle.visible")
            : L("settings.advanced.menuBarSubtitle.hidden")
    }

    @objc private func toggleShowMenuBarIcon() {
        let visible = showMenuBarIconControl.state == .on
        gMenu?.setMenuBarIconVisible(visible)
        updateMenuBarSubtitle()
        resizePaneToFit()
    }
}

// MARK: - Updates Pane

/// The "Updates" pane: manual update check and the manual-update notice.
final class UpdatesPaneController: SettingsPaneViewController {

    override var paneTitle: String { SettingsPane.updates.title }

    private var checkButton: NSButton!

    override func buildContent() -> [NSView] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

        let subtitle = NSTextField(wrappingLabelWithString:
            L("settings.updates.installedVersion", version))
        subtitle.font                    = .systemFont(ofSize: 11)
        subtitle.textColor               = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 240

        checkButton = NSButton(title: L("settings.updates.checkNow"), target: self,
                               action: #selector(checkNow))
        checkButton.bezelStyle = .rounded

        let group = groupBox([settingsRow(
            label:    L("settings.updates.checkForUpdates"),
            control:  checkButton,
            subtitle: subtitle
        )])
        return [group, buildUpdateNoticeBox()]
    }

    /// Manually checks GitHub for a newer release, then reports the result
    /// as a sheet on the settings window. Mirrors the menu bar's
    /// "Check for Updates…" flow.
    @objc private func checkNow() {
        checkButton.isEnabled = false

        checkForUpdatesManually(
            onFound: { [weak self] downloadURL in
                guard let self else { return }
                self.checkButton.isEnabled = true

                // Show the tray banner so it persists after the dialog is dismissed
                gMenu?.showUpdateBanner(downloadURL: downloadURL)

                self.presentAlert(
                    title:   L("update.available.title"),
                    text:    L("update.available.message"),
                    buttons: [L("update.install"), L("common.later")]
                ) { response in
                    if response == .alertFirstButtonReturn {
                        startUpdate(downloadURL: downloadURL)
                    }
                }
            },
            onUpToDate: { [weak self] in
                guard let self else { return }
                self.checkButton.isEnabled = true
                self.presentAlert(
                    title:   L("update.upToDate.title"),
                    text:    L("update.upToDate.message"),
                    buttons: [L("common.ok")]
                )
            },
            onError: { [weak self] in
                guard let self else { return }
                self.checkButton.isEnabled = true
                self.presentAlert(
                    title:   L("update.checkFailed.title"),
                    text:    L("update.checkFailed.message"),
                    buttons: [L("common.ok")]
                )
            }
        )
    }

    /// Shows an alert as a sheet on the settings window (falls back to a
    /// standalone modal if the window is gone).
    private func presentAlert(title: String, text: String, buttons: [String],
                              completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText     = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }

        if let window = view.window {
            alert.beginSheetModal(for: window) { completion?($0) }
        } else {
            completion?(alert.runModal())
        }
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

        let text = NSTextField(wrappingLabelWithString: L("settings.updates.notice"))
        text.preferredMaxLayoutWidth = 380
        text.font      = .systemFont(ofSize: 11)
        text.textColor = .secondaryLabelColor

        let contentRow = NSStackView(views: [icon, text])
        contentRow.orientation = .horizontal
        contentRow.alignment   = .top
        contentRow.spacing     = 6
        contentRow.translatesAutoresizingMaskIntoConstraints = false

        // Rounded box container matching the group card style
        let box = NSBox()
        box.boxType            = .custom
        box.titlePosition      = .noTitle
        box.cornerRadius       = Layout.groupCornerRadius
        box.borderWidth        = 0
        box.borderColor        = .clear
        box.fillColor          = .quaternarySystemFill
        box.contentViewMargins = .zero

        let content = box.contentView ?? box
        content.addSubview(contentRow)
        NSLayoutConstraint.activate([
            contentRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            contentRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            contentRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            contentRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        return box
    }
}

// MARK: - About Pane

/// The "About" pane showing app info, version, and authors.
///
/// Displays the app icon, name, version, copyright, website link,
/// and author links.
final class AboutPaneController: SettingsPaneViewController {

    override var paneTitle: String { SettingsPane.about.title }

    override func buildContent() -> [NSView] {
        let appInfoStack = buildAppInfoStack()
        let authorsStack = buildAuthorsStack()

        let aboutStack = NSStackView(views: [appInfoStack, authorsStack])
        aboutStack.orientation = .vertical
        aboutStack.alignment   = .centerX
        aboutStack.spacing     = Layout.aboutSpacing
        aboutStack.translatesAutoresizingMaskIntoConstraints = false

        // Wrapper spans the pane's full width; the stack centers inside it
        let wrapper = NSView()
        wrapper.addSubview(aboutStack)
        NSLayoutConstraint.activate([
            aboutStack.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 4),
            aboutStack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            aboutStack.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
        ])
        return [wrapper]
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

        let nameLabel = NSTextField(labelWithString: L("app.name"))
        nameLabel.font      = .boldSystemFont(ofSize: 15)
        nameLabel.textColor = .labelColor

        let versionLabel = NSTextField(labelWithString: L("common.version", version))
        versionLabel.font      = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        let copyrightLabel = NSTextField(labelWithString: L("about.copyright"))
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
/// Used for author/website links in the About pane.
final class LinkTextField: NSTextField {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// An `NSButton` subclass that shows a pointing-hand cursor on hover.
/// Used for the "Reset to system default" link in the Advanced pane.
final class LinkButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
