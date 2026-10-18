import Foundation

public var localizationLocale: Locale {
    let language = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
    let region = Locale.current.region?.identifier ?? (language == "zh" ? "CN" : "US")
    return Locale(identifier: "\(language)_\(region)")
}

/// Keeps interpolated values separate from the translation key.
public struct LocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]

    public init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) {
            key += literal.replacingOccurrences(of: "%", with: "%%")
        }

        public mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append(String(describing: value))
        }
    }
}

public func localized(_ text: LocalizedText) -> String {
    let format = localizedText(text.key)
    guard !text.arguments.isEmpty else { return format }
    return String(format: format, locale: localizationLocale, arguments: text.arguments)
}

/// Chinese remains the stable source language; other system languages use English.
public func localizedText(_ key: String) -> String {
    if Locale.preferredLanguages.first?.hasPrefix("zh") == true { return key }
    for table in ["App", "Core"] {
        if let value = LocalizationResources.english?.localizedString(forKey: key, value: nil, table: table), value != key {
            return value
        }
    }
    return key
}

private enum LocalizationResources {
    static let english: Bundle? = {
        let name = "MacEven_MacEvenCore"
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: "bundle"),
            Bundle.main.bundleURL.appendingPathComponent(name + ".bundle"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(name + ".bundle")
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: candidate), let path = bundle.path(forResource: "en", ofType: "lproj") {
                return Bundle(path: path)
            }
        }
        return nil
    }()
}
