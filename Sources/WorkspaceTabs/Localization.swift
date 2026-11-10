import SwiftUI
import WorkspaceCore

@MainActor final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    static let changed = Notification.Name("WorkspaceTabsLanguageChanged")
    static let preferenceKey = "interfaceLanguage"
    private let defaults: UserDefaults
    @Published var preference: AppLanguage {
        didSet {
            guard oldValue != preference else { return }
            defaults.set(preference.rawValue, forKey: Self.preferenceKey)
            Localization.language = resolved
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }
    var resolved: AppLanguage { AppLanguage.resolve(preference) }
    var locale: Locale { Locale(identifier: resolved.rawValue) }
    var safeModeNextLaunch:Bool {
        get {defaults.bool(forKey:"safeModeNextLaunch")}
        set {defaults.set(newValue,forKey:"safeModeNextLaunch")}
    }
    init(defaults: UserDefaults? = nil) {
        let environment = ProcessInfo.processInfo.environment
        if let defaults { self.defaults = defaults }
        else if let directory = environment["WORKSPACE_TABS_UI_CHECK_DIRECTORY"] {
            self.defaults = UserDefaults(suiteName: "com.ssuzuki.WorkspaceTabs.QA." + Data(directory.utf8).base64EncodedString())!
        } else if CommandLine.arguments.contains(where: { $0.hasSuffix("-checks") }) {
            self.defaults = UserDefaults(suiteName: "com.ssuzuki.WorkspaceTabs.checks.\(ProcessInfo.processInfo.processIdentifier)")!
        } else { self.defaults = .standard }
        preference = AppLanguage(rawValue: self.defaults.string(forKey: Self.preferenceKey) ?? "system") ?? .system
        if defaults == nil, CommandLine.arguments.contains(where: { $0.hasSuffix("-checks") }) {
            preference = .japanese // Existing diagnostic fixtures have a stable language.
        }
        Localization.language = resolved
    }
}

struct LanguagePicker: View {
    @ObservedObject private var localization = AppLocalization.shared
    var body: some View {
        Picker(L("言語"), selection: $localization.preference) {
            Text(L("システム")).tag(AppLanguage.system)
            Text("日本語").tag(AppLanguage.japanese)
            Text("English").tag(AppLanguage.english)
            Text("한국어").tag(AppLanguage.korean)
        }.accessibilityIdentifier("interface-language")
    }
}
