import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system, japanese = "ja", english = "en", korean = "ko"
    public var id: String { rawValue }
    public static func resolve(_ preference: AppLanguage, preferredLanguages: [String]? = nil) -> AppLanguage {
        guard preference == .system else { return preference }
        for identifier in preferredLanguages ?? Locale.preferredLanguages {
            switch identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
            case "ja": return .japanese
            case "en": return .english
            case "ko": return .korean
            default: continue
            }
        }
        return .english
    }
}

/// The source text is the stable key. Interpolated values are kept out of that key,
/// so names, URLs and other user data are never translated or parsed as a format.
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let key: String
    public let arguments: [String]
    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) { arguments.reserveCapacity(interpolationCount) }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"; arguments.append(String(describing: value))
        }
    }
}

public enum Localization {
    private static let lock = NSLock()
    private static var active: AppLanguage = .japanese
    public static var language: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return active }
        set { lock.lock(); active = AppLanguage.resolve(newValue); lock.unlock() }
    }
    public static let catalog: [String: [String: String]] = {
        // App bundles load their own copy. Never fall back to a developer's absolute
        // build path (or trap inside Bundle.module) when an installed app is damaged.
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        guard let url = bundle.url(forResource: "Localizations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return value
    }()
    public static func text(_ key: String, language: AppLanguage? = nil) -> String {
        let resolved = AppLanguage.resolve(language ?? self.language)
        return resolved == .japanese ? key : catalog[key]?[resolved.rawValue] ?? key
    }
    public static func render(_ message: LocalizedMessage, language: AppLanguage? = nil) -> String {
        let template = text(message.key, language: language)
        guard !message.arguments.isEmpty else { return template }
        // A single pass prevents a user value such as "{1}" being substituted again.
        let source = template as NSString
        var result = "", offset = 0
        for match in pattern.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: offset, length: match.range.location - offset))
            if let index = Int(source.substring(with: match.range(at: 1))), message.arguments.indices.contains(index) {
                result += message.arguments[index]
            } else { result += source.substring(with: match.range) }
            offset = NSMaxRange(match.range)
        }
        return result + source.substring(from: offset)
    }
    private static let pattern = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
}

public func L(_ message: LocalizedMessage) -> String { Localization.render(message) }
