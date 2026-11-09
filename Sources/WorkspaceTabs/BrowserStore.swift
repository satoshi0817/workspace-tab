import AppKit
import SwiftUI
import WebKit
import Network
import WorkspaceCore

struct PageReference: Codable, Equatable, Identifiable {
    var workspaceID: UUID
    var pageID: UUID
    var id: UUID { pageID }
}
@MainActor final class BrowserStore: ObservableObject {
    @Published var session = BrowserSession()
    @Published var networkOffline=false
    @Published var recentCandidates:[PageReference]=[]
    @Published var recentIndex=0
    var recentPages:[PageReference]=[]
    var selectionRevision:UInt=0
    var selectionWorkQueued=false
    var panelFocus:PanelFocus?
    var networkMonitor:NWPathMonitor?
    var responsivenessProbe:MainThreadProbe?
    var loadedEngines:[BrowserEngine] {Array(engines.values)}

    @Published var worksets:[Workset]=[]
    @Published var pendingExternalURL:String? {willSet {if newValue != nil && pendingExternalURL == nil {capturePanelFocus()}}}
    let timings=TimingLog()
    var pendingDisplay:[UUID:Double]=[:]
    func engineIfLoaded(_ pageID:UUID)->BrowserEngine? {engines[pageID]}
    func pageID(for webView:WKWebView)->UUID? {engines.first{$0.value.webView === webView}?.key}

    lazy var notion=NotionLibrary(store:self)
    lazy var linkRouting=NotionLinkRouting(directory:directory)
    @Published var split: PageReference?
    @Published var detachedWorkspaceIDs: Set<UUID> = []
    var detachedControllers: [UUID: DetachedWorkspaceController] = [:]
    @Published var error: String?
    @Published var notice: String?
    var noticeIsError=false
    var notionCreationMenu:NotionCreationMenu?
    @Published var newTabRequest:PageReference?
    @Published var workspaceHintsVisible=false
    var workspaceHintHold=WorkspaceShortcutHold()
    var workspaceHintTask:Task<Void,Never>?
    var workspaceHintsSuspended=false
    @Published var focusedPage: PageReference?
    private var noticeID=UUID()
    var commandPage: PageReference? {
        if let focusedPage,detachedWorkspaceIDs.contains(focusedPage.workspaceID),let pageID=workspace(focusedPage.workspaceID)?.selectedPageID {
            return PageReference(workspaceID:focusedPage.workspaceID,pageID:pageID)
        }
        let left=selected.flatMap { w in w.selectedPageID.map { PageReference(workspaceID:w.id,pageID:$0) } }
        if let focusedPage, page(focusedPage) != nil, focusedPage == left || focusedPage == split || detachedWorkspaceIDs.contains(focusedPage.workspaceID) {return focusedPage}
        return left
    }
    func notify(_ message: String,isError:Bool=false) {
        noticeIsError=isError
        let id=UUID();noticeID=id;notice=message
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { [weak self] in if self?.noticeID == id {self?.notice=nil} }
    }
    func copyPageURL(to pasteboard:NSPasteboard = .general) {
        guard let ref=commandPage, let page=page(ref) else {return}
        let value=engine(ref.workspaceID,ref.pageID)?.webView.url?.absoluteString ?? page.url
        pasteboard.clearContents()
        if pasteboard.setString(value,forType:.string) {notify("URLをコピーしました")}
    }
    func trackClick(_ event:NSEvent) {
        guard let eventWindow=event.window,
              eventWindow === window || detachedControllers.values.contains(where: {$0.window === eventWindow}),
              let content=eventWindow.contentView else {return}
        let point=content.convert(event.locationInWindow,from:nil)
        guard let hit=content.hitTest(point) else {return}
        for engine in engines.values where hit === engine.webView || hit.isDescendant(of:engine.webView) {
            focusedPage=PageReference(workspaceID:engine.workspaceID,pageID:engine.pageID);selectionChanged();break
        }
    }
    @Published var onboardingPresented=false
    private(set) var firstLaunch=false
    @Published var showSettings = false {willSet {if newValue && !showSettings {capturePanelFocus()}}}
    @Published var helpPresented = false {willSet {if newValue && !helpPresented {capturePanelFocus()}}}
    @Published var editingBrowserTab: PageReference? {willSet {if newValue != nil && editingBrowserTab == nil {capturePanelFocus()}}}
    @Published var editingWorkspace: UUID? {willSet {if newValue != nil && editingWorkspace == nil {capturePanelFocus()}}}
    @Published var addressFocus = UUID()
    @Published var commandsPresented = false {willSet {if newValue && !commandsPresented {capturePanelFocus()}}}
    var commandTarget:PageReference?
    var previousWorkspaceID:UUID?
    @Published var searchForSplit = false
    @Published var searchPresented = false {willSet {if newValue && !searchPresented {capturePanelFocus()}}}
    @Published var favoritesPresented = false {willSet {if newValue && !favoritesPresented {capturePanelFocus()}}}
    @Published var favoriteDraft: FavoriteLink? {willSet {if newValue != nil && favoriteDraft == nil {capturePanelFocus()}}}
    @Published var migrationNotice = false
    @Published var hovered = false
    let directory: URL
    private var writable = true
    private var historyWarningShown=false
    private var lastPersistedSession:BrowserSession?
    private var lastPersistedData:Data?
    private lazy var historyArchive=SessionHistoryArchive(directory:directory)
    private(set) var persistenceWrites=0
    var lastLauncherIndex:LauncherIndex?
    lazy var launcherToken:String = loadLauncherToken()
    let iconCache=LocalIconCache()
    lazy var faviconCache=FaviconCache(directory:directory)
    var liveEngineCount:Int {engines.count}
    private var saveWork: DispatchWorkItem?
    private var timer: Timer?
    private var engines: [UUID: BrowserEngine] = [:]
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    private var closedPages: [(UUID, BrowserPage)] = []
    var window: NSWindow?
    var selected: BrowserWorkspace? { session.workspaces.first { $0.id == session.selectedWorkspaceID } }
    var selectedPage: BrowserPage? { selected.flatMap { w in w.pages.first { $0.id == w.selectedPageID } } }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorkspaceTabs")
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if let loaded=try SessionRecovery.load(directory:self.directory) {
                session=loaded.session
                if loaded.recovered {self.error="設定ファイルを直近の正常なバックアップから復元しました。元のファイルはRecoveryフォルダに保管しています。"}
            } else {
                let old = self.directory.appendingPathComponent("workspaces.json")
                firstLaunch = !FileManager.default.fileExists(atPath:old.path)
                if FileManager.default.fileExists(atPath: old.path) {
                    let native = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: old)).validated()
                    session = BrowserSession.migrate(native); migrationNotice = true
                    session.theme = UserDefaults.standard.string(forKey: "AppTheme") ?? "system"
                    let oldLayout = UserDefaults.standard.string(forKey: "TabLayout") ?? "left"
                    session.sidebarPosition = oldLayout == "top" ? "top" : "left"
                    session.sidebarMode = oldLayout == "leftIcons" ? "icons" : oldLayout == "leftHover" ? "hover" : "full"
                }
                if session.workspaces.isEmpty { addWorkspace(name: "Notion") }
                save()
            }
            if session.splitStateRecorded == true {
                if let wid=session.splitWorkspaceID,let pid=session.splitPageID {split=PageReference(workspaceID:wid,pageID:pid)}
            } else if let data = try? Data(contentsOf: self.directory.appendingPathComponent("browser-split.json")),
               let ref = try? JSONDecoder().decode(PageReference.self, from: data), page(ref) != nil { split = ref }
        } catch {
            writable = false
            self.error = "設定を読み込めませんでした。元ファイルは保持しています。\n\(error.localizedDescription)"
        }
        try? LegacyPagePreviewCleanup.remove(in:self.directory)
        loadWorksets()
        applyTheme()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapshot(); self?.save(); self?.pollNotionWorkspace() }
        }
        timer?.tolerance=1
    }
    func profile(_ id: UUID) -> LoginProfile? { session.profiles.first { $0.id == id } }
    func workspace(_ id: UUID) -> BrowserWorkspace? { session.workspaces.first { $0.id == id } }
    func page(_ ref: PageReference) -> BrowserPage? { workspace(ref.workspaceID)?.pages.first { $0.id == ref.pageID } }
    func dataStore(_ id: UUID) -> WKWebsiteDataStore {
        if let store = dataStores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id); dataStores[id] = store; return store
    }
    func engine(_ workspaceID: UUID, _ pageID: UUID, configuration: WKWebViewConfiguration? = nil, load: Bool = true) -> BrowserEngine? {
        if let engine = engines[pageID],engine.workspaceID == workspaceID { return engine }
        guard let workspace = workspace(workspaceID), let page = workspace.pages.first(where: { $0.id == pageID }) else { return nil }
        let engine = BrowserEngine(store: self, workspace: workspace, page: page, configuration: configuration)
        engines[pageID] = engine
        if load, page.isStartPage != true, let url = BrowserAddress.url(page.url) { engine.webView.load(URLRequest(url: url)) }
        return engine
    }
    func selectWorkspace(_ id: UUID) {
        defer {selectionChanged()}
        if let pid=workspace(id)?.selectedPageID {beginDisplay(pid)}
        guard workspace(id) != nil else { return }
        let current=commandPage?.workspaceID ?? session.selectedWorkspaceID
        if current != id {previousWorkspaceID=current}
        session.selectedWorkspaceID = id
        focusedPage=nil
        if let detached=detachedControllers[id] {detached.window.makeKeyAndOrderFront(nil);focusedPage=selectedPage.map {PageReference(workspaceID:id,pageID:$0.id)}}
        if split?.workspaceID == id && split?.pageID == selectedPage?.id { split = nil }
        changed()
    }
    func cycleWorkspace(_ offset:Int) {
        let workspaces=session.workspaces
        guard !workspaces.isEmpty else{return}
        let current=commandPage?.workspaceID ?? session.selectedWorkspaceID
        let index=workspaces.firstIndex{$0.id == current} ?? 0
        let next=((index+offset)%workspaces.count+workspaces.count)%workspaces.count
        selectWorkspace(workspaces[next].id)
    }
    func selectPage(_ pageID: UUID, in workspaceID: UUID) {
        defer {selectionChanged()}
        beginDisplay(pageID)
        guard let i = session.workspaces.firstIndex(where: { $0.id == workspaceID }), session.workspaces[i].pages.contains(where: { $0.id == pageID }) else { return }
        session.workspaces[i].selectedPageID = pageID
        revealTabGroup(pageID,in:workspaceID)
        if split?.pageID == pageID && session.selectedWorkspaceID == workspaceID { split = nil }
        changed()
    }
    @discardableResult func addWorkspace(name: String = "新しいアプリ", url: String = "https://app.notion.com") -> UUID {
        let profile = LoginProfile(name: name + " のログイン環境")
        session.profiles.append(profile)
        let workspace = BrowserWorkspace(name: name, profileID: profile.id, url: url)
        session.workspaces.append(workspace); session.selectedWorkspaceID = workspace.id
        changed(); return workspace.id
    }
    @discardableResult func addPage(to workspaceID: UUID? = nil, url: String? = nil, configuration: WKWebViewConfiguration? = nil, load:Bool = true, groupID:UUID? = nil, startPage:Bool = false) -> BrowserEngine? {
        defer {selectionChanged()}
        guard let id = workspaceID ?? session.selectedWorkspaceID, let i = session.workspaces.firstIndex(where: { $0.id == id }) else { return nil }
        var page = BrowserPage(url: startPage ? "about:blank" : (url ?? session.workspaces[i].homeURL))
        page.isStartPage=startPage ? true:nil
        page.groupID=groupID ?? session.workspaces[i].visibleGroupID
        session.workspaces[i].visibleTabGroupID=page.groupID
        session.workspaces[i].pages.append(page); session.workspaces[i].selectedPageID = page.id
        changed()
        return engine(id, page.id, configuration: configuration, load: configuration == nil && load)
    }
    func leaveStartPage(_ workspaceID:UUID,_ pageID:UUID,url:URL) {
        guard let i=session.workspaces.firstIndex(where:{$0.id == workspaceID}),
              let j=session.workspaces[i].pages.firstIndex(where:{$0.id == pageID}),
              session.workspaces[i].pages[j].isStartPage == true else{return}
        session.workspaces[i].pages[j].isStartPage=nil
        session.workspaces[i].pages[j].url=BrowserAddress.savedURL(url)
        changed()
    }
    func closePage(_ pageID: UUID, in workspaceID: UUID) {
        defer {selectionChanged()}
        guard let i = session.workspaces.firstIndex(where: { $0.id == workspaceID }), let j = session.workspaces[i].pages.firstIndex(where: { $0.id == pageID }) else { return }
        guard session.workspaces[i].pages[j].pinned != true else {notify("ピン留めを解除してから閉じてください");return}
        closedPages.append((workspaceID, session.workspaces[i].pages[j])); closedPages = Array(closedPages.suffix(20))
        engines.removeValue(forKey: pageID)?.dispose()
        session.workspaces[i].pages.remove(at: j)
        if session.workspaces[i].pages.isEmpty { session.workspaces[i].pages = [BrowserPage(url: session.workspaces[i].homeURL)] }
        if session.workspaces[i].selectedPageID == pageID {
            let next=visibleGroupPages(in:workspaceID).first ?? session.workspaces[i].pages[min(j,session.workspaces[i].pages.count-1)]
            session.workspaces[i].selectedPageID=next.id;revealTabGroup(next.id,in:workspaceID)
        }
        if split?.pageID == pageID { split = nil }
        changed()
    }
    func updateBrowserTab(_ value: BrowserPage, in workspaceID: UUID) {
        guard let i=session.workspaces.firstIndex(where: {$0.id == workspaceID}),let j=session.workspaces[i].pages.firstIndex(where: {$0.id == value.id}) else {return}
        session.workspaces[i].pages[j].pinned=value.pinned
        session.workspaces[i].pages[j].pinnedDisplay=value.pinnedDisplay
        session.workspaces[i].pages[j].tabName=value.tabName
        session.workspaces[i].pages[j].tabEmoji=value.tabEmoji
        session.workspaces[i].pages[j].tabIconFile=value.tabIconFile
        session.workspaces[i].pages[j].groupID=value.groupID
        changed()
    }
    func orderedPages(in workspaceID:UUID) -> [BrowserPage] {
        let pages=workspace(workspaceID)?.pages ?? []
        return pages.filter {$0.pinned == true} + pages.filter {$0.pinned != true}
    }
    func reopenPage() {
        defer {selectionChanged()}
        guard let (id, page) = closedPages.popLast(), let i = session.workspaces.firstIndex(where: { $0.id == id }) else { return }
        session.workspaces[i].pages.append(page); session.workspaces[i].selectedPageID = page.id; session.selectedWorkspaceID = id
        revealTabGroup(page.id,in:id);changed()
    }
    func removeWorkspace(_ id: UUID) {
        defer {selectionChanged()}
        guard let workspace = workspace(id), !workspace.pinned else { return }
        let alert = NSAlert(); alert.messageText = "「\(workspace.name)」を閉じますか？"
        alert.informativeText = "アプリタブとページ一覧を削除します。ログイン環境のCookieや保存データは残します。"
        alert.addButton(withTitle: "キャンセル"); alert.addButton(withTitle: "閉じる")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        reattachWorkspace(id,activate:false)
        for page in workspace.pages { engines.removeValue(forKey: page.id)?.dispose() }
        session.workspaces.removeAll { $0.id == id }
        if session.selectedWorkspaceID == id { session.selectedWorkspaceID = session.workspaces.first?.id }
        if split?.workspaceID == id { split = nil }; changed()
    }
    func moveWorkspace(_ id: UUID, before other: UUID, after:Bool=false) {
        guard id != other, let from = session.workspaces.firstIndex(where: { $0.id == id }), session.workspaces.contains(where: { $0.id == other }) else { return }
        let item = session.workspaces.remove(at: from)
        session.workspaces.insert(item, at: session.workspaces.firstIndex(where: { $0.id == other })! + (after ? 1:0)); changed()
    }
    @discardableResult func movePage(_ id:UUID,in workspaceID:UUID,relativeTo other:UUID,after:Bool)->Bool {
        guard let i=session.workspaces.firstIndex(where:{$0.id == workspaceID}),
              let from=session.workspaces[i].pages.firstIndex(where:{$0.id == id}),
              let target=session.workspaces[i].pages.first(where:{$0.id == other}) else{return false}
        if id == other {return true}
        guard (session.workspaces[i].pages[from].pinned == true) == (target.pinned == true) else{return false}
        let page=session.workspaces[i].pages.remove(at:from)
        let destination=session.workspaces[i].pages.firstIndex(where:{$0.id == other})! + (after ? 1:0)
        session.workspaces[i].pages.insert(page,at:destination);changed();return true
    }
    func updateWorkspace(_ value: BrowserWorkspace) {
        guard let i = session.workspaces.firstIndex(where: { $0.id == value.id }) else { return }
        let old = session.workspaces[i]
        var updated = value
        // Editing metadata must not discard tabs opened while the editor was visible.
        updated.pages = old.pages; updated.selectedPageID = old.selectedPageID
        updated.tabGroups=old.tabGroups;updated.visibleTabGroupID=old.visibleTabGroupID
        session.workspaces[i] = updated
        if old.profileID != value.profileID {
            for page in old.pages { engines.removeValue(forKey: page.id)?.dispose() }
        } else {
            for page in old.pages { engines[page.id]?.updateStyle(updated) }
        }
        changed()
    }
    func updateProfile(_ profile: LoginProfile) {
        guard let i = session.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        session.profiles[i] = profile; changed()
    }
    func createProfile(name: String) -> UUID {
        let profile = LoginProfile(name: name); session.profiles.append(profile); changed(); return profile.id
    }
    func updatePage(_ workspaceID: UUID, _ pageID: UUID, url: URL?, title: String?) {
        guard let i = session.workspaces.firstIndex(where: { $0.id == workspaceID }), let j = session.workspaces[i].pages.firstIndex(where: { $0.id == pageID }) else { return }
        let old=session.workspaces[i].pages[j]
        var updated=old
        if let url, BrowserAddress.url(url.absoluteString) != nil { updated.url = BrowserAddress.savedURL(url) }
        if let title, !title.isEmpty { updated.title = title }
        guard updated != old else{return}
        session.workspaces[i].pages[j]=updated
        changed()
    }
    func setSplit(_ ref: PageReference?) {
        defer {selectionChanged()}
        guard let ref else { split = nil; changed(); return }
        guard page(ref) != nil, ref.pageID != selectedPage?.id else { return }
        if detachedWorkspaceIDs.contains(ref.workspaceID) {reattachWorkspace(ref.workspaceID,activate:false)}
        if let selected,detachedWorkspaceIDs.contains(selected.id) {reattachWorkspace(selected.id,activate:false)}
        revealTabGroup(ref.pageID,in:ref.workspaceID)
        split = ref; changed()
    }
    func swapSplit() {
        defer {selectionChanged()}
        guard let right = split, let leftW = selected, let leftP = selectedPage else { return }
        session.selectedWorkspaceID = right.workspaceID
        if let i = session.workspaces.firstIndex(where: { $0.id == right.workspaceID }) { session.workspaces[i].selectedPageID = right.pageID }
        split = PageReference(workspaceID: leftW.id, pageID: leftP.id); changed()
    }
    func applyTheme() {
        NSApp.appearance = session.theme == "dark" ? NSAppearance(named: .darkAqua) : session.theme == "light" ? NSAppearance(named: .aqua) : nil
    }
    func changed() {
        objectWillChange.send(); saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }; saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    func snapshot() {
        for engine in engines.values { updatePage(engine.workspaceID, engine.pageID, url: engine.webView.url, title: engine.webView.title) }
        if let window, !window.styleMask.contains(.fullScreen), session.windowFrame != WindowRect(window.frame) { session.windowFrame = WindowRect(window.frame) }
    }
    @discardableResult func save(forceBackup:Bool=false) -> Bool {
        let started=ProcessInfo.processInfo.systemUptime
        defer {if ProcessInfo.processInfo.systemUptime-started>0.008 {recordTiming("セッション保存",since:started)}}
        guard writable else { return false }
        do {
            if session.splitStateRecorded != true {session.splitStateRecorded=true}
            if session.splitWorkspaceID != split?.workspaceID {session.splitWorkspaceID=split?.workspaceID}
            if session.splitPageID != split?.pageID {session.splitPageID=split?.pageID}
            if lastPersistedSession == session && !forceBackup {
                // The periodic save can archive the final edit after the interval,
                // even when the user has stopped interacting in the meantime.
                if let lastPersistedData {recordHistory(lastPersistedData)}
                exportLauncherIndex();return true
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(session.validated())
            let file = directory.appendingPathComponent("browser-session.json")
            let old = try? Data(contentsOf:file)
            if forceBackup {try historyArchive.record(data,force:true)}
            else if let old,old != data {recordHistory(old)}
            if old != data {try data.write(to: file, options: .atomic);persistenceWrites += 1}
            // Split state is committed atomically with the session. The legacy file
            // is only read when splitStateRecorded is absent; it cannot block saving.
            lastPersistedSession=session;lastPersistedData=data
            exportLauncherIndex()
            return true
        } catch { self.error = "保存できませんでした：\(error.localizedDescription)";return false }
    }
    private func recordHistory(_ data:Data) {
        do {try historyArchive.record(data);historyWarningShown=false}
        catch {
            // Optional recovery history must not prevent saving the current session.
            // Explicit pre-restore checkpoints remain mandatory in save(forceBackup:).
            if !historyWarningShown {
                historyWarningShown=true
                notify("復元履歴を保存できません。現在のタブは通常どおり保存します。",isError:true)
            }
        }
    }
    @discardableResult func saveBeforeExit(forceBackup:Bool=false) -> Bool {snapshot();saveWork?.cancel();return save(forceBackup:forceBackup)}
    var visiblePageIDs:Set<UUID> {
        var ids=Set<UUID>()
        if let id=selectedPage?.id {ids.insert(id)}
        if let id=split?.pageID {ids.insert(id)}
        for id in detachedWorkspaceIDs {if let page=workspace(id)?.selectedPageID {ids.insert(page)}}
        return ids
    }
    func pollNotionWorkspace() {
        for id in visiblePageIDs {engines[id]?.detectNotionWorkspace()}
    }
    @discardableResult func routeNotion(_ url:URL, detectedID:String?=nil, from:PageReference) -> Bool {
        guard let target=NotionWorkspace.target(url:url,detectedID:detectedID,workspaces:session.workspaces),target != from.workspaceID else {return false}
        guard from == commandPage else {return false}
        let link=FavoriteLink(title:"Notion",url:url.absoluteString,workspaceID:target)
        guard openFavorite(link) else {return false}
        notify("「\(workspace(target)?.name ?? "")」で開きました")
        return true
    }
    func shutdown() { resetWorkspaceHints();stopRuntimeMonitoring();notion.stop();timer?.invalidate(); snapshot(); saveWork?.cancel(); save();for engine in engines.values {engine.dispose()};engines.removeAll() }
    func restoreTabBackup(_ backup:BrowserBackup)throws {
        var restored=try backup.session.validated()
        let iconDir=directory.appendingPathComponent("Icons")
        try FileManager.default.createDirectory(at:iconDir,withIntermediateDirectories:true)
        for i in restored.workspaces.indices {
            for j in restored.workspaces[i].pages.indices {
                restored.workspaces[i].pages[j].tabIconFile=try importTabIcon(restored.workspaces[i].pages[j].tabIconFile,from:backup.icons)
            }
            restored.workspaces[i].iconFile=try importTabIcon(restored.workspaces[i].iconFile,from:backup.icons)
            for j in (restored.workspaces[i].tabGroups ?? []).indices {
                restored.workspaces[i].tabGroups![j].iconFile=try importTabIcon(restored.workspaces[i].tabGroups![j].iconFile,from:backup.icons)
            }
        }
        guard saveBeforeExit(forceBackup:true) else{throw LVError("現在の状態を保存できないため復元を中止しました")}
        for id in Array(detachedWorkspaceIDs) {reattachWorkspace(id,activate:false)}
        for engine in engines.values {engine.dispose()};engines.removeAll()
        restored.favorites=session.favorites;restored.windowFrame=session.windowFrame
        session=restored;split=restored.splitWorkspaceID.flatMap {wid in restored.splitPageID.map{PageReference(workspaceID:wid,pageID:$0)}};focusedPage=nil;applyTheme();changed()
    }
    func importTabIcon(_ original:String?,from icons:[String:Data]) throws -> String? {
        guard let original,let bytes=icons[original],bytes.count<2_000_000,NSImage(data:bytes) != nil else{return nil}
        let dir=directory.appendingPathComponent("Icons")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let name=UUID().uuidString+(original.contains(".template.") ? ".template.png":".png")
        try bytes.write(to:dir.appendingPathComponent(name),options:.atomic)
        return name
    }
    func chooseIcon() -> String? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return nil }
        return saveIcon(image)
    }
}
