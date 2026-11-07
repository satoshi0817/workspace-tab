import AppKit
import WebKit
import SwiftUI
import WorkspaceCore

@MainActor enum BrowserChecks {
    enum Failure: Error { case check(String) }
    static func run() async -> Int32 {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-browser-checks-" + UUID().uuidString)
        var profiles: [UUID] = []
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            func expect(_ value: Bool, _ name: String) throws {
                guard value else { throw Failure.check(name) }
                print("PASS " + name)
            }
            let nativeTab = WorkspaceTab(bundleID: "notion.dev.id", windowTitle: "Same", name: "Dev workspace", emoji: "🌙", color: "#123456")
            let native = SavedState(groups:[WorkspaceGroup(tabs:[nativeTab,WorkspaceTab(bundleID:"notion.id",windowTitle:"Same")])])
            let migrated = BrowserSession.migrate(native)
            try expect(migrated.workspaces.count == 2 && migrated.workspaces[0].name == nativeTab.name && migrated.workspaces[0].emoji == nativeTab.emoji && migrated.workspaces[0].color == nativeTab.color, "Migration preserves customization and duplicate app tabs")
            try expect(migrated.workspaces[0].profileID != migrated.workspaces[1].profileID && migrated.workspaces[0].homeURL == "https://app.dev.notion.com", "Migration creates separate profiles and dev home")
            try expect(BrowserAddress.url("javascript:alert(1)") == nil && BrowserAddress.url("https://user:secret@example.com") == nil, "Reject non-web URLs and embedded credentials")
            try expect(!BrowserAddress.isNotion(URL(string:"https://app.notion.com.evil.test")!) && BrowserAddress.isNotion(URL(string:"https://app.dev.notion.com")!), "CSS host matching is exact")
            try expect(!BrowserAddress.savedURL(URL(string:"https://example.test/callback?code=secret&x=1#access_token=secret")!).contains("secret"), "Auth callback tokens are omitted from saved URLs")
            var routingA=BrowserWorkspace(name:"Production",profileID:UUID(),url:"https://app.notion.com/p/acme/11111111111111111111111111111111")
            routingA.notionSpaceID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";routingA.notionAutoRoute=true
            var routingB=BrowserWorkspace(name:"Development",profileID:UUID(),url:"https://app.dev.notion.com/p/acme/11111111111111111111111111111111")
            routingB.notionSpaceID=routingA.notionSpaceID;routingB.notionAutoRoute=true
            let prodURL=URL(string:routingA.homeURL)!,devURL=URL(string:routingB.homeURL)!
            try expect(NotionWorkspace.target(url:prodURL,detectedID:nil,workspaces:[routingA,routingB]) == routingA.id && NotionWorkspace.target(url:devURL,detectedID:routingB.notionSpaceID,workspaces:[routingA,routingB]) == routingB.id, "Notion routing separates production and development")
            var duplicate=routingA;duplicate.id=UUID()
            try expect(NotionWorkspace.target(url:prodURL,detectedID:routingA.notionSpaceID,workspaces:[routingA,duplicate]) == nil && NotionWorkspace.target(url:prodURL,detectedID:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",workspaces:[routingA]) == nil, "Ambiguous or conflicting Notion identity never routes")
            try expect(NotionWorkspace.target(url:URL(string:"https://app.notion.com/11111111111111111111111111111111")!,detectedID:nil,workspaces:[routingA]) == nil && NotionWorkspace.target(url:URL(string:"https://app.notion.com.evil.test/p/acme/11111111111111111111111111111111")!,detectedID:nil,workspaces:[routingA]) == nil, "Page IDs and lookalike hosts are not workspace evidence")
            let store = BrowserStore(directory:root)
            store.session = BrowserSession()
            let a = store.addWorkspace(name:"Alpha",url:"http://127.0.0.1:48761/")
            let b = store.addWorkspace(name:"Beta",url:"http://127.0.0.1:48761/")
            let wa = store.workspace(a)!, wb = store.workspace(b)!
            profiles = store.session.profiles.map(\.id)
            let da = store.dataStore(wa.profileID), db = store.dataStore(wb.profileID)
            let cookie = HTTPCookie(properties:[.domain:"127.0.0.1",.path:"/",.name:"workspace_test",.value:"alpha",.expires:Date().addingTimeInterval(3600)])!
            await da.httpCookieStore.setCookie(cookie)
            let ca = await da.httpCookieStore.allCookies(), cb = await db.httpCookieStore.allCookies()
            try expect(ca.contains{$0.name == "workspace_test" && $0.value == "alpha"} && !cb.contains{$0.name == "workspace_test"}, "WebKit profile cookies are isolated")
            let same = WKWebsiteDataStore(forIdentifier:wa.profileID)
            let sameCookies = await same.httpCookieStore.allCookies()
            try expect(sameCookies.contains{$0.name == "workspace_test" && $0.value == "alpha"}, "Persistent profile identifier reopens the same cookie store")
            let ea = store.engine(a,wa.pages[0].id)!, eb = store.engine(b,wb.pages[0].id)!
            try await wait { ea.webView.url?.host == "127.0.0.1" && !ea.webView.isLoading && !eb.webView.isLoading }
            try expect(ea.failure == nil && eb.failure == nil, "Both browser environments load the local fixture")
            _ = try await ea.webView.evaluateJavaScript("localStorage.setItem('environment','alpha')")
            let otherStorage = try await eb.webView.evaluateJavaScript("localStorage.getItem('environment') === null") as? Bool
            try expect(otherStorage == true, "Local storage is isolated between profiles")
            let routeFixture="LRU:KeyValueStore2:"
            _ = try await ea.webView.evaluateJavaScript("localStorage.setItem('\(routeFixture)lastVisitedRoute',JSON.stringify({value:{name:'page',blockId:'11111111-1111-1111-1111-111111111111'}}));localStorage.setItem('\(routeFixture)lastVisitedRouteSpaceId',JSON.stringify({value:'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}))")
            let detection=NotionWorkspace.detectionScript.replacingOccurrences(of:"location.protocol",with:"'https:'").replacingOccurrences(of:"location.hostname",with:"'app.notion.com'").replacingOccurrences(of:"location.pathname",with:"'/p/acme/11111111111111111111111111111111'")
            let detected=try await ea.webView.evaluateJavaScript(detection) as? [String:String]
            try expect(detected?["spaceID"] == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "Notion metadata detector accepts the exact current page only")
            let stale=try await ea.webView.evaluateJavaScript(detection.replacingOccurrences(of:"/p/acme/11111111111111111111111111111111",with:"/p/acme/22222222222222222222222222222222"))
            try expect(stale is NSNull, "Stale Notion last-visited metadata is rejected")
            let before = store.workspace(a)!.pages.count
            _ = try await ea.webView.evaluateJavaScript("window.open('/child','_blank'); true")
            try await wait { store.workspace(a)!.pages.count == before + 1 }
            let childPage = store.workspace(a)!.pages.last!
            let child = store.engine(a,childPage.id)!
            try await wait { !child.webView.isLoading && child.webView.url?.path == "/child" }
            let childStorage = try await child.webView.evaluateJavaScript("localStorage.getItem('environment')") as? String
            try expect(child.profileID == wa.profileID && childStorage == "alpha", "Popup stays in its parent app tab and inherits its profile")
            store.selectWorkspace(a);store.selectPage(wa.pages[0].id,in:a)
            store.setSplit(PageReference(workspaceID:b,pageID:wb.pages[0].id))
            try expect(store.split?.workspaceID == b && ea.profileID != eb.profileID, "Split View keeps separate profile ownership")
            store.swapSplit()
            try expect(store.selected?.id == b && store.split?.workspaceID == a, "Split panes can swap without profile reassignment")
            store.focusedPage=store.split
            let pasteboard=NSPasteboard.withUniqueName()
            store.copyPageURL(to:pasteboard)
            try expect(store.commandPage == store.split && pasteboard.string(forType:.string) == ea.webView.url?.absoluteString && store.notice == "URLをコピーしました", "Copy URL targets the focused split pane and posts a nonmodal notice")
            pasteboard.releaseGlobally()
            let offHostScript = BrowserStyle.script(hex:"#123456",enabled:true,strength:0.3)
            _ = try await ea.webView.evaluateJavaScript(offHostScript)
            let absent = try await ea.webView.evaluateJavaScript("document.getElementById('workspace-tabs-sidebar-theme') === null") as? Bool
            try expect(absent == true, "CSS is not injected on other hosts")
            let simulated = offHostScript.replacingOccurrences(of:"location.protocol",with:"'https:'").replacingOccurrences(of:"location.hostname",with:"'app.notion.com'")
            _ = try await ea.webView.evaluateJavaScript(simulated)
            let exists = try await ea.webView.evaluateJavaScript("!!document.getElementById('workspace-tabs-sidebar-theme')") as? Bool
            try expect(exists == true, "Notion style creates a scoped stylesheet on an allowed host")
            _ = try await ea.webView.evaluateJavaScript(BrowserStyle.script(hex:"#123456",enabled:false,strength:0.3))
            let removed = try await ea.webView.evaluateJavaScript("document.getElementById('workspace-tabs-sidebar-theme') === null") as? Bool
            try expect(removed == true, "CSS toggle removes the injected stylesheet immediately")
            let testWindow = NSWindow(contentRect:NSRect(x:100,y:100,width:1100,height:700),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
            testWindow.contentView = NSHostingView(rootView:BrowserRoot(store:store))
            testWindow.contentView?.layoutSubtreeIfNeeded()
            try await wait { testWindow.contentView?.layoutSubtreeIfNeeded(); return ea.webView.frame.width > 250 && ea.webView.frame.height > 200 && eb.webView.frame.width > 250 && eb.webView.frame.height > 200 }
            try expect(ea.webView.superview !== eb.webView.superview, "Split View mounts both live WebViews in distinct visible-sized panes")
            // Exercise native event handlers in an offscreen test window; no OS input injection.
            let dragRoot=NSView(frame:NSRect(x:0,y:0,width:600,height:200))
            let dragSource=TabDragHandle.Handle(frame:NSRect(x:0,y:0,width:100,height:40))
            let dragTarget=TabDragHandle.Handle(frame:NSRect(x:200,y:0,width:100,height:40))
            dragRoot.addSubview(dragSource);dragRoot.addSubview(dragTarget);testWindow.contentView=dragRoot
            let dragID=UUID();dragSource.payload=TabDragPayload(workspaceID:a,pageID:dragID)
            var dropped:UUID?,afterDrop=false,clicks=0
            dragSource.click={clicks += 1}
            dragTarget.drop={payload,after in dropped=payload.pageID;afterDrop=after}
            func mouse(_ type:NSEvent.EventType,_ x:CGFloat,_ y:CGFloat)->NSEvent {
                NSEvent.mouseEvent(with:type,location:NSPoint(x:x,y:y),modifierFlags:[],timestamp:0,windowNumber:testWindow.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            }
            dragSource.mouseDown(with:mouse(.leftMouseDown,20,20))
            dragSource.mouseDragged(with:mouse(.leftMouseDragged,280,20))
            dragSource.mouseUp(with:mouse(.leftMouseUp,280,20))
            try expect(dropped == dragID && afterDrop && clicks == 0,"Native drag routes to the target after midpoint without selecting the source")
            dropped=nil
            dragSource.mouseDown(with:mouse(.leftMouseDown,20,20))
            dragSource.mouseDragged(with:mouse(.leftMouseDragged,220,20))
            dragSource.mouseUp(with:mouse(.leftMouseUp,220,20))
            try expect(dropped == dragID && !afterDrop,"Native drag can insert before the target midpoint")
            dragSource.mouseDown(with:mouse(.leftMouseDown,20,20))
            dragSource.mouseUp(with:mouse(.leftMouseUp,20,20))
            try expect(clicks == 1,"Native tab click remains distinct from reorder")
            testWindow.contentView = nil
            var favorite = FavoriteLink(title:"Alpha home",url:"http://127.0.0.1:48761/",workspaceID:a)
            favorite.emoji="⭐";favorite.category="Work";favorite.pinned=true
            try expect(store.saveFavorite(favorite), "Favorite saves title, icon, category and destination")
            let countA = store.workspace(a)!.pages.count, countB = store.workspace(b)!.pages.count
            try expect(store.openFavorite(favorite) && store.selected?.id == a && store.workspace(a)!.pages.count == countA && store.workspace(b)!.pages.count == countB, "Favorite reuses URL only in its assigned environment")
            try expect(store.openFavorite(favorite,newTab:true) && store.workspace(a)!.pages.count == countA+1, "Favorite can explicitly open a new browser tab")
            var missing = favorite; missing.workspaceID=UUID()
            let selectedBeforeMissing = store.selected?.id
            try expect(!store.openFavorite(missing) && store.selected?.id == selectedBeforeMissing, "Missing favorite destination never falls back to another environment")
            store.error=nil
            let dataWithoutFavorites = try JSONSerialization.jsonObject(with:JSONEncoder().encode(store.session)) as! [String:Any]
            var legacy=dataWithoutFavorites;legacy.removeValue(forKey:"favorites")
            let decoded=try JSONDecoder().decode(BrowserSession.self,from:JSONSerialization.data(withJSONObject:legacy)).validated()
            try expect(decoded.favorites == nil && decoded.workspaces.count == 2, "Pre-launcher sessions remain readable without favorites")
            var pin=store.workspace(b)!.pages[0];pin.pinned=true;pin.tabEmoji="📌";pin.tabName="Pinned test"
            store.updateBrowserTab(pin,in:b)
            let pinnedCount=store.workspace(b)!.pages.count
            store.closePage(pin.id,in:b)
            try expect(store.workspace(b)!.pages.count == pinnedCount && store.workspace(b)!.pages[0].iconOnly, "Pinned browser tabs default to icons and resist accidental close")
            var later=store.workspace(a)!.pages.last!;later.pinned=true
            store.updateBrowserTab(later,in:a)
            try expect(store.orderedPages(in:a).first?.id == later.id, "Pinned browser tabs appear before unpinned tabs")
            later.pinned=false;store.updateBrowserTab(later,in:a)
            pin.pinnedDisplay="name";store.updateBrowserTab(pin,in:b)
            try expect(!store.workspace(b)!.pages[0].iconOnly && store.workspace(b)!.pages[0].displayTitle == "Pinned test", "Pinned tabs can display their custom name")
            try expect(Palette.ink("#000000") == .white && Palette.ink("#FFFFFF") == .black, "Browser tab foreground switches for dark and light colors")
            store.snapshot();store.save()
            let loaded = BrowserStore(directory:root)
            try expect(loaded.session.workspaces.map(\.profileID) == store.session.workspaces.map(\.profileID) && loaded.split == store.split, "Session and split ownership survive reload")
            try expect(loaded.workspace(b)?.pages[0].pinned == true && loaded.workspace(b)?.pages[0].tabEmoji == "📌" && loaded.workspace(b)?.pages[0].pinnedDisplay == "name", "Pinned tab presentation survives session reload")
            try expect(loaded.favorites == [favorite], "Favorite metadata and target survive session reload")
            store.deleteFavorite(favorite.id)
            try expect(store.favorites.isEmpty, "Favorite removal leaves browser pages intact")
            store.closePage(childPage.id,in:a);store.reopenPage()
            try expect(store.workspace(a)!.pages.contains{$0.id == childPage.id}, "Closed browser tabs can be reopened in their original environment")
            store.selectWorkspace(b);store.selectPage(wb.pages[0].id,in:b)
            store.setSplit(PageReference(workspaceID:a,pageID:wa.pages[0].id))
            store.selectWorkspace(a);store.selectPage(wa.pages[0].id,in:a)
            testWindow.contentView=NSHostingView(rootView:BrowserRoot(store:store))
            testWindow.contentView?.layoutSubtreeIfNeeded()
            let engineBeforeDetach=store.engine(a,wa.pages[0].id)!
            let pageIDsBeforeDetach=store.workspace(a)!.pages.map(\.id)
            store.detachWorkspace(a,show:false)
            let detached=store.detachedControllers[a]!
            detached.window.contentView?.layoutSubtreeIfNeeded()
            try await wait {detached.window.contentView?.layoutSubtreeIfNeeded();testWindow.contentView?.layoutSubtreeIfNeeded();return engineBeforeDetach.webView.window === detached.window && engineBeforeDetach.webView.frame.width > 250}
            try expect(store.detachedWorkspaceIDs.contains(a) && store.split == nil && store.engine(a,wa.pages[0].id) === engineBeforeDetach && store.workspace(a)!.pages.map(\.id) == pageIDsBeforeDetach, "Detach preserves the live browser, profile and complete page list")
            let closing=childPage.id
            store.selectPage(closing,in:a)
            store.focusedPage=PageReference(workspaceID:a,pageID:closing)
            store.closePage(closing,in:a)
            try expect(store.commandPage?.workspaceID == a && store.commandPage?.pageID == store.workspace(a)?.selectedPageID, "Detached keyboard commands stay in the same app after closing a page")
            store.reopenPage()
            store.reattachWorkspace(a,activate:false)
            try expect(!store.detachedWorkspaceIDs.contains(a) && store.detachedControllers[a] == nil && store.engine(a,wa.pages[0].id) === engineBeforeDetach, "Reattach preserves the original WebView without reloading")
            store.detachWorkspace(a,show:false)
            store.detachedControllers[a]!.window.close()
            try expect(!store.detachedWorkspaceIDs.contains(a) && Set(store.workspace(a)!.pages.map(\.id)) == Set(pageIDsBeforeDetach), "Closing a detached window returns its app tab without deleting pages")
            testWindow.contentView=nil
            store.selectWorkspace(b);store.setSplit(PageReference(workspaceID:a,pageID:wa.pages[0].id))
            try expect(store.saveBeforeExit(), "Exit synchronously flushes the latest session")
            let exited=BrowserStore(directory:root)
            try expect(exited.session == store.session && exited.split == store.split, "Exit restores all URLs, order, selected tabs, profile IDs and split atomically")
            let fixture=root.appendingPathComponent("link-viewer.json")
            let fixtureLinks:[[String:Any]]=[
                ["id":"one","sourceId":"source","name":"Imported","url":"https://example.com","app":store.workspace(a)!.name,"pinned":true,"emoji":"⭐","category":["name":"Work"]],
                ["id":"two","sourceId":"source","name":"Unassigned","url":"https://example.org","app":"Unknown","pinned":false]]
            try JSONSerialization.data(withJSONObject:["data":["links":fixtureLinks]]).write(to:fixture)
            _=store.importLinkViewer(source:fixture)
            try expect(store.favorites.count == 2 && store.favorites.first?.workspaceID == a && store.favorites.first?.category == "Work", "Link Viewer imports metadata and exact destinations")
            try expect(store.workspace(store.favorites[1].workspaceID) == nil, "Ambiguous imported destinations remain unassigned")
            _=store.importLinkViewer(source:fixture)
            try expect(store.favorites.count == 2, "Link Viewer reimport is idempotent")
            let suite="WorkspaceTabs-checks-"+UUID().uuidString
            let defaults=UserDefaults(suiteName:suite)!
            defer{defaults.removePersistentDomain(forName:suite)}
            let prefs=ShortcutPreferences(defaults:defaults)
            let first=ShortcutPreferences.actions[0],second=ShortcutPreferences.actions[1]
            let custom=ShortcutBinding(key:"n",code:45,modifiers:NSEvent.ModifierFlags([.command,.option,.control,.shift]).rawValue)
            try expect(prefs.set(custom,for:first) == nil && prefs.set(custom,for:second) != nil,"Shortcut customization rejects duplicate actions")
            try expect(ShortcutPreferences(defaults:defaults).binding(first) == custom,"Shortcut overrides persist across reload")
            try expect(prefs.reset(first) == nil && prefs.binding(first) == first.initial && prefs.binding(second) == second.initial,"Per-action reset preserves other shortcuts")
            try expect(prefs.set(ShortcutBinding(key:"a",code:0,modifiers:0),for:first) != nil,"Unmodified shortcuts cannot intercept normal typing")
            let tap=ShortcutStroke(key:"",code:0,modifiers:NSEvent.ModifierFlags.command.rawValue,modifierOnly:true)
            let doubleTap=ShortcutBinding(sequence:[tap,tap],key:"",code:0,modifiers:NSEvent.ModifierFlags.command.rawValue)
            try expect(prefs.set(doubleTap,for:first) == nil && prefs.binding(first).label == "⌘ → ⌘", "Modifier-only sequential shortcut is accepted and displayed")
            try expect(prefs.set(ShortcutBinding(sequence:[tap,tap,tap],key:"",code:0,modifiers:tap.modifiers),for:second) != nil,"Ambiguous sequence prefixes are rejected")
            let strokeRecorder=ShortcutStrokeRecorder()
            func keyEvent(_ type:NSEvent.EventType,_ flags:NSEvent.ModifierFlags,_ key:String="",_ code:UInt16=55)->NSEvent {
                NSEvent.keyEvent(with:type,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:key,charactersIgnoringModifiers:key,isARepeat:false,keyCode:code)!
            }
            try expect(strokeRecorder.consume(keyEvent(.flagsChanged,.command)) == nil && strokeRecorder.consume(keyEvent(.flagsChanged,[])) == tap,"Modifier tap records only after release")
            _=strokeRecorder.consume(keyEvent(.flagsChanged,.command))
            let chord=strokeRecorder.consume(keyEvent(.keyDown,.command,"k",40))
            try expect(chord?.key == "k" && strokeRecorder.consume(keyEvent(.flagsChanged,[])) == nil,"A simultaneous chord never adds a phantom modifier stroke")
            let optionChord=strokeRecorder.consume(keyEvent(.keyDown,[.command,.option],"˚",40))
            try expect(optionChord?.key == "k" && optionChord?.modifiers == NSEvent.ModifierFlags([.command,.option]).rawValue,"Option chord records the base key rather than the generated symbol")
            let shiftedChord=strokeRecorder.consume(keyEvent(.keyDown,[.command,.shift],"C",8))
            try expect(shiftedChord?.key == "c" && shiftedChord?.label == "⇧⌘C","Shift chord records a single normalized stroke")
            var categoryLink=FavoriteLink(title:"Category route",url:"https://example.com",workspaceID:b)
            categoryLink.category=store.workspace(a)!.name
            try expect(store.favoriteWorkspace(categoryLink)?.id == a,"Category name takes precedence over a stale explicit favorite destination")
            categoryLink.category="No matching category"
            try expect(store.favoriteWorkspace(categoryLink)?.id == b,"Unmatched category preserves an explicitly assigned destination")
            let numberPrefs=ShortcutPreferences(defaults:defaults)
            try expect(numberPrefs.setWorkspaceModifiers([.command,.option]) == nil && ShortcutPreferences.numberedActions.allSatisfy{numberPrefs.binding($0).flags == [.command,.option] && numberPrefs.binding($0).code == $0.initial.code},"Numbered tab modifiers update all nine shortcuts while preserving digits")
            let savedOverrides=numberPrefs.overrides
            try expect(numberPrefs.setWorkspaceModifiers([]) != nil && numberPrefs.overrides == savedOverrides,"Empty modifier selection leaves every shortcut unchanged")
            try expect(numberPrefs.setWorkspaceModifiers([.control,.option],reset:true) == nil && ShortcutPreferences.numberedActions.allSatisfy{numberPrefs.binding($0) == $0.initial},"Numbered shortcut group resets together")
            var idWorkspace=store.workspace(a)!
            idWorkspace.notionSpaceID="abcdefabcdefabcdefabcdefabcdefab"
            store.updateWorkspace(idWorkspace)
            categoryLink.categoryWorkspaceID="ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB"
            categoryLink.category="Renamed category"
            try expect(store.favoriteWorkspace(categoryLink)?.id == a,"Category Workspace ID survives category rename and normalizes UUID formatting")
            categoryLink.categoryWorkspaceID="invalid"
            try expect(store.favoriteWorkspace(categoryLink) == nil,"Invalid explicit Workspace ID cannot fall back to a different login")
            var updates=0
            let subscription=store.objectWillChange.sink {updates += 1}
            let unchanged=store.workspace(a)!.pages[0]
            store.updatePage(a,unchanged.id,url:URL(string:unchanged.url),title:unchanged.title)
            try expect(updates == 0,"Unchanged page metadata does not invalidate the entire browser UI")
            subscription.cancel()
            let firstWorkspace=store.session.workspaces.first!.id,lastWorkspace=store.session.workspaces.last!.id
            store.selectWorkspace(lastWorkspace);store.cycleWorkspace(1)
            try expect(store.session.selectedWorkspaceID == firstWorkspace,"Next app shortcut wraps from last to first workspace")
            store.cycleWorkspace(-1)
            try expect(store.session.selectedWorkspaceID == lastWorkspace,"Previous app shortcut wraps from first to last workspace")
            let arrow=strokeRecorder.consume(keyEvent(.keyDown,[.command,.option],"\u{F703}",124))
            try expect(arrow?.code == 124 && arrow?.label == "⌥⌘→","Shortcut recorder accepts arrow-key combinations")
            let workspaceOrder=store.session.workspaces.map(\.id)
            store.moveWorkspace(workspaceOrder[0],before:workspaceOrder[1],after:true)
            try expect(store.session.workspaces.map(\.id) == [workspaceOrder[1],workspaceOrder[0]],"Dropping an app tab after its neighbor changes order")
            let pagesBefore=store.workspace(a)!.pages
            if pagesBefore.count>1 {
                let first=pagesBefore[0].id,last=pagesBefore.last!.id,selected=store.workspace(a)!.selectedPageID
                let liveEngine=store.engine(a,first)
                try expect(store.movePage(first,in:a,relativeTo:last,after:true) && store.workspace(a)!.pages.last!.id == first,"Browser tab can move after its last neighbor")
                try expect(store.workspace(a)!.selectedPageID == selected && store.engine(a,first) === liveEngine,"Reordering preserves selection and the live WebView")
                var pinned=store.workspace(a)!.pages[0];pinned.pinned=true;store.updateBrowserTab(pinned,in:a)
                try expect(!store.movePage(first,in:a,relativeTo:pinned.id,after:false),"Browser tab reorder preserves pinned groups")
            }
            try expect(store.tabSearchRows("").count == store.session.workspaces.reduce(0){$0+$1.pages.count},"All-tabs picker includes every workspace")
            try expect(store.tabSearchRows("Alpha 127.0.0.1").allSatisfy{$0.workspace.id == a} && !store.tabSearchRows("Alpha 127.0.0.1").isEmpty,"All-tabs search combines workspace and URL terms")
            store.selectWorkspace(a);store.selectWorkspace(b);store.runCommand("lastWorkspace")
            try expect(store.session.selectedWorkspaceID == a,"Previous-workspace command returns to last workspace")
            func runNotionScript(_ script:String) async throws {
                let _:Any = try await withCheckedThrowingContinuation { continuation in
                    ea.webView.callAsyncJavaScript(script,arguments:["action":"notionChat"],in:nil,in:.page) { continuation.resume(with:$0) }
                }
            }
            let actionScript=NotionActions.script.replacingOccurrences(of:"location.protocol",with:"'https:'").replacingOccurrences(of:"location.hostname",with:"'app.notion.com'")
            _ = try await ea.webView.evaluateJavaScript("document.body.innerHTML='<button onclick=\"window.actionClicks++\">New chat</button>';window.actionClicks=0")
            try await runNotionScript(actionScript)
            let clicked=try await ea.webView.evaluateJavaScript("window.actionClicks") as? Int
            try expect(clicked == 1,"Notion action clicks the uniquely named visible control")
            _ = try await ea.webView.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend','<button>New chat</button>')")
            try await runNotionScript(actionScript)
            let duplicateClicks=try await ea.webView.evaluateJavaScript("window.actionClicks") as? Int
            try expect(duplicateClicks == 1,"Ambiguous Notion controls are not clicked")
            try await runNotionScript(NotionActions.script)
            let offHostClicks=try await ea.webView.evaluateJavaScript("window.actionClicks") as? Int
            try expect(offHostClicks == 1,"Notion actions reject non-Notion hosts")
            for (action,label) in [("notionPage","New page"),("notionMeeting","New meeting note")] {
                _ = try await ea.webView.evaluateJavaScript("document.body.innerHTML='<button onclick=\"window.actionClicks++\">\(label)</button>';window.actionClicks=0")
                let _:Any = try await withCheckedThrowingContinuation { continuation in
                    ea.webView.callAsyncJavaScript(actionScript,arguments:["action":action],in:nil,in:.page) {continuation.resume(with:$0)}
                }
                let result=try await ea.webView.evaluateJavaScript("window.actionClicks") as? Int
                try expect(result == 1,"Notion action detects creation control: \(action)")
            }
            // Idle persistence must not rewrite any files or instantiate hidden tabs.
            store.snapshot();_ = store.save()
            let writes=store.persistenceWrites,live=store.liveEngineCount
            let indexURL=root.appendingPathComponent("raycast-index.json")
            let indexBefore=try FileManager.default.attributesOfItem(atPath:indexURL.path)[.modificationDate] as? Date
            let saveStart=Date()
            for _ in 0..<100 { _ = store.save();_ = store.tabSearchRows("Alpha") }
            let elapsed=Date().timeIntervalSince(saveStart)*1000
            let indexAfter=try FileManager.default.attributesOfItem(atPath:indexURL.path)[.modificationDate] as? Date
            try expect(store.persistenceWrites == writes && indexBefore == indexAfter,"100 idle saves perform zero session or Raycast index writes")
            try expect(store.liveEngineCount == live,"Searching hidden tabs never allocates WebViews")
            print(String(format:"METRIC 100 idle saves and searches: %.2f ms",elapsed))
            let beforeRefresh=ea.refreshPasses
            for _ in 0..<100 {ea.refresh()}
            try await wait {ea.refreshPasses > beforeRefresh}
            try expect(ea.refreshPasses == beforeRefresh+1,"100 queued WebKit refreshes coalesce into one pass")
            var disposable:BrowserEngine?=store.addPage(to:a,url:"about:blank")
            let disposableID=disposable!.pageID
            weak var released=disposable
            store.closePage(disposableID,in:a);disposable=nil
            try await wait {released == nil}
            try expect(released == nil,"Closing a tab releases its engine and observers")
            let icons=root.appendingPathComponent("Icons")
            try FileManager.default.createDirectory(at:icons,withIntermediateDirectories:true)
            let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            try bitmap.representation(using:.png,properties:[:])!.write(to:icons.appendingPathComponent("large.png"))
            let cache=LocalIconCache(),image=cache.image(directory:root,name:"large.png")
            let imageStart=Date()
            for _ in 0..<1000 {_ = cache.image(directory:root,name:"large.png")}
            try expect(cache.decodeCount == 1 && image != nil && image!.size.width<=128,"1000 icon lookups reuse one downsampled image")
            try expect(cache.image(directory:root,name:"../outside.png") == nil,"Icon cache rejects traversal paths")
            print(String(format:"METRIC 1000 cached icon lookups: %.2f ms",Date().timeIntervalSince(imageStart)*1000))
            let iconClient=NotionClient()
            let remotePage:JSONObject=["id":UUID().uuidString,"last_edited_time":"2026-11-07T00:00:00Z"]
            let downloaded=try await iconClient.downloadIcon(URL(string:"http://127.0.0.1:48761/icon.png")!,page:remotePage,directory:icons)
            let cachedDownload=try await iconClient.downloadIcon(URL(string:"http://127.0.0.1:1/unreachable")!,page:remotePage,directory:icons)
            try expect(downloaded == cachedDownload && FileManager.default.fileExists(atPath:downloaded),"Unchanged Notion icon reuses disk cache without another network request")
            store.exportLauncherIndex()
            let launcherFile=root.appendingPathComponent("raycast-index.json")
            let launcher=try JSONDecoder().decode(LauncherIndex.self,from:Data(contentsOf:launcherFile))
            try expect(launcher.tabs.count == store.tabSearchRows("").count && launcher.workspaces.count == store.session.workspaces.count,"Raycast exports all tabs and workspaces")
            let bridgeURL=URL(string:"workspacetabs://launch?token=\(launcher.token)&kind=tab&id=\(wa.pages[0].id)&workspace=\(a)")!
            try expect(LauncherRequest.parse(bridgeURL,token:launcher.token)?.workspaceID == a,"Raycast routes an authenticated tab ID in its workspace")
            try expect(LauncherRequest.parse(bridgeURL,token:"wrong") == nil && LauncherRequest.parse(URL(string:bridgeURL.absoluteString+"&id=duplicate")!,token:launcher.token) == nil,"Raycast rejects invalid token and duplicate parameters")
            try expect(!BrowserStore.launcherCommandIDs.contains("quit") && !BrowserStore.launcherCommandIDs.contains("close"),"Raycast command allowlist excludes destructive operations")
            let permissions=try FileManager.default.attributesOfItem(atPath:launcherFile.path)[.posixPermissions] as? NSNumber
            try expect(permissions?.intValue == 0o600,"Raycast index is readable only by the file owner")
            store.save()
            let reordered=BrowserStore(directory:root)
            try expect(reordered.session.workspaces == store.session.workspaces,"App and browser tab order survive reload")
            reordered.shutdown()
            exited.shutdown();loaded.shutdown();store.shutdown()
            for id in profiles { try? await WKWebsiteDataStore.remove(forIdentifier:id) }
            print("PASS Browser checks complete")
            return 0
        } catch {
            print("FAIL \(error)")
            for id in profiles { try? await WKWebsiteDataStore.remove(forIdentifier:id) }
            return 1
        }
    }
    static func wait(_ predicate: () -> Bool) async throws {
        let end=Date().addingTimeInterval(20)
        while !predicate() {
            if Date()>end {throw Failure.check("Timed out waiting for WebKit")}
            try await Task.sleep(nanoseconds:100_000_000)
        }
    }
}
