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
    @Published var safeMode=false
    var safeLoadedPages=Set<UUID>()
    var suspendedPages=Set<UUID>()
    var onResumeFromSafeMode:(()->Void)?
    let startupRecovery:StartupRecovery?
    var canPersist:Bool {writable}
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
    /// When each loaded tab was last on screen (system uptime). Memory only.
    var lastVisibleAt:[UUID:TimeInterval]=[:]
    static let idleDiscardEnabledKey="IdleTabDiscardEnabled",idleDiscardMinutesKey="IdleTabDiscardMinutes"
    static var idleDiscardEnabled:Bool {UserDefaults.standard.object(forKey:idleDiscardEnabledKey) as? Bool ?? true}
    static var idleDiscardMinutes:Int {max(5,UserDefaults.standard.object(forKey:idleDiscardMinutesKey) as? Int ?? 30)}
    /// Frees the memory of tabs that have not been shown for a while. The tab stays in
    /// the strip and loads again from its saved URL when opened; unsent input is lost,
    /// so anything visible, pinned, busy or using the mic or camera is left alone.
    @discardableResult func discardIdleTabs(olderThan seconds:TimeInterval,now:TimeInterval=ProcessInfo.processInfo.systemUptime)->Int {
        let visible=visiblePageIDs
        for id in visible {lastVisibleAt[id]=now}
        lastVisibleAt=lastVisibleAt.filter{engines[$0.key] != nil}
        var count=0
        for engine in Array(engines.values) where !visible.contains(engine.pageID) {
            guard let last=lastVisibleAt[engine.pageID] else{lastVisibleAt[engine.pageID]=now;continue}
            guard now-last>=seconds,let page=page(PageReference(workspaceID:engine.workspaceID,pageID:engine.pageID)),
                  page.pinned != true,page.isStartPage != true,!engine.webView.isLoading,engine.webView.url != nil,
                  engine.webView.cameraCaptureState == .none,engine.webView.microphoneCaptureState == .none,
                  newTabRequest?.pageID != engine.pageID,siteSettingsPage?.pageID != engine.pageID else{continue}
            updatePage(engine.workspaceID,engine.pageID,url:engine.webView.url,title:engine.webView.title)
            engines.removeValue(forKey:engine.pageID)?.dispose();lastVisibleAt[engine.pageID]=nil;count += 1
        }
        if count>0 {changed()}
        return count
    }
    func pageID(for webView:WKWebView)->UUID? {engines.first{$0.value.webView === webView}?.key}

    lazy var downloads=BrowserDownloads(store:self)
    lazy var sites=SitePreferences(directory:directory)
    // Injectable destination selection for isolated local WebKit checks.
    var downloadDestinationChooser:((String,@escaping(URL?)->Void)->Void)?
    lazy var notion=NotionLibrary(store:self)
    lazy var linkRouting=NotionLinkRouting(directory:directory)
    @Published var split: PageReference?
    struct InnerSplit {var pageID:UUID;var sidePageIDs:[UUID];var orientation:String?;var fraction:Double?}
    /// Same-app-tab Splits set aside while another app tab is showing. Memory only.
    var innerSplits:[UUID:InnerSplit]=[:]
    /// The tab a new tab replaced as the visible one, until the new tab is placed.
    var selectionBeforeNewPage:(new:UUID,previous:UUID?)?
    @Published var detachedWorkspaceIDs: Set<UUID> = []
    var detachedControllers: [UUID: DetachedWorkspaceController] = [:]
    @Published var error: String?
    @Published var notice: String?
    var noticeIsError=false
    var notionCreationMenu:NotionCreationMenu?
    @Published var newTabRequest:PageReference?
    @Published var workspaceHintsVisible=false
    lazy var workspaceShortcutHints=WorkspaceShortcutHintsController(
        canShow:{[weak self] in self?.canShowWorkspaceHints == true},
        modifiers:{NSEvent.modifierFlags},
        publish:{[weak self] visible in self?.workspaceHintsVisible=visible})
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
        if pasteboard.setString(value,forType:.string) {notify(L("URLをコピーしました"))}
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
    @Published var downloadsPresented = false {willSet {if newValue && !downloadsPresented {capturePanelFocus()}}}
    @Published var previewFile:FilePreview? {willSet {if newValue != nil && previewFile == nil {capturePanelFocus()}}}
    @Published var siteSettingsPage:PageReference? {willSet {if newValue != nil && siteSettingsPage == nil {capturePanelFocus()}}}
    /// The tab editor was opened to pin the tab, so it starts with pinning switched on.
    var editingBrowserTabToPin=false
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
    private var memoryPressure:DispatchSourceMemoryPressure?
    private var engines: [UUID: BrowserEngine] = [:]
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    /// Account to start Notion as, keyed by a tab that has not been created yet.
    var notionAccountSeeds:[UUID:String]=[:]
    /// Names for the account chooser. Memory only.
    var notionDirectory:[String:NotionAccount]=[:]
    /// Live Notion pages of one environment (production or dev), current tab first.
    func notionEngines(environment:String)->[BrowserEngine] {
        engines.values.filter{!isPageSuspended($0.pageID) && !$0.webView.isLoading && $0.webView.url.flatMap(NotionWorkspace.environment) == environment}
            .sorted{a,_ in a.pageID == selectedPage?.id}
    }
    /// A live Notion page in this login environment, to ask Notion about its accounts.
    func notionEngine(profileID:UUID,environment:String)->BrowserEngine? {
        engines.values.first{$0.profileID == profileID && !isPageSuspended($0.pageID) && !$0.webView.isLoading && $0.webView.url.flatMap(NotionWorkspace.environment) == environment}
    }
    var closedPages: [(UUID, BrowserPage)] = []
    var closedPageProfiles:[UUID:UUID]=[:]
    // Isolated checks supply a decision without opening modal UI or sending keys.
    var loginEnvironmentChangeConfirmation:(([UUID])->Bool)?
    var window: NSWindow?
    var selected: BrowserWorkspace? { session.workspaces.first { $0.id == session.selectedWorkspaceID } }
    var selectedPage: BrowserPage? { selected.flatMap { w in w.pages.first { $0.id == w.selectedPageID } } }
    init(directory: URL? = nil,safeMode:Bool=false,trackStartup:Bool=false) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorkspaceTabs")
        startupRecovery=trackStartup ? StartupRecovery(directory:self.directory):nil
        self.safeMode=safeMode || startupRecovery?.interruptedStartup == true
        startupRecovery?.mark("starting")
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if let loaded=try SessionRecovery.load(directory:self.directory) {
                session=loaded.session
                if loaded.recovered {self.error=L("設定ファイルを直近の正常なバックアップから復元しました。元のファイルはRecoveryフォルダに保管しています。")}
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
            restorePinnedURLs()
            if session.splitStateRecorded == true {
                if let wid=session.splitWorkspaceID,let pid=session.splitPageID {split=PageReference(workspaceID:wid,pageID:pid)}
            } else if let data = try? Data(contentsOf: self.directory.appendingPathComponent("browser-split.json")),
               let ref = try? JSONDecoder().decode(PageReference.self, from: data), page(ref) != nil { split = ref }
        } catch {
            writable = false
            self.safeMode=true
            self.error = L("設定を読み込めませんでした。元ファイルは保持しています。\n\(error.localizedDescription)")
        }
        try? LegacyPagePreviewCleanup.remove(in:self.directory)
        loadWorksets()
        applyTheme()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.snapshot(); self?.save(); self?.pollNotionWorkspace()
                if Self.idleDiscardEnabled {self?.discardIdleTabs(olderThan:TimeInterval(Self.idleDiscardMinutes*60))}
            }
        }
        timer?.tolerance=1
        // When macOS reports memory pressure, do not wait for the full idle time.
        let pressure=DispatchSource.makeMemoryPressureSource(eventMask:[.warning,.critical],queue:.main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard Self.idleDiscardEnabled,let self,let event=self.memoryPressure?.data else{return}
                self.discardIdleTabs(olderThan:event.contains(.critical) ? 300:600)
            }
        }
        pressure.resume();memoryPressure=pressure
    }
    func profile(_ id: UUID) -> LoginProfile? { session.profiles.first { $0.id == id } }
    func workspace(_ id: UUID) -> BrowserWorkspace? { session.workspaces.first { $0.id == id } }
    func page(_ ref: PageReference) -> BrowserPage? { workspace(ref.workspaceID)?.pages.first { $0.id == ref.pageID } }
    func dataStore(_ id: UUID) -> WKWebsiteDataStore {
        if let store = dataStores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id); dataStores[id] = store; return store
    }
    func engine(_ workspaceID: UUID, _ pageID: UUID, configuration: WKWebViewConfiguration? = nil, load: Bool = true) -> BrowserEngine? {
        guard let workspace = workspace(workspaceID), let page = workspace.pages.first(where: { $0.id == pageID }),profile(workspace.profileID(for:page)) != nil else { return nil }
        if let engine=engines[pageID],engine.profileID != workspace.profileID(for:page) {engines.removeValue(forKey:pageID);engine.dispose()}
        if let engine = engines[pageID],engine.workspaceID == workspaceID {
            if load,suspendedPages.contains(pageID),!isPageSuspended(pageID) {resumePage(PageReference(workspaceID:workspaceID,pageID:pageID))}
            return engine
        }
        let engine = BrowserEngine(store: self, workspace: workspace, page: page, configuration: configuration)
        engines[pageID] = engine
        if load,page.isStartPage != true {
            if isPageSuspended(pageID) {suspendedPages.insert(pageID)}
            else if let url=BrowserAddress.url(page.url) {engine.webView.load(URLRequest(url:url))}
        }
        return engine
    }
    func selectWorkspace(_ id: UUID) {
        defer {selectionChanged()}
        if let pid=workspace(id)?.selectedPageID {beginDisplay(pid)}
        guard workspace(id) != nil else { return }
        let current=commandPage?.workspaceID ?? session.selectedWorkspaceID
        if current != id {previousWorkspaceID=current}
        // A Split between two tabs of one app tab belongs to that app tab: leaving shows
        // the next app tab on its own, and coming back brings the Split back.
        if let leaving=session.selectedWorkspaceID,leaving != id,let inner=split,inner.workspaceID == leaving {
            let side=secondPanePageIDs()
            if !side.isEmpty {
                innerSplits[leaving]=InnerSplit(pageID:inner.pageID,sidePageIDs:session.splitSidePageIDs ?? [inner.pageID],orientation:session.splitOrientation,fraction:session.splitFraction)
                split=nil;session.splitSidePageIDs=nil
            }
        }
        session.selectedWorkspaceID = id
        if split == nil,let saved=innerSplits.removeValue(forKey:id),let w=workspace(id),saved.pageID != w.selectedPageID,w.pages.contains(where:{$0.id == saved.pageID}),!detachedWorkspaceIDs.contains(id) {
            split=PageReference(workspaceID:id,pageID:saved.pageID)
            session.splitSidePageIDs=saved.sidePageIDs.filter{pid in pid != w.selectedPageID && w.pages.contains{$0.id == pid}}
            session.splitOrientation=saved.orientation;session.splitFraction=saved.fraction
        }
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
        if split?.workspaceID == workspaceID {session.splitSidePageIDs?.removeAll{$0 == pageID}}
        changed()
    }
    @discardableResult func addWorkspace(name: String = L("新しいアプリ"), url: String = "https://app.notion.com") -> UUID {
        let profile = LoginProfile(name: name + L(" のログイン環境"))
        session.profiles.append(profile)
        let workspace = BrowserWorkspace(name: name, profileID: profile.id, url: url)
        session.workspaces.append(workspace); session.selectedWorkspaceID = workspace.id
        changed(); return workspace.id
    }
    @discardableResult func addPage(to workspaceID: UUID? = nil, url: String? = nil, configuration: WKWebViewConfiguration? = nil, load:Bool = true, groupID:UUID? = nil, startPage:Bool = false, notionUserID:String? = nil) -> BrowserEngine? {
        defer {selectionChanged()}
        guard let id = workspaceID ?? session.selectedWorkspaceID, let i = session.workspaces.firstIndex(where: { $0.id == id }) else { return nil }
        var page = BrowserPage(url: startPage ? "about:blank" : (url ?? session.workspaces[i].homeURL))
        page.isStartPage=startPage ? true:nil
        page.groupID=groupID ?? session.workspaces[i].visibleGroupID
        session.workspaces[i].visibleTabGroupID=page.groupID
        selectionBeforeNewPage=(page.id,session.workspaces[i].selectedPageID)
        session.workspaces[i].pages.append(page); session.workspaces[i].selectedPageID = page.id
        if !startPage,let notionUserID {notionAccountSeeds[page.id]=notionUserID}
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
        guard session.workspaces[i].pages[j].pinned != true else {notify(L("ピン留めを解除してから閉じてください"));return}
        let closedGroup=session.workspaces[i].pages[j].groupID
        // Closing the current tab moves one tab to the left in the strip as shown
        // (pinned first, same group). The leftmost tab hands over to its right neighbour.
        let second=secondPanePageIDs(),closedSecond=second.contains(pageID)
        let strip=orderedPages(in:workspaceID).filter{session.workspaces[i].groupID(for:$0) == session.workspaces[i].groupID(for:session.workspaces[i].pages[j]) && second.contains($0.id) == closedSecond}.map(\.id)
        let neighbour=strip.firstIndex(of:pageID).flatMap{$0>0 ? strip[$0-1]:(strip.count>1 ? strip[1]:nil)}
        closedPages.append((workspaceID, session.workspaces[i].pages[j])); closedPages = Array(closedPages.suffix(20))
        closedPageProfiles[pageID]=session.workspaces[i].profileID(for:session.workspaces[i].pages[j])
        let retained=Set(closedPages.map{$0.1.id});closedPageProfiles=closedPageProfiles.filter{retained.contains($0.key)}
        engines.removeValue(forKey: pageID)?.dispose()
        session.workspaces[i].pages.remove(at: j)
        if session.workspaces[i].pages.isEmpty {var page=BrowserPage(url:session.workspaces[i].homeURL);page.groupID=closedGroup;session.workspaces[i].pages=[page]}
        if session.workspaces[i].selectedPageID == pageID {
            let pages=session.workspaces[i].pages
            let neighbourPage=pages.first{$0.id == neighbour}
            let firstPanePage=pages.first{!second.contains($0.id)}
            let splitPage:BrowserPage?=closedSecond ? nil:pages.first{$0.id == split?.pageID}
            let fallbackPage=visibleGroupPages(in:workspaceID).first ?? pages[min(j,pages.count-1)]
            let next=neighbourPage ?? firstPanePage ?? splitPage ?? fallbackPage
            session.workspaces[i].selectedPageID=next.id;revealTabGroup(next.id,in:workspaceID)
            // The first pane's only tab was closed: end the Split and show the other pane's tab.
            if split?.pageID == next.id {split=nil}
        }
        if split?.pageID == pageID {
            // Hand the second pane to another of its tabs before giving up the Split.
            let heir=session.workspaces[i].pages.first{$0.id == neighbour && closedSecond} ?? session.workspaces[i].pages.first{second.contains($0.id) && $0.id != pageID}
            split=heir.map{PageReference(workspaceID:workspaceID,pageID:$0.id)}
        }
        if split == nil {session.splitSidePageIDs=nil} else {session.splitSidePageIDs?.removeAll{$0 == pageID}}
        changed()
    }
    @discardableResult func updateBrowserTab(_ value: BrowserPage, in workspaceID: UUID)->Bool {
        guard let i=session.workspaces.firstIndex(where: {$0.id == workspaceID}),let j=session.workspaces[i].pages.firstIndex(where: {$0.id == value.id}) else {return false}
        if session.workspaces[i].groupID(for:session.workspaces[i].pages[j]) != session.workspaces[i].groupID(for:value),
           !movePageToGroup(value.id,in:workspaceID,groupID:session.workspaces[i].groupID(for:value)) {return false}
        // The pinned page is kept only while pinned, in the same cleaned form as saved URLs.
        var pinnedURL:String?
        let typed=(value.pinnedURL ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        if value.pinned == true,!typed.isEmpty {
            guard let url=BrowserAddress.url(typed),url.scheme != "about" else {notify(L("ピン留めするURLを確認してください"),isError:true);return false}
            pinnedURL=BrowserAddress.savedURL(url)
        }
        session.workspaces[i].pages[j].pinnedURL=pinnedURL
        session.workspaces[i].pages[j].pinned=value.pinned
        session.workspaces[i].pages[j].pinnedDisplay=value.pinnedDisplay
        session.workspaces[i].pages[j].tabName=value.tabName
        session.workspaces[i].pages[j].tabEmoji=value.tabEmoji
        session.workspaces[i].pages[j].tabIconFile=value.tabIconFile
        session.workspaces[i].pages[j].groupID=value.groupID
        changed();return true
    }
    /// At launch a pinned tab starts from its pinned page, not wherever it was left.
    func restorePinnedURLs() {
        for i in session.workspaces.indices {
            for j in session.workspaces[i].pages.indices {
                let page=session.workspaces[i].pages[j]
                guard page.pinned == true,let pinned=page.pinnedURL,pinned != page.url,BrowserAddress.url(pinned) != nil else{continue}
                session.workspaces[i].pages[j].url=pinned
                session.workspaces[i].pages[j].isStartPage=nil
            }
        }
    }
    func openPinnedURL(_ ref:PageReference) {
        guard let pinned=page(ref)?.pinnedURL,let engine=engine(ref.workspaceID,ref.pageID) else{return}
        engine.navigate(pinned)
    }
    func showsAccountEmail(_ pageID:UUID,in workspaceID:UUID)->Bool {
        guard let w=workspace(workspaceID),let page=w.pages.first(where:{$0.id == pageID}) else{return false}
        return w.showsAccountEmail(for:page)
    }
    func toggleAccountEmail(_ pageID:UUID,in workspaceID:UUID) {
        guard let i=session.workspaces.firstIndex(where:{$0.id == workspaceID}),let j=session.workspaces[i].pages.firstIndex(where:{$0.id == pageID}) else{return}
        // Store only a difference from the app tab's setting, so tabs keep following it.
        let next = !session.workspaces[i].showsAccountEmail(for:session.workspaces[i].pages[j])
        session.workspaces[i].pages[j].showAccountEmail=next == (session.workspaces[i].showAccountEmail ?? false) ? nil:next
        changed()
    }
    func orderedPages(in workspaceID:UUID) -> [BrowserPage] {
        let pages=workspace(workspaceID)?.pages ?? []
        return pages.filter {$0.pinned == true} + pages.filter {$0.pinned != true}
    }
    func reopenPage() {
        if let page=closedPages.last?.1 {_=restoreClosedPage(page.id)}
    }
    func removeWorkspace(_ id: UUID) {
        defer {selectionChanged()}
        guard let workspace = workspace(id), !workspace.pinned else { return }
        let alert = NSAlert(); alert.messageText = L("「\(workspace.name)」を閉じますか？")
        alert.informativeText = L("アプリタブとページ一覧を削除します。ログイン環境のCookieや保存データは残します。")
        alert.addButton(withTitle: L("キャンセル")); alert.addButton(withTitle: L("閉じる"))
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
            for page in old.pages where old.profileID(for:page) != updated.profileID(for:page) {engines.removeValue(forKey:page.id)?.dispose()}
        }
        for page in old.pages {engines[page.id]?.updateStyle(updated)}
        changed()
    }
    func updateProfile(_ profile: LoginProfile) {
        guard let i = session.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        session.profiles[i] = profile; changed()
    }
    func createProfile(name: String) -> UUID {
        let profile = LoginProfile(name: name); session.profiles.append(profile); changed(); return profile.id
    }
    func discardPageEngines(_ ids:[UUID]) {
        for id in ids {
            guard let engine=engines[id] else{continue}
            updatePage(engine.workspaceID,id,url:engine.webView.url,title:engine.webView.title)
            engines.removeValue(forKey:id)?.dispose()
        }
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
        guard let ref else { split = nil; session.splitSidePageIDs=nil; if let id=session.selectedWorkspaceID {innerSplits[id]=nil}; changed(); return }
        // A tab just opened from the second pane became the visible tab. Put back what was
        // showing so the new tab can take the second pane instead.
        if ref.pageID == selectedPage?.id,let before=selectionBeforeNewPage,before.new == ref.pageID,let previous=before.previous,previous != ref.pageID,
           let i=session.workspaces.firstIndex(where:{$0.id == ref.workspaceID}),session.workspaces[i].pages.contains(where:{$0.id == previous}) {
            session.workspaces[i].selectedPageID=previous
        }
        selectionBeforeNewPage=nil
        guard page(ref) != nil, ref.pageID != selectedPage?.id else { return }
        if detachedWorkspaceIDs.contains(ref.workspaceID) {reattachWorkspace(ref.workspaceID,activate:false)}
        if let selected,detachedWorkspaceIDs.contains(selected.id) {reattachWorkspace(selected.id,activate:false)}
        revealTabGroup(ref.pageID,in:ref.workspaceID)
        if ref.workspaceID == session.selectedWorkspaceID {
            // Keep the second pane's other tabs; the first pane's current tab stays out.
            var ids=secondPanePageIDs();ids.insert(ref.pageID)
            session.splitSidePageIDs=session.workspaces.first{$0.id == ref.workspaceID}?.pages.map(\.id).filter(ids.contains)
        } else {session.splitSidePageIDs=nil}
        split = ref; changed()
    }
    /// Tabs that belong to the second pane. Empty unless both panes show the same app tab,
    /// where each tab appears in exactly one pane's strip.
    func secondPanePageIDs()->Set<UUID> {
        guard let split,let workspace=selected,split.workspaceID == workspace.id,let main=workspace.selectedPageID,split.pageID != main,
              workspace.pages.contains(where:{$0.id == split.pageID}),!detachedWorkspaceIDs.contains(workspace.id) else{return []}
        var ids=Set(session.splitSidePageIDs ?? []).intersection(workspace.pages.map(\.id))
        ids.insert(split.pageID);ids.remove(main)
        return ids
    }
    /// The tab strip for one pane: the visible group, minus tabs that belong to the other pane.
    func paneTabs(in workspaceID:UUID,second isSecond:Bool,detached:Bool=false)->[BrowserPage] {
        let pages=visibleGroupPages(in:workspaceID)
        let second=secondPanePageIDs()
        guard !detached,!second.isEmpty,workspaceID == session.selectedWorkspaceID else{return pages}
        return pages.filter{second.contains($0.id) == isSecond}
    }
    /// Moves a tab to one pane of a same-app-tab Split and shows it there. No other tab
    /// changes sides: if the move empties a pane, the Split ends.
    @discardableResult func movePageToPane(_ ref:PageReference,second toSecond:Bool)->Bool {
        let second=secondPanePageIDs()
        guard !second.isEmpty,let workspace=selected,ref.workspaceID == workspace.id,let main=workspace.selectedPageID,let current=split,page(ref) != nil else{return false}
        func neighbour(of id:UUID,second side:Bool)->UUID? {
            let strip=paneTabs(in:workspace.id,second:side).map(\.id)
            if let index=strip.firstIndex(of:id),strip.count>1 {return strip[index>0 ? index-1:1]}
            return orderedPages(in:workspace.id).map(\.id).first{second.contains($0) == side && $0 != id}
        }
        if toSecond {
            if ref.pageID == main {
                // The first pane needs another of its own tabs to show.
                guard let next=neighbour(of:main,second:false) else {setSplit(nil);return true}
                selectPage(next,in:workspace.id)
            }
            setSplit(ref)
        } else if ref == current {
            // The second pane needs another of its own tabs to show.
            if let next=neighbour(of:ref.pageID,second:true) {setSplit(PageReference(workspaceID:workspace.id,pageID:next))} else {setSplit(nil)}
            selectPage(ref.pageID,in:workspace.id)
        } else {selectPage(ref.pageID,in:workspace.id)}
        return true
    }
    /// A tab dropped on the page area: show it on that side next to what is on screen.
    /// Returns false when there is nothing to pair it with.
    @discardableResult func dropForSplit(_ dropped:PageReference,side:SplitDropSide)->Bool {
        guard let workspace=selected,let main=selectedPage,page(dropped) != nil,!detachedWorkspaceIDs.contains(workspace.id) else{return false}
        let mainRef=PageReference(workspaceID:workspace.id,pageID:main.id)
        let wantsFirst=side == .left
        let sameAppTab=dropped.workspaceID == workspace.id
        if sameAppTab,!secondPanePageIDs().isEmpty {
            // Already split within this app tab: the tab moves to that pane.
            guard movePageToPane(dropped,second:!wantsFirst) else{return false}
            if split != nil {session.splitOrientation=side == .bottom ? "vertical":"horizontal";changed()}
            return true
        }
        if dropped == mainRef {
            if let other=split,page(other) != nil {
                // Already on screen in the first pane; swap only if it should be the second.
                if !wantsFirst {swapSplit()}
            } else {
                // The visible tab itself was dragged: pair it with the tab beside it.
                guard let index=workspace.pages.firstIndex(where:{$0.id == main.id}),workspace.pages.count>1 else{return false}
                let neighbour=PageReference(workspaceID:workspace.id,pageID:workspace.pages[index>0 ? index-1:index+1].id)
                if wantsFirst {setSplit(neighbour)} else {selectPage(neighbour.pageID,in:workspace.id);setSplit(dropped)}
            }
        } else if split == dropped {
            if wantsFirst {swapSplit()}
        } else if wantsFirst,let other=split,page(other) != nil {
            // Replace the first pane and keep the second.
            selectWorkspace(dropped.workspaceID);selectPage(dropped.pageID,in:dropped.workspaceID);setSplit(other)
        } else if wantsFirst,sameAppTab {
            // Only the dropped tab and the one that was showing take part; the rest stay put.
            selectPage(dropped.pageID,in:workspace.id);setSplit(mainRef)
        } else {
            setSplit(dropped)
            if wantsFirst {swapSplit()}
        }
        guard split != nil else{return false}
        session.splitOrientation=side == .bottom ? "vertical":"horizontal"
        changed()
        return true
    }
    func swapSplit() {
        defer {selectionChanged()}
        guard let right = split, let leftW = selected, let leftP = selectedPage else { return }
        let second=secondPanePageIDs()
        let traded=second.isEmpty ? nil:leftW.pages.map(\.id).filter{!second.contains($0)}
        session.selectedWorkspaceID = right.workspaceID
        session.splitFraction=1-(session.splitFraction ?? 0.5)
        if let i = session.workspaces.firstIndex(where: { $0.id == right.workspaceID }) { session.workspaces[i].selectedPageID = right.pageID }
        session.splitSidePageIDs=traded
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
        } catch { self.error = L("保存できませんでした：\(error.localizedDescription)");return false }
    }
    private func recordHistory(_ data:Data) {
        do {try historyArchive.record(data);historyWarningShown=false}
        catch {
            // Optional recovery history must not prevent saving the current session.
            // Explicit pre-restore checkpoints remain mandatory in save(forceBackup:).
            if !historyWarningShown {
                historyWarningShown=true
                notify(L("復元履歴を保存できません。現在のタブは通常どおり保存します。"),isError:true)
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
        for id in visiblePageIDs {
            engines[id]?.detectNotionWorkspace()
            if let engine=engines[id],!isPageSuspended(id) {engine.notionAccount.refresh(in:engine.webView)}
        }
    }
    @discardableResult func routeNotion(_ url:URL, detectedID:String?=nil, from:PageReference) -> Bool {
        guard let target=NotionWorkspace.target(url:url,detectedID:detectedID,workspaces:session.workspaces),target != from.workspaceID else {return false}
        guard from == commandPage else {return false}
        let link=FavoriteLink(title:"Notion",url:url.absoluteString,workspaceID:target)
        guard openFavorite(link) else {return false}
        notify(L("「\(workspace(target)?.name ?? "")」で開きました"))
        return true
    }
    func shutdown() { downloads.shutdown();resetWorkspaceHints();stopRuntimeMonitoring();notion.stop();timer?.invalidate(); snapshot(); saveWork?.cancel(); save();for engine in engines.values {engine.dispose()};engines.removeAll();startupRecovery?.mark("clean") }
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
        guard saveBeforeExit(forceBackup:true) else{throw LVError(L("現在の状態を保存できないため復元を中止しました"))}
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
