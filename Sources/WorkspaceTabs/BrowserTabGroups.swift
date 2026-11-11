import SwiftUI
import AppKit
import WorkspaceCore

extension BrowserStore {
    func visibleGroupPages(in workspaceID:UUID)->[BrowserPage] {
        guard let w=workspace(workspaceID) else{return []}
        return orderedPages(in:workspaceID).filter{w.groupID(for:$0) == w.visibleGroupID}
    }
    /// One entry per login environment used by this app tab's groups, in group order.
    /// Empty unless the app tab really has more than one, so nothing extra is asked.
    func accountChoices(in workspaceID:UUID)->[AccountChoice] {
        guard let w=workspace(workspaceID) else{return []}
        var seen=Set<UUID>(),choices:[AccountChoice]=[]
        for group in w.resolvedTabGroups {
            let id=w.profileID(forGroup:group.id)
            guard seen.insert(id).inserted,let profile=profile(id) else{continue}
            let note=profile.accountNote.trimmingCharacters(in:.whitespacesAndNewlines)
            choices.append(AccountChoice(id:group.id.uuidString,title:note.isEmpty ? profile.name:note,detail:note.isEmpty ? group.name:profile.name+" · "+group.name,current:group.id == w.visibleGroupID || id == w.profileID(forGroup:w.visibleGroupID),groupID:group.id,notionUserID:nil))
        }
        return choices.count>1 ? choices:[]
    }
    /// Accounts to offer when opening Notion: separate login environments if the app tab
    /// has them, otherwise the Notion accounts signed in to its one environment.
    func notionAccountChoices(in workspaceID:UUID,from pageID:UUID?=nil) async->[AccountChoice] {
        let groups=accountChoices(in:workspaceID)
        guard groups.isEmpty,let w=workspace(workspaceID),let home=BrowserAddress.url(w.homeURL),
              let environment=NotionWorkspace.environment(home),let host=home.host?.lowercased() else{return groups}
        let profileID=w.profileID(forGroup:w.visibleGroupID)
        let cookies=await dataStore(profileID).httpCookieStore.allCookies()
        let match=cookies.filter{cookie in
            let domain=cookie.domain.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))
            return cookie.name == "notion_users" && (host == domain || host.hasSuffix("."+domain))
        }.max{$0.domain.count<$1.domain.count}
        let ids=match.map{NotionAccount.userIDs(fromCookie:$0.value)} ?? []
        guard ids.count>1 else{return []}
        let missing=ids.filter{notionDirectory[$0] == nil}
        if !missing.isEmpty,let engine=notionEngine(profileID:profileID,environment:environment),
           let rows=(try? await engine.webView.callAsyncJavaScript(NotionAccount.directoryScript,arguments:["ids":missing],in:nil,contentWorld:.defaultClient)) as? [[String:Any]] {
            for row in rows {
                if let id=row["id"] as? String,missing.contains(id),let account=NotionAccount.decode(row,matching:id) {notionDirectory[id]=account}
            }
        }
        let current=pageID.flatMap{engine(workspaceID,$0,load:false)?.notionAccount.account?.id}
        return ids.enumerated().map{index,id in
            let account=notionDirectory[id]
            return AccountChoice(id:id,title:account?.displayName ?? L("Notionアカウント \(index+1)"),detail:account.map{$0.name.isEmpty ? "":$0.email} ?? L("名前を確認できませんでした"),current:id == current,groupID:nil,notionUserID:id)
        }
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
    @discardableResult func saveTabGroup(_ value:BrowserTabGroup,in workspaceID:UUID,createIndependentProfile:Bool=false)->Bool {
        let name=String(value.name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty,let i=session.workspaces.firstIndex(where:{$0.id == workspaceID}) else{return false}
        var groups=session.workspaces[i].resolvedTabGroups
        guard !groups.contains(where:{$0.id != value.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame}) else {
            notify(L("同じ名前のグループがあります"),isError:true);return false
        }
        let fresh=createIndependentProfile ? LoginProfile(name:name+L(" のログイン環境")):nil
        let group=BrowserTabGroup(id:value.id,name:name,iconFile:value.iconFile,profileID:fresh?.id ?? value.profileID)
        guard group.profileID == nil || group.profileID == fresh?.id || profile(group.profileID!) != nil else{return false}
        let old=session.workspaces[i]
        let before=old.profileID(forGroup:value.id),after=group.profileID ?? old.profileID
        let affected=before == after ? []:old.pages.filter{old.groupID(for:$0) == group.id}.map(\.id)
        guard allowLoginEnvironmentChange(affected) else{return false}
        discardPageEngines(affected)
        if let fresh {session.profiles.append(fresh)}
        if let j=groups.firstIndex(where:{$0.id == value.id}) {groups[j]=group} else {groups.append(group)}
        session.workspaces[i].tabGroups=groups;session.workspaces[i].visibleTabGroupID=value.id;changed();return true
    }
    @discardableResult func movePageToGroup(_ pageID:UUID,in workspaceID:UUID,groupID:UUID)->Bool {
        guard let i=session.workspaces.firstIndex(where:{$0.id == workspaceID}),
              let j=session.workspaces[i].pages.firstIndex(where:{$0.id == pageID}),
              session.workspaces[i].resolvedTabGroups.contains(where:{$0.id == groupID}) else{return false}
        let workspace=session.workspaces[i]
        if workspace.profileID(for:workspace.pages[j]) != workspace.profileID(forGroup:groupID) {
            guard allowLoginEnvironmentChange([pageID]) else{return false}
            discardPageEngines([pageID])
        }
        session.workspaces[i].pages[j].groupID=groupID;changed();return true
    }
    func removeTabGroup(_ groupID:UUID,in workspaceID:UUID) {
        guard groupID != workspaceID,let i=session.workspaces.firstIndex(where:{$0.id == workspaceID}) else{return}
        let workspace=session.workspaces[i]
        let affected=workspace.profileID(forGroup:groupID) == workspace.profileID(forGroup:workspaceID) ? []:workspace.pages.filter{workspace.groupID(for:$0) == groupID}.map(\.id)
        guard allowLoginEnvironmentChange(affected) else{return}
        discardPageEngines(affected)
        for j in session.workspaces[i].pages.indices where session.workspaces[i].pages[j].groupID == groupID {
            session.workspaces[i].pages[j].groupID=nil
        }
        session.workspaces[i].tabGroups=session.workspaces[i].resolvedTabGroups.filter{$0.id != groupID}
        if session.workspaces[i].visibleTabGroupID == groupID {session.workspaces[i].visibleTabGroupID=workspaceID}
        changed()
    }
    private func allowLoginEnvironmentChange(_ pages:[UUID])->Bool {
        guard !pages.isEmpty else{return true}
        if let confirmation=loginEnvironmentChangeConfirmation {return confirmation(pages)}
        let alert=NSAlert();alert.messageText=L("ログイン環境を変更しますか？")
        alert.informativeText=L("対象の\(pages.count)タブを別のログイン環境で読み込み直します。未送信の入力は引き継げません。元の環境のCookieは残ります。必要な内容を保存してから変更してください。")
        alert.addButton(withTitle:L("キャンセル"));alert.addButton(withTitle:L("変更する"))
        return alert.runModal() == .alertSecondButtonReturn
    }
}

struct AccountChoice:Identifiable,Equatable {
    let id:String
    let title:String
    let detail:String
    let current:Bool
    /// Tab group the new tab goes into; its login environment decides the account.
    let groupID:UUID?
    /// Notion account to start as, inside the current login environment.
    let notionUserID:String?
}

struct BrowserGroupPicker:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store:BrowserStore
    let workspace:BrowserWorkspace
    @State private var editing:BrowserTabGroup?
    @State private var removing=false
    private var current:BrowserTabGroup {workspace.resolvedTabGroups.first{$0.id == workspace.visibleGroupID}!}
    var body:some View {
        HStack(spacing:BrowserLayout.gap) {
            selector.padding(.horizontal,BrowserLayout.small).frame(height:BrowserLayout.control)
            Rectangle().fill(Palette.ink(workspace.color).opacity(0.25)).frame(width:1,height:24)
                .accessibilityHidden(true)
        }.fixedSize()
    }
    private var selector:some View {
        Menu {
            ForEach(workspace.resolvedTabGroups) {group in
                Button {store.showTabGroup(group.id,in:workspace.id)} label:{
                    if group.id == current.id {Label(group.name,systemImage:"checkmark")} else {Text(group.name)}
                }
            }
            Divider()
            Button(L("新しいグループ…")) {editing=BrowserTabGroup(name:"")}
            Button(L("グループを編集…")) {editing=current}
            if current.id != workspace.id {Button(L("グループを削除…")) {removing=true}}
        } label:{
            // AppKit menus replace SwiftUI label foreground styles with system ink.
            // Preserve the tab bar's explicit contrast color, including the chevron.
            Image(nsImage:Palette.groupMenuLabel(current.name,ink:Palette.ink(workspace.color),icon:current.iconFile.flatMap{store.iconCache.image(directory:store.directory,name:$0)},iconKey:current.iconFile ?? "folder"))
                .renderingMode(.original)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height:20)
            .accessibilityLabel(L("タブグループ: ")+current.name)
            .help(L("表示するタブグループ。上下スクロールでも切り替えられます。ページはタブをクリックするまで変わりません。"))
            .sheet(item:$editing,onDismiss:store.restorePanelFocus) {group in
                BrowserGroupEditor(store:store,workspaceID:workspace.id,draft:group)
            }
            .alert(L("グループを削除しますか？"),isPresented:$removing) {
                Button(L("キャンセル"),role:.cancel) {}
                Button(L("削除"),role:.destructive) {store.removeTabGroup(current.id,in:workspace.id)}
            } message:{Text(L("タブは閉じずに、先頭のグループへ移動します。"))}
    }
}
private struct BrowserGroupEditor:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store:BrowserStore
    let workspaceID:UUID
    @State var draft:BrowserTabGroup
    @State private var environment="inherit"
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L("タブグループ")).font(.title2.weight(.semibold))
            TextField(L("名前（例：Notion、外部ツール）"),text:$draft.name).textFieldStyle(.roundedBorder)
            IconSelectionRow(store:store,file:$draft.iconFile,defaultSymbol:"folder")
            Picker(L("ログイン環境"),selection:$environment) {
                Text(L("アプリタブと共有")).tag("inherit")
                Text(L("新しい環境で独立させる")).tag("new")
                ForEach(store.session.profiles){profile in Text(profile.name).tag(profile.id.uuidString)}
            }
            Text(L("独立した環境ではCookieとサイトデータを分けます。最初にそのグループ内でログインしてください。同じ環境を選んだグループ同士はログインを共有します。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("キャンセル")) {dismiss()}.keyboardShortcut(.cancelAction)
                Button(L("保存")) {
                    draft.profileID=UUID(uuidString:environment)
                    if store.saveTabGroup(draft,in:workspaceID,createIndependentProfile:environment == "new") {
                        if environment == "new",let workspace=store.workspace(workspaceID),!workspace.pages.contains(where:{workspace.groupID(for:$0) == draft.id}) {
                            _=store.addPage(to:workspaceID,url:workspace.homeURL,groupID:draft.id)
                        }
                        dismiss()
                    }
                }
                    .keyboardShortcut(.defaultAction).disabled(draft.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.foregroundStyle(Color.primary).padding(24).frame(width:460)
            .onAppear{environment=draft.profileID?.uuidString ?? "inherit"}
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
