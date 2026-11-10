import AppKit
import SwiftUI
import WebKit
import WorkspaceCore

@MainActor enum LocalizationChecks {
    static func run(store:BrowserStore, engine:BrowserEngine) async throws {
        func expect(_ value:Bool,_ label:String) throws {
            guard value else {throw BrowserChecks.Failure.check(label)}
            print("PASS " + label)
        }
        let localization=AppLocalization.shared
        let original=localization.preference,oldMenu=NSApp.mainMenu
        let suite="WorkspaceTabs.localization-checks."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:700),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        defer {
            localization.preference=original;Localization.language = .japanese
            NSApp.mainMenu=oldMenu;window.contentView=nil;window.close()
            defaults.removePersistentDomain(forName:suite)
        }
        let bindingIDs=ShortcutPreferences.actions.map(\.id)
        let bindings=ShortcutPreferences.actions.map{ShortcutPreferences.shared.binding($0)}
        let workspaces=store.session.workspaces,profiles=store.session.profiles,favorites=store.favorites
        let navigationCount=engine.navigationStarts,dataStore=engine.webView.configuration.websiteDataStore
        _ = try await engine.webView.evaluateJavaScript("window.languageSentinel='draft {1} 日本語 한국어'; document.body.insertAdjacentHTML('beforeend','<input id=language-draft>'); document.getElementById('language-draft').value=window.languageSentinel")
        window.contentView=NSHostingView(rootView:BrowserRoot(store:store))
        for (language,title,query) in [(AppLanguage.english,"Settings…","language"),(.korean,"설정…","언어"),(.japanese,"設定…","言語")] {
            localization.preference=language
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds:100_000_000)
            let delegate=AppDelegate();delegate.createMenu()
            let settingsItem=NSApp.mainMenu?.items.first?.submenu?.items.first{$0.representedObject as? String == "settings"}
            try expect(settingsItem?.title == title && settingsItem?.keyEquivalent == ",","Localized native menu retains shortcut identity: \(language.rawValue)")
            try expect(HelpCatalog.topics.contains{$0.id == "language" && $0.matches(query)},"Help search uses selected language: \(language.rawValue)")
            try expect(ShortcutPreferences.actions.map(\.id) == bindingIDs && ShortcutPreferences.actions.map{ShortcutPreferences.shared.binding($0)} == bindings,"Language switching preserves shortcut bindings: \(language.rawValue)")
            try expect(ShortcutSettingsGroup.appTabs.actions.map(\.id) == ["previousWorkspace","nextWorkspace"] && !ShortcutSettingsGroup.other.actions.contains{$0.id == "previousWorkspace" || $0.id == "nextWorkspace"},"Shortcut settings groups use stable IDs in \(language.rawValue)")
            let sentinel=try await engine.webView.evaluateJavaScript("document.getElementById('language-draft').value === window.languageSentinel") as? Bool
            try expect(sentinel == true && engine.navigationStarts == navigationCount && engine.webView.configuration.websiteDataStore === dataStore && store.engine(engine.workspaceID,engine.pageID) === engine,"Language switching preserves live WebView, login profile and unsent input: \(language.rawValue)")
            try expect(store.session.workspaces == workspaces && store.session.profiles == profiles && store.favorites == favorites,"Language switching leaves user names and saved session untouched: \(language.rawValue)")
            let preference=AppLocalization(defaults:defaults);preference.preference=language
            try expect(AppLocalization(defaults:defaults).preference == language,"Language preference survives recreation: \(language.rawValue)")
        }
        defaults.set("unsupported",forKey:AppLocalization.preferenceKey)
        try expect(AppLocalization(defaults:defaults).preference == .system,"Unknown language preference falls back safely")
        defaults.removeObject(forKey:AppLocalization.preferenceKey)
        try expect(AppLocalization(defaults:defaults).preference == .system,"Existing installations without a language preference follow system")
        Localization.language = .korean
        try expect(NotionActions.localizedMessage("新しいAIチャットを開きました") == "새 AI 채팅을 열었습니다","Notion action notifications are localized outside the page script")
        try expect(NotionActions.localizedMessage("新規ページのボタンが見つかりません。Notionのサイドバーを表示して再実行してください").hasPrefix("새 페이지 버튼"),"Notion action errors localize the action and explanation")
        try expect(PresetIcons.shared.filtered(query:"폴더",category:"").contains{$0.id.contains("folder")},"Korean icon search finds folder presets")
        _ = try await engine.webView.evaluateJavaScript("document.getElementById('language-draft').remove(); delete window.languageSentinel")
    }
}
