import AppKit
import AVFoundation
import WebKit

/// Explicit local diagnostics; never runs during normal startup or contacts Notion.
@MainActor enum MediaChecks {
    static func run() async -> Int32 {
        guard let raw=ProcessInfo.processInfo.environment["WORKSPACE_TABS_MEDIA_CHECK_URL"],
              let url=URL(string:raw),url.scheme == "http",url.host == "127.0.0.1",url.path == "/media-check" else {
            print("FAIL media checks require the local fixture runner");return 1
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("workspace-media-"+UUID().uuidString)
        let store=BrowserStore(directory:root)
        let profiles=store.session.profiles.map(\.id)
        guard let workspace=store.selected,let page=store.selectedPage,let engine=store.engine(workspace.id,page.id,load:false) else{return 1}
        let window=NSWindow(contentRect:NSRect(x:160,y:160,width:780,height:510),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="Workspace Tabs — ローカル音声検証";window.isReleasedWhenClosed=false
        window.contentView=engine.webView;window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        engine.navigate(url.absoluteString)
        var result:Int32=1
        do {
            try await BrowserChecks.wait{!engine.webView.isLoading && engine.lastHTTPStatus == 200}
            let live=CommandLine.arguments.contains("--live-microphone")
            if live {
                _=try await engine.webView.evaluateJavaScript("window.liveMode=true;document.getElementById('start').hidden=false;true")
                print("WAIT Click the local microphone test button; audio is not saved or sent.")
            } else {_=try await engine.webView.evaluateJavaScript("window.startTest(false);true")}
            let deadline=Date().addingTimeInterval(live ? 240:20)
            var report:[String:Any]?
            while Date()<deadline,window.isVisible {
                report=try await engine.webView.evaluateJavaScript("window.testResult || null") as? [String:Any]
                if report != nil {break}
                try await Task.sleep(for:.milliseconds(200))
            }
            if let report {
                let data=try JSONSerialization.data(withJSONObject:report,options:.sortedKeys)
                print(String(decoding:data,as:UTF8.self))
                result=report["ok"] as? Bool == true ? 0:1
            } else {print("FAIL media check cancelled or timed out")}
        } catch {print("FAIL media check:",error.localizedDescription)}
        store.shutdown();window.contentView=nil;window.close()
        for profile in profiles {try? await WKWebsiteDataStore.remove(forIdentifier:profile)}
        try? FileManager.default.removeItem(at:root)
        return result
    }
}
