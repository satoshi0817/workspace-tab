import Foundation
import CoreGraphics
import WorkspaceCore

// A dependency-free runner so the checks work with Apple's Command Line Tools,
// which do not include XCTest or Swift Testing. A failure exits nonzero.
struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
var assertions = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) throws {
    assertions += 1
    if !condition() { throw CheckFailure(description: "Line \(line): \(message)") }
}
func expectThrows(_ block: () throws -> Void, _ message: String) throws {
    do { try block() } catch { assertions += 1; return }
    throw CheckFailure(description: message)
}

let checks: [(String, () throws -> Void)] = [
    ("Localization resolves system languages and safely interpolates user values", {
        try expect(AppLanguage.resolve(.system,preferredLanguages:["fr-FR","ko-KR","en-US"]) == .korean,"Select the first supported preferred language")
        try expect(AppLanguage.resolve(.system,preferredLanguages:["ja_JP"]) == .japanese,"Support underscore regional identifiers")
        try expect(AppLanguage.resolve(.system,preferredLanguages:["fr-FR"]) == .english,"Unsupported languages fall back to English")
        try expect(AppLanguage.resolve(.korean,preferredLanguages:["ja"]) == .korean,"Explicit choice overrides system")
        try expect(Localization.catalog.count >= 779,"Translation resources are present")
        let placeholders=try NSRegularExpression(pattern:#"\{\d+\}"#)
        func tokens(_ text:String)->[String] {placeholders.matches(in:text,range:NSRange(text.startIndex...,in:text)).map{(text as NSString).substring(with:$0.range)}.sorted()}
        for (key,translations) in Localization.catalog {
            try expect(Set(translations.keys) == ["en","ko"],"Every key has both translations")
            for language in [AppLanguage.english,.korean] {
                let value=translations[language.rawValue]!
                try expect(!value.isEmpty && tokens(key) == tokens(value),"Translations preserve every placeholder: \(key)")
                try expect(Localization.text(key,language:language) == value,"Catalog lookup uses selected language")
            }
        }
        let workspace="Company {1} %@ 日本語",owner="한국어"
        let message:LocalizedMessage="作成先：\(workspace) / \(owner) のプライベート"
        try expect(Localization.render(message,language:.english) == "Destination: Private space of 한국어 in Company {1} %@ 日本語","Placeholder reordering never reinterprets user text")
        try expect(Localization.render("\(3)タブ",language:.korean) == "탭 3개","Numeric interpolation uses Korean word order")
        try expect(Localization.text("unknown key",language:.korean) == "unknown key","Missing translations have a safe source fallback")
        let previous=Localization.language
        defer {Localization.language=previous}
        var page=BrowserPage(url:"about:blank")
        Localization.language = .english
        try expect(page.displayTitle == "New tab","A new tab placeholder follows the current language")
        Localization.language = .korean
        try expect(page.displayTitle == "새 탭","A new tab placeholder changes without rewriting stored data")
        page.title="新しいタブ"
        try expect(page.displayTitle == "新しいタブ","Site titles must never be translated, even if they match a UI string")
        page.tabName="設定"
        try expect(page.displayTitle == "設定","Custom tab names must never be translated")
    }),
    ("Restoration uses unique identity hints and preserves ambiguity", {
        var a = WorkspaceTab(bundleID: "notion", windowTitle: "Same", name: "A", emoji: "A")
        var b = WorkspaceTab(bundleID: "notion", windowTitle: "Same", name: "B", emoji: "B")
        let first = WindowIdentity(bundleID: "notion", title: "Same", identifier: "1", session: "pid:launch")
        let second = WindowIdentity(bundleID: "notion", title: "Same", identifier: "2", session: "pid:launch")
        try expect(WindowRestoration.matches(tabs: [a,b], windows: [first,second]).isEmpty, "Duplicate titles without hints must stay saved and unbound")
        a.windowIdentity = first; b.windowIdentity = second
        let matched = WindowRestoration.matches(tabs: [a,b], windows: [second,first])
        try expect(matched[a.id] == 1 && matched[b.id] == 0, "Identity matching must ignore enumeration order")
        var restarted = second; restarted.session = "new-launch"
        var restartedA = first; restartedA.session = "new-launch"
        try expect(WindowRestoration.matches(tabs: [a,b], windows: [restarted,restartedA]).isEmpty, "Identifiers cannot cross process sessions")
        a.windowIdentity?.document = "https://example.test/pageA"
        var renamed = restartedA; renamed.title = "Renamed"; renamed.document = "https://example.test/pageA"
        try expect(WindowRestoration.matches(tabs: [a], windows: [renamed])[a.id] == 0, "A unique document survives a title and app-session change")
        let plain = WorkspaceTab(bundleID: "notion", windowTitle: "Unique")
        try expect(WindowRestoration.matches(tabs: [plain], windows: [WindowIdentity(bundleID: "notion", title: "Unique")])[plain.id] == 0, "Legacy unique titles still restore")
        try expect(WindowRestoration.matches(tabs: [plain], windows: [WindowIdentity(bundleID: "other", title: "Unique")]).isEmpty, "Never restore into another app")
    }),
    ("Tab layout preserves the shell across orientation and display changes", {
        let shell = CGRect(x: -1800, y: 25, width: 1200, height: 850)
        for layout in TabLayout.allCases {
            let content = layout.content(in: shell)
            let panel = layout.panel(beside: content)
            try expect(layout.shell(around: content) == shell, "Layout must round-trip the outer frame")
            try expect(content.union(panel) == shell, "Tab panel and app must share one perimeter")
            try expect(content.intersection(panel).isEmpty, "Tab panel must not cover the app content")
            try expect(layout == .top ? panel.minY - content.maxY == 4 : content.minX - panel.maxX == 4, "All layouts must leave a four-point gap")
        }
        try expect(TabLayout.leftIcons.leftInset == 60, "Icon rail reserves 56 points plus a 4-point gap")
        try expect(TabLayout.leftHover.leftInset == 12, "Hover rail reserves 8 points plus a 4-point gap")
        let hoverContent = TabLayout.leftHover.content(in: shell)
        var expanded = TabLayout.leftHover.panel(beside: hoverContent)
        expanded.size.width = 220
        try expect(expanded.minX == shell.minX && expanded.union(hoverContent) == shell, "Hover expansion must overlay without changing the outer frame")
        let top = TabLayout.top.content(in: shell)
        let left = TabLayout.left.content(in: TabLayout.top.shell(around: top))
        try expect(left.minX == shell.minX + 224 && left.height == shell.height, "Left layout reserves width rather than top height")
        try expect(TabLayout.top.content(in: TabLayout.left.shell(around: left)) == top, "Switching back must restore the content rectangle")
        let display = CGRect(x: 1800, y: -500, width: 1440, height: 2560)
        try expect(TabLayout.left.shell(around: TabLayout.left.content(in: display)) == display, "Maximize must fit portrait and negative-origin displays")
    }),
    ("Drag grouping commits only after dwell and mouse release", {
        let target = UUID()
        var dwell = DragDwell()
        try expect(dwell.update(target: target, holding: true, now: 0, delay: 1) == nil, "Entering cannot add a window")
        _ = dwell.update(target: target, holding: true, now: 0.9, delay: 1)
        try expect(!dwell.ready, "A short overlap must not arm")
        try expect(dwell.update(target: target, holding: true, now: 1.1, delay: 1) == nil && dwell.ready, "Holding only arms the target")
        try expect(dwell.update(target: target, holding: false, now: 1.2, delay: 1) == target, "Release commits an armed target")
        try expect(dwell.update(target: target, holding: false, now: 1.3, delay: 1) == nil, "One drag cannot commit twice")
    }),
    ("Leaving, changing target, and early release cancel drag grouping", {
        let a = UUID(), b = UUID()
        var dwell = DragDwell()
        _ = dwell.update(target: a, holding: true, now: 0, delay: 1)
        try expect(dwell.update(target: a, holding: false, now: 0.5, delay: 1) == nil, "Early release cannot group")
        _ = dwell.update(target: a, holding: true, now: 1, delay: 1)
        _ = dwell.update(target: a, holding: true, now: 2.1, delay: 1)
        _ = dwell.update(target: nil, holding: true, now: 2.2, delay: 1)
        try expect(!dwell.ready && dwell.candidate == nil, "Leaving cancels the armed target")
        _ = dwell.update(target: a, holding: true, now: 3, delay: 1)
        _ = dwell.update(target: a, holding: true, now: 4.1, delay: 1)
        _ = dwell.update(target: b, holding: true, now: 4.2, delay: 1)
        try expect(!dwell.ready, "Changing targets starts a new countdown")
        _ = dwell.update(target: b, holding: true, now: 5.3, delay: 1)
        try expect(dwell.update(target: a, holding: false, now: 5.4, delay: 1) == nil, "Releasing over another target cannot commit")
    }),
    ("Geometry tolerance ignores sub-pixel noise", {
        let a = CGRect(x: 10, y: 10, width: 800, height: 600)
        try expect(WorkspaceRules.framesNear(a, a.offsetBy(dx: 0.5, dy: 0.5)), "Sub-pixel noise should not trigger group-wide resizing")
        try expect(!WorkspaceRules.framesNear(a, a.offsetBy(dx: 10, dy: 0)), "An actual move must be recognized")
    }),
    ("Ambiguous Notion windows are never rebound", {
        try expect(WorkspaceRules.uniqueMatch(bundleID: "notion.id", title: "Home", candidates: [
            ("notion.id", "Home"), ("notion.id", "Home")
        ]) == nil, "An ambiguous title must require manual reconnect")
    }),
    ("Reconnect stays within the original app and workspace title", {
        try expect(WorkspaceRules.uniqueMatch(bundleID: "notion.id", title: "Work", candidates: [
            ("notion.id", "Personal"), ("com.browser", "Work")
        ]) == nil, "Cannot pick a different workspace or app")
        try expect(WorkspaceRules.uniqueMatch(bundleID: "notion.id", title: "Work", candidates: [
            ("com.browser", "Work"), ("notion.id", "Work")
        ]) == 1, "An exact unique match should reconnect")
    }),
    ("Keyboard cycling wraps in both directions", {
        let a = WorkspaceTab(bundleID: "notion.id", windowTitle: "A")
        let b = WorkspaceTab(bundleID: "notion.id", windowTitle: "B")
        try expect(WorkspaceRules.nextTab(in: [a,b], current: a.id, delta: -1) == b.id, "Previous must wrap")
        try expect(WorkspaceRules.nextTab(in: [a,b], current: b.id, delta: 1) == a.id, "Next must wrap")
        try expect(WorkspaceRules.nextTab(in: [], current: nil, delta: 1) == nil, "An empty group must not crash")
    }),
    ("Coordinates round-trip on negative and vertical displays", {
        for frame in [CGRect(x: -1400, y: 140, width: 1000, height: 700),
                      CGRect(x: 200, y: -1200, width: 900, height: 800),
                      CGRect(x: 1920, y: 800, width: 1200, height: 900)] {
            let converted = WorkspaceRules.appKitFrame(fromAX: frame, primaryTop: 1080)
            try expect(WorkspaceRules.axFrame(fromAppKit: converted, primaryTop: 1080) == frame, "AX and AppKit must invert")
        }
    }),
    ("A missing display leaves the window and strip reachable", {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let fitted = WorkspaceRules.fit(CGRect(x: 2500, y: -900, width: 1900, height: 1300), inside: visible)
        try expect(visible.contains(fitted), "A window cannot remain outside the visible screen")
        try expect(fitted.maxY + 42 <= visible.maxY, "The strip must remain visible")
        try expect(fitted.width == 1440, "An oversized window must fit")
    }),
    ("Custom names, image icons, pins, and order survive persistence", {
        let tab = WorkspaceTab(bundleID: "notion.id", windowTitle: "Changing page title", name: "会社", emoji: "🏢", iconFile: UUID().uuidString + ".png", color: "rose", pinned: true)
        let group = WorkspaceGroup(name: "仕事", tabs: [tab])
        let state = SavedState(groups: [group], selectedGroupID: group.id)
        let decoded = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state)).validated()
        try expect(decoded.groups == state.groups, "All presentation data must survive")
        try expect(decoded.groups[0].tabs[0].name == "会社", "Page titles cannot replace a custom name")
        try expect(decoded.selectedGroupID == group.id, "The selected group must survive")
    }),
    ("Restoring a detached window does not leave room for an absent tab bar", {
        let visible = CGRect(x: 0, y: 30, width: 1440, height: 870)
        try expect(WorkspaceRules.fit(visible, inside: visible, barHeight: 0, minimum: .zero) == visible,
                   "A previously maximized window must restore its full height")
        let small = CGRect(x: 50, y: 60, width: 180, height: 120)
        try expect(WorkspaceRules.fit(small, inside: visible, barHeight: 0, minimum: .zero) == small,
                   "Restoration must preserve small windows too")
    }),
    ("Maximized groups preserve their normal geometry across restart", {
        let normal = WindowRect(x: -1200, y: 150, width: 900, height: 650)
        let group = WorkspaceGroup(frame: WindowRect(x: -1600, y: 0, width: 1600, height: 950), normalFrame: normal)
        let state = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(SavedState(groups: [group]))).validated()
        try expect(state.groups[0].normalFrame == normal, "The original size cannot be lost after maximizing")
    }),
    ("Invalid backups cannot introduce duplicate identities", {
        let tab = WorkspaceTab(bundleID: "notion.id", windowTitle: "A")
        let state = SavedState(groups: [WorkspaceGroup(tabs: [tab]), WorkspaceGroup(tabs: [tab])])
        try expectThrows({ _ = try state.validated() }, "Duplicate identities must be rejected")
    }),
    ("Corrupt geometry and newer schemas are preserved, not loaded", {
        let state = SavedState(groups: [WorkspaceGroup(frame: WindowRect(x: 0, y: 0, width: -1, height: 400))])
        try expectThrows({ _ = try state.validated() }, "Negative sizes must be rejected")
        var newer = SavedState(groups: []); newer.version = 42
        try expectThrows({ _ = try newer.validated() }, "Newer schemas must not be silently overwritten")
    })
]
do {
    for (name, check) in checks { try check(); print("PASS \(name)") }
    print("\(checks.count) checks, \(assertions) assertions passed")
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
