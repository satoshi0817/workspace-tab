import AppKit
import WebKit
import WorkspaceCore

@MainActor enum WorkflowChecks {
    static func run(root:URL,webView:WKWebView) async throws {
        func expect(_ value:Bool,_ name:String)throws {
            guard value else{throw BrowserChecks.Failure.check(name)}
            print("PASS "+name)
        }
        try await LinkRoutingChecks.run(root:root)
        // Exercise the actual action script against local HTML only.
        let pageID="11111111111111111111111111111111",spaceID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        _ = try await webView.evaluateJavaScript("""
        localStorage.setItem('LRU:KeyValueStore2:lastVisitedRoute',JSON.stringify({value:{name:'page',blockId:'\(pageID)'}}));
        localStorage.setItem('LRU:KeyValueStore2:lastVisitedRouteSpaceId',JSON.stringify({value:'\(spaceID)'}));
        document.body.innerHTML='<button onclick="window.guardClicks++">New page</button>';window.guardClicks=0;
        """)
        let script=NotionActions.script.replacingOccurrences(of:"location.protocol",with:"'https:'")
            .replacingOccurrences(of:"location.hostname",with:"'app.notion.com'")
            .replacingOccurrences(of:"location.pathname",with:"'/\(pageID)'")
            .replacingOccurrences(of:"loadingNewTab?12000:3500",with:"80")
        func execute(_ source:String,id:String,env:String="production",action:String="notionPage") async throws -> [String:Any] {
            let value:Any = try await withCheckedThrowingContinuation {continuation in
                webView.callAsyncJavaScript(source,arguments:["action":action,"expectedSpaceID":id,"expectedEnvironment":env],in:nil,in:.page){continuation.resume(with:$0)}
            }
            return value as? [String:Any] ?? [:]
        }
        let mismatch=try await execute(script,id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let unknown=try await execute(script.replacingOccurrences(of:"'/\(pageID)'",with:"'/ai'"),id:spaceID)
        let wrongEnvironment=try await execute(script,id:spaceID,env:"dev")
        let noClicks=try await webView.evaluateJavaScript("window.guardClicks") as? Int
        try expect(mismatch["message"] as? String == "設定と異なるワークスペースのため作成を中止しました" && mismatch["ok"] as? Bool == false && unknown["ok"] as? Bool == false && wrongEnvironment["ok"] as? Bool == false && noClicks == 0,"Creation guard rejects mismatched, unknown and wrong-environment workspaces without clicking")
        let match=try await execute(script,id:spaceID)
        let clicks=try await webView.evaluateJavaScript("window.guardClicks") as? Int
        try expect(match["ok"] as? Bool == true && clicks == 1,"Creation guard allows the matching workspace exactly once")

        for action in ["notionDatabase","notionCustomPage"] {
            _ = try await webView.evaluateJavaScript("""
            document.body.innerHTML='<nav class="notion-sidebar-container"><div data-inp-target="sidebar-create-page"><button aria-label="More options">▼</button></div></nav>';
            window.dropdownClicks=0;window.creationClicks=0;
            document.querySelector('button').onclick=()=>{
              window.dropdownClicks++;
              const button=document.createElement('button');button.textContent='\(action == "notionDatabase" ? "New database":"Custom page")';
              button.onclick=()=>window.creationClicks++;document.querySelector('nav').append(button);
            };void 0;
            """)
            let rejected=try await execute(script,id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",action:action)
            let untouched=try await webView.evaluateJavaScript("window.dropdownClicks+window.creationClicks") as? Int
            try expect(rejected["ok"] as? Bool == false && untouched == 0,"\(action) checks workspace before opening creation dropdown")
            let created=try await execute(script.replacingOccurrences(of:",80);",with:",1500);"),id:spaceID,action:action)
            let createdCount=try await webView.evaluateJavaScript("window.creationClicks") as? Int
            try expect(created["ok"] as? Bool == true && createdCount == 1,"\(action) opens the sidebar dropdown and activates its unique creation control")
        }

        let directory=root.appendingPathComponent("workflow")
        let store=BrowserStore(directory:directory)
        store.session=BrowserSession()
        let a=store.addWorkspace(name:"A",url:"http://127.0.0.1:48761/")
        let b=store.addWorkspace(name:"B",url:"http://127.0.0.1:48761/child")
        let pa=store.workspace(a)!.pages[0],pb=store.workspace(b)!.pages[0]
        store.selectWorkspace(a);store.setSplit(PageReference(workspaceID:b,pageID:pb.id))
        store.saveWorkset(name:"Meeting")
        let saved=store.worksets[0]
        var extra=BrowserPage(url:"http://127.0.0.1:48761/extra");extra.tabName="Keep me"
        store.session.workspaces[0].pages.append(extra)
        store.setSplit(nil);store.selectWorkspace(b)
        try expect(store.restoreWorkset(saved.id) && store.page(PageReference(workspaceID:a,pageID:extra.id)) != nil && store.selected?.id == a && store.split?.pageID == pb.id,"Workset restoration preserves current tabs and restores selection and split")
        let count=store.session.workspaces.reduce(0){$0+$1.pages.count}
        _=store.restoreWorkset(saved.id)
        try expect(store.session.workspaces.reduce(0){$0+$1.pages.count} == count,"Restoring a workset twice never duplicates existing URLs")
        store.detachWorkspace(b,show:false)
        try expect(store.restoreWorkset(saved.id) && !store.detachedWorkspaceIDs.contains(b) && store.split?.workspaceID == b,"Workset split restores detached workspaces to the main window")
        var sameURL=pa;sameURL.id=UUID()
        store.session.workspaces[0].pages.append(sameURL)
        store.selectPage(pa.id,in:a);store.setSplit(PageReference(workspaceID:a,pageID:sameURL.id))
        store.saveWorkset(name:"Two views of one URL")
        let splitSet=store.worksets.last!.id
        store.setSplit(nil)
        try expect(store.restoreWorkset(splitSet) && store.split?.pageID != store.selectedPage?.id && store.split?.pageID == sameURL.id,"Workset preserves intentional duplicate tabs used in split view")
        let originalProfile=store.session.workspaces[0].profileID
        store.session.workspaces[0].profileID=UUID()
        let before=store.session
        try expect(!store.restoreWorkset(saved.id) && store.session == before,"Missing workset login fails before modifying any tabs")
        store.session.workspaces[0].profileID=originalProfile
        let index=try JSONDecoder().decode(LauncherIndex.self,from:Data(contentsOf:directory.appendingPathComponent("raycast-index.json")))
        try expect(index.commands.contains{$0.id == "workset:"+saved.id.uuidString},"Raycast exposes saved worksets as commands")
        store.worksets=[];store.loadWorksets()
        try expect(store.worksets.first?.id == saved.id,"Worksets survive disk reload")
        let urlA="https://www.notion.so/Title-\(pageID)"
        let urlB="https://app.notion.com/p/acme/\(pageID)"
        try expect(BrowserStore.pageKey(urlA) == BrowserStore.pageKey(urlB),"Notion aliases for the same page deduplicate")
        try expect(BrowserStore.pageKey(urlA+"?v=one") != BrowserStore.pageKey(urlB+"?v=two") && BrowserStore.pageKey(urlB) != BrowserStore.pageKey(urlB.replacingOccurrences(of:"app.notion.com",with:"app.dev.notion.com")),"Different views and production/dev pages remain distinct")
        var notionPage=BrowserPage(url:urlA)
        notionPage.tabName="Notion fixture"
        store.session.workspaces[0].pages.append(notionPage)
        store.openExternalNotion(URL(string:urlB)!)
        try expect(store.selected?.id == a && store.selectedPage?.id == notionPage.id,"External Notion URL selects its unique existing app tab")
        store.openExternalNotion(URL(string:"https://app.notion.com/"+String(repeating:"2",count:32))!)
        try expect(store.pendingExternalURL != nil,"Unresolved external URL asks for an environment instead of guessing")
        store.pendingExternalURL=nil
        try expect(AppDelegate.externalNotionURL(URL(string:"workspacetabs://open?url=https%3A%2F%2Fapp.notion.com%2F"+pageID)!) != nil && AppDelegate.externalNotionURL(URL(string:"workspacetabs://open?url=javascript%3Aalert(1)")!) == nil && AppDelegate.externalNotionURL(URL(string:"workspacetabs://open?url=https%3A%2F%2Fapp.notion.com&url=https%3A%2F%2Fevil.test")!) == nil,"External bridge validates host, scheme and duplicate parameters")
        for _ in 0..<205 {store.timings.add("fixture",milliseconds:1)}
        try expect(store.timings.entries.count == 200,"Diagnostic memory ring is bounded")
        store.save()
        store.session.workspaces[0].name="Changed";store.save()
        try expect(!store.sessionHistory().isEmpty,"Existing session backups are available as validated restore history")
        store.shutdown()
        for profile in store.session.profiles {try? await WKWebsiteDataStore.remove(forIdentifier:profile.id)}
        _=pa
    }
}
