import SwiftUI
import WorkspaceCore

// Stable scope IDs are independent of the displayed language.
enum SearchScope:String,CaseIterable,Identifiable {
    case all,tabs,favorites,closed,downloads,commands
    var id:String {rawValue}
    var title:String {
        switch self {
        case .all:return L("すべて")
        case .tabs:return L("タブ")
        case .favorites:return L("お気に入り")
        case .closed:return L("閉じたタブ")
        case .downloads:return L("ダウンロード")
        case .commands:return L("操作")
        }
    }
}
struct UniversalResult:Identifiable {
    enum Target {case tab(PageReference),favorite(UUID),closed(UUID),download(UUID),command(String)}
    let id:String
    let title:String
    let subtitle:String
    let icon:String
    let scope:SearchScope
    let target:Target
}
extension BrowserStore {
    func universalResults(_ query:String,scope:SearchScope)->[UniversalResult] {
        let words=query.split(whereSeparator:{$0.isWhitespace}).map(String.init)
        func matches(_ value:String)->Bool {words.allSatisfy{value.localizedStandardContains($0)}}
        var result:[UniversalResult]=[]
        func append(_ rows:[UniversalResult],for category:SearchScope) {
            guard scope == .all || scope == category else{return}
            result += rows.filter{matches($0.title+" "+$0.subtitle)}.prefix(scope == .all ? 50:250)
        }
        append(tabSearchRows("").map{UniversalResult(id:"tab:"+$0.id.uuidString,title:$0.page.displayTitle,subtitle:$0.workspace.name+" · "+$0.page.url,icon:"rectangle.on.rectangle",scope:.tabs,target:.tab($0.ref))},for:.tabs)
        append(favoriteSections().flatMap(\.links).map{UniversalResult(id:"favorite:"+$0.id.uuidString,title:$0.title,subtitle:$0.category+" · "+(favoriteWorkspace($0)?.name ?? "")+" · "+$0.url,icon:"star",scope:.favorites,target:.favorite($0.id))},for:.favorites)
        append(closedPages.reversed().compactMap {wid,page in
            guard let workspace=workspace(wid) else{return nil}
            return UniversalResult(id:"closed:"+page.id.uuidString,title:page.displayTitle,subtitle:workspace.name+" · "+page.url,icon:"clock.arrow.circlepath",scope:.closed,target:.closed(page.id))
        },for:.closed)
        append(downloads.records.map {record in
            UniversalResult(id:"download:"+record.id.uuidString,title:record.name.isEmpty ? L("ファイル"):record.name,
                            subtitle:record.state == .completed ? (downloads.file(for:record) == nil ? L("ファイルが見つかりません"):L("保存済み")) : (record.isActive ? L("ダウンロード中…"):L("未完了")),
                            icon:"arrow.down.circle",scope:.downloads,target:.download(record.id))
        },for:.downloads)
        var actions=ShortcutPreferences.actions.filter{(BrowserCommands.ids.contains($0.id) && $0.id != "commands") || $0.id == "settings"}
            .map{UniversalResult(id:"command:"+$0.id,title:$0.title,subtitle:ShortcutPreferences.shared.binding($0).label,icon:"command",scope:.commands,target:.command($0.id))}
        actions.append(UniversalResult(id:"command:downloads",title:L("ダウンロードを表示"),subtitle:"",icon:"arrow.down.circle",scope:.commands,target:.command("downloads")))
        append(actions,for:.commands)
        return result
    }
    @discardableResult func restoreClosedPage(_ pageID:UUID)->Bool {
        guard let index=closedPages.lastIndex(where:{$0.1.id == pageID}),
              let i=session.workspaces.firstIndex(where:{$0.id == closedPages[index].0}) else{return false}
        let closed=closedPages[index].1,workspace=session.workspaces[i]
        guard closedPageProfiles[pageID] == workspace.profileID(for:closed),
              closed.groupID == nil || workspace.resolvedTabGroups.contains(where:{$0.id == closed.groupID}) else {
            notify(L("閉じたタブのログイン環境が変わっています。別の環境では復元しません。"),isError:true);return false
        }
        let page=closedPages.remove(at:index).1
        closedPageProfiles[pageID]=nil
        if !session.workspaces[i].pages.contains(where:{$0.id == page.id}) {session.workspaces[i].pages.append(page)}
        session.workspaces[i].selectedPageID=page.id;session.selectedWorkspaceID=session.workspaces[i].id
        revealTabGroup(page.id,in:session.workspaces[i].id);changed();selectionChanged();return true
    }
    func executeUniversal(_ result:UniversalResult,target:PageReference?,reveal:Bool=false) {
        searchPresented=false;commandsPresented=false
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {[weak self] in
            guard let self else{return}
            switch result.target {
            case .tab(let ref):self.activatePage(ref)
            case .favorite(let id):if let link=self.favorites.first(where:{$0.id == id}){_=self.openFavorite(link)}
            case .closed(let id):_=self.restoreClosedPage(id)
            case .download(let id):
                if let record=self.downloads.records.first(where:{$0.id == id}) {
                    if reveal {self.downloads.reveal(record)} else {self.downloads.open(record)}
                }
            case .command(let id):
                if id == "settings" {self.showSettings=true}
                else if id == "downloads" {self.downloadsPresented=true}
                else {self.runCommand(id,target:target)}
            }
        }
    }
}
struct UniversalSearch:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @ObservedObject var downloads:BrowserDownloads
    @State var scope:SearchScope = .all
    @State private var query=""
    @State private var selection:String?
    @State private var target:PageReference?
    @FocusState private var searchFocused:Bool
    @FocusState private var listFocused:Bool
    private var results:[UniversalResult] {store.universalResults(query,scope:scope)}
    private func run(_ reveal:Bool=false) {if let row=results.first(where:{$0.id == selection}) ?? results.first {store.executeUniversal(row,target:target,reveal:reveal)}}
    private func cycle(_ offset:Int) {
        let all=SearchScope.allCases,index=all.firstIndex(of:scope) ?? 0
        scope=all[(index+offset+all.count)%all.count]
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Text(L("検索")).font(.title2.bold());Spacer();Button(L("閉じる")){store.searchPresented=false;store.commandsPresented=false}.keyboardShortcut(.cancelAction)}
            TextField(L("タブ・お気に入り・ファイル・操作を検索"),text:$query)
                .textFieldStyle(.roundedBorder).focused($searchFocused).onSubmit{run()}
                .onKeyPress(.downArrow){listFocused=true;return .handled}
            Picker(L("表示する項目"),selection:$scope) {ForEach(SearchScope.allCases){Text($0.title).tag($0)}}.pickerStyle(.segmented)
            if results.isEmpty {Text(L("見つかりませんでした")).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)}
            else {
                List(selection:$selection) {
                    ForEach(results) {row in
                        HStack(spacing:12) {
                            Image(systemName:row.icon).frame(width:24).foregroundStyle(.secondary)
                            VStack(alignment:.leading,spacing:4) {
                                Text(row.title).lineLimit(1)
                                Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength:8)
                            Text(row.scope.title).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical,5).tag(row.id).contentShape(Rectangle())
                            .onTapGesture(count:2){store.executeUniversal(row,target:target)}
                            .contextMenu {
                                if case .tab(let ref)=row.target {Button(L("分割して表示")){store.searchPresented=false;store.commandsPresented=false;store.setSplit(ref)}}
                                if case .download(let id)=row.target,let record=downloads.records.first(where:{$0.id == id}),downloads.file(for:record) != nil {
                                    Button(L("プレビュー")){store.searchPresented=false;store.commandsPresented=false;DispatchQueue.main.asyncAfter(deadline:.now()+0.15){store.previewDownload(record)}}
                                    Button(L("Finderで表示")){store.executeUniversal(row,target:target,reveal:true)}
                                }
                            }
                    }
                }.listStyle(.inset).focused($listFocused)
                    .onKeyPress(.return,phases:.down){press in run(press.modifiers.contains(.command));return .handled}
                    .onKeyPress(.leftArrow){cycle(-1);return .handled}.onKeyPress(.rightArrow){cycle(1);return .handled}
            }
            Text(L("↑↓ 選択 · Enter 実行 · ←→ 分類 · ⌘F 検索")).font(.caption).foregroundStyle(.secondary)
            Button(""){searchFocused=true}.keyboardShortcut("f",modifiers:.command).hidden().frame(height:0)
        }.padding(20).frame(width:740,height:520)
            .onAppear {target=store.commandsPresented ? store.commandTarget:store.commandPage;selection=results.first?.id;searchFocused=true}
            .onChange(of:query){_,_ in selection=results.first?.id}.onChange(of:scope){_,_ in selection=results.first?.id}
    }
}
