// Validate.swift — build-time localization consistency check.
//
// Run by `make build` (target `verify-localizations`); a non-zero exit fails
// the build. Guards the invariant that makes shipping a second language safe:
// the set of keys is identical everywhere, and nothing in the code refers to
// a key that does not exist.
//
// Usage: swift Tools/Localization/Validate.swift <resources-dir> <sources-dir>
//
// Checks, in order:
//   1. Every .lproj holds the same table files as en.lproj (and parses).
//   2. Every table declares exactly the same keys in every language.
//   3. Format specifiers of a key match between English and each language
//      (as a multiset, so translations may reorder with %1$@ / %2$@).
//   4. Every `L("…")` key in the sources is declared in English, and every
//      declared key is used somewhere (dead keys are reported, not tolerated).
//
// Only en.lproj is required to exist; the other languages are whatever
// directories are present, so this stays correct as translations are added.

import Foundation

// MARK: - Constants

/// The development language, whose tables define the reference key set.
let kBaseLanguage = "en"

/// Table whose keys are consumed by Swift code via `L("…")`. Other tables
/// (e.g. InfoPlist) are read by macOS, so they get no code cross-check.
let kCodeTable = "Localizable"

// MARK: - Reporting

var errors: [String] = []

func fail(_ message: String) {
    errors.append(message)
}

// MARK: - Arguments

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 else {
    FileHandle.standardError.write(Data(
        "usage: Validate.swift <resources-dir> <sources-dir>\n".utf8))
    exit(2)
}
let resourcesDir = args[0]
let sourcesDir   = args[1]

// MARK: - Table Loading

/// A localization table: the keys declared by one file of one language.
struct Table {
    let keys:   Set<String>
    /// Format specifiers per key, in declaration order. Empty for
    /// `.stringsdict` tables, whose per-language structure differs by design.
    let format: [String: [String]]
}

/// Extracts the printf-style conversion specifiers from a format string.
///
/// Positional prefixes are dropped (`%1$@` → `@`) so a translation may
/// reorder arguments freely; `%%` is skipped as it prints a literal percent.
///
/// - Parameter value: The localized string to scan.
/// - Returns: Conversion characters in the order they appear.
func formatSpecifiers(in value: String) -> [String] {
    var specifiers: [String] = []
    let chars = Array(value)
    var i = 0

    while i < chars.count {
        guard chars[i] == "%" else { i += 1; continue }
        i += 1
        guard i < chars.count else { break }

        // Literal percent, not a specifier
        if chars[i] == "%" { i += 1; continue }

        // Skip the positional index, flags, width and precision
        while i < chars.count,
              chars[i].isNumber || "$.-+ #'".contains(chars[i]) { i += 1 }

        // Length modifiers (%ld, %lld, %zu) and the stringsdict variable form
        while i < chars.count, "lhqLzjt".contains(chars[i]) { i += 1 }

        guard i < chars.count else { break }
        specifiers.append(String(chars[i]))
        i += 1
    }
    return specifiers
}

/// Reads a `.strings` or `.stringsdict` file into a `Table`.
///
/// - Parameters:
///   - path: Absolute path to the table file.
///   - collectFormats: Whether to record format specifiers per key (only
///     meaningful for flat `.strings` tables).
/// - Returns: The parsed table, or `nil` after recording a parse error.
func loadTable(at path: String, collectFormats: Bool) -> Table? {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("\(path): cannot be read")
        return nil
    }

    let parsed: Any
    do {
        parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)
    } catch {
        // A syntax error here would silently degrade to showing raw keys at
        // runtime, so it has to break the build instead
        fail("\(path): not a valid strings file — \(error.localizedDescription)")
        return nil
    }

    guard let dict = parsed as? [String: Any] else {
        fail("\(path): expected a dictionary at the top level")
        return nil
    }

    var formats: [String: [String]] = [:]
    if collectFormats {
        for (key, value) in dict {
            guard let string = value as? String else {
                fail("\(path): key \"\(key)\" must map to a string")
                continue
            }
            formats[key] = formatSpecifiers(in: string)
        }
    } else {
        // Light structural check: a stringsdict entry is a dictionary built
        // around NSStringLocalizedFormatKey
        for (key, value) in dict {
            guard let entry = value as? [String: Any] else {
                fail("\(path): key \"\(key)\" must map to a dictionary")
                continue
            }
            if entry["NSStringLocalizedFormatKey"] == nil {
                fail("\(path): key \"\(key)\" is missing NSStringLocalizedFormatKey")
            }
        }
    }

    return Table(keys: Set(dict.keys), format: formats)
}

// MARK: - Language Discovery

/// Language codes of the `.lproj` directories under the resources directory.
func discoverLanguages() -> [String] {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: resourcesDir)) ?? []
    return entries
        .filter { $0.hasSuffix(".lproj") }
        .map    { String($0.dropLast(".lproj".count)) }
        .sorted()
}

let languages = discoverLanguages()

guard languages.contains(kBaseLanguage) else {
    FileHandle.standardError.write(Data(
        "==> ERROR: \(resourcesDir)/\(kBaseLanguage).lproj is missing\n".utf8))
    exit(1)
}

/// Table file names declared by the base language (e.g. `Localizable.strings`).
let tableFiles: [String] = {
    let baseDir = "\(resourcesDir)/\(kBaseLanguage).lproj"
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: baseDir)) ?? []
    return entries
        .filter { $0.hasSuffix(".strings") || $0.hasSuffix(".stringsdict") }
        .sorted()
}()

guard !tableFiles.isEmpty else {
    FileHandle.standardError.write(Data(
        "==> ERROR: no .strings tables in \(resourcesDir)/\(kBaseLanguage).lproj\n".utf8))
    exit(1)
}

// MARK: - Checks 1–3: Tables Across Languages

/// Loaded tables, keyed by table file name then language.
var tables: [String: [String: Table]] = [:]

for file in tableFiles {
    let collectFormats = file.hasSuffix(".strings")

    for language in languages {
        let path = "\(resourcesDir)/\(language).lproj/\(file)"

        guard FileManager.default.fileExists(atPath: path) else {
            // The whole point of the check: a language that never got the
            // new table (or lost one) must not ship
            fail("\(language).lproj/\(file): missing (declared by \(kBaseLanguage).lproj)")
            continue
        }
        if let table = loadTable(at: path, collectFormats: collectFormats) {
            tables[file, default: [:]][language] = table
        }
    }

    // Files present in a translation but unknown to the base language:
    // dead weight that no key set governs
    for language in languages where language != kBaseLanguage {
        let dir     = "\(resourcesDir)/\(language).lproj"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for entry in entries
        where (entry.hasSuffix(".strings") || entry.hasSuffix(".stringsdict"))
              && !tableFiles.contains(entry) {
            fail("\(language).lproj/\(entry): unknown table (not in \(kBaseLanguage).lproj)")
        }
    }

    guard let base = tables[file]?[kBaseLanguage] else { continue }

    for language in languages where language != kBaseLanguage {
        guard let translation = tables[file]?[language] else { continue }

        for key in base.keys.subtracting(translation.keys).sorted() {
            fail("\(language).lproj/\(file): key \"\(key)\" is not translated")
        }
        for key in translation.keys.subtracting(base.keys).sorted() {
            fail("\(language).lproj/\(file): key \"\(key)\" does not exist in \(kBaseLanguage)")
        }

        // Check 3: a translation that drops or invents a format specifier
        // crashes String(format:) or prints garbage
        for key in base.keys.intersection(translation.keys).sorted() {
            let expected = (base.format[key] ?? []).sorted()
            let actual   = (translation.format[key] ?? []).sorted()
            if expected != actual {
                fail("""
                     \(language).lproj/\(file): key "\(key)" has format specifiers \
                     \(actual.isEmpty ? "none" : actual.map { "%\($0)" }.joined(separator: " ")) \
                     but \(kBaseLanguage) declares \
                     \(expected.isEmpty ? "none" : expected.map { "%\($0)" }.joined(separator: " "))
                     """)
            }
        }
    }
}

// MARK: - Check 4: Keys Used By The Code

/// Strips `//` line comments and `/* … */` block comments from Swift source,
/// so a key mentioned in documentation is not mistaken for a real call site.
///
/// - Parameter source: Full text of a Swift file.
/// - Returns: The same text with comment bodies removed.
func stripComments(from source: String) -> String {
    var output = ""
    let chars  = Array(source)
    var i      = 0

    while i < chars.count {
        // String literal: copy verbatim so "//" inside it is preserved
        if chars[i] == "\"" {
            output.append(chars[i])
            i += 1
            while i < chars.count {
                if chars[i] == "\\", i + 1 < chars.count {
                    output.append(chars[i]); output.append(chars[i + 1])
                    i += 2
                    continue
                }
                output.append(chars[i])
                if chars[i] == "\"" || chars[i] == "\n" { i += 1; break }
                i += 1
            }
            continue
        }

        if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
            while i < chars.count, chars[i] != "\n" { i += 1 }
            continue
        }

        if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
            // Swift block comments nest
            var depth = 0
            while i < chars.count {
                if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    depth += 1; i += 2; continue
                }
                if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    depth -= 1; i += 2
                    if depth == 0 { break }
                    continue
                }
                i += 1
            }
            output.append(" ")
            continue
        }

        output.append(chars[i])
        i += 1
    }
    return output
}

/// Every `L("…")` key found in the Swift sources, mapped to the files using it.
func collectUsedKeys() -> [String: Set<String>] {
    var used: [String: Set<String>] = [:]

    let entries = (try? FileManager.default.contentsOfDirectory(atPath: sourcesDir)) ?? []
    let regex   = try! NSRegularExpression(pattern: #"(?<![\w.])L\(\s*"([^"\\]*)""#)

    for entry in entries.filter({ $0.hasSuffix(".swift") }).sorted() {
        guard let raw = try? String(contentsOfFile: "\(sourcesDir)/\(entry)",
                                    encoding: .utf8) else { continue }
        let source = stripComments(from: raw)
        let range  = NSRange(source.startIndex..., in: source)

        for match in regex.matches(in: source, options: [], range: range) {
            guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
            used[String(source[keyRange]), default: []].insert(entry)
        }
    }
    return used
}

let usedKeys = collectUsedKeys()

// Union of the flat table and the plural table: both answer to L("…")
let codeKeys: Set<String> = tableFiles
    .filter { $0.hasPrefix("\(kCodeTable).") }
    .reduce(into: Set<String>()) { result, file in
        result.formUnion(tables[file]?[kBaseLanguage]?.keys ?? [])
    }

for (key, files) in usedKeys.sorted(by: { $0.key < $1.key })
where !codeKeys.contains(key) {
    fail("\(files.sorted().joined(separator: ", ")): L(\"\(key)\") "
       + "is not declared in \(kBaseLanguage).lproj/\(kCodeTable).strings")
}

for key in codeKeys.subtracting(usedKeys.keys).sorted() {
    fail("\(kBaseLanguage).lproj/\(kCodeTable): key \"\(key)\" is never used — "
       + "remove it, or reference it as a literal L(\"\(key)\")")
}

// MARK: - Result

if errors.isEmpty {
    let languageList = languages.joined(separator: ", ")
    print("==> Localizations OK: \(codeKeys.count) keys × \(languages.count) "
        + "language(s) (\(languageList))")
    exit(0)
}

FileHandle.standardError.write(Data(
    "==> ERROR: \(errors.count) localization problem(s):\n".utf8))
for error in errors.sorted() {
    FileHandle.standardError.write(Data("      \(error)\n".utf8))
}
exit(1)
