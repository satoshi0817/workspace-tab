import AppKit
import SwiftUI
import WorkspaceCore

struct Workset:Codable,Identifiable,Equatable {
    var id=UUID()
    var name:String
    var createdAt=Date()
    var workspaces:[BrowserWorkspace]
    var selectedWorkspaceID:UUID?
    var split:PageReference?
    var splitOrientation:String?
    var splitFraction:Double?
}
struct TimingEntry:Identifiable {
    let id=UUID()
    let date=Date()
    let operation:String
    let milliseconds:Double
}
@MainActor final class TimingLog:ObservableObject {
    @Published var entries:[TimingEntry]=[]
    func add(_ operation:String,milliseconds:Double) {
        guard milliseconds.isFinite,milliseconds>=0 else{return}
        entries.append(TimingEntry(operation:operation,milliseconds:milliseconds))
        if entries.count>200 {entries.removeFirst(entries.count-200)}
    }
}
struct SessionHistoryEntry:Identifiable {
    let url:URL
    let date:Date
    let tabCount:Int
    var id:String {url.lastPathComponent}
}
extension BrowserStore {
    func recordTiming(_ operation:String,since start:Double) {
        timings.add(operation,milliseconds:(ProcessInfo.processInfo.systemUptime-start)*1000)
    }
    func beginDisplay(_ id:UUID) {
        guard selectedPage?.id != id else{return}
        pendingDisplay.removeAll()
        pendingDisplay[id]=ProcessInfo.processInfo.systemUptime
    }
    func recordDisplay(pageID:UUID?) {
        guard let pageID,let start=pendingDisplay.removeValue(forKey:pageID) else{return}
        recordTiming("タブのWebView配置",since:start)
    }
    func exportTimings() {
        let panel=NSSavePanel();panel.nameFieldStringValue="workspace-tabs-timings.csv"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        let formatter=ISO8601DateFormatter()
        let rows=timings.entries.map{formatter.string(from:$0.date)+","+String(format:"%.2f",$0.milliseconds)+","+$0.operation}
        do {try ("date,milliseconds,operation\n"+rows.joined(separator:"\n")).write(to:url,atomically:true,encoding:.utf8)}
        catch {self.error=error.localizedDescription}
    }
    static func pageKey(_ value:String)->String? {
        guard let url=BrowserAddress.url(value) else{return nil}
        // Keep query/fragment: database views and anchored locations are distinct.
        if let environment=NotionWorkspace.environment(url),
           !url.pathComponents.contains("ai"),!url.pathComponents.contains("chat") {
            let tail=url.lastPathComponent
            let suffix=String(tail.suffix(36))
            let compact=NotionWorkspace.normalizedID(suffix) ?? NotionWorkspace.normalizedID(String(tail.suffix(32)))
            if let compact {return environment+":"+compact+"?"+(url.query ?? "")+"#"+(url.fragment ?? "")}
        }
        return BrowserAddress.savedURL(url)
    }
    var duplicatePages:[PageReference] {
        let rows=session.workspaces.flatMap {workspace in workspace.pages.map{(workspace,$0)}}
        let groups=Dictionary(grouping:rows) {workspace,page in workspace.profileID(for:page).uuidString+":"+(Self.pageKey(page.url) ?? page.id.uuidString)}
        let duplicateIDs=Set(groups.values.filter{$0.count>1}.flatMap{$0.map{$0.1.id}})
        return rows.filter{duplicateIDs.contains($0.1.id)}.map{PageReference(workspaceID:$0.0.id,pageID:$0.1.id)}
    }
    func existingPage(url:String,in workspaceID:UUID)->BrowserPage? {
        guard let key=Self.pageKey(url),let workspace=workspace(workspaceID) else{return nil}
        let profile=workspace.profileID(forGroup:workspace.visibleGroupID)
        return workspace.pages.first {workspace.profileID(for:$0) == profile && Self.pageKey($0.url) == key}
    }
    func loadWorksets() {
        let file=directory.appendingPathComponent("worksets.json")
        guard let data=try? Data(contentsOf:file),let values=try? JSONDecoder().decode([Workset].self,from:data) else{return}
        worksets=values
    }
    @discardableResult func persistWorksets(_ values:[Workset])->Bool {
        do {
            let file=directory.appendingPathComponent("worksets.json")
            try JSONEncoder().encode(values).write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            worksets=values;exportLauncherIndex();return true
        } catch {self.error=L("作業セットを保存できませんでした: ")+error.localizedDescription;return false}
    }
    func saveWorkset(name:String) {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty else{return}
        snapshot()
        let value=Workset(name:name,workspaces:session.workspaces,selectedWorkspaceID:session.selectedWorkspaceID,split:split,splitOrientation:session.splitOrientation,splitFraction:session.splitFraction)
        if persistWorksets(worksets+[value]) {notify(L("作業セットを保存しました"))}
    }
    @discardableResult func restoreWorkset(_ id:UUID)->Bool {
        guard let value=worksets.first(where:{$0.id == id}) else{return false}
        guard value.workspaces.allSatisfy({saved in
            guard let current=workspace(saved.id),current.profileID == saved.profileID else{return false}
            return saved.pages.allSatisfy{page in BrowserAddress.url(page.url) != nil && saved.profileID(for:page) == current.profileID(for:page) && (page.groupID == nil || current.resolvedTabGroups.contains{$0.id == page.groupID})}
        }) else {
            notify(L("保存時のアプリタブまたはログイン環境が見つかりません。別の環境では開きません"),isError:true);return false
        }
        var mapping:[UUID:UUID]=[:]
        for saved in value.workspaces {
            guard let i=session.workspaces.firstIndex(where:{$0.id == saved.id}) else{continue}
            var used=Set<UUID>()
            for page in saved.pages {
                let candidates=session.workspaces[i].pages.filter{!used.contains($0.id) && session.workspaces[i].profileID(for:$0) == saved.profileID(for:page) && Self.pageKey($0.url) == Self.pageKey(page.url)}
                if let existing=candidates.first(where:{$0.id == page.id}) ?? candidates.first {mapping[page.id]=existing.id;used.insert(existing.id)}
                else {
                    var restored=page;restored.id=UUID()
                    session.workspaces[i].pages.append(restored);mapping[page.id]=restored.id;used.insert(restored.id)
                }
            }
            if let selected=saved.selectedPageID.flatMap({mapping[$0]}) {session.workspaces[i].selectedPageID=selected}
        }
        session.selectedWorkspaceID=value.selectedWorkspaceID
        if let selected=session.selectedWorkspaceID,detachedWorkspaceIDs.contains(selected) {reattachWorkspace(selected,activate:false)}
        session.splitOrientation=value.splitOrientation == "vertical" ? "vertical":"horizontal"
        session.splitFraction=value.splitFraction.flatMap{$0.isFinite && (0.15...0.85).contains($0) ? $0:nil} ?? 0.5
        setSplit(value.split.flatMap {ref in mapping[ref.pageID].map{PageReference(workspaceID:ref.workspaceID,pageID:$0)}})
        focusedPage=nil;changed();notify(L("作業セットを開きました"))
        return true
    }
    func sessionHistory()->[SessionHistoryEntry] {
        let dir=directory.appendingPathComponent("BrowserBackups")
        return ((try? FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []).filter{$0.pathExtension == "json"}.compactMap {url in
            guard let data=try? Data(contentsOf:url),let value=try? JSONDecoder().decode(BrowserSession.self,from:data),
                  (try? value.validated()) != nil else{return nil}
            let date=(try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return SessionHistoryEntry(url:url,date:date,tabCount:value.workspaces.reduce(0){$0+$1.pages.count})
        }.sorted{$0.date>$1.date}
    }
    func restoreHistory(_ entry:SessionHistoryEntry) {
        do {
            let value=try JSONDecoder().decode(BrowserSession.self,from:Data(contentsOf:entry.url)).validated()
            let alert=NSAlert();alert.messageText=L("この履歴に戻しますか？")
            alert.informativeText=L("現在のタブを閉じて復元します。未送信の入力は失われます。現在の構成は復元前に保存します。")
            alert.addButton(withTitle:L("キャンセル"));alert.addButton(withTitle:L("復元"))
            guard alert.runModal() == .alertSecondButtonReturn else{return}
            var icons:[String:Data]=[:]
            for workspace in value.workspaces {
                if let name=workspace.iconFile,!name.contains("/"),let bytes=try? Data(contentsOf:directory.appendingPathComponent("Icons").appendingPathComponent(name)) {icons[name]=bytes}
            }
            for group in value.workspaces.flatMap({$0.resolvedTabGroups}) {
                if let name=group.iconFile,name == URL(fileURLWithPath:name).lastPathComponent {icons[name]=try? Data(contentsOf:directory.appendingPathComponent("Icons").appendingPathComponent(name))}
            }
            for page in value.workspaces.flatMap(\.pages) {
                if let name=page.tabIconFile,name == URL(fileURLWithPath:name).lastPathComponent {icons[name]=try? Data(contentsOf:directory.appendingPathComponent("Icons").appendingPathComponent(name))}
            }
            try restoreTabBackup(BrowserBackup(session:value,icons:icons))
            notify(L("履歴を復元しました"))
        } catch {self.error=L("履歴を復元できませんでした: ")+error.localizedDescription}
    }
    func openExternalNotion(_ url:URL) {
        guard let environment=NotionWorkspace.environment(url) else{return}
        if let target=NotionWorkspace.target(url:url,detectedID:nil,workspaces:session.workspaces) {
            _=openFavorite(FavoriteLink(title:"Notion",url:url.absoluteString,workspaceID:target));return
        }
        let matches=session.workspaces.filter{existingPage(url:url.absoluteString,in:$0.id) != nil}
        if matches.count == 1,let match=matches.first,let page=existingPage(url:url.absoluteString,in:match.id) {
            activatePage(PageReference(workspaceID:match.id,pageID:page.id));return
        }
        // Only one app tab uses this Notion environment (for example the dev site):
        // every link for it belongs there.
        let sameEnvironment=session.workspaces.filter{BrowserAddress.url($0.homeURL).flatMap(NotionWorkspace.environment) == environment}
        if sameEnvironment.count == 1 {_=openFavorite(FavoriteLink(title:"Notion",url:url.absoluteString,workspaceID:sameEnvironment[0].id));return}
        // The URL does not name a workspace. Ask Notion which one owns the page, through
        // pages that are already signed in; fall back to asking the user.
        let engines=Array(notionEngines(environment:environment).prefix(3))
        guard let pageID=NotionWorkspace.pageID(url),!engines.isEmpty else{pendingExternalURL=BrowserAddress.savedURL(url);return}
        Task { [weak self] in
            var space:String?
            for engine in engines where space == nil {
                let raw=try? await engine.webView.callAsyncJavaScript(NotionWorkspace.spaceLookupScript,arguments:["pageID":pageID],in:nil,contentWorld:.defaultClient)
                space=NotionWorkspace.normalizedID(raw as? String)
            }
            guard let self else{return}
            if let target=NotionWorkspace.target(url:url,detectedID:space,workspaces:self.session.workspaces) {
                _=self.openFavorite(FavoriteLink(title:"Notion",url:url.absoluteString,workspaceID:target))
            } else if !self.anyPanelPresented {self.pendingExternalURL=BrowserAddress.savedURL(url)}
        }
    }
}
struct WorkflowSettings:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @State private var name=""
    @AppStorage(BrowserStore.idleDiscardEnabledKey) private var idleDiscard=true
    @AppStorage(BrowserStore.idleDiscardMinutesKey) private var idleMinutes=30
    var body:some View {
        Section(L("作業セット")) {
            HStack {TextField(L("例：開発、定例会議"),text:$name);Button(L("現在のタブを保存")){store.saveWorkset(name:name);name=""}.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
            Text(L("全アプリタブとSplit Viewの組み合わせを保存します。復元時は現在のタブを残し、同じページを再利用します。")).font(.caption).foregroundStyle(.secondary)
            ForEach(store.worksets){value in
                HStack {Text(value.name);Spacer();Button(L("開く")){_=store.restoreWorkset(value.id)};Button(L("削除")){_=store.persistWorksets(store.worksets.filter{$0.id != value.id})}}
            }
        }
        Section(L("メモリの節約")) {
            Toggle(L("しばらく表示していないタブを休止する"),isOn:$idleDiscard)
            Picker(L("休止するまでの時間"),selection:$idleMinutes) {
                ForEach([15,30,60,120],id:\.self) {minutes in Text(L("\(minutes)分")).tag(minutes)}
            }.disabled(!idleDiscard)
            Text(L("Macのメモリが不足したときは、5〜10分表示していないタブも休止します。")).font(.caption).foregroundStyle(.secondary)
            Text(L("休止したタブはタブ列に残り、開くと読み込み直します。未送信の入力は消えます。表示中・Split表示中・ピン留め・読み込み中・マイクやカメラを使用中のタブは休止しません。")).font(.caption).foregroundStyle(.secondary)
        }
        Section(L("重複しているタブ")) {
            Text(L("お気に入り・外部リンク・作業セットからは既存タブを再利用します。⌘クリックや明示的な新規タブはそのまま作成します。")).font(.caption)
            if store.duplicatePages.isEmpty {Text(L("重複はありません")).foregroundStyle(.secondary)}
            ForEach(store.duplicatePages) {ref in
                HStack {
                    Text(store.page(ref)?.displayTitle ?? "")
                    Text(store.workspace(ref.workspaceID)?.name ?? "").foregroundStyle(.secondary)
                    Spacer()
                    Button(L("表示")){store.activatePage(ref);store.showSettings=false}
                }
            }
        }
        Section(L("リンクを開く")) {
            Text(L("外部から受け取ったNotionリンクは、URLのワークスペース名や既存タブから開く先を判定します。一意に決まらない場合は環境を選びます。"))
            Text(L("既定のブラウザは自動変更しません。Raycastの「Open Notion Link」からURLを渡せます。")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct TimingSettings:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var log:TimingLog
    let export:()->Void
    var body:some View {
        Section(L("遅延診断")) {
            Text(L("直近200件をメモリに記録します。URL・ページ内容・入力文字は記録しません。配置時間は描画完了、読み込み時間はNotionの同期完了を意味しません。")).font(.caption)
            HStack {Button(L("CSVを書き出す"),action:export);Button(L("記録を消す")){log.entries.removeAll()}}
            ForEach(log.entries.suffix(30).reversed()) {entry in
                HStack {Text(entry.operation);Spacer();Text(String(format:"%.1f ms",entry.milliseconds)).monospacedDigit()}.font(.caption)
            }
        }
    }
}
struct HistorySettings:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @State private var entries:[SessionHistoryEntry]=[]
    var body:some View {
        Section(L("復元履歴（直近20件）")) {
            Text(L("通常は5分間隔、設定の読み込み・復元前にも保存します。現在状態の自動保存は継続します。")).font(.caption).foregroundStyle(.secondary)
            Button(L("履歴を更新")){entries=store.sessionHistory()}
            ForEach(entries) {entry in
                HStack {Text(entry.date,format:.dateTime.month().day().hour().minute().second());Text(L("\(entry.tabCount)タブ")).foregroundStyle(.secondary);Spacer();Button(L("復元…")){store.restoreHistory(entry);entries=store.sessionHistory()}}
            }
        }.onAppear {entries=store.sessionHistory()}
    }
}
struct ExternalLinkPicker:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text(L("Notionリンクを開く環境")).font(.headline)
            Text(L("URLだけではワークスペースを特定できないため、開く先を選んでください。")).font(.callout)
            ForEach(store.session.workspaces) {workspace in
                Button(workspace.name) {
                    if let url=store.pendingExternalURL {_=store.openFavorite(FavoriteLink(title:"Notion",url:url,workspaceID:workspace.id))}
                    store.pendingExternalURL=nil;dismiss()
                }
            }
            Button(L("キャンセル")){store.pendingExternalURL=nil;dismiss()}.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width:420)
    }
}
