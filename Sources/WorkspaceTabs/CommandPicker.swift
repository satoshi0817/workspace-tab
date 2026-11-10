import SwiftUI
import WorkspaceCore

struct TabSearchRow:Identifiable {
    let workspace:BrowserWorkspace
    let page:BrowserPage
    var id:UUID {page.id}
    var ref:PageReference {PageReference(workspaceID:workspace.id,pageID:page.id)}
}
extension BrowserStore {
    func tabSearchRows(_ query:String)->[TabSearchRow] {
        let words=query.split(whereSeparator:{$0.isWhitespace}).map(String.init)
        return session.workspaces.flatMap { w in
            orderedPages(in:w.id).filter { p in
                let text=[w.name,p.displayTitle,p.title,p.url].joined(separator:" ")
                return words.allSatisfy{text.localizedCaseInsensitiveContains($0)}
            }.map {TabSearchRow(workspace:w,page:$0)}
        }
    }
}
struct AllTabsPicker:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @State private var query=""
    @State private var selection:UUID?
    @FocusState private var listFocused:Bool
    @FocusState private var searchFocused:Bool
    private var rows:[TabSearchRow] {store.tabSearchRows(query).filter { !store.searchForSplit || $0.ref != store.commandPage }}
    private func open(_ row:TabSearchRow) {
        let splitting=store.searchForSplit
        store.searchPresented=false;store.searchForSplit=false
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
            if splitting {store.setSplit(row.ref)} else {store.activatePage(row.ref)}
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(store.searchForSplit ? L("並べて表示するタブ"):L("すべてのタブ")).font(.title2.bold())
                Text("\(rows.count)").foregroundStyle(.secondary)
                Spacer()
                Button(L("検索")) {searchFocused=true}.keyboardShortcut("f",modifiers:.command)
                Button(L("閉じる")) {store.searchPresented=false;store.searchForSplit=false}.keyboardShortcut(.cancelAction)
            }
            TextField(L("アプリ名・ページ名・URLを検索"),text:$query).textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit {if let row=rows.first(where:{$0.id == selection}) ?? rows.first {open(row)}}
                .onKeyPress(.downArrow){listFocused=true;return .handled}
            if rows.isEmpty {Text(L("一致するタブはありません")).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)}
            else {
                List(selection:$selection) {
                    ForEach(rows) {row in
                        HStack(spacing:10) {
                            WorkspaceIcon(store:store,workspace:row.workspace,size:26)
                            VStack(alignment:.leading,spacing:4) {
                                Text(row.page.displayTitle).lineLimit(1)
                                Text(row.workspace.name + (store.detachedWorkspaceIDs.contains(row.workspace.id) ? L(" · 別ウインドウ"):"")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if row.page.pinned == true {Image(systemName:"pin.fill").foregroundStyle(.secondary)}
                            if row.ref == store.commandPage {Image(systemName:"checkmark").foregroundStyle(.secondary)}
                        }.padding(.vertical,5).contentShape(Rectangle()).tag(row.id)
                            .onTapGesture(count:2){open(row)}
                            .contextMenu {Button(L("このタブへ移動")){open(row)};Button(L("分割して表示")){store.searchPresented=false;store.setSplit(row.ref)}}
                    }
                }.listStyle(.inset).focused($listFocused)
                    .onKeyPress(.return){if let row=rows.first(where:{$0.id == selection}) {open(row)};return .handled}
            }
            HStack {
                Text(L("↑↓で選択 · Enterで移動 · ⌘Fで検索")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(store.searchForSplit ? L("分割して表示"):L("このタブへ移動")) {if let row=rows.first(where:{$0.id == selection}) {open(row)}}.disabled(selection == nil)
            }
        }.padding(20).frame(width:680,height:500)
            .onAppear{selection=rows.first(where:{$0.ref == store.commandPage})?.id ?? rows.first?.id;listFocused=true}
            .onChange(of:query){_,_ in selection=rows.first?.id}
    }
}
struct CommandPicker:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @ObservedObject private var preferences=ShortcutPreferences.shared
    @State private var query=""
    @State private var selection:String?
    @FocusState private var listFocused:Bool
    @FocusState private var searchFocused:Bool
    private var commands:[ShortcutAction] {
        ShortcutPreferences.actions.filter{(BrowserCommands.ids.contains($0.id) && $0.id != "commands" || $0.id == "search") && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))}
    }
    private func run(_ action:ShortcutAction) {
        let target=store.commandTarget
        store.commandsPresented=false
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {store.runCommand(action.id == "search" ? "allTabs":action.id,target:target)}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Text(L("コマンド")).font(.title2.bold());Spacer();Button(L("閉じる")){store.commandsPresented=false}.keyboardShortcut(.cancelAction)}
            TextField(L("操作名を検索"),text:$query).textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit {if let item=commands.first(where:{$0.id == selection}) ?? commands.first {run(item)}}
                .onKeyPress(.downArrow){listFocused=true;return .handled}
            List(selection:$selection) {
                ForEach(commands) {action in
                    HStack {Text(action.title);Spacer();Text(preferences.binding(action).label).monospaced().foregroundStyle(.secondary)}
                        .padding(.vertical,7).contentShape(Rectangle()).tag(action.id).onTapGesture(count:2){run(action)}
                }
            }.listStyle(.inset).focused($listFocused)
                .onKeyPress(.return){if let item=commands.first(where:{$0.id == selection}){run(item)};return .handled}
            Text(L("↑↓で選択 · Enterで実行 · キーは設定で変更できます")).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width:640,height:480)
            .onAppear{selection=commands.first?.id;searchFocused=true}
            .onChange(of:query){_,_ in selection=commands.first?.id}
    }
}
