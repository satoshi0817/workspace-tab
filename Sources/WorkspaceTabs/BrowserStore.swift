import AppKit
import SwiftUI
import WebKit
import WorkspaceCore

struct PageReference: Codable, Equatable, Identifiable {
    var workspaceID: UUID
    var pageID: UUID
    var id: UUID { pageID }
}
@MainActor final class BrowserStore: ObservableObject {
    @Published var session = BrowserSession()
    lazy var notion=NotionLibrary(store:self)
    @Published var split: PageReference?
    @Published var detachedWorkspaceIDs: Set<UUID> = []
    var detachedControllers: [UUID: DetachedWorkspaceController] = [:]
    @Published var error: String?
    @Published var notice: String?
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
    func notify(_ message: String) {
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
            focusedPage=PageReference(workspaceID:engine.workspaceID,pageID:engine.pageID);break
        }
    }
    @Published var showSettings = false
    @Published var helpPresented = false
    @Published var editingBrowserTab: PageReference?
    @Published var editingWorkspace: UUID?
    @Published var addressFocus = UUID()
    @Published var commandsPresented = false
    var commandTarget:PageReference?
    var previousWorkspaceID:UUID?
    @Published var searchForSplit = false
    @Published var searchPresented = false
    @Published var favoritesPresented = false
    @Published var favoriteDraft: FavoriteLink?
    @Published var migrationNotice = false
    @Published var hovered = false
    let directory: URL
    private var writable = true
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
            let file = self.directory.appendingPathComponent("browser-session.json")
            if FileManager.default.fileExists(atPath: file.path) {
                session = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: file)).validated()
            } else {
                let old = self.directory.appendingPathComponent("workspaces.json")
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
        applyTheme()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapshot(); self?.save(); self?.pollNotionWorkspace() }
        }
    }
    func profile(_ id: UUID) -> LoginProfile? { session.profiles.first { $0.id == id } }
    func workspace(_ id: UUID) -> BrowserWorkspace? { session.workspaces.first { $0.id == id } }
    func page(_ ref: PageReference) -> BrowserPage? { workspace(ref.workspaceID)?.pages.first { $0.id == ref.pageID } }
    func dataStore(_ id: UUID) -> WKWebsiteDataStore {
        if let store = dataStores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id); dataStores[id] = store; return store
    }
    func engine(_ workspaceID: UUID, _ pageID: UUID, configuration: WKWebViewConfiguration? = nil, load: Bool = true) -> BrowserEngine? {
        if let engine = engines[pageID] { return engine }
        guard let workspace = workspace(workspaceID), let page = workspace.pages.first(where: { $0.id == pageID }) else { return nil }
        let engine = BrowserEngine(store: self, workspace: workspace, page: page, configuration: configuration)
        engines[pageID] = engine
        if load, let url = BrowserAddress.url(page.url) { engine.webView.load(URLRequest(url: url)) }
        return engine
    }
    func selectWorkspace(_ id: UUID) {
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
        guard let i = session.workspaces.firstIndex(where: { $0.id == workspaceID }), session.workspaces[i].pages.contains(where: { $0.id == pageID }) else { return }
        session.workspaces[i].selectedPageID = pageID
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
    @discardableResult func addPage(to workspaceID: UUID? = nil, url: String? = nil, configuration: WKWebViewConfiguration? = nil) -> BrowserEngine? {
        guard let id = workspaceID ?? session.selectedWorkspaceID, let i = session.workspaces.firstIndex(where: { $0.id == id }) else { return nil }
        let page = BrowserPage(url: url ?? session.workspaces[i].homeURL)
        session.workspaces[i].pages.append(page); session.workspaces[i].selectedPageID = page.id
        changed()
        return engine(id, page.id, configuration: configuration, load: configuration == nil)
    }
    func closePage(_ pageID: UUID, in workspaceID: UUID) {
        guard let i = session.workspaces.firstIndex(where: { $0.id == workspaceID }), let j = session.workspaces[i].pages.firstIndex(where: { $0.id == pageID }) else { return }
        guard session.workspaces[i].pages[j].pinned != true else {notify("ピン留めを解除してから閉じてください");return}
        closedPages.append((workspaceID, session.workspaces[i].pages[j])); closedPages = Array(closedPages.suffix(20))
        engines.removeValue(forKey: pageID)?.webView.stopLoading()
        session.workspaces[i].pages.remove(at: j)
        if session.workspaces[i].pages.isEmpty { session.workspaces[i].pages = [BrowserPage(url: session.workspaces[i].homeURL)] }
        if session.workspaces[i].selectedPageID == pageID { session.workspaces[i].selectedPageID = session.workspaces[i].pages[min(j, session.workspaces[i].pages.count - 1)].id }
        if split?.pageID == pageID { split = nil }
        changed()
    }
    func updateBrowserTab(_ value: BrowserPage, in workspaceID: UUID) {
        guard let i=session.workspaces.firstIndex(where: {$0.id == workspaceID}),let j=session.workspaces[i].pages.firstIndex(where: {$0.id == value.id}) else {return}
        session.workspaces[i].pages[j].pinned=value.pinned
        session.workspaces[i].pages[j].pinnedDisplay=value.pinnedDisplay
        session.workspaces[i].pages[j].tabName=value.tabName
        session.workspaces[i].pages[j].tabEmoji=value.tabEmoji
        changed()
    }
    func orderedPages(in workspaceID:UUID) -> [BrowserPage] {
        let pages=workspace(workspaceID)?.pages ?? []
        return pages.filter {$0.pinned == true} + pages.filter {$0.pinned != true}
    }
    func reopenPage() {
        guard let (id, page) = closedPages.popLast(), let i = session.workspaces.firstIndex(where: { $0.id == id }) else { return }
        session.workspaces[i].pages.append(page); session.workspaces[i].selectedPageID = page.id; session.selectedWorkspaceID = id; changed()
    }
    func removeWorkspace(_ id: UUID) {
        guard let workspace = workspace(id), !workspace.pinned else { return }
        let alert = NSAlert(); alert.messageText = "「\(workspace.name)」を閉じますか？"
        alert.informativeText = "アプリタブとページ一覧を削除します。ログイン環境のCookieや保存データは残します。"
        alert.addButton(withTitle: "キャンセル"); alert.addButton(withTitle: "閉じる")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        reattachWorkspace(id,activate:false)
        for page in workspace.pages { engines.removeValue(forKey: page.id)?.webView.stopLoading() }
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
        session.workspaces[i] = updated
        if old.profileID != value.profileID {
            for page in old.pages { engines.removeValue(forKey: page.id)?.webView.stopLoading() }
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
        guard let ref else { split = nil; changed(); return }
        guard page(ref) != nil, ref.pageID != selectedPage?.id else { return }
        if detachedWorkspaceIDs.contains(ref.workspaceID) {reattachWorkspace(ref.workspaceID,activate:false)}
        if let selected,detachedWorkspaceIDs.contains(selected.id) {reattachWorkspace(selected.id,activate:false)}
        split = ref; changed()
    }
    func swapSplit() {
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
    @discardableResult func save() -> Bool {
        guard writable else { return false }
        do {
            if session.splitStateRecorded != true {session.splitStateRecorded=true}
            if session.splitWorkspaceID != split?.workspaceID {session.splitWorkspaceID=split?.workspaceID}
            if session.splitPageID != split?.pageID {session.splitPageID=split?.pageID}
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(session.validated())
            let file = directory.appendingPathComponent("browser-session.json")
            if let old = try? Data(contentsOf: file), old != data {
                let backups = directory.appendingPathComponent("BrowserBackups")
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                try old.write(to: backups.appendingPathComponent("\(Int64(Date().timeIntervalSince1970*1000))-\(UUID()).json"), options: .atomic)
                let files = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
                for old in files.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
            }
            if (try? Data(contentsOf:file)) != data {try data.write(to: file, options: .atomic)}
            let splitURL = directory.appendingPathComponent("browser-split.json")
            if let split { try encoder.encode(split).write(to: splitURL, options: .atomic) }
            else if FileManager.default.fileExists(atPath: splitURL.path) { try FileManager.default.removeItem(at: splitURL) }
            exportLauncherIndex()
            return true
        } catch { self.error = "保存できませんでした：\(error.localizedDescription)";return false }
    }
    @discardableResult func saveBeforeExit() -> Bool {snapshot();saveWork?.cancel();return save()}
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
    func shutdown() { notion.stop();timer?.invalidate(); snapshot(); saveWork?.cancel(); save() }
    func restoreTabBackup(_ backup:BrowserBackup)throws {
        var restored=try backup.session.validated()
        let iconDir=directory.appendingPathComponent("Icons")
        try FileManager.default.createDirectory(at:iconDir,withIntermediateDirectories:true)
        for i in restored.workspaces.indices {
            if let old=restored.workspaces[i].iconFile,let bytes=backup.icons[old],bytes.count<2_000_000,NSImage(data:bytes) != nil {
                let name=UUID().uuidString+".png";try bytes.write(to:iconDir.appendingPathComponent(name),options:.atomic);restored.workspaces[i].iconFile=name
            } else {restored.workspaces[i].iconFile=nil}
        }
        guard saveBeforeExit() else{throw LVError("現在の状態を保存できないため復元を中止しました")}
        for id in Array(detachedWorkspaceIDs) {reattachWorkspace(id,activate:false)}
        for engine in engines.values {engine.webView.stopLoading()};engines.removeAll()
        restored.favorites=session.favorites;restored.windowFrame=session.windowFrame
        session=restored;split=nil;focusedPage=nil;applyTheme();changed()
    }
    func chooseIcon() -> String? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return nil }
        let resized = NSImage(size: NSSize(width: 128, height: 128)); resized.lockFocus()
        let ratio = min(128/image.size.width,128/image.size.height)
        let size = NSSize(width: image.size.width*ratio,height: image.size.height*ratio)
        image.draw(in: NSRect(x:(128-size.width)/2,y:(128-size.height)/2,width:size.width,height:size.height)); resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let png = bitmap.representation(using:.png,properties:[:]) else { return nil }
        let name = UUID().uuidString+".png", dir = directory.appendingPathComponent("Icons")
        do { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); try png.write(to:dir.appendingPathComponent(name)); return name }
        catch { self.error = error.localizedDescription; return nil }
    }
}
