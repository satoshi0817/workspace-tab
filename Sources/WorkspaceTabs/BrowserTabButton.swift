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
                    .overlay(TabDragHandle(payload:TabDragPayload(workspaceID:workspace.id,pageID:page.id),title:page.displayTitle,drop:{payload,after in if let id=payload.pageID,payload.workspaceID == workspace.id {_ = store.movePage(id,in:workspace.id,relativeTo:page.id,after:after)}},click:{select()}))
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
                Button(page.pinned == true ? L("ピン留めを解除"):L("タブをピン留め")) {var copy=page;copy.pinned=page.pinned != true;store.updateBrowserTab(copy,in:workspace.id)}
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
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L("タブの表示")).font(.title2.weight(.semibold))
            TextField(L("表示名（空欄でページ名）"),text:Binding(get:{draft.tabName ?? ""},set:{draft.tabName=$0}))
            TextField(L("アイコン（絵文字・文字、空欄でサイトのfavicon）"),text:Binding(get:{draft.tabEmoji ?? ""},set:{draft.tabEmoji=String($0.prefix(2))}))
            IconSelectionRow(store:store,file:$draft.tabIconFile)
            if let workspace=store.workspace(workspaceID) {
                Picker(L("グループ"),selection:Binding(get:{workspace.groupID(for:draft)},set:{draft.groupID=$0})) {
                    ForEach(workspace.resolvedTabGroups) {group in Text(group.name).tag(group.id)}
                }
            }
            Toggle(L("ピン留め"),isOn:Binding(get:{draft.pinned == true},set:{draft.pinned=$0}))
            if draft.pinned == true {
                Picker(L("表示"),selection:Binding(get:{draft.pinnedDisplay ?? "icon"},set:{draft.pinnedDisplay=$0})) {
                    Text(L("アイコンのみ")).tag("icon")
                    Text(L("アイコンと名前")).tag("name")
                }.pickerStyle(.segmented)
            }
            HStack {
                Spacer()
                Button(L("キャンセル")) {dismiss()}.keyboardShortcut(.cancelAction)
                Button(L("保存")) {if store.updateBrowserTab(draft,in:workspaceID) {store.notify(L("タブの表示を保存しました"));dismiss()}}.keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width:480)
    }
}
