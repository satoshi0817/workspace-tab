import AppKit
import WebKit
import WorkspaceCore

/// Opt-in, anonymous first-start diagnostics. No user settings, migration, PATs or existing WebKit profiles are used.
@MainActor enum StartupChecks {
    private static func report(_ value:[String:Any]) {
        if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),var line=String(data:data,encoding:.utf8) {
            line += "\n";FileHandle.standardOutput.write(Data(line.utf8))
        }
    }
    static func run() async -> Int32 {
        let count=min(10,max(1,Int(ProcessInfo.processInfo.environment["WORKSPACE_TABS_STARTUP_ATTEMPTS"] ?? "5") ?? 5))
        let target=ProcessInfo.processInfo.environment["WORKSPACE_TABS_STARTUP_URL"] ?? "https://app.notion.com"
        guard let url=BrowserAddress.url(target) else {report(["error":"Invalid startup URL"]);return 1}
        var failures=0
        for attempt in 1...count {
            let result=await attemptLaunch(url:url,index:attempt)
            report(result.report)
            if !result.ok {failures += 1}
            for profile in result.profiles {try? await WKWebsiteDataStore.remove(forIdentifier:profile)}
        }
        report(["attempts":count,"failures":failures,"macOS":ProcessInfo.processInfo.operatingSystemVersionString])
        return failures == 0 ? 0:1
    }
    private static func attemptLaunch(url:URL,index:Int) async -> (ok:Bool,report:[String:Any],profiles:[UUID]) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("workspace-startup-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=BrowserStore(directory:root)
        let profiles=store.session.profiles.map(\.id)
        guard store.firstLaunch,store.error == nil,let workspace=store.selected,let page=store.selectedPage,
              store.session.workspaces.count == 1,profiles.count == 1,
              store.favorites.isEmpty,!store.notion.state.enabled,store.notion.state.sources.isEmpty else {
            store.shutdown();return (false,["attempt":index,"error":"Fresh session initialization failed"],profiles)
        }
        let before=await store.dataStore(workspace.profileID).httpCookieStore.allCookies()
        let engine=store.engine(workspace.id,page.id,load:false)!
        let window=NSWindow(contentRect:NSRect(x:150,y:150,width:1000,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.title="Workspace Tabs — 初回起動の検証";window.contentView=engine.webView;window.orderFront(nil)
        engine.navigate(url.absoluteString)
        let deadline=Date().addingTimeInterval(60)
        var content:[String:Any]=[:]
        while Date()<deadline {
            if engine.failure != nil {break}
            if !engine.webView.isLoading,engine.loadingState == .none {
                content=(try? await engine.webView.evaluateJavaScript(#"""
                (()=>{
                  const text=(document.body?.innerText||'').trim();
                  const serverError=/^(?:504|502|503|500)\b|gateway\s*(?:time.?out|error)|bad gateway|internal server error/i.test(text.slice(0,500));
                  const signIn=!!document.querySelector('input[type=email],input[autocomplete=username]') || /log in|sign in|continue with|ログイン|メールアドレス/i.test(text);
                  return {ready:document.readyState==='complete' && text.length>0,serverError,signIn};
                })()
                """#)) as? [String:Any] ?? [:]
                if content["ready"] as? Bool == true {break}
            }
            try? await Task.sleep(for:.milliseconds(200))
        }
        let status=engine.lastHTTPStatus ?? 0
        let ok=before.isEmpty && engine.failure == nil && (200..<400).contains(status) && content["ready"] as? Bool == true && content["serverError"] as? Bool != true
        let finalURL=engine.webView.url
        let outcome:[String:Any]=["attempt":index,"ok":ok,"cookiesBefore":before.count,"status":status,
            "host":finalURL?.host ?? "","path":finalURL?.path ?? "","contentReady":content["ready"] as? Bool ?? false,
            "signInVisible":content["signIn"] as? Bool ?? false,"serverErrorPage":content["serverError"] as? Bool ?? false,
            "error":engine.failure ?? (content["ready"] as? Bool == true ? "":"Timed out waiting for page content")]
        store.shutdown();window.contentView=nil;window.close()
        return (ok,outcome,profiles)
    }
}
