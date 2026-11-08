import SwiftUI
import WorkspaceCore

struct BrowserTabButton: View {
    @ObservedObject var store:BrowserStore
    let workspace:BrowserWorkspace
    let page:BrowserPage
    let selected:Bool
    let isRight:Bool
    let detached:Bool
    private var ink:Color {Palette.ink(workspace.color)}
    private func select() {
        if isRight {store.setSplit(PageReference(workspaceID:workspace.id,pageID:page.id))}
        else {store.selectPage(page.id,in:workspace.id)}
        store.focusedPage=PageReference(workspaceID:workspace.id,pageID:page.id)
    }
    var body:some View {
        HStack(spacing:6) {
                HStack(spacing:6) {
                    if let file=page.tabIconFile,let image=store.iconCache.image(directory:store.directory,name:file) {Image(nsImage:image).resizable().scaledToFit().frame(width:18,height:18)}
                    else if let emoji=page.tabEmoji,!emoji.isEmpty {Text(emoji).font(.system(size:16))}
                    else {BrowserFavicon(cache:store.faviconCache,profile:workspace.profileID,pageURL:page.url)}
                    if !page.iconOnly {Text(page.displayTitle).lineLimit(1).frame(maxWidth:180)}
                }.frame(minWidth:page.iconOnly ? 24:0,minHeight:32).contentShape(Rectangle())
                    .overlay(TabDragHandle(payload:TabDragPayload(workspaceID:workspace.id,pageID:page.id),title:page.displayTitle,drop:{payload,after in if let id=payload.pageID,payload.workspaceID == workspace.id {_ = store.movePage(id,in:workspace.id,relativeTo:page.id,after:after)}},click:{select()}))
                .accessibilityElement(children:.ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {select()}
                .accessibilityLabel(page.displayTitle + (page.pinned == true ? "（ピン留め）":""))
                .accessibilityAddTraits(selected ? .isSelected:[])
            if page.pinned != true {
                Button {store.closePage(page.id,in:workspace.id)} label:{Image(systemName:"xmark").font(.system(size:9))}.buttonStyle(.plain).help("ブラウザタブを閉じる")
            }
        }.font(.system(size:12,weight:selected ? .semibold:.regular))
            .padding(.horizontal,8).foregroundStyle(ink)
            .background(selected ? (ink == .white ? Color.black:Color.white).opacity(0.16):Color.clear,in:RoundedRectangle(cornerRadius:6))
            .overlay(alignment:.bottom) {if selected {Capsule().fill(ink).frame(height:2).padding(.horizontal,5)}}
            .help(page.displayTitle + "\n" + page.url)
            .contextMenu {
                Button(page.pinned == true ? "ピン留めを解除":"タブをピン留め") {var copy=page;copy.pinned=page.pinned != true;store.updateBrowserTab(copy,in:workspace.id)}
                if page.pinned == true {
                    Picker("ピン留めタブの表示",selection:Binding(get:{page.pinnedDisplay ?? "icon"},set:{mode in var copy=page;copy.pinnedDisplay=mode;store.updateBrowserTab(copy,in:workspace.id)})) {
                        Text("アイコンのみ").tag("icon")
                        Text("アイコンと名前").tag("name")
                    }
                }
                Menu("グループへ移動") {
                    ForEach(workspace.resolvedTabGroups) {group in
                        Button {store.movePageToGroup(page.id,in:workspace.id,groupID:group.id)} label:{
                            if workspace.groupID(for:page) == group.id {Label(group.name,systemImage:"checkmark")} else {Text(group.name)}
                        }
                    }
                }
                Button("表示名・アイコンを編集…") {
                    store.window?.makeKeyAndOrderFront(nil)
                    store.editingBrowserTab=PageReference(workspaceID:workspace.id,pageID:page.id)
                }
                Button("右側に並べて表示") {store.setSplit(PageReference(workspaceID:workspace.id,pageID:page.id))}.disabled(detached || page.id == store.selectedPage?.id)
                Divider()
                Button("タブを閉じる") {store.closePage(page.id,in:workspace.id)}.disabled(page.pinned == true)
            }
    }
}

struct BrowserTabEditor:View {
    @ObservedObject var store:BrowserStore
    let workspaceID:UUID
    @State var draft:BrowserPage
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("タブの表示").font(.title2.weight(.semibold))
            TextField("表示名（空欄でページ名）",text:Binding(get:{draft.tabName ?? ""},set:{draft.tabName=$0}))
            TextField("アイコン（絵文字・文字、空欄でサイトのfavicon）",text:Binding(get:{draft.tabEmoji ?? ""},set:{draft.tabEmoji=String($0.prefix(2))}))
            HStack(spacing:12) {
                if let file=draft.tabIconFile,let image=store.iconCache.image(directory:store.directory,name:file) {
                    Image(nsImage:image).resizable().scaledToFit().frame(width:28,height:28)
                }
                Button("画像を選ぶ…") {if let file=store.chooseIcon() {draft.tabIconFile=file}}
                if draft.tabIconFile != nil {Button("画像を解除") {draft.tabIconFile=nil}}
                Spacer()
            }
            if draft.tabIconFile != nil {Text("画像を優先して表示します。解除すると絵文字またはfaviconに戻ります。").font(.caption).foregroundStyle(.secondary)}
            if let workspace=store.workspace(workspaceID) {
                Picker("グループ",selection:Binding(get:{workspace.groupID(for:draft)},set:{draft.groupID=$0})) {
                    ForEach(workspace.resolvedTabGroups) {group in Text(group.name).tag(group.id)}
                }
            }
            Toggle("ピン留め",isOn:Binding(get:{draft.pinned == true},set:{draft.pinned=$0}))
            if draft.pinned == true {
                Picker("表示",selection:Binding(get:{draft.pinnedDisplay ?? "icon"},set:{draft.pinnedDisplay=$0})) {
                    Text("アイコンのみ").tag("icon")
                    Text("アイコンと名前").tag("name")
                }.pickerStyle(.segmented)
            }
            HStack {
                Spacer()
                Button("キャンセル") {dismiss()}.keyboardShortcut(.cancelAction)
                Button("保存") {store.updateBrowserTab(draft,in:workspaceID);store.notify("タブの表示を保存しました");dismiss()}.keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width:480)
    }
}
