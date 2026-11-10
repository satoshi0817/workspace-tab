import SwiftUI
import AppKit
import WorkspaceCore

extension BrowserStore {
    func favoriteWorkspace(_ link:FavoriteLink)->BrowserWorkspace? {
        if let raw=link.categoryWorkspaceID?.trimmingCharacters(in:.whitespacesAndNewlines),!raw.isEmpty {
            guard let id=NotionWorkspace.normalizedID(raw) else{return nil}
            let env=BrowserAddress.url(link.url).flatMap(NotionWorkspace.environment)
            let matches=session.workspaces.filter { w in
                NotionWorkspace.normalizedID(w.notionSpaceID) == id &&
                (env == nil || BrowserAddress.url(w.homeURL).flatMap(NotionWorkspace.environment) == env)
            }
            return matches.count == 1 ? matches[0]:nil
        }
        let category=link.category.trimmingCharacters(in:.whitespacesAndNewlines)
        if !category.isEmpty {
            let matches=session.workspaces.filter {$0.name.trimmingCharacters(in:.whitespacesAndNewlines) == category}
            if !matches.isEmpty {return matches.count == 1 ? matches[0]:nil}
        }
        return workspace(link.workspaceID)
    }
    var favorites: [FavoriteLink] { session.favorites ?? [] }
    func prepareFavorite(workspaceID: UUID, pageID: UUID) {
        guard let page = page(PageReference(workspaceID: workspaceID, pageID: pageID)) else { return }
        window?.makeKeyAndOrderFront(nil)
        favoriteDraft = FavoriteLink(title: page.displayTitle, url: page.url, workspaceID: workspaceID)
    }
    @discardableResult func saveFavorite(_ value: FavoriteLink) -> Bool {
        guard let url = BrowserAddress.url(value.url), favoriteWorkspace(value) != nil,
              !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var copy = value
        copy.workspaceID=favoriteWorkspace(value)!.id
        copy.url = BrowserAddress.savedURL(url)
        copy.title = copy.title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.category = copy.category.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.notionSourceID != nil {
            do {try notion.enqueue(copy)} catch {self.error=error.localizedDescription;return false}
        }
        var links = favorites
        if let index = links.firstIndex(where: { $0.id == copy.id }) { links[index] = copy } else { links.append(copy) }
        session.favorites = links; changed(); notify(copy.notionSourceID == nil ? L("お気に入りを保存しました"):L("Notionへの保存を予約しました"));if copy.notionSourceID != nil {Task{await notion.sync()}}; return true
    }
    func deleteFavorite(_ id: UUID) {
        if let value=favorites.first(where:{$0.id == id}),value.notionSourceID != nil {
            do {try notion.enqueue(value,delete:true)} catch {self.error=error.localizedDescription;return}
            Task{await notion.sync()}
        }
        session.favorites = favorites.filter { $0.id != id }; changed(); notify(L("お気に入りを削除しました"))
    }
    @discardableResult func openFavorite(_ link: FavoriteLink, newTab: Bool = false) -> Bool {
        guard let workspace = favoriteWorkspace(link), let url = BrowserAddress.url(link.url) else {
            error = L("開く先を一意に特定できません。CategoriesのWorkspace ID、アプリタブのWorkspace ID・名前・HOME URLを確認してください。")
            return false
        }
        let target = BrowserAddress.savedURL(url)
        let existing = existingPage(url:target,in:workspace.id)
        selectWorkspace(workspace.id)
        if !newTab, let existing { selectPage(existing.id, in: workspace.id) }
        else { _ = addPage(to: workspace.id, url: target) }
        favoritesPresented = false
        return true
    }
}

struct FavoriteSection:Identifiable {
    var id:String {category}
    let category:String
    var title:String {category.isEmpty ? L("未分類"):category}
    let links:[FavoriteLink]
}
extension BrowserStore {
    func favoriteSections(_ input:[FavoriteLink]? = nil)->[FavoriteSection] {
        let grouped=Dictionary(grouping:input ?? favorites,by:{$0.category.trimmingCharacters(in:.whitespacesAndNewlines)})
        let categories=notion.state.cache?.sources.flatMap(\.categories) ?? []
        func rank(_ name:String)->Double {categories.filter{$0.name.trimmingCharacters(in:.whitespacesAndNewlines) == name}.compactMap(\.order).min() ?? .infinity}
        let names=grouped.keys.sorted {a,b in
            if a.isEmpty != b.isEmpty {return !a.isEmpty}
            if rank(a) != rank(b) {return rank(a)<rank(b)}
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return names.map {name in FavoriteSection(category:name,links:grouped[name]!.sorted {a,b in
            if a.pinned != b.pinned {return a.pinned}
            if (a.order ?? .infinity) != (b.order ?? .infinity) {return (a.order ?? .infinity)<(b.order ?? .infinity)}
            let comparison=a.title.localizedStandardCompare(b.title)
            return comparison == .orderedSame ? a.id.uuidString<b.id.uuidString:comparison == .orderedAscending
        })}
    }
    func launcherIconPath(_ file:String?)->String? {
        guard let file,!file.isEmpty,file == URL(fileURLWithPath:file).lastPathComponent else{return nil}
        let url=directory.appendingPathComponent("Icons").appendingPathComponent(file)
        return FileManager.default.fileExists(atPath:url.path) ? url.path:nil
    }
}

struct FavoritesLauncher: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var category:String? = nil
    @State private var draft: FavoriteLink?
    @State private var deleting: FavoriteLink?
    @State private var selection: UUID?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    private var categories:[FavoriteSection] {store.favoriteSections()}
    private var sections:[FavoriteSection] {
        let words=query.split(whereSeparator:{$0.isWhitespace}).map(String.init)
        return store.favoriteSections(store.favorites.filter {link in
            let name=link.category.trimmingCharacters(in:.whitespacesAndNewlines)
            let text=[link.title,link.url,name,store.favoriteWorkspace(link)?.name ?? ""].joined(separator:" ")
            return (category == nil || category == name) && words.allSatisfy{text.localizedCaseInsensitiveContains($0)}
        })
    }
    private var links:[FavoriteLink] {sections.flatMap(\.links)}
    private func cycleCategory(_ offset:Int) {
        let values:[String?]=[nil]+categories.map{Optional($0.category)}
        let current=values.firstIndex(where:{$0 == category}) ?? 0
        category=values[(current+offset+values.count)%values.count]
        selection=links.first?.id;listFocused=true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("お気に入り")).font(.title2.weight(.semibold)); Spacer()
                Button(L("追加…")) { draft = FavoriteLink(title: "", url: "", workspaceID: store.session.selectedWorkspaceID ?? UUID()) }.disabled(store.session.workspaces.isEmpty)
                Button(L("閉じる")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField(L("タイトル・URL・カテゴリ・アプリタブを検索"), text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit { if let link = links.first(where: { $0.id == selection }) ?? links.first { _ = store.openFavorite(link) } }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    categoryButton(L("すべて"), value: nil)
                    ForEach(categories) { categoryButton($0.title, value: $0.category) }
                }
            }
            if links.isEmpty {
                VStack(spacing: 8) {
                    Text(store.favorites.isEmpty ? L("お気に入りを追加してください") : L("一致するお気に入りはありません"))
                    Text(L("URL欄の星ボタンから、開いているページも登録できます。")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(sections) { section in
                        Section(section.title) {
                    ForEach(section.links) { link in
                        HStack(spacing: 10) {
                            Button { _ = store.openFavorite(link) } label: {
                                HStack(spacing: 10) {
                                    FavoriteIcon(store: store, link: link)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(link.title).font(.body.weight(.medium)).lineLimit(1)
                                        Text(link.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(store.favoriteWorkspace(link)?.name ?? L("開く先を設定してください")).lineLimit(1)
                                        if !link.category.isEmpty { Text(link.category).foregroundStyle(.secondary).lineLimit(1) }
                                    }.font(.caption).frame(maxWidth: 180, alignment: .trailing)
                                    if link.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(store.favoriteWorkspace(link) == nil)
                            Button { draft = link } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help(L("お気に入りを編集")).accessibilityLabel(L("編集：") + link.title)
                        }.padding(.vertical, 5).tag(link.id)
                        .contextMenu {
                            Button(L("開く")) { _ = store.openFavorite(link) }.disabled(store.favoriteWorkspace(link) == nil)
                            Button(L("新しいブラウザタブで開く")) { _ = store.openFavorite(link, newTab: true) }.disabled(store.favoriteWorkspace(link) == nil)
                            Button(L("編集…")) { draft = link }
                            Button(L("URLをコピー")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.url, forType: .string); store.notify(L("URLをコピーしました")) }
                            Button(link.pinned ? L("ピン留めを解除") : L("ピン留め")) { var copy = link; copy.pinned.toggle(); _ = store.saveFavorite(copy) }
                            Divider(); Button(L("削除…"), role: .destructive) { deleting = link }
                        }
                    }
                        }
                    }
                }.listStyle(.inset).focused($listFocused)
                    .onKeyPress(.leftArrow){cycleCategory(-1);return .handled}
                    .onKeyPress(.rightArrow){cycleCategory(1);return .handled}
                    .onKeyPress(.return) {
                        if let link=links.first(where:{$0.id == selection}) {_ = store.openFavorite(link)}
                        return .handled
                    }
            }
            Text(L("← →でカテゴリ切り替え · ↑↓で選択 · Enterで開く"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 740, height: 510)
            .onAppear { selection=links.first?.id;listFocused=true }
            .onChange(of: query) { _,_ in selection=links.first?.id }
            .onChange(of: category) { _,_ in selection=links.first?.id;listFocused=true }
            .sheet(item: $draft) { FavoriteEditor(store: store, draft: $0) }
            .alert(L("お気に入りを削除しますか？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(L("キャンセル"), role: .cancel) { deleting = nil }
                Button(L("削除"), role: .destructive) { if let link = deleting { store.deleteFavorite(link.id) }; deleting = nil }
            } message: { Text((deleting?.title ?? "") + (deleting?.notionPageID != nil ? L("\nNotionの該当ページもゴミ箱へ移動します。"):"")) }
    }
    private func categoryButton(_ title: String, value: String?) -> some View {
        Button(title) { category = value; selection = links.first?.id }
            .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 5)
            .background(category == value ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule())
            .accessibilityAddTraits(category == value ? .isSelected : [])
    }
}

struct FavoriteIcon: View {
    @ObservedObject private var localization = AppLocalization.shared
    let store: BrowserStore
    let link: FavoriteLink
    var body: some View {
        Group {
            if let file = link.iconFile, file == URL(fileURLWithPath: file).lastPathComponent,
               let image = store.iconCache.image(directory:store.directory,name:file) {
                Image(nsImage: image).renderingMode(image.isTemplate ? .template:.original).resizable().scaledToFit()
            } else if !link.emoji.isEmpty { Text(link.emoji).font(.system(size: 23)) }
            else { Image(systemName: "link").font(.system(size: 21)).foregroundStyle(.secondary) }
        }.frame(width: 32, height: 32)
    }
}

struct FavoriteEditor: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store: BrowserStore
    @State var draft: FavoriteLink
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("お気に入りを編集")).font(.title2.weight(.semibold))
            Form {
                Picker(L("保存先"),selection:Binding(get:{draft.notionSourceID ?? ""},set:{value in
                    draft.notionSourceID=value.isEmpty ? nil:value;draft.notionPageID=nil;draft.notionEditedTime=nil;draft.importKey=nil
                })) {
                    Text(L("内蔵（このMac）")).tag("")
                    ForEach(store.notion.state.sources){source in Text("Notion: "+source.title).tag(source.id)}
                }.disabled(draft.notionPageID != nil)
                if draft.notionSourceID != nil {Text(L("Notion保存をオンにすると同期されます。画像アイコンはこのMacに保存し、絵文字はNotionにも保存します。")).font(.caption).foregroundStyle(.secondary)}
                TextField(L("タイトル"), text: $draft.title)
                TextField("URL", text: $draft.url)
                Picker(L("開くアプリタブ"), selection: $draft.workspaceID) {
                    if store.workspace(draft.workspaceID) == nil { Text(L("選択してください")).tag(draft.workspaceID) }
                    ForEach(store.session.workspaces) { Text($0.name).tag($0.id) }
                }
                if let workspace = store.favoriteWorkspace(draft) {
                    Text(L("ログイン環境：") + (store.profile(workspace.profileID)?.name ?? "")).font(.caption).foregroundStyle(.secondary)
                }
                TextField(L("アイコン（絵文字・文字）"), text: $draft.emoji)
                IconSelectionRow(store:store,file:$draft.iconFile,defaultSymbol:"link")
                TextField(L("カテゴリ"), text: $draft.category)
                Text(L("Category名とアプリタブ名が一致すると、そちらを優先して開きます。同名のタブが複数ある場合は開けません。")).font(.caption).foregroundStyle(.secondary)
                Toggle(L("ピン留め"), isOn: $draft.pinned)
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button(L("キャンセル")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("保存")) { if store.saveFavorite(draft) { dismiss() } }.keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || BrowserAddress.url(draft.url) == nil || draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.favoriteWorkspace(draft) == nil)
            }
        }.padding(20).frame(width: 540, height: 570)
    }
}
