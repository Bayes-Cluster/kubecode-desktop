import Foundation

private struct StringsData: Decodable {
    struct Entry: Decodable {
        let key: String
    }

    let tables: [String: [Entry]]
}

private enum ValidationError: LocalizedError {
    case invalidArguments
    case invalidCatalog(String)
    case noMetadata(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "usage: apple-localization-validator <metadata-directory> <english.strings> <zh-Hans.strings>"
        case let .invalidCatalog(path):
            "Localization catalog is not a string dictionary: \(path)"
        case let .noMetadata(path):
            "No compiler .stringsdata files found under: \(path)"
        }
    }
}

private func loadCatalog(at path: String) throws -> [String: String] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard let catalog = propertyList as? [String: String] else {
        throw ValidationError.invalidCatalog(path)
    }
    return catalog
}

private func compiledKeys(in directory: String) throws -> Set<String> {
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw ValidationError.noMetadata(directory)
    }

    var keys: Set<String> = []
    var metadataCount = 0
    for case let fileURL as URL in enumerator where fileURL.pathExtension == "stringsdata" {
        let metadata = try JSONDecoder().decode(
            StringsData.self,
            from: Data(contentsOf: fileURL)
        )
        metadataCount += 1
        keys.formUnion(metadata.tables["Localizable", default: []].map(\.key))
    }
    guard metadataCount > 0 else {
        throw ValidationError.noMetadata(directory)
    }
    return keys
}

private let placeholderExpression = try! NSRegularExpression(
    pattern: #"%(?!%)(?:\d+\$)?[-+#0 ']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@diuoxXfFeEgGaAcCsSp]"#
)

private func placeholders(in value: String) -> [String] {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return placeholderExpression.matches(in: value, range: range).compactMap { match in
        guard let matchRange = Range(match.range, in: value) else { return nil }
        return value[matchRange]
            .replacingOccurrences(
                of: #"^%(?:\d+\$)?"#,
                with: "%",
                options: .regularExpression
            )
    }.sorted()
}

private func describe(_ keys: Set<String>) -> String {
    keys.sorted().map { "  - \($0.debugDescription)" }.joined(separator: "\n")
}

private func validate(
    compiled: Set<String>,
    english: [String: String],
    simplifiedChinese: [String: String]
) -> [String] {
    let englishKeys = Set(english.keys)
    let chineseKeys = Set(simplifiedChinese.keys)
    var failures: [String] = []

    let missingEnglish = compiled.subtracting(englishKeys)
    if !missingEnglish.isEmpty {
        failures.append("Missing English keys:\n\(describe(missingEnglish))")
    }

    let missingChinese = compiled.subtracting(chineseKeys)
    if !missingChinese.isEmpty {
        failures.append("Missing Simplified Chinese keys:\n\(describe(missingChinese))")
    }

    let staleEnglish = englishKeys.subtracting(compiled)
    if !staleEnglish.isEmpty {
        failures.append("English keys not emitted by the compiler:\n\(describe(staleEnglish))")
    }

    let staleChinese = chineseKeys.subtracting(compiled)
    if !staleChinese.isEmpty {
        failures.append("Simplified Chinese keys not emitted by the compiler:\n\(describe(staleChinese))")
    }

    for key in compiled.sorted() {
        let expected = placeholders(in: key)
        for (language, catalog) in [("English", english), ("Simplified Chinese", simplifiedChinese)] {
            guard let value = catalog[key] else { continue }
            if value.isEmpty {
                failures.append("\(language) value is empty for \(key.debugDescription)")
            }
            let actual = placeholders(in: value)
            if expected != actual {
                failures.append(
                    "\(language) placeholders differ for \(key.debugDescription): "
                        + "expected \(expected), found \(actual)"
                )
            }
        }
    }

    return failures
}

do {
    guard CommandLine.arguments.count == 4 else {
        throw ValidationError.invalidArguments
    }
    let metadataDirectory = CommandLine.arguments[1]
    let englishPath = CommandLine.arguments[2]
    let simplifiedChinesePath = CommandLine.arguments[3]
    let compiled = try compiledKeys(in: metadataDirectory)
    let english = try loadCatalog(at: englishPath)
    let simplifiedChinese = try loadCatalog(at: simplifiedChinesePath)
    let failures = validate(
        compiled: compiled,
        english: english,
        simplifiedChinese: simplifiedChinese
    )

    if failures.isEmpty {
        print(
            "Localization catalogs valid: \(compiled.count) compiler keys, "
                + "English \(english.count), Simplified Chinese \(simplifiedChinese.count)."
        )
    } else {
        fputs(failures.joined(separator: "\n\n") + "\n", stderr)
        exit(EXIT_FAILURE)
    }
} catch {
    fputs("Localization validation failed: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
