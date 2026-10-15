import Foundation

private struct LocalizationAudit {
    private let root: URL
    private var failures: [String] = []
    private var en: [String: String] = [:]
    private var zhHans: [String: String] = [:]

    init(root: URL) {
        self.root = root
    }

    mutating func run() -> Int32 {
        loadResources()
        checkResourceParity()
        checkFormatPlaceholders()
        checkLiteralDecoding()
        checkSourceUIKeys()
        checkLanguageFallback()
        checkBundleLookupsAndPermissionMessages()

        if failures.isEmpty {
            print("LOCALIZATION PASS: resources, UI keys, format placeholders, and locale fallback.")
            return 0
        }
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        fputs("LOCALIZATION FAIL: \(failures.count) issue(s).\n", stderr)
        return 1
    }

    private mutating func loadResources() {
        en = loadStrings("en")
        zhHans = loadStrings("zh-Hans")
    }

    private mutating func loadStrings(_ language: String) -> [String: String] {
        let url = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8),
              let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let values = parsed as? [String: String] else {
            failures.append("cannot parse \(url.path) as a Localizable.strings dictionary")
            return [:]
        }

        let entryPattern = try! NSRegularExpression(pattern: #"(?m)^\s*"((?:\\.|[^"\\])*)"\s*="#)
        let nsContents = contents as NSString
        let matches = entryPattern.matches(in: contents, range: NSRange(location: 0, length: nsContents.length))
        var seen = Set<String>()
        var duplicates = Set<String>()
        for match in matches where match.numberOfRanges > 1 {
            let key = nsContents.substring(with: match.range(at: 1))
            if !seen.insert(key).inserted { duplicates.insert(key) }
        }
        for key in duplicates.sorted() {
            failures.append("\(language).Localizable.strings has duplicate key: \(key)")
        }
        print("\(language).Localizable.strings: \(values.count) parsed keys, \(duplicates.count) duplicate(s)")
        return values
    }

    private mutating func checkResourceParity() {
        let enKeys = Set(en.keys), zhKeys = Set(zhHans.keys)
        for key in zhKeys.subtracting(enKeys).sorted() {
            failures.append("English translation is missing key: \(key)")
        }
        for key in enKeys.subtracting(zhKeys).sorted() {
            failures.append("Simplified Chinese translation is missing key: \(key)")
        }
    }

    private mutating func checkFormatPlaceholders() {
        var checked = 0
        for key in Set(en.keys).intersection(zhHans.keys).sorted() {
            let enSignature = placeholderSignature(en[key]!)
            let zhSignature = placeholderSignature(zhHans[key]!)
            if !enSignature.isEmpty || !zhSignature.isEmpty { checked += 1 }
            if enSignature != zhSignature {
                failures.append("placeholder order/type differs for \(key): en [\(enSignature)] vs zh-Hans [\(zhSignature)]")
            }
        }
        print("Format placeholder signatures checked: \(checked)")
    }

    private func placeholderSignature(_ value: String) -> String {
        let pattern = #"%(?:([1-9][0-9]*)\$)?[-+ #0']*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?(hh|h|ll|l|L|z|j|t|q)?([@diuoxXfFeEgGaAcCsSpn])"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let nsValue = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
        let tokens: [(position: Int?, type: String)] = matches.map { match in
            let position = match.range(at: 1).location == NSNotFound
                ? nil : Int(nsValue.substring(with: match.range(at: 1)))
            let length = match.range(at: 2).location == NSNotFound
                ? "" : nsValue.substring(with: match.range(at: 2))
            let conversion = nsValue.substring(with: match.range(at: 3))
            return (position, "\(placeholderKind(conversion))\(length)")
        }

        let hasPositions = tokens.contains { $0.position != nil }
        guard hasPositions else { return tokens.map(\.type).joined(separator: ",") }
        guard tokens.allSatisfy({ $0.position != nil }) else { return "mixed positional/sequential" }
        return tokens.sorted { $0.position! < $1.position! }
            .map { "\($0.position!):\($0.type)" }.joined(separator: ",")
    }

    private func placeholderKind(_ conversion: String) -> String {
        switch conversion {
        case "@": return "object"
        case "d", "i": return "signed-int"
        case "u", "o", "x", "X": return "unsigned-int"
        case "f", "F", "e", "E", "g", "G", "a", "A": return "float"
        case "c", "C": return "character"
        case "s": return "cstring"
        case "p": return "pointer"
        case "n": return "count-pointer"
        default: return conversion
        }
    }

    private mutating func checkSourceUIKeys() {
        let sourceDirectory = root.appendingPathComponent("Sources/MoniView", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: sourceDirectory,
                                                                       includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "swift" }) else {
            failures.append("cannot read Sources/MoniView for localized UI key references")
            return
        }

        var keys = Set<String>()
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            keys.formUnion(localizedLiterals(in: source))
        }

        for key in keys.sorted() {
            let missingLanguages = [
                en[key] == nil ? "en" : nil,
                zhHans[key] == nil ? "zh-Hans" : nil
            ].compactMap { $0 }
            guard missingLanguages.isEmpty, let enValue = en[key], let zhValue = zhHans[key] else {
                failures.append("UI key missing from \(missingLanguages.joined(separator: ", ")) resources: \(key)")
                continue
            }
            if enValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || enValue == key {
                failures.append("English UI value is empty or untranslated for key: \(key)")
            }
            if zhValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("Simplified Chinese UI value is empty for key: \(key)")
            }
        }
        print("Source localization references checked: \(keys.count)")
    }

    private func localizedLiterals(in source: String) -> Set<String> {
        let markerPattern = #"\b(L10n\.(?:text|format)|Text|Button|Toggle|Picker|Window|QualityPreset|help|accessibilityLabel|settingsToggle|labeledPicker|labeledSlider|panelHeading|panelButton|informationMetric|presetButton|fpsButton)\s*\("#
        let markers = try! NSRegularExpression(pattern: markerPattern)
        let nsSource = source as NSString
        let calls = markers.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        var literals = Set<String>()

        for call in calls {
            guard call.numberOfRanges > 1 else { continue }
            let marker = nsSource.substring(with: call.range(at: 1))
            let firstArgumentOnly = marker.hasPrefix("L10n.")
            var index = NSMaxRange(call.range) - 1
            var depth = 0
            var inString = false
            var escaped = false
            var literalStart = 0
            var capture = true

            while index < nsSource.length {
                let unit = nsSource.character(at: index)
                if inString {
                    if escaped {
                        escaped = false
                    } else if unit == 92 {
                        escaped = true
                    } else if unit == 34 {
                        if capture && depth == 1 {
                            let body = nsSource.substring(with: NSRange(location: literalStart, length: index - literalStart))
                            if body.unicodeScalars.contains(where: isHanScalar) { literals.insert(decodedLiteral(body)) }
                        }
                        inString = false
                    }
                    index += 1
                    continue
                }

                if unit == 34 {
                    inString = true
                    literalStart = index + 1
                } else if unit == 40 {
                    depth += 1
                } else if unit == 41 {
                    depth -= 1
                    if depth == 0 { break }
                } else if unit == 44 && depth == 1 && firstArgumentOnly {
                    capture = false
                }
                index += 1
            }
        }
        return literals
    }

    /// Localization keys currently use ordinary Swift strings with JSON-compatible
    /// escapes. Decode those escapes once, rather than comparing source spelling
    /// (for example backslash-n) with Foundation's already-decoded resource keys.
    /// Preserve unsupported forms so they still fail the audit instead of being skipped.
    private func decodedLiteral(_ body: String) -> String {
        let data = Data(("\"" + body + "\"").utf8)
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String ?? body
    }

    private mutating func checkLiteralDecoding() {
        let cases: [(String, String)] = [
            (#"中文\n下一行"#, "中文\n下一行"),
            (#"中文\\n"#, #"中文\n"#),
            (#"中文\"引用\""#, "中文\"引用\""),
            (#"中文\u{4E2D}"#, #"中文\u{4E2D}"#)
        ]
        for (source, expected) in cases where decodedLiteral(source) != expected {
            failures.append("localized literal escape decoding differs for \(source)")
        }
        print("Localized literal escape cases checked: \(cases.count)")
    }

    private func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) ||
        (0x4E00...0x9FFF).contains(scalar.value) ||
        (0xF900...0xFAFF).contains(scalar.value)
    }

    private mutating func checkLanguageFallback() {
        let infoURL = root.appendingPathComponent("Resources/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = raw as? [String: Any],
              let supported = info["CFBundleLocalizations"] as? [String] else {
            failures.append("cannot read CFBundleLocalizations from Resources/Info.plist")
            return
        }

        let expected = Set(["en", "zh-Hans"])
        guard Set(supported) == expected else {
            failures.append("CFBundleLocalizations should match the audited en/zh-Hans resources; found \(supported)")
            return
        }
        let resourceDirectory = root.appendingPathComponent("Resources", isDirectory: true)
        let resourceLocalizations = (try? FileManager.default.contentsOfDirectory(atPath: resourceDirectory.path))?
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) } ?? []
        if Set(resourceLocalizations) != Set(supported) {
            failures.append("CFBundleLocalizations \(supported) does not match resource folders \(resourceLocalizations)")
        }

        let cases: [([String], String)] = [
            (["zh-Hans", "zh-Hant", "en"], "zh-Hans"),
            (["zh-Hant", "zh-Hans", "en"], "zh-Hans"),
            (["zh-Hant", "en"], "en"),
            (["zh-Hans-CN", "zh-Hant-TW", "en-US"], "zh-Hans"),
            (["zh-Hant-TW", "en-US"], "en"),
            (["en", "zh-Hans"], "en"),
            (["fr", "en"], "en"),
            ([], "en")
        ]
        for (preferences, expectedLanguage) in cases {
            let selected = Bundle.preferredLocalizations(from: supported, forPreferences: preferences).first
            if selected != expectedLanguage {
                failures.append("language fallback for \(preferences) selected \(selected ?? "nil"), expected \(expectedLanguage)")
            }
        }
        print("Language fallback checked: \(cases.count) preference orders; zh-Hans wins when listed, zh-Hant-only falls through to en.")
    }

    private mutating func checkBundleLookupsAndPermissionMessages() {
        let permissionKeys = ["NSCameraUsageDescription", "NSMicrophoneUsageDescription"]
        for (language, strings) in [("en", en), ("zh-Hans", zhHans)] {
            let directory = root.appendingPathComponent("Resources/\(language).lproj")
            guard let bundle = Bundle(url: directory) else {
                failures.append("cannot load \(language) resource bundle")
                continue
            }
            for (key, value) in strings {
                if bundle.localizedString(forKey: key, value: "__missing__", table: "Localizable") != value {
                    failures.append("Foundation bundle lookup differs for \(language): \(key)")
                }
            }
            for key in permissionKeys {
                let value = bundle.localizedString(forKey: key, value: "__missing__", table: "InfoPlist")
                if value == "__missing__" || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    failures.append("missing \(language) permission message: \(key)")
                }
            }
        }
        print("Foundation bundle lookups checked: \(en.count + zhHans.count) UI values and 4 permission messages.")
    }
}

@main
private enum LocalizationTests {
    static func main() {
        guard let path = CommandLine.arguments.dropFirst().first else {
            fputs("Usage: localization-tests <repository-root>\n", stderr)
            exit(2)
        }
        var audit = LocalizationAudit(root: URL(fileURLWithPath: path, isDirectory: true))
        exit(audit.run())
    }
}
