/*
 * Localization.swift — Localized string lookup
 *
 * Every user-visible string in Space Rabbit lives in a `.strings` table
 * inside `App/Resources/<lang>.lproj/`, never inline in Swift. Call sites
 * use `L("some.key")` (see below), which resolves against the bundle's
 * `Localizable` table.
 *
 * Language selection is handled entirely by the bundle loader: macOS picks
 * the `.lproj` matching the user's preferred language when Space Rabbit
 * ships one, and otherwise falls back to `CFBundleDevelopmentRegion` (en).
 * There is no in-app language setting and no manual locale plumbing.
 *
 * `make build` fails when a key is used but undeclared, declared but
 * unused, or present in one language and missing from another — see
 * `Tools/Localization/Validate.swift`. That means adding a string is
 * always a change to *every* `.lproj`, not just `en.lproj`.
 */

import Foundation

// MARK: - Lookup

/// Returns the localized string for `key`, formatted with `args`.
///
/// Keys must be written as string literals at the call site: the build-time
/// validator scans the sources for `L("…")` occurrences to cross-check them
/// against the `.strings` tables, and cannot see a key held in a variable.
///
/// Plural-sensitive keys live in `Localizable.stringsdict` instead of
/// `Localizable.strings` and are looked up through this same function; pass
/// the count as the argument driving the plural rule (see `stats.switches`).
///
/// - Parameters:
///   - key: Key into the bundle's `Localizable` table (e.g. `"menu.quit"`).
///   - args: Values substituted into the format specifiers of the localized
///     string, in the order the *English* string declares them. Translations
///     may reorder them using positional specifiers (`%1$@`, `%2$@`).
/// - Returns: The localized (and formatted) string, or `key` itself when no
///   table declares it — a state the build-time validator rules out.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)

    // Formatting an argument-less string would misread a literal "%" in the
    // translation as a format specifier
    guard !args.isEmpty else { return format }

    return String(format: format, locale: .current, arguments: args)
}

// MARK: - Duration Formatting

/// Formats a duration as a localized, correctly-pluralized string.
///
/// Delegates to `DateComponentsFormatter` rather than assembling unit names
/// from the `.strings` table: unit names and their plural forms then come
/// from the system for every language, and no translator has to supply them.
///
/// - Parameter seconds: Duration to format.
/// - Returns: A compact string using at most the two largest non-zero units
///   (e.g. "42 sec", "3 min", "1 hr, 20 min", "2 days, 5 hr").
func localizedDuration(_ seconds: Int) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits           = [.day, .hour, .minute, .second]
    formatter.unitsStyle             = .short
    formatter.maximumUnitCount       = 2
    formatter.zeroFormattingBehavior = .dropAll

    return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)"
}
