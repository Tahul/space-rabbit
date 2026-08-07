/*
 * UpdateCheck.swift — GitHub release version checking
 *
 * Checks the GitHub Releases API for a newer version of Space Rabbit.
 *
 * Two entry points:
 *   - checkForUpdatesAutomatically() — called once at launch, silently shows the
 *                                     tray banner when a newer DMG exists.
 *                                     Throttled: when a check already ran less
 *                                     than an hour ago it skips the network
 *                                     entirely and restores the banner from the
 *                                     remembered release, so relaunching the app
 *                                     does not hammer the API. Only the network
 *                                     path is delayed — the cached one runs
 *                                     synchronously.
 *   - checkForUpdatesManually()      — called from "Check Now…" in the settings
 *                                     window's Updates pane, reports the result
 *                                     via callbacks so the caller can show
 *                                     dialogs and drive the install flow.
 */

import Foundation

// MARK: - GitHub API

/// The GitHub API endpoint for the latest release of Space Rabbit.
private let kReleasesURL = "https://api.github.com/repos/Tahul/space-rabbit/releases/latest"

// MARK: - Throttling

/// Minimum delay between two *automatic* update checks.
///
/// Manual checks from the Updates pane are never throttled.
private let kUpdateCheckInterval: TimeInterval = 3600

/// How long after launch the automatic check waits before hitting the network,
/// giving the app time to settle first.
///
/// Applies **only** when a request is actually going to be made: a throttled
/// launch reads the remembered release instead, which costs nothing and so has
/// no reason to make the user wait for the banner.
private let kUpdateCheckLaunchDelay: TimeInterval = 5

/// Records "now" as the moment of the last update check.
private func stampUpdateCheck() {
    UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate,
                              forKey: Defaults.lastUpdateCheck)
}

/// Whether enough time has passed since the last check to run another
/// automatic one.
///
/// A stamp in the future (system clock moved backwards) is treated as stale
/// so a bad clock cannot suppress checks forever.
private func isAutomaticCheckDue() -> Bool {
    guard let stamp = UserDefaults.standard.object(forKey: Defaults.lastUpdateCheck) as? Double
    else { return true }

    let elapsed = Date().timeIntervalSinceReferenceDate - stamp
    return elapsed < 0 || elapsed >= kUpdateCheckInterval
}

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

// MARK: - Pending Update Cache

/// Remembers a newer release across launches, so the menu bar banner reappears
/// on a relaunch that the throttle keeps from checking again.
private func storePendingUpdate(version: String, downloadURL: String) {
    UserDefaults.standard.set(version,     forKey: Defaults.pendingUpdateVersion)
    UserDefaults.standard.set(downloadURL, forKey: Defaults.pendingUpdateURL)
}

/// Forgets the remembered release — called as soon as a check reports the
/// running version is the latest (typically right after an update installed).
private func clearPendingUpdate() {
    UserDefaults.standard.removeObject(forKey: Defaults.pendingUpdateVersion)
    UserDefaults.standard.removeObject(forKey: Defaults.pendingUpdateURL)
}

/// The remembered release's DMG URL, or `nil` when nothing is pending.
///
/// The stored version is re-compared against the running one: an entry left
/// behind by a version the user has since installed by hand must not raise a
/// banner for an update that is already in place.
private func pendingUpdateDownloadURL() -> String? {
    let defaults = UserDefaults.standard

    guard let version     = defaults.string(forKey: Defaults.pendingUpdateVersion),
          let downloadURL = defaults.string(forKey: Defaults.pendingUpdateURL)
    else { return nil }

    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

    guard isNewerVersion(version, than: current) else {
        clearPendingUpdate()
        return nil
    }

    return downloadURL
}

// MARK: - Shared Fetch

/// Result of a GitHub release fetch.
private enum ReleaseResult {
    case newer(version: String, downloadURL: String)
    case upToDate
    case error
}

/// Fetches the latest GitHub release, compares it to the running version,
/// caches the outcome (see `Defaults.pendingUpdateVersion`) and calls
/// `completion` with the result on a background thread.
///
/// - Parameter bypassHTTPCache: When `true`, ignores any locally cached
///   response and goes to the network. The GitHub API sends
///   `Cache-Control: max-age=60`, so `URLSession`'s default policy would
///   otherwise answer a check made within a minute of a previous one from
///   the URL cache — acceptable for the launch check (throttled to once an
///   hour anyway), but not for a check the user explicitly asked for.
private func fetchRelease(bypassHTTPCache: Bool = false,
                          _ completion: @escaping (ReleaseResult) -> Void) {
    guard let url = URL(string: kReleasesURL) else { completion(.error); return }

    var request = URLRequest(url: url)
    if bypassHTTPCache { request.cachePolicy = .reloadIgnoringLocalCacheData }

    URLSession.shared.dataTask(with: request) { data, _, networkError in
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

        guard isNewerVersion(tag, than: current) else {
            clearPendingUpdate()
            completion(.upToDate)
            return
        }

        storePendingUpdate(version: tag, downloadURL: downloadURL)
        completion(.newer(version: tag, downloadURL: downloadURL))
    }.resume()
}

// MARK: - Automatic Check (launch-time)

/// Fetches the latest GitHub release and, if a newer DMG exists, shows the
/// update banner in the menu bar dropdown.
///
/// Called once at launch, from the main thread.
///
/// Skips the network request when a check (automatic or manual) already ran
/// less than `kUpdateCheckInterval` ago — quitting and relaunching the app is
/// cheap and must not turn into a burst of API requests. The banner still
/// shows in that case, from the release remembered by the last real check.
///
/// That cached path shows the banner **immediately**: it only reads
/// UserDefaults, so the `kUpdateCheckLaunchDelay` courtesy delay would serve no
/// purpose other than making the banner appear late. The network path keeps the
/// delay and runs on a background URLSession thread, dispatching its UI update
/// back to the main thread.
func checkForUpdatesAutomatically() {
    guard isAutomaticCheckDue() else {
        if let downloadURL = pendingUpdateDownloadURL() {
            gMenu?.showUpdateBanner(downloadURL: downloadURL)
        }
        return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + kUpdateCheckLaunchDelay) {
        stampUpdateCheck()

        fetchRelease { result in
            guard case .newer(_, let downloadURL) = result else { return }
            DispatchQueue.main.async { gMenu?.showUpdateBanner(downloadURL: downloadURL) }
        }
    }
}

// MARK: - Manual Check (user-triggered)

/// Fetches the latest GitHub release and reports the result via callbacks.
///
/// Always hits the network: neither the launch-time throttle nor the URL
/// cache applies, since the user explicitly asked for a fresh answer. It does
/// reset the automatic check's timer, and refreshes the remembered release.
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
    stampUpdateCheck()

    fetchRelease(bypassHTTPCache: true) { result in
        DispatchQueue.main.async {
            switch result {
            case .newer(_, let url): onFound(url)
            case .upToDate:       onUpToDate()
            case .error:          onError()
            }
        }
    }
}
