/*
 * UpdateInstall.swift — Automatic update download and installation
 *
 * Handles the full update flow when the user clicks "Update available"
 * in the menu bar dropdown or "Install Now" from a manual check:
 *
 *   1. Opens a small progress window and downloads the DMG from GitHub.
 *   2. Mounts the DMG, copies the new .app over the running bundle, unmounts.
 *   3. Prompts the user to restart (dismissible to keep old version running).
 *
 * On failure an alert offers "Try Again" or "Cancel".
 * Cancelling at any point leaves the "Update available" banner intact so
 * the user can retry later.
 */

import AppKit
import Foundation

// MARK: - Entry Point

/// Called by `SwoopMenu` when the user clicks the "Update available" banner
/// or confirms "Install Now" from a manual update check.
///
/// Delegates to the shared `UpdaterWindowController`, which manages the
/// download, installation, and UI feedback.
///
/// - Parameter downloadURL: Direct HTTPS URL to the DMG asset on GitHub Releases.
func startUpdate(downloadURL: String) {
    UpdaterWindowController.shared.start(downloadURL: downloadURL)
}

// MARK: - UpdaterWindowController

/// Manages the update download + install flow with a progress window.
///
/// Responsibilities:
///   - Presents a non-modal progress window during download
///   - Downloads the DMG to a temporary location via `URLSession`
///   - Mounts the DMG, locates the `.app` inside, and atomically replaces
///     the running bundle using `FileManager.replaceItemAt`
///   - Offers restart after successful installation
///   - Provides retry/cancel on failure
///
/// This is a singleton — only one update can be in progress at a time.
/// Calling `start(downloadURL:)` while an existing download is running
/// cancels the previous one and begins fresh.
final class UpdaterWindowController: NSObject, NSWindowDelegate, URLSessionDownloadDelegate {

    static let shared = UpdaterWindowController()

    // MARK: UI Elements

    /// Small progress window shown during download and installation.
    private let window:       NSWindow

    /// Label showing the current phase: "Downloading…", "Installing…", etc.
    private let statusLabel:  NSTextField

    /// Horizontal progress bar — indeterminate until download progress is known.
    private let progressBar:  NSProgressIndicator

    /// Cancel button — disabled once installation begins (file writes in progress).
    private let cancelButton: NSButton

    // MARK: State

    /// The URLSession managing the current download. Set to `nil` when idle.
    private var session:      URLSession?

    /// The active download task. Set to `nil` when idle.
    private var downloadTask: URLSessionDownloadTask?

    /// The URL being downloaded — retained so "Try Again" can restart the flow.
    private var currentURL:   String?

    /// `true` while files are being written to disk. When set, the window's
    /// close button and cancel button are both disabled to prevent corruption.
    private var isInstalling  = false

    // MARK: - Init

    /// Builds the progress window and its subviews.
    ///
    /// The window is 400×130 pt, closable, and not released when closed
    /// (so it can be re-shown on retry). All subviews use Auto Layout.
    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 130),
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        window.title = "Space Rabbit Update"
        window.isReleasedWhenClosed      = false
        window.isMovableByWindowBackground = true

        statusLabel = NSTextField(labelWithString: "Preparing download…")
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar = NSProgressIndicator()
        progressBar.style           = .bar
        progressBar.isIndeterminate = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        // Escape key dismisses the window (standard macOS convention)
        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        super.init()

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        window.delegate     = self

        // Layout: status label → progress bar → cancel button, vertically stacked
        let content = window.contentView!
        content.addSubview(statusLabel)
        content.addSubview(progressBar)
        content.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor .constraint(equalTo: content.leadingAnchor,      constant:  20),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor,     constant: -20),
            statusLabel.topAnchor     .constraint(equalTo: content.topAnchor,          constant:  22),

            progressBar.leadingAnchor .constraint(equalTo: content.leadingAnchor,      constant:  20),
            progressBar.trailingAnchor.constraint(equalTo: content.trailingAnchor,     constant: -20),
            progressBar.topAnchor     .constraint(equalTo: statusLabel.bottomAnchor,   constant:  12),

            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor,    constant: -20),
            cancelButton.topAnchor     .constraint(equalTo: progressBar.bottomAnchor,  constant:  14),
            cancelButton.bottomAnchor  .constraint(equalTo: content.bottomAnchor,      constant: -16),
        ])
    }

    // MARK: - Start

    /// Resets the window state and begins a fresh download.
    ///
    /// Safe to call while a previous download is already in progress —
    /// the old session is silently cancelled before starting the new one.
    ///
    /// - Parameter downloadURL: Direct HTTPS URL to the DMG asset.
    func start(downloadURL: String) {
        // Ignore re-entry while an install is writing files: restarting the
        // flow would reset `isInstalling`, re-enabling Cancel mid-write and
        // letting a second download race the ongoing bundle swap.
        guard !isInstalling else { return }

        // Validate the URL before touching any UI, so a malformed one can't
        // leave the window stuck on an indeterminate spinner with no task.
        guard let url = URL(string: downloadURL) else { return }

        currentURL = downloadURL

        // Cancel any in-flight session silently. `invalidateAndCancel` prevents
        // the error delegate from firing for the cancelled download.
        session?.invalidateAndCancel()
        session      = nil
        downloadTask = nil

        // Reset UI to initial downloading state
        statusLabel.stringValue     = "Downloading update…"
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        cancelButton.isEnabled      = true

        // Center and bring the progress window to the front
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Create a new URLSession with ourselves as the download delegate.
        // We use a dedicated session (not URLSession.shared) so we can
        // invalidate it cleanly on cancel without affecting other networking.
        let s    = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session  = s
        downloadTask = s.downloadTask(with: url)
        downloadTask?.resume()
    }

    // MARK: - Cancel

    /// Called when the user clicks "Cancel" or presses Escape.
    ///
    /// Tears down the active download session and closes the window.
    /// Does nothing if installation is already in progress (files being written).
    /// The "Update available" banner stays visible so the user can retry later.
    @objc private func cancelTapped() {
        // Block cancel once file writes have begun — closing mid-install
        // could leave the app bundle in a corrupt state
        guard !isInstalling else { return }

        session?.invalidateAndCancel()
        session      = nil
        downloadTask = nil
        window.close()
    }

    // MARK: - NSWindowDelegate

    /// Prevents closing the window while files are being written to disk.
    ///
    /// - Parameter sender: The window requesting close permission.
    /// - Returns: `true` if the window may close, `false` to block it.
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isInstalling }

    /// Tears down the download session when the window is closed.
    ///
    /// Only fires if `windowShouldClose` returned `true` (i.e. not mid-install).
    func windowWillClose(_ notification: Notification) {
        guard !isInstalling else { return }
        session?.invalidateAndCancel()
        session      = nil
        downloadTask = nil
    }

    // MARK: - URLSessionDownloadDelegate — Progress

    /// Updates the progress bar as download bytes arrive.
    ///
    /// Switches the progress bar from indeterminate to determinate once
    /// the server provides a `Content-Length` (i.e. `totalBytesExpectedToWrite > 0`).
    ///
    /// - Parameters:
    ///   - session: The URL session managing the download.
    ///   - downloadTask: The download task that received data.
    ///   - bytesWritten: Bytes written since the last callback.
    ///   - totalBytesWritten: Cumulative bytes written so far.
    ///   - totalBytesExpectedToWrite: Total expected bytes, or -1 if unknown.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Skip progress updates when the server doesn't provide Content-Length
        guard totalBytesExpectedToWrite > 0 else { return }

        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        DispatchQueue.main.async {
            self.progressBar.isIndeterminate = false
            self.progressBar.minValue        = 0
            self.progressBar.maxValue        = 1
            self.progressBar.doubleValue     = fraction
        }
    }

    // MARK: - URLSessionDownloadDelegate — Completion

    /// Called when the download finishes successfully.
    ///
    /// The downloaded file at `location` is ephemeral and will be deleted by
    /// the system after this method returns, so we immediately move it to a
    /// stable temporary path before beginning installation.
    ///
    /// - Parameters:
    ///   - session: The URL session managing the download.
    ///   - downloadTask: The completed download task.
    ///   - location: Temporary file URL where the downloaded DMG was saved.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Move the downloaded DMG to a known temp path — the system-provided
        // `location` is deleted as soon as this delegate method returns
        let dmgPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SpaceRabbitUpdate.dmg")

        do {
            // Remove any leftover DMG from a previous failed attempt
            if FileManager.default.fileExists(atPath: dmgPath.path) {
                try FileManager.default.removeItem(at: dmgPath)
            }
            try FileManager.default.moveItem(at: location, to: dmgPath)
        } catch {
            reportFailure()
            return
        }

        // Transition to the installation phase: disable cancel and show
        // indeterminate progress while files are being copied.
        //
        // This block runs *synchronously* on the main thread so that by the
        // time install() starts below, Cancel and window-close (both handled
        // on the main thread) already see `isInstalling == true`. Dispatching
        // async here left a gap where the user could tear the session down
        // while files were being written.
        var cancelledMeanwhile = false
        DispatchQueue.main.sync {
            // The user may have cancelled in the instant between the download
            // completing and this block running — honor it and don't install.
            guard self.session != nil else {
                cancelledMeanwhile = true
                return
            }
            self.isInstalling                = true
            self.statusLabel.stringValue     = "Installing…"
            self.progressBar.isIndeterminate = true
            self.progressBar.startAnimation(nil)
            self.cancelButton.isEnabled      = false
        }

        if cancelledMeanwhile {
            try? FileManager.default.removeItem(at: dmgPath)
            return
        }

        // The install runs synchronously on the URLSession's background
        // delegate queue — this keeps the main thread free for UI updates
        install(dmgPath: dmgPath)
    }

    /// Called when the download task completes (with or without error).
    ///
    /// Only triggers error UI for genuine failures — user-initiated cancellation
    /// (via `invalidateAndCancel`) produces `NSURLErrorCancelled`, which we
    /// silently ignore.
    ///
    /// - Parameters:
    ///   - session: The URL session managing the download.
    ///   - task: The completed task.
    ///   - error: The error that caused the failure, or `nil` on success.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }

        // NSURLErrorCancelled means the user clicked "Cancel" — no error UI needed
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        reportFailure()
    }

    // MARK: - Install

    /// Mounts the DMG, copies the `.app` over the running bundle, then unmounts.
    ///
    /// This runs on a background thread (the URLSession delegate queue).
    /// On success, prompts the user to restart on the main thread.
    /// On failure, shows an error alert with "Try Again" / "Cancel".
    ///
    /// The installation steps:
    ///   1. Mount the DMG using `hdiutil attach` (no Finder browsing)
    ///   2. Locate the `.app` bundle inside the mounted volume
    ///   3. Copy the new `.app` to a staging path next to the current bundle
    ///   4. Verify the staged bundle's code signature (see `verifyStagedApp`)
    ///   5. Atomically swap the staged bundle into place via `replaceItemAt`
    ///   6. Clean up: unmount the DMG and delete the temp file
    ///   7. Prompt the user to restart
    ///
    /// - Parameter dmgPath: Path to the downloaded DMG in the temp directory.
    private func install(dmgPath: URL) {
        // Step 1: Mount the DMG in the background (no Finder window, no auto-open)
        let mountOutput = shell("/usr/bin/hdiutil",
                                ["attach", "-nobrowse", "-noautoopen", dmgPath.path]).output

        guard let mountPoint = parseMountPoint(from: mountOutput) else {
            cleanup(dmgPath: dmgPath, mountPoint: nil)
            reportFailure()
            return
        }

        // Step 2: Find the .app bundle inside the mounted volume.
        // There should be exactly one — GitHub release DMGs contain only the app.
        let volumeURL = URL(fileURLWithPath: mountPoint)
        guard let appEntry = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint))?
                .first(where: { $0.hasSuffix(".app") }) else {
            cleanup(dmgPath: dmgPath, mountPoint: mountPoint)
            reportFailure()
            return
        }

        let sourceApp = volumeURL.appendingPathComponent(appEntry)
        let destApp   = Bundle.main.bundleURL

        // Step 3: Copy the new .app to a staging location next to the current bundle.
        // Using the same parent directory ensures the copy and the subsequent rename
        // happen on the same volume, making the atomic swap cheap.
        let stagedApp = destApp.deletingLastPathComponent()
            .appendingPathComponent("Space Rabbit.staged.app")

        do {
            // Remove any leftover staged app from a previous failed install
            if FileManager.default.fileExists(atPath: stagedApp.path) {
                try FileManager.default.removeItem(at: stagedApp)
            }
            try FileManager.default.copyItem(at: sourceApp, to: stagedApp)
        } catch {
            cleanup(dmgPath: dmgPath, mountPoint: mountPoint)
            reportFailure()
            return
        }

        // Step 4: Verify the staged bundle's code signature before letting it
        // anywhere near the running bundle. The DMG came off the network — a
        // valid signature, our bundle identifier, and (for signed builds)
        // the same signing team are all required.
        guard verifyStagedApp(at: stagedApp) else {
            try? FileManager.default.removeItem(at: stagedApp)
            cleanup(dmgPath: dmgPath, mountPoint: mountPoint)
            reportFailure()
            return
        }

        // Step 5: Atomically swap the staged bundle into place.
        // `replaceItemAt` uses POSIX rename semantics — the swap is atomic from
        // the filesystem's perspective, so the app bundle is never in a half-written state.
        do {
            _ = try FileManager.default.replaceItemAt(destApp, withItemAt: stagedApp)
        } catch {
            try? FileManager.default.removeItem(at: stagedApp)
            cleanup(dmgPath: dmgPath, mountPoint: mountPoint)
            reportFailure()
            return
        }

        // Step 6: Clean up the mounted DMG and temp file
        cleanup(dmgPath: dmgPath, mountPoint: mountPoint)

        // Step 7: Ask the user to restart on the main thread
        DispatchQueue.main.async { self.showRestartPrompt() }
    }

    // MARK: - Signature Verification

    /// Verifies the staged update before it replaces the running bundle.
    ///
    /// Three checks, all required:
    ///   1. `codesign --verify --deep --strict` passes — the signature is
    ///      valid and the bundle unmodified (this also rejects completely
    ///      unsigned apps).
    ///   2. The code-signing identifier matches the running app's bundle ID.
    ///   3. The signing team matches the running app's — skipped when the
    ///      running build has no team (unsigned/ad-hoc development builds),
    ///      where the first two checks are the best available.
    ///
    /// - Parameter stagedApp: The staged `.app` bundle to verify.
    /// - Returns: `true` when the update is safe to swap into place.
    private func verifyStagedApp(at stagedApp: URL) -> Bool {
        guard shell("/usr/bin/codesign",
                    ["--verify", "--deep", "--strict", stagedApp.path]).status == 0
        else { return false }

        // `codesign -d` prints its details to stderr
        let stagedInfo  = shell("/usr/bin/codesign",
                                ["-d", "--verbose=2", stagedApp.path],
                                captureStderr: true).output
        let runningInfo = shell("/usr/bin/codesign",
                                ["-d", "--verbose=2", Bundle.main.bundlePath],
                                captureStderr: true).output

        /// First "name=value" occurrence of the field in codesign output.
        func field(_ name: String, in info: String) -> String? {
            for line in info.components(separatedBy: "\n")
            where line.hasPrefix("\(name)=") {
                return String(line.dropFirst(name.count + 1))
            }
            return nil
        }

        /// Team identifier, treating codesign's "not set" (ad-hoc) as none.
        func teamID(in info: String) -> String? {
            guard let team = field("TeamIdentifier", in: info),
                  team != "not set" else { return nil }
            return team
        }

        guard let identifier = field("Identifier", in: stagedInfo),
              identifier == Bundle.main.bundleIdentifier else { return false }

        if let runningTeam = teamID(in: runningInfo) {
            guard teamID(in: stagedInfo) == runningTeam else { return false }
        }

        return true
    }

    // MARK: - Post-Install Prompt

    /// Shows a "Restart Now / Later" dialog after successful installation.
    ///
    /// If the user clicks "Restart Now", spawns a detached shell process that
    /// waits for this process to exit, then re-opens the (now-updated) app bundle.
    /// This two-step approach is more reliable than calling `openApplication` +
    /// `terminate` back-to-back, where the process can die before the OS has
    /// processed the open request.
    ///
    /// If the user clicks "Later", the old version keeps running — the update
    /// will take effect the next time the app is launched.
    private func showRestartPrompt() {
        isInstalling = false
        window.close()

        let alert = NSAlert()
        alert.messageText      = "Update installed"
        alert.informativeText  = "Restart Space Rabbit to start using the new version."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Spawn a detached shell that waits for this process to exit, then
        // re-opens the (now-updated) bundle. The 0.5 s sleep gives the process
        // time to fully terminate before the OS tries to launch the new copy.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments     = ["-c", "sleep 0.5 && open \"$1\"", "--",
                               Bundle.main.bundleURL.path]
        try? proc.run()
        NSApp.terminate(nil)
    }

    // MARK: - Error Handling

    /// Shows an error alert with "Try Again" and "Cancel" options.
    ///
    /// Called from any point in the download/install pipeline where an
    /// unrecoverable error occurs. "Try Again" restarts the full flow
    /// from download using the same URL. "Cancel" dismisses everything
    /// but leaves the menu bar banner visible.
    ///
    /// Always dispatches to the main thread (safe to call from the
    /// URLSession background delegate queue).
    private func reportFailure() {
        DispatchQueue.main.async {
            self.isInstalling = false
            self.window.close()

            let alert = NSAlert()
            alert.messageText     = "Could not update Space Rabbit"
            alert.informativeText = "Something went wrong while downloading or installing the update."
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Cancel")

            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, let url = self.currentURL {
                self.start(downloadURL: url)
            }
            // "Cancel" — window stays closed, banner stays visible so the
            // user can retry from the menu bar whenever they want
        }
    }

    // MARK: - Helpers

    /// Cleans up after a download/install attempt by unmounting the DMG
    /// and deleting the temporary file.
    ///
    /// Safe to call with a `nil` mount point (e.g. if mounting failed).
    ///
    /// - Parameters:
    ///   - dmgPath: Path to the temporary DMG file to delete.
    ///   - mountPoint: The `/Volumes/…` mount point to detach, or `nil` if not mounted.
    private func cleanup(dmgPath: URL, mountPoint: String?) {
        if let mp = mountPoint {
            shell("/usr/bin/hdiutil", ["detach", mp, "-force"])
        }
        try? FileManager.default.removeItem(at: dmgPath)
    }

    /// Runs a command synchronously and returns its exit status and output.
    ///
    /// Used to invoke `hdiutil` (DMG mount/unmount) and `codesign`
    /// (update verification).
    ///
    /// - Parameters:
    ///   - executable: Absolute path to the executable (e.g. `/usr/bin/hdiutil`).
    ///   - args: Command-line arguments to pass.
    ///   - captureStderr: When `true`, stderr is captured into `output`
    ///     alongside stdout (`codesign -d` prints its details there);
    ///     otherwise stderr is discarded.
    /// - Returns: The exit status (`-1` if the process failed to launch)
    ///   and the captured output.
    @discardableResult
    private func shell(_ executable: String, _ args: [String],
                       captureStderr: Bool = false) -> (status: Int32, output: String) {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL  = URL(fileURLWithPath: executable)
        proc.arguments      = args
        proc.standardOutput = pipe
        proc.standardError  = captureStderr ? pipe : FileHandle.nullDevice

        do { try proc.run() } catch { return (-1, "") }

        // Drain the pipe BEFORE waiting for exit: waiting first deadlocks
        // as soon as the child fills the pipe buffer (~64 KB) and blocks
        // on write while we block on waitUntilExit
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Extracts the `/Volumes/…` mount point from `hdiutil attach` output.
    ///
    /// `hdiutil attach` prints one tab-separated row per partition. The mount
    /// point appears in the third column of the row containing `/Volumes/`:
    ///
    ///     /dev/disk4s1    Apple_HFS    /Volumes/Space Rabbit
    ///
    /// - Parameter output: Raw stdout from `hdiutil attach`.
    /// - Returns: The `/Volumes/…` path, or `nil` if parsing failed.
    private func parseMountPoint(from output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            let cols = line.components(separatedBy: "\t")
            if cols.count >= 3 {
                let candidate = cols[2].trimmingCharacters(in: .whitespaces)
                if candidate.hasPrefix("/Volumes/") { return candidate }
            }
        }
        return nil
    }
}
