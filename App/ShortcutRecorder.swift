/*
 * ShortcutRecorder.swift — Native-style global shortcut recording control
 *
 * Captures safe keyboard shortcuts for cycling Spaces. Bare Fn/Globe is
 * recognized on release, while F1 through F20 are recorded by keycode so
 * they work in either macOS top-row keyboard mode.
 */

import Cocoa
import CoreGraphics

/// Native-style field for recording a global keyboard shortcut.
///
/// A local event monitor is installed only while recording so shortcuts such
/// as Command-W reach the field before AppKit treats them as window commands.
/// The global event tap stands down concurrently via
/// `gIsRecordingCycleShortcut`.
final class ShortcutRecorderButton: NSButton {

    /// Called with the new shortcut, or `nil` when the user clears it.
    var onChange: ((CycleShortcut?) -> Void)?

    private var shortcut: CycleShortcut?
    private let recordingTitle: String
    private let emptyTitle: String
    /// When `true`, recording is performed by the global event tap rather
    /// than a local monitor — required for the auto-follow ignore list,
    /// whose chords are other apps' live global hotkeys: a local monitor
    /// would never receive them, and the press would fire the very popup
    /// being recorded (see `gIsRecordingIgnoredHotkey`).
    private let capturesGlobally: Bool
    private var localMonitor: Any?
    private var recordingObservers: [NSObjectProtocol] = []
    private var isRecording = false
    private var recordingFnState: BareFnPressState = .idle

    override var acceptsFirstResponder: Bool { true }

    init(shortcut: CycleShortcut?, recordingTitle: String, emptyTitle: String,
         capturesGlobally: Bool = false) {
        self.shortcut = shortcut
        self.recordingTitle = recordingTitle
        self.emptyTitle = emptyTitle
        self.capturesGlobally = capturesGlobally
        super.init(frame: .zero)

        bezelStyle  = .rounded
        controlSize = .regular
        font        = .monospacedSystemFont(ofSize: 12, weight: .regular)
        target      = self
        action      = #selector(beginRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopRecording()
    }

    /// Refreshes the displayed binding when Preferences reappears.
    func setShortcut(_ shortcut: CycleShortcut?) {
        self.shortcut = shortcut
        if !isRecording { updateTitle() }
    }

    @objc private func beginRecording() {
        guard !isRecording else { return }

        isRecording = true
        recordingFnState.reset()
        if capturesGlobally {
            gIsRecordingIgnoredHotkey = true
            gIgnoredHotkeyCaptureHandler = { [weak self] event in
                self?.handleGlobalCapture(event)
            }
        } else {
            gIsRecordingCycleShortcut = true
        }
        syncKeyboardAuxiliaryTaps()
        title = recordingTitle
        window?.makeFirstResponder(self)

        if !capturesGlobally {
            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .flagsChanged, .systemDefined]
            ) { [weak self] event in
                guard let self, self.isRecording else { return event }
                self.handleRecordingEvent(event)
                return nil
            }
        }

        let center = NotificationCenter.default
        if let window {
            recordingObservers.append(center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main
            ) { [weak self] _ in self?.cancelRecording() })
        }
        recordingObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp, queue: .main
        ) { [weak self] _ in self?.cancelRecording() })
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign { stopRecording() }
        return didResign
    }

    /// Handles one locally-monitored key event while recording.
    private func handleRecordingEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleModifierChange(event)
            return
        case .systemDefined:
            recordingFnState.markChorded()
            return
        case .keyDown:
            break
        default:
            return
        }

        let fnWasDown = recordingFnState.isDown
        recordingFnState.markChorded()

        let keycode = Int64(event.keyCode)
        let modifiers = cycleModifiers(from: event.modifierFlags)

        // Escape cancels without changing the existing shortcut.
        if keycode == kEscapeKeycode {
            cancelRecording()
            return
        }

        guard let (label, isFunctionKey) = keyLabel(for: event) else {
            NSSound.beep()
            return
        }

        // Physical Fn chords are not recordable, except when Fn is how the
        // keyboard produces an F-key in the current macOS top-row mode.
        guard !fnWasDown || isFunctionKey else {
            NSSound.beep()
            return
        }

        // An unmodified Delete or Forward Delete clears the field.
        if keycode == kDeleteKeycode || keycode == kForwardDeleteKeycode,
           modifiers.isEmpty {
            commit(nil)
            return
        }

        // Bare typing keys would fire during ordinary text entry. Require
        // Control, Option, or Command; standalone F-keys remain valid.
        let safeModifiers: CGEventFlags = [
            .maskControl, .maskAlternate, .maskCommand
        ]
        guard isFunctionKey || !modifiers.intersection(safeModifiers).isEmpty else {
            NSSound.beep()
            return
        }

        commit(CycleShortcut(keycode: keycode, modifiers: modifiers, keyLabel: label))
    }

    /// Handles one key-down captured by the event tap while recording for
    /// the auto-follow ignore list (see `gIsRecordingIgnoredHotkey`). The
    /// tap has already swallowed the event, so the hotkey's own app stays
    /// quiet. Validation mirrors `handleRecordingEvent` minus the Fn
    /// special cases, which cannot occur here — bare Fn arrives as a
    /// `flagsChanged` and is never captured.
    private func handleGlobalCapture(_ cgEvent: CGEvent) {
        guard isRecording, let event = NSEvent(cgEvent: cgEvent) else { return }

        let keycode = Int64(event.keyCode)
        let modifiers = cycleModifiers(from: event.modifierFlags)

        // Escape cancels; an unmodified Delete commits nothing — both
        // leave recording mode, exactly like the local path.
        if keycode == kEscapeKeycode, modifiers.isEmpty {
            cancelRecording()
            return
        }
        if keycode == kDeleteKeycode || keycode == kForwardDeleteKeycode,
           modifiers.isEmpty {
            commit(nil)
            return
        }

        guard let (label, isFunctionKey) = keyLabel(for: event),
              isFunctionKey || !modifiers.intersection(
                  [.maskControl, .maskAlternate, .maskCommand]).isEmpty
        else {
            NSSound.beep()
            return
        }

        commit(CycleShortcut(keycode: keycode, modifiers: modifiers, keyLabel: label))
    }

    /// Recognizes Fn by itself while leaving other modifier-only presses
    /// available as part of a later regular-key shortcut.
    private func handleModifierChange(_ event: NSEvent) {
        let keycode = Int64(event.keyCode)
        guard keycode == kFnKeycode else {
            recordingFnState.markChorded()
            return
        }

        if event.modifierFlags.contains(.function) {
            recordingFnState.begin(
                usedAsModifier: !cycleModifiers(from: event.modifierFlags).isEmpty
            )
        } else {
            if recordingFnState.finish() { commit(.fn) }
        }
    }

    /// Converts AppKit modifier flags to the CoreGraphics representation used
    /// by the session event tap.
    private func cycleModifiers(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result = CGEventFlags()
        if flags.contains(.control)  { result.insert(.maskControl) }
        if flags.contains(.option)   { result.insert(.maskAlternate) }
        if flags.contains(.shift)    { result.insert(.maskShift) }
        if flags.contains(.command)  { result.insert(.maskCommand) }
        return result
    }

    /// Returns a compact key label and whether the key is an F-key (which is
    /// safe to bind without another modifier).
    private func keyLabel(for event: NSEvent) -> (label: String, isFunctionKey: Bool)? {
        let keycode = Int64(event.keyCode)
        if let label = CycleShortcut.functionKeyLabels[keycode] { return (label, true) }
        if let label = CycleShortcut.specialKeyLabels[keycode]  { return (label, false) }

        guard let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else { return nil }
        return (characters.uppercased(), false)
    }

    /// Commits a recorded value, updates the field, and leaves recording mode.
    private func commit(_ shortcut: CycleShortcut?) {
        self.shortcut = shortcut
        onChange?(shortcut)
        stopRecording()
        window?.makeFirstResponder(nil)
    }

    private func cancelRecording() {
        stopRecording()
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    /// Removes the temporary monitor and restores the field title.
    private func stopRecording() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        let center = NotificationCenter.default
        recordingObservers.forEach(center.removeObserver)
        recordingObservers.removeAll()
        isRecording = false
        recordingFnState.reset()
        if capturesGlobally {
            gIsRecordingIgnoredHotkey = false
            gIgnoredHotkeyCaptureHandler = nil
        } else {
            gIsRecordingCycleShortcut = false
        }
        syncKeyboardAuxiliaryTaps()
        updateTitle()
    }

    private func updateTitle() {
        title = shortcut?.displayString ?? emptyTitle
    }
}
