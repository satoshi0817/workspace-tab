import SwiftUI
import AppKit
import WorkspaceCore

extension BrowserStore {
    func visibleGroupPages(in workspaceID:UUID)->[BrowserPage] {
        guard let w=workspace(workspaceID) else{return []}
        return orderedPages(in:workspaceID).filter{w.groupID(for:$0) == w.visibleGroupID}
    }
    // Browsing groups changes only the strip. Never select or load a page here.
    func showTabGroup(_ groupID:UUID,in workspaceID:UUID) {
        guard let i=session.workspaces.firstIndex(where:{$0.id == workspaceID}),
              session.workspaces[i].resolvedTabGroups.contains(where:{$0.id == groupID}) else{return}
        session.workspaces[i].visibleTabGroupID=groupID;changed()
    }
    func cycleTabGroup(_ offset:Int,in workspaceID:UUID) {
        guard let w=workspace(workspaceID) else{return}
        let groups=w.resolvedTabGroups
        guard groups.count>1,let index=groups.firstIndex(where:{$0.id == w.visibleGroupID}) else{return}
        showTabGroup(groups[(index+offset%groups.count+groups.count)%groups.count].id,in:workspaceID)
    }
    func revealTabGroup(_ pageID:UUID,in workspaceID:UUID) {
        guard let i=session.workspaces.firstIndex(where:{$0.id == workspaceID}),
              let page=session.workspaces[i].pages.first(where:{$0.id == pageID}) else{return}
        session.workspaces[i].visibleTabGroupID=session.workspaces[i].groupID(for:page)
    }
    @discardableResult func saveTabGroup(_ value:BrowserTabGroup,in workspaceID:UUID)->Bool {
        let name=String(value.name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty,let i=session.workspaces.firstIndex(where:{$0.id == workspaceID}) else{return false}
        var groups=session.workspaces[i].resolvedTabGroups
        guard !groups.contains(where:{$0.id != value.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame}) else {
            notify("同じ名前のグループがあります",isError:true);return false
        }
        let group=BrowserTabGroup(id:value.id,name:name)
        if let j=groups.firstIndex(where:{$0.id == value.id}) {groups[j]=group} else {groups.append(group)}
        session.workspaces[i].tabGroups=groups;session.workspaces[i].visibleTabGroupID=value.id;changed();return true
    }
    func movePageToGroup(_ pageID:UUID,in workspaceID:UUID,groupID:UUID) {
        guard let i=session.workspaces.firstIndex(where:{$0.id == workspaceID}),
              let j=session.workspaces[i].pages.firstIndex(where:{$0.id == pageID}),
              session.workspaces[i].resolvedTabGroups.contains(where:{$0.id == groupID}) else{return}
        session.workspaces[i].pages[j].groupID=groupID;changed()
    }
    func removeTabGroup(_ groupID:UUID,in workspaceID:UUID) {
        guard groupID != workspaceID,let i=session.workspaces.firstIndex(where:{$0.id == workspaceID}) else{return}
        for j in session.workspaces[i].pages.indices where session.workspaces[i].pages[j].groupID == groupID {
            session.workspaces[i].pages[j].groupID=nil
        }
        session.workspaces[i].tabGroups=session.workspaces[i].resolvedTabGroups.filter{$0.id != groupID}
        if session.workspaces[i].visibleTabGroupID == groupID {session.workspaces[i].visibleTabGroupID=workspaceID}
        changed()
    }
}

struct BrowserGroupPicker:View {
    @ObservedObject var store:BrowserStore
    let workspace:BrowserWorkspace
    @State private var editing:BrowserTabGroup?
    @State private var removing=false
    private var current:BrowserTabGroup {workspace.resolvedTabGroups.first{$0.id == workspace.visibleGroupID}!}
    var body:some View {
        Menu {
            ForEach(workspace.resolvedTabGroups) {group in
                Button {store.showTabGroup(group.id,in:workspace.id)} label:{
                    if group.id == current.id {Label(group.name,systemImage:"checkmark")} else {Text(group.name)}
                }
            }
            Divider()
            Button("新しいグループ…") {editing=BrowserTabGroup(name:"")}
            Button("グループ名を変更…") {editing=current}
            if current.id != workspace.id {Button("グループを削除…") {removing=true}}
        } label:{
            // AppKit menus replace SwiftUI label foreground styles with system ink.
            // Preserve the tab bar's explicit contrast color, including the chevron.
            Image(nsImage:Palette.groupMenuLabel(current.name,ink:Palette.ink(workspace.color)))
                .renderingMode(.original)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(maxWidth:150)
            .padding(.horizontal,10).frame(height:28)
            .background(Palette.ink(workspace.color).opacity(0.12),in:Capsule())
            .overlay(Capsule().strokeBorder(Palette.ink(workspace.color).opacity(0.18),lineWidth:0.5))
            .padding(.leading,8)
            .accessibilityLabel("タブグループ: "+current.name)
            .help("表示するタブグループ。上下スクロールでも切り替えられます。ページはタブをクリックするまで変わりません。")
            .sheet(item:$editing,onDismiss:store.restorePanelFocus) {group in
                BrowserGroupEditor(store:store,workspaceID:workspace.id,draft:group)
            }
            .alert("グループを削除しますか？",isPresented:$removing) {
                Button("キャンセル",role:.cancel) {}
                Button("削除",role:.destructive) {store.removeTabGroup(current.id,in:workspace.id)}
            } message:{Text("タブは閉じずに、先頭のグループへ移動します。")}
    }
}
private struct BrowserGroupEditor:View {
    @ObservedObject var store:BrowserStore
    let workspaceID:UUID
    @State var draft:BrowserTabGroup
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("タブグループ").font(.title2.weight(.semibold))
            TextField("名前（例：Notion、外部ツール）",text:$draft.name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("キャンセル") {dismiss()}.keyboardShortcut(.cancelAction)
                Button("保存") {if store.saveTabGroup(draft,in:workspaceID) {dismiss()}}
                    .keyboardShortcut(.defaultAction).disabled(draft.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width:340)
    }
}

// One trackpad gesture changes at most one group; momentum never changes groups.
// Horizontal scrolling remains available for overflowing tab rows.
struct TabGroupScrollGesture {
    var accumulated:Double=0
    var switched=false
    var lastTime:Double = -1
    mutating func step(delta:Double,precise:Bool,time:Double,began:Bool,ended:Bool,momentum:Bool)->Int? {
        if momentum {return nil}
        if began || time-lastTime>0.35 {accumulated=0;switched=false}
        defer {lastTime=time;if ended {accumulated=0;switched=false}}
        guard delta != 0,!switched else{return nil}
        accumulated += delta
        guard abs(accumulated)>=(precise ? 32:1) else{return nil}
        if precise {switched=true} else {
            guard time-lastTime>0.25 else{return nil}
            accumulated=0
        }
        return delta<0 ? 1:-1
    }
}
struct TabGroupScrollArea:NSViewRepresentable {
    var enabled:Bool
    var cycle:(Int)->Void
    func makeNSView(context:Context)->Area {Area()}
    func updateNSView(_ view:Area,context:Context) {view.enabled=enabled;view.cycle=cycle}
    static func dismantleNSView(_ view:Area,coordinator:()) {view.stop()}
    final class Area:NSView {
        var enabled=false
        var cycle:((Int)->Void)?
        private var monitor:Any?
        private var gesture=TabGroupScrollGesture()
        override func hitTest(_ point:NSPoint)->NSView? {nil}
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow();stop()
            guard window != nil else{return}
            monitor=NSEvent.addLocalMonitorForEvents(matching:.scrollWheel) {[weak self] event in
                guard let self,self.acceptsScroll(at:event.locationInWindow,in:event.window),
                      abs(event.scrollingDeltaY)>abs(event.scrollingDeltaX) else{return event}
                if let offset=self.gesture.step(delta:event.scrollingDeltaY,precise:event.hasPreciseScrollingDeltas,time:event.timestamp,
                                               began:event.phase.contains(.began),ended:event.phase.contains(.ended) || event.phase.contains(.cancelled),
                                               momentum:event.momentumPhase != []) {self.cycle?(offset)}
                return nil
            }
        }
        func acceptsScroll(at point:NSPoint,in eventWindow:NSWindow?)->Bool {
            guard enabled,let window,eventWindow === window,window.attachedSheet == nil,
                  !isHiddenOrHasHiddenAncestor,bounds.height>0,bounds.height<=48 else{return false}
            let local=convert(point,from:nil)
            guard bounds.contains(local),visibleRect.contains(local) else{return false}
            return true
        }
        func stop() {if let monitor {NSEvent.removeMonitor(monitor)};monitor=nil}
        deinit {if let monitor {NSEvent.removeMonitor(monitor)}}
    }
}
