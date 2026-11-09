import AppKit
import WebKit
import WorkspaceCore

@MainActor enum StabilityChecks {
    final class WeakEngine {weak var value:BrowserEngine?;init(_ value:BrowserEngine){self.value=value}}
    static func run(root:URL) async throws {
        func expect(_ value:Bool,_ name:String)throws {
            guard value else{throw BrowserChecks.Failure.check(name)}
            print("PASS "+name)
        }
        let directory=root.appendingPathComponent("stability")
        let store=BrowserStore(directory:directory)
        store.session=BrowserSession()
        let a=store.addWorkspace(name:"A",url:"http://127.0.0.1:48761/"),b=store.addWorkspace(name:"B",url:"http://127.0.0.1:48761/child")
        let pa=store.workspace(a)!.pages[0].id,pb=store.workspace(b)!.pages[0].id
        let ea=store.engine(a,pa)!,eb=store.engine(b,pb)!
        try await BrowserChecks.wait {ea.navigationStarts>0 && eb.navigationStarts>0 && !ea.webView.isLoading && !eb.webView.isLoading}
        _=try await ea.webView.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend','<textarea id=\"draft\">unsent draft</textarea>');window.stressSentinel=42")
        let startsA=ea.navigationStarts,startsB=eb.navigationStarts
        for iteration in 0..<200 {
            store.selectWorkspace(a);store.selectPage(pa,in:a)
            store.setSplit(PageReference(workspaceID:b,pageID:pb));store.swapSplit()
            store.setSplit(nil);store.selectWorkspace(b)
            if iteration%10 == 0 {try await Task.sleep(for:.milliseconds(10))}
        }
        for _ in 0..<20 {store.detachWorkspace(a,show:false);try await Task.sleep(for:.milliseconds(10));store.reattachWorkspace(a,activate:false)}
        try await Task.sleep(for:.milliseconds(100))
        let sentinel=try await ea.webView.evaluateJavaScript("window.stressSentinel") as? Int
        let draft=try await ea.webView.evaluateJavaScript("document.getElementById('draft').value") as? String
        try expect(ea.navigationStarts == startsA && eb.navigationStarts == startsB && sentinel == 42 && draft == "unsent draft","200 switch/split cycles and 20 detach cycles preserve live pages and unsent input")
        let baseline=store.liveEngineCount
        var weakEngines:[WeakEngine]=[]
        for _ in 0..<40 {
            let page=store.addPage(to:a,url:"about:blank",load:false)!
            weakEngines.append(WeakEngine(page));store.closePage(page.pageID,in:a)
        }
        try await BrowserChecks.wait {weakEngines.allSatisfy{$0.value == nil}}
        try expect(store.liveEngineCount == baseline,"40 open/close cycles release engines and return to baseline")
        store.selectWorkspace(a);store.selectPage(pa,in:a)
        await Task.yield()
        store.selectWorkspace(b);store.selectPage(pb,in:b)
        try await Task.sleep(for:.milliseconds(50))
        store.cycleRecentTabs()
        try expect(store.recentCandidates.indices.contains(store.recentIndex) && store.recentCandidates[store.recentIndex].pageID == pa,"Recent-tab picker follows usage order across app workspaces")
        store.finishRecentTabs(commit:false)
        try expect(store.commandPage?.pageID == pb,"Cancelling recent-tab switching leaves selection unchanged")
        store.cycleRecentTabs();store.finishRecentTabs(commit:true)
        try expect(store.commandPage?.pageID == pa,"Committing recent-tab switching activates the selected existing tab")
        // Cancel an actual waiting JS action before its control appears.
        let actionScript=NotionActions.script.replacingOccurrences(of:"location.protocol",with:"'https:'").replacingOccurrences(of:"location.hostname",with:"'app.notion.com'")
        _=try await ea.webView.evaluateJavaScript("document.body.innerHTML='';window.cancelledClicks=0")
        let waiting=Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Any,Error>) in
                ea.webView.callAsyncJavaScript(actionScript,arguments:["action":"notionPage"],in:nil,in:.page){continuation.resume(with:$0)}
            }
        }
        try await Task.sleep(for:.milliseconds(100))
        _=try await ea.webView.evaluateJavaScript("globalThis.__workspaceTabsCancelAction?.();document.body.innerHTML='<button onclick=\"window.cancelledClicks++\">New page</button>';true")
        let cancelled=try await waiting.value as? [String:Any]
        let clicks=try await ea.webView.evaluateJavaScript("window.cancelledClicks") as? Int
        try expect(cancelled?["cancelled"] as? Bool == true && clicks == 0,"Cancelling a pending Notion action disconnects observers and prevents a later click")
        let generation=ea.documentGeneration
        ea.navigate("http://127.0.0.1:48761/")
        try expect(!ea.acceptsDocumentResult(generation),"Navigation invalidates old results even when the URL is unchanged")
        try await BrowserChecks.wait {!ea.webView.isLoading}
        let temporary=store.addPage(to:a,url:"about:blank",load:false)!
        let disposedGeneration=temporary.documentGeneration
        store.closePage(temporary.pageID,in:a)
        try expect(!temporary.acceptsDocumentResult(disposedGeneration),"Disposed pages reject late asynchronous results")

        // A failure on an already loaded document must not reload its unsent input.
        let loadedStarts=eb.navigationStarts
        store.selectWorkspace(b);store.selectPage(pb,in:b)
        let failure=NSError(domain:NSURLErrorDomain,code:NSURLErrorNotConnectedToInternet,userInfo:[NSURLErrorFailingURLErrorKey:eb.webView.url!])
        eb.webView(eb.webView,didFailProvisionalNavigation:nil,withError:failure)
        store.connectionChanged(online:false);store.connectionChanged(online:true)
        try expect(eb.connectionRetryURL == nil && eb.navigationStarts == loadedStarts,"Network recovery never reloads an already committed document")
        let failed=store.addPage(to:b,url:"http://127.0.0.1:48762/offline")!
        try await BrowserChecks.wait {failed.failure != nil}
        let initialFailure=failed.connectionRetryURL
        store.connectionChanged(online:false)
        failed.prepareForDisplay()
        try expect(initialFailure != nil && failed.connectionRetryURL == initialFailure,"Offline state defers retry of a failed initial GET")
        store.connectionChanged(online:true)
        try expect(failed.connectionRetryURL == nil,"Connectivity restoration consumes a failed initial GET retry once")
        store.closePage(failed.pageID,in:b)

        store.save()
        let expected=store.session
        let backupDir=directory.appendingPathComponent("BrowserBackups")
        try FileManager.default.createDirectory(at:backupDir,withIntermediateDirectories:true)
        let good=try JSONEncoder().encode(expected.validated())
        try good.write(to:backupDir.appendingPathComponent("9999999999998-good.json"))
        try Data("{broken".utf8).write(to:backupDir.appendingPathComponent("9999999999999-broken.json"))
        let primary=directory.appendingPathComponent("browser-session.json"),corrupt=Data("{corrupt primary".utf8)
        try corrupt.write(to:primary)
        let recovered=try SessionRecovery.load(directory:directory)
        try expect(recovered?.session == expected && recovered?.recovered == true,"Startup recovery skips a corrupt latest backup and restores the newest valid session")
        let archived=try FileManager.default.contentsOfDirectory(at:directory.appendingPathComponent("Recovery"),includingPropertiesForKeys:nil)
        try expect(archived.contains{(try? Data(contentsOf:$0)) == corrupt},"Recovery archives the exact damaged primary before replacing it")
        try FileManager.default.removeItem(at:primary)
        try expect(try SessionRecovery.load(directory:directory)?.recovered == true,"A missing primary can recover from valid backup history")
        var future=try JSONSerialization.jsonObject(with:good) as! [String:Any];future["version"]=999
        let futureBytes=try JSONSerialization.data(withJSONObject:future);try futureBytes.write(to:primary)
        var rejected=false
        do {_=try SessionRecovery.load(directory:directory)}catch{rejected=true}
        try expect(rejected && (try Data(contentsOf:primary)) == futureBytes,"Newer session formats are never silently downgraded or overwritten")
        try good.write(to:primary)
        let brokenOnly=directory.appendingPathComponent("broken-only")
        let brokenBackups=brokenOnly.appendingPathComponent("BrowserBackups")
        try FileManager.default.createDirectory(at:brokenBackups,withIntermediateDirectories:true)
        try corrupt.write(to:brokenBackups.appendingPathComponent("1.json"))
        var refusedReset=false
        do {_=try SessionRecovery.load(directory:brokenOnly)}catch{refusedReset=true}
        try expect(refusedReset && !FileManager.default.fileExists(atPath:brokenOnly.appendingPathComponent("browser-session.json").path),"Unrecoverable backup history never silently creates an empty session")
        store.shutdown()
        for engine in store.loadedEngines {engine.dispose()}
        for profile in store.session.profiles {try? await WKWebsiteDataStore.remove(forIdentifier:profile.id)}
    }
}
