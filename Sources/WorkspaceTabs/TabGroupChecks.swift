import AppKit
import SwiftUI
import WebKit
import WorkspaceCore

@MainActor enum TabGroupChecks {
    static func run(root:URL) async throws {
        func expect(_ value:Bool,_ name:String)throws {
            guard value else{throw BrowserChecks.Failure.check(name)}
            print("PASS "+name)
        }
        try expect(HelpCatalog.topics.first(where:{$0.id == "groups"})?.matches("グループ スクロール") == true
                   && HelpCatalog.topics.first(where:{$0.id == "icons"})?.matches("画像") == true
                   && HelpCatalog.topics.allSatisfy{!$0.matches("zz-no-such-help-topic")},
                   "Help search finds new features and handles unmatched queries")
        let store=BrowserStore(directory:root.appendingPathComponent("tab-groups"))
        store.session=BrowserSession()
        let id=store.addWorkspace(name:"Groups",url:"about:blank")
        let original=store.workspace(id)!.pages[0]
        let tools=BrowserTabGroup(name:"外部ツール")
        let other=BrowserTabGroup(name:"資料")
        try expect(store.workspace(id)!.resolvedTabGroups.count == 1 && store.visibleGroupPages(in:id).count == 1,"Legacy tabs appear in the default group")
        try expect(store.saveTabGroup(tools,in:id) && store.saveTabGroup(other,in:id),"Named browser tab groups can be created")
        let before=store.selectedPage!.id
        let engines=store.liveEngineCount
        store.showTabGroup(tools.id,in:id)
        try expect(store.selectedPage!.id == before && store.liveEngineCount == engines && store.visibleGroupPages(in:id).isEmpty,"Browsing groups never activates or loads a page")
        store.cycleTabGroup(1,in:id)
        try expect(store.workspace(id)!.visibleGroupID == other.id && store.selectedPage!.id == before,"Scrolling previews the next group without changing the active tab")
        store.cycleTabGroup(1,in:id)
        try expect(store.workspace(id)!.visibleGroupID == id,"Group scrolling wraps at the end")
        store.showTabGroup(tools.id,in:id)
        let added=store.addPage(to:id,url:"about:blank",load:false)!
        try expect(store.workspace(id)!.pages.first(where:{$0.id == added.pageID})?.groupID == tools.id,"New tabs belong to the displayed group")
        store.selectPage(original.id,in:id)
        try expect(store.workspace(id)!.visibleGroupID == id,"Explicit tab selection reveals its group")
        store.movePageToGroup(original.id,in:id,groupID:tools.id)
        try expect(store.selectedPage!.id == original.id && store.visibleGroupPages(in:id).isEmpty,"Moving a tab changes membership without navigating")
        let data=try JSONEncoder().encode(store.session)
        let decoded=try JSONDecoder().decode(BrowserSession.self,from:data).validated()
        try expect(decoded.workspaces[0].tabGroups == store.workspace(id)!.tabGroups && decoded.workspaces[0].pages[0].groupID == tools.id,"Tab groups and memberships survive session serialization")
        let backup=try NotionLibrary.tabBackup(store:store,includePages:true)
        try expect(backup.session.workspaces[0].tabGroups == decoded.workspaces[0].tabGroups,"Notion backups preserve tab groups")
        store.showTabGroup(tools.id,in:id)
        let dragWindow=NSWindow(contentRect:NSRect(x:100,y:100,width:1100,height:700),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        dragWindow.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:BrowserRoot(store:store));dragWindow.contentView=host
        func handles(_ view:NSView)->[TabDragHandle.Handle] {
            (view as? TabDragHandle.Handle).map{[$0]} ?? view.subviews.flatMap{handles($0)}
        }
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if handles(host).filter({$0.payload?.pageID != nil && $0.bounds.width>0}).count>=2 {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        guard let source=handles(host).first(where:{$0.payload?.pageID == added.pageID}),
              let target=handles(host).first(where:{$0.payload?.pageID == original.id}) else {
            throw BrowserChecks.Failure.check("Hosted group tabs expose native drag handles")
        }
        let from=source.convert(NSPoint(x:source.bounds.midX,y:source.bounds.midY),to:nil)
        let to=target.convert(NSPoint(x:target.bounds.width*0.25,y:target.bounds.midY),to:nil)
        func mouse(_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent {
            NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:dragWindow.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        func scrollAreas(_ view:NSView)->[TabGroupScrollArea.Area] {
            (view as? TabGroupScrollArea.Area).map{[$0]} ?? view.subviews.flatMap{scrollAreas($0)}
        }
        guard let area=scrollAreas(host).first else{throw BrowserChecks.Failure.check("Group scroll area exists")}
        try expect(area.bounds.height<=48 && area.acceptsScroll(at:from,in:dragWindow),"Group scrolling is limited to the actual browser tab strip")
        let pagePoint=NSPoint(x:host.bounds.midX,y:host.bounds.midY)
        try expect(!area.acceptsScroll(at:pagePoint,in:dragWindow),"Page content scroll events are never consumed by tab groups")
        let sidebarPoint=NSPoint(x:10,y:host.bounds.midY)
        try expect(!area.acceptsScroll(at:sidebarPoint,in:dragWindow),"Sidebar scrolling never changes browser groups")
        source.mouseDown(with:mouse(.leftMouseDown,from))
        source.mouseDragged(with:mouse(.leftMouseDragged,to))
        source.mouseUp(with:mouse(.leftMouseUp,to))
        try expect(store.visibleGroupPages(in:id).map(\.id) == [added.pageID,original.id],"Dragging tabs in a new group reorders the actual hosted tab strip")
        try expect(store.selectedPage!.id == original.id,"Reordering a group leaves its active page unchanged")
        dragWindow.contentView=nil;dragWindow.close()
        store.removeTabGroup(tools.id,in:id)
        try expect(store.workspace(id)!.pages.count == 2 && store.workspace(id)!.pages.allSatisfy{$0.groupID == nil},"Deleting a group retains its tabs in the default group")
        var renamed=other;renamed.name="  参考資料  "
        try expect(store.saveTabGroup(renamed,in:id) && store.workspace(id)!.resolvedTabGroups.last?.name == "参考資料","Groups can be renamed with trimmed names")
        var gesture=TabGroupScrollGesture()
        let tiny=gesture.step(delta:-10,precise:true,time:1,began:true,ended:false,momentum:false)
        let next=gesture.step(delta:-25,precise:true,time:1.1,began:false,ended:false,momentum:false)
        let repeated=gesture.step(delta:-80,precise:true,time:1.2,began:false,ended:false,momentum:false)
        let inertia=gesture.step(delta:-80,precise:true,time:2,began:false,ended:false,momentum:true)
        let previous=gesture.step(delta:40,precise:true,time:3,began:true,ended:false,momentum:false)
        try expect(tiny == nil && next == 1 && repeated == nil && inertia == nil && previous == -1,"Group scrolling ignores jitter and inertia and changes once per trackpad gesture")
        store.shutdown()
        for profile in store.session.profiles {try? await WKWebsiteDataStore.remove(forIdentifier:profile.id)}
    }
}
