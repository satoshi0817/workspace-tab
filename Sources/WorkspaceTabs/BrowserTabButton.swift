import SwiftUI
import WorkspaceCore

struct BrowserTabButton: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store:BrowserStore
    let workspace:BrowserWorkspace
    let page:BrowserPage
    let selected:Bool
    let isRight:Bool
    let detached:Bool
    @State private var hovered=false
    private var ink:Color {Palette.ink(workspace.color)}
    private func select() {
        if isRight {store.setSplit(PageReference(workspaceID:workspace.id,pageID:page.id))}
        else {store.selectPage(page.id,in:workspace.id)}
        store.focusedPage=PageReference(workspaceID:workspace.id,pageID:page.id)
    }
    var body:some View {
        HStack(spacing:BrowserLayout.gap) {
                HStack(spacing:BrowserLayout.gap) {
                    if let file=page.tabIconFile,let image=store.iconCache.image(directory:store.directory,name:file) {Image(nsImage:image).renderingMode(image.isTemplate ? .template:.original).resizable().scaledToFit().frame(width:18,height:18)}
                    else if let emoji=page.tabEmoji,!emoji.isEmpty {Text(emoji).font(.system(size:16))}
                    else {BrowserFavicon(cache:store.faviconCache,profile:workspace.profileID(for:page),pageURL:page.url)}
                    if !page.iconOnly {Text(page.displayTitle).lineLimit(1).frame(maxWidth:180)}
                }.frame(minWidth:page.iconOnly ? 16:0,minHeight:BrowserLayout.control).contentShape(Rectangle())
                    .overlay(TabDragHandle(payload:TabDragPayload(workspaceID:workspace.id,pageID:page.id),title:page.displayTitle,drop:{payload,after in if let id=payload.pageID,payload.workspaceID == workspace.id {_ = store.movePage(id,in:workspace.id,relativeTo:page.id,after:after);if !detached,store.secondPanePageIDs().contains(id) != isRight {store.movePageToPane(PageReference(workspaceID:workspace.id,pageID:id),second:isRight)}}},click:{select()}))
                .accessibilityElement(children:.ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {select()}
                .accessibilityLabel(page.displayTitle + (page.pinned == true ? L("（ピン留め）"):""))
                .accessibilityAddTraits(selected ? .isSelected:[])
            if page.pinned != true {
                Button {store.closePage(page.id,in:workspace.id)} label:{Image(systemName:"xmark").font(.system(size:9)).frame(width:16,height:20).contentShape(Rectangle())}.buttonStyle(.plain).help(L("ブラウザタブを閉じる"))
            }
        }.font(.system(size:12,weight:selected ? .semibold:.medium))
            .padding(.horizontal,BrowserLayout.gap).foregroundStyle(ink)
            .modifier(BrowserStripChip(ink:ink,selected:selected,hovered:hovered))
            .overlay(alignment:.bottom) {if selected {Capsule().fill(ink).frame(height:2).padding(.horizontal,BrowserLayout.gap).padding(.bottom,2)}}
            .onHover {hovered=$0}
            .help(page.displayTitle + "\n" + page.url)
            .contextMenu {
                if page.pinned == true {
                    Button(L("ピン留めを解除")) {var copy=page;copy.pinned=false;store.updateBrowserTab(copy,in:workspace.id)}
                    Button(L("ピン留めしたページに戻る")) {store.openPinnedURL(PageReference(workspaceID:workspace.id,pageID:page.id))}.disabled(page.pinnedURL == nil)
                    Button(L("ピン留めの設定…")) {
                        store.window?.makeKeyAndOrderFront(nil)
                        store.editingBrowserTab=PageReference(workspaceID:workspace.id,pageID:page.id)
                    }
                } else {
                    // Pinning opens the settings first, so the page it will reopen is visible.
                    Button(L("タブをピン留め…")) {
                        store.window?.makeKeyAndOrderFront(nil)
                        store.editingBrowserTabToPin=true
                        store.editingBrowserTab=PageReference(workspaceID:workspace.id,pageID:page.id)
                    }
                }
                if page.pinned == true {
                    Picker(L("ピン留めタブの表示"),selection:Binding(get:{page.pinnedDisplay ?? "icon"},set:{mode in var copy=page;copy.pinnedDisplay=mode;store.updateBrowserTab(copy,in:workspace.id)})) {
                        Text(L("アイコンのみ")).tag("icon")
                        Text(L("アイコンと名前")).tag("name")
                    }
                }
                Menu(L("グループへ移動")) {
                    ForEach(workspace.resolvedTabGroups) {group in
                        Button {store.movePageToGroup(page.id,in:workspace.id,groupID:group.id)} label:{
                            if workspace.groupID(for:page) == group.id {Label(group.name,systemImage:"checkmark")} else {Text(group.name)}
                        }
                    }
                }
                Button(L("表示名・アイコンを編集…")) {
                    store.window?.makeKeyAndOrderFront(nil)
                    store.editingBrowserTab=PageReference(workspaceID:workspace.id,pageID:page.id)
                }
                Button(L("右側に並べて表示")) {store.setSplit(PageReference(workspaceID:workspace.id,pageID:page.id))}.disabled(detached || page.id == store.selectedPage?.id)
                Divider()
                Button(L("タブを閉じる")) {store.closePage(page.id,in:workspace.id)}.disabled(page.pinned == true)
            }
    }
}

struct BrowserTabEditor:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store:BrowserStore
    let workspaceID:UUID
    @State var draft:BrowserPage
    var pinning=false
    @Environment(\.dismiss) private var dismiss
    /// The editor's starting values. Opened to pin, it proposes the page now showing.
    static func draft(_ page:BrowserPage,pinning:Bool)->BrowserPage {
        var draft=page
        if pinning {draft.pinned=true}
        if draft.pinned == true,draft.pinnedURL == nil,pinning {draft.pinnedURL=pinnable(page.url)}
        return draft
    }
    private static func pinnable(_ url:String)->String? {BrowserAddress.url(url).flatMap{$0.scheme == "about" ? nil:url}}
    private var currentURL:String? {store.workspace(workspaceID)?.pages.first{$0.id == draft.id}.flatMap{Self.pinnable($0.url)}}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(pinning ? L("タブをピン留め"):L("タブの表示")).font(.title2.weight(.semibold))
            TextField(L("表示名（空欄でページ名）"),text:Binding(get:{draft.tabName ?? ""},set:{draft.tabName=$0}))
            TextField(L("アイコン（絵文字・文字、空欄でサイトのfavicon）"),text:Binding(get:{draft.tabEmoji ?? ""},set:{draft.tabEmoji=String($0.prefix(2))}))
            IconSelectionRow(store:store,file:$draft.tabIconFile)
            if let workspace=store.workspace(workspaceID) {
                Picker(L("グループ"),selection:Binding(get:{workspace.groupID(for:draft)},set:{draft.groupID=$0})) {
                    ForEach(workspace.resolvedTabGroups) {group in Text(group.name).tag(group.id)}
                }
            }
            Toggle(L("ピン留め"),isOn:Binding(get:{draft.pinned == true},set:{draft.pinned=$0;if $0,draft.pinnedURL == nil {draft.pinnedURL=currentURL}}))
            if draft.pinned == true {
                Picker(L("表示"),selection:Binding(get:{draft.pinnedDisplay ?? "icon"},set:{draft.pinnedDisplay=$0})) {
                    Text(L("アイコンのみ")).tag("icon")
                    Text(L("アイコンと名前")).tag("name")
                }.pickerStyle(.segmented)
                VStack(alignment:.leading,spacing:6) {
                    Text(L("ピン留めするページ")).font(.headline)
                    HStack {
                        TextField(L("URL（空欄で最後に開いていたページ）"),text:Binding(get:{draft.pinnedURL ?? ""},set:{draft.pinnedURL=$0.isEmpty ? nil:$0}))
                        Button(L("今のページを使う")) {draft.pinnedURL=currentURL}.disabled(currentURL == nil || currentURL == draft.pinnedURL)
                    }
                    Text(L("アプリを開き直すと、このタブはこのURLで開きます。空欄にすると、最後に開いていたページを復元します。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
            HStack {
                Spacer()
                Button(L("キャンセル")) {dismiss()}.keyboardShortcut(.cancelAction)
                Button(pinning ? L("ピン留め"):L("保存")) {if store.updateBrowserTab(draft,in:workspaceID) {store.notify(L("タブの表示を保存しました"));dismiss()}}.keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width:520)
    }
}
