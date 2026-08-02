/*
 * UpdateCheck.swift — GitHub release version checking
 *
 * Checks the GitHub Releases API for a newer version of Space Rabbit.
 *
 * Two entry points:
 *   - checkForUpdates()         — called once at launch (5 s delay), silently
 *                                 shows the tray banner when a newer DMG exists.
 *   - checkForUpdatesManually() — called from "Check Now…" in the settings
 *                                 window's Updates pane, reports the result via
 *                                 callbacks so the caller can show dialogs and
 *                                 drive the install flow.
 */

import Foundation

// MARK: - GitHub API

/// The GitHub API endpoint for the latest release of Space Rabbit.
private let kReleasesURL = "https://api.github.com/repos/Tahul/space-rabbit/releases/latest"

// MARK: - Version Comparison

/// Compares two semantic version strings (with optional "v" prefix).
///
/// Supports versions with any number of components (e.g. "1.2", "1.2.3", "2.0.0.1").
/// Missing components are treated as zero (e.g. "1.2" == "1.2.0").
///
/// - Parameters:
///   - remote: The version string from the GitHub release (e.g. "v1.3.0").
///   - local: The current app version (e.g. "1.2.0").
/// - Returns: `true` if `remote` is strictly newer than `local`.
private func isNewerVersion(_ remote: String, than local: String) -> Bool {
    let stripPrefix = { (s: String) -> String in s.hasPrefix("v") ? String(s.dropFirst()) : s }
    let toComponents = { (s: String) -> [Int] in
        stripPrefix(s).split(separator: ".").compactMap { Int($0) }
    }

    let remoteComponents = toComponents(remote)
    let localComponents  = toComponents(local)
    let maxCount         = max(remoteComponents.count, localComponents.count)

    for i in 0..<maxCount {
        let remoteValue = i < remoteComponents.count ? remoteComponents[i] : 0
        let localValue  = i < localComponents.count  ? localComponents[i]  : 0
        if remoteValue != localValue { return remoteValue > localValue }
    }

    return false
}

// MARK: - Shared Fetch

/// Result of a GitHub release fetch.
private enum ReleaseResult {
    case newer(downloadURL: String)
    case upToDate
    case error
}

/// Fetches the latest GitHub release, compares it to the running version,
/// and calls `completion` with the result on a background thread.
private func fetchRelease(_ completion: @escaping (ReleaseResult) -> Void) {
    guard let url = URL(string: kReleasesURL) else { completion(.error); return }

    URLSession.shared.dataTask(with: url) { data, _, networkError in
        guard networkError == nil,
              let data,
              let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag     = json["tag_name"] as? String,
              let assets  = json["assets"]   as? [[String: Any]],
              let dmg     = assets.first(where: {
                  ($0["name"] as? String)?.hasSuffix(".dmg") == true
              }),
              let downloadURL = dmg["browser_download_url"] as? String
        else {
            completion(.error)
            return
        }

        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        completion(isNewerVersion(tag, than: current) ? .newer(downloadURL: downloadURL) : .upToDate)
    }.resume()
}

// MARK: - Automatic Check (launch-time)

/// Fetches the latest GitHub release and, if a newer DMG exists, shows the
/// update banner in the menu bar dropdown.
///
/// Runs once, 5 seconds after launch, on a background URLSession thread.
/// The UI update is dispatched back to the main thread.
func checkForUpdates() {
    fetchRelease { result in
        guard case .newer(let downloadURL) = result else { return }
        DispatchQueue.main.async { gMenu?.showUpdateBanner(downloadURL: downloadURL) }
    }
}

// MARK: - Manual Check (user-triggered)

/// Fetches the latest GitHub release and reports the result via callbacks.
///
/// All callbacks are delivered on the **main thread**.
///
/// - Parameters:
///   - onFound:    Called with the DMG download URL when a newer version exists.
///   - onUpToDate: Called when the running version is already the latest.
///   - onError:    Called when the network request or JSON parsing fails.
func checkForUpdatesManually(onFound:    @escaping (_ downloadURL: String) -> Void,
                             onUpToDate: @escaping () -> Void,
                             onError:    @escaping () -> Void) {
    fetchRelease { result in
        DispatchQueue.main.async {
            switch result {
            case .newer(let url): onFound(url)
            case .upToDate:       onUpToDate()
            case .error:          onError()
            }
        }
    }
}
