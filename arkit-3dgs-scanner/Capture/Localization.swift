import Foundation

/// The app language is explicit, persisted, and independent of the device language.
nonisolated enum AppLanguage: String, CaseIterable, Sendable {
    case traditionalChinese = "zh-Hant"
    case english = "en"

    static let preferenceKey = "app.language"
    static func resolve(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .traditionalChinese
    }
    static var current: Self { resolve(UserDefaults.standard.string(forKey: preferenceKey)) }
    var locale: Locale { Locale(identifier: rawValue) }
    var nativeName: String { self == .traditionalChinese ? "繁體中文" : "English" }
}

/// Interpolation is translated as a complete sentence, before substituting values.
/// This also keeps printf templates available to existing String(format:) callers.
nonisolated struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]
    init(stringLiteral value: String) { key = value; arguments = [] }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        private let interpolated: Bool
        init(literalCapacity: Int, interpolationCount: Int) {
            interpolated = interpolationCount > 0
            key.reserveCapacity(literalCapacity)
        }
        mutating func appendLiteral(_ literal: String) {
            key += interpolated ? literal.replacingOccurrences(of: "%", with: "%%") : literal
        }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"; arguments.append(String(describing: value))
        }
    }
}

nonisolated enum L10n {
    private static let chineseBundle = localizedBundle(.traditionalChinese, in: .main)
    private static let englishBundle = localizedBundle(.english, in: .main)
    static var locale: Locale { AppLanguage.current.locale }

    static func localizedBundle(_ language: AppLanguage, in bundle: Bundle) -> Bundle {
        bundle.path(forResource: language.rawValue, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? bundle
    }

    static func text(_ message: LocalizedMessage) -> String {
        let language = AppLanguage.current
        return render(message, language: language,
                      bundle: language == .english ? englishBundle : chineseBundle)
    }

    static func render(_ message: LocalizedMessage, language: AppLanguage, bundle: Bundle) -> String {
        let template = bundle.localizedString(forKey: message.key, value: message.key, table: "Localizable")
        guard !message.arguments.isEmpty else { return template }
        return String(format: template, locale: language.locale,
                      arguments: message.arguments.map { $0 as NSString })
    }
}
