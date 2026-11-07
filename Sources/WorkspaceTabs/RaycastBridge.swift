import AppKit
import WorkspaceCore

struct LauncherEntry: Codable, Equatable {
    var id:String
    var title:String
    var subtitle:String
    var emoji:String
    var workspaceID:String?
}
struct LauncherIndex: Codable, Equatable {
    var version = 1
    var token:String
    var workspaces:[LauncherEntry]
    var tabs:[LauncherEntry]
    var favorites:[LauncherEntry]
    var commands:[LauncherEntry]
}
struct LauncherRequest {
    let kind:String
    let id:String
    let workspaceID:UUID?
    static func parse(_ url:URL,token:String)->LauncherRequest? {
        guard url.scheme == "workspacetabs", url.host == "launch", url.path.isEmpty,
              let parts=URLComponents(url:url,resolvingAgainstBaseURL:false),let items=parts.queryItems,
              Set(items.map(\.name)).count == items.count,
              items.allSatisfy({["token","kind","id","workspace"].contains($0.name)}) else{return nil}
        func value(_ key:String)->String? {items.first{$0.name == key}?.value}
        guard !token.isEmpty,value("token") == token,let kind=value("kind"),["tab","workspace","favorite","command"].contains(kind),let id=value("id"),!id.isEmpty else{return nil}
        let workspace=value("workspace").flatMap(UUID.init(uuidString:))
        if value("workspace") != nil && workspace == nil {return nil}
        return LauncherRequest(kind:kind,id:id,workspaceID:workspace)
    }
}
extension BrowserStore {
    func loadLauncherToken()->String {
        let file=directory.appendingPathComponent("launcher-token")
        if let token=try? String(contentsOf:file,encoding:.utf8),UUID(uuidString:token) != nil {return token}
        let token=UUID().uuidString
        do {try Data(token.utf8).write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)} catch {return ""}
        return token
    }
    static let launcherCommandIDs:Set<String> = BrowserCommands.ids.union(["favorites","show","search","previousWorkspace","nextWorkspace","copyURL","new","reopen"])
    func exportLauncherIndex() {
        let token=launcherToken
        guard !token.isEmpty else{return}
        let workspaces=session.workspaces.map{LauncherEntry(id:$0.id.uuidString,title:$0.name,subtitle:"アプリタブ",emoji:$0.emoji)}
        let tabs=tabSearchRows("").map{LauncherEntry(id:$0.id.uuidString,title:$0.page.displayTitle,subtitle:$0.workspace.name,emoji:$0.page.tabEmoji ?? $0.workspace.emoji,workspaceID:$0.workspace.id.uuidString)}
        let favorites=favorites.sorted{if $0.pinned != $1.pinned{return $0.pinned};return ($0.order ?? .infinity)<($1.order ?? .infinity)}.map{link in LauncherEntry(id:link.id.uuidString,title:link.title,subtitle:favoriteWorkspace(link)?.name ?? "開く先が未設定",emoji:link.emoji,workspaceID:favoriteWorkspace(link)?.id.uuidString)}
        let commands=ShortcutPreferences.actions.filter{Self.launcherCommandIDs.contains($0.id)}.map{LauncherEntry(id:$0.id,title:$0.title,subtitle:ShortcutPreferences.shared.binding($0).label,emoji:"")}
        let index=LauncherIndex(token:token,workspaces:workspaces,tabs:tabs,favorites:favorites,commands:commands)
        guard index != lastLauncherIndex else{return}
        let file=directory.appendingPathComponent("raycast-index.json")
        do {
            let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
            let data=try encoder.encode(index)
            if (try? Data(contentsOf:file)) != data {try data.write(to:file,options:.atomic)}
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            lastLauncherIndex=index
        }catch{NSLog("Workspace Tabs: launcher index export failed")}
    }
}
extension AppDelegate {
    func application(_ application:NSApplication,open urls:[URL]) {
        guard store != nil else {pendingLauncherURLs.append(contentsOf:urls);return}
        for url in urls {handleLauncherURL(url)}
    }
    func handleLauncherURL(_ url:URL) {
        guard let request=LauncherRequest.parse(url,token:store.launcherToken) else{return}
        guard window.attachedSheet == nil else {store.notify("開いているダイアログを閉じてから再実行してください");return}
        let original=store.commandPage
        switch request.kind {
        case "workspace":
            guard let id=UUID(uuidString:request.id),store.workspace(id) != nil else {store.notify("アプリタブが見つかりません");return}
            show();store.selectWorkspace(id)
        case "tab":
            guard let wid=request.workspaceID,let pid=UUID(uuidString:request.id),store.page(PageReference(workspaceID:wid,pageID:pid)) != nil else {store.notify("タブは閉じられています");return}
            show();store.activatePage(PageReference(workspaceID:wid,pageID:pid))
        case "favorite":
            guard let id=UUID(uuidString:request.id),let link=store.favorites.first(where:{$0.id == id}) else {store.notify("お気に入りが見つかりません");return}
            show();_ = store.openFavorite(link)
        case "command":
            guard BrowserStore.launcherCommandIDs.contains(request.id) else{return}
            var target=original
            if let id=request.workspaceID {
                guard let workspace=store.workspace(id),let pid=workspace.selectedPageID else{return}
                target=PageReference(workspaceID:id,pageID:pid)
            }
            show()
            if let target {store.activatePage(target)}
            if request.id.hasPrefix("notion"),let target {
                Task { @MainActor [weak self] in
                    guard let self else{return}
                    for _ in 0..<50 {
                        guard self.store.page(target) != nil else{return}
                        if let engine=self.store.engine(target.workspaceID,target.pageID),!engine.webView.isLoading {break}
                        try? await Task.sleep(nanoseconds:200_000_000)
                    }
                    self.store.runCommand(request.id,target:target)
                }
            } else if let action=ShortcutPreferences.actions.first(where:{$0.id == request.id}) {performShortcut(action)}
        default:break
        }
    }
}
