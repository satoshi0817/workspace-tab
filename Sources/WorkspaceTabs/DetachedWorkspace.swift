import AppKit
import SwiftUI
import WorkspaceCore

extension BrowserStore {
    func detachWorkspace(_ id: UUID, show: Bool = true) {
        guard let workspace=workspace(id) else {return}
        if let existing=detachedControllers[id] {if show {existing.window.makeKeyAndOrderFront(nil)};return}
        // A WKWebView can have only one parent. Remove all main-window mounts first.
        if split?.workspaceID == id || session.selectedWorkspaceID == id {split=nil}
        detachedWorkspaceIDs.insert(id)
        let controller=DetachedWorkspaceController(store:self,workspaceID:id,title:workspace.name)
        detachedControllers[id]=controller
        focusedPage=workspace.selectedPageID.map {PageReference(workspaceID:id,pageID:$0)}
        if show {controller.window.makeKeyAndOrderFront(nil)}
        changed();notify(L("「\(workspace.name)」を切り離しました"))
    }
    func reattachWorkspace(_ id: UUID, activate: Bool = true) {
        defer {if activate {selectionChanged()}}
        guard let controller=detachedControllers.removeValue(forKey:id) else {return}
        controller.window.delegate=nil
        controller.window.contentView=nil
        controller.window.close()
        detachedWorkspaceIDs.remove(id)
        if activate {
            session.selectedWorkspaceID=id;focusedPage=nil
            window?.makeKeyAndOrderFront(nil)
            notify(L("元のウインドウに戻しました"))
        }
        changed()
    }
    func detachedWindowClosed(_ id: UUID) {
        defer {selectionChanged()}
        guard let controller=detachedControllers.removeValue(forKey:id) else {return}
        controller.window.contentView=nil
        detachedWorkspaceIDs.remove(id)
        session.selectedWorkspaceID=id;focusedPage=nil
        window?.makeKeyAndOrderFront(nil)
        changed();notify(L("元のウインドウに戻しました"))
    }
}

@MainActor final class DetachedWorkspaceController: NSObject, NSWindowDelegate {
    let window: NSWindow
    weak var store: BrowserStore?
    let workspaceID: UUID
    init(store: BrowserStore, workspaceID: UUID, title: String) {
        self.store=store;self.workspaceID=workspaceID
        window=BrowserWindow(contentRect:NSRect(x:160,y:160,width:1100,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init()
        window.title=title+" — Workspace Tabs";window.isReleasedWhenClosed=false
        window.minSize=NSSize(width:560,height:400);window.collectionBehavior=[.fullScreenPrimary]
        window.delegate=self
        window.contentView=NSHostingView(rootView:DetachedWorkspaceView(store:store,workspaceID:workspaceID))
        window.center()
    }
    func windowWillClose(_ notification: Notification) {store?.detachedWindowClosed(workspaceID)}
    func windowDidBecomeKey(_ notification: Notification) {
        guard let pageID=store?.workspace(workspaceID)?.selectedPageID else {return}
        store?.focusedPage=PageReference(workspaceID:workspaceID,pageID:pageID)
    }
}

struct DetachedWorkspaceView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store: BrowserStore
    let workspaceID: UUID
    var body: some View {
        Group {
            if let workspace=store.workspace(workspaceID), let pageID=workspace.selectedPageID {
                BrowserPane(store:store,workspaceID:workspaceID,pageID:pageID,isRight:false,detached:true)
            }
        }.frame(minWidth:560,minHeight:400).overlay {RecentTabsOverlay(store:store)}
            .overlay(alignment:.bottom) {
                if let notice=store.notice {
                    Text(notice).font(.callout).padding(12).background(.regularMaterial,in:Capsule())
                        .padding(.bottom,16).allowsHitTesting(false)
                }
            }
    }
}
