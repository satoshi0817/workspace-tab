import AppKit
import WebKit
import WorkspaceCore

@MainActor enum DownloadChecks {
    static func run() async -> Int32 {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("workspace-download-checks-"+UUID().uuidString)
        var store:BrowserStore?=BrowserStore(directory:root)
        var profiles:[UUID]=[]
        let result:Int32
        do {
            try await verify(store!,root:root)
            result=0
        } catch {print("FAIL \(error)");result=1}
        profiles=store!.session.profiles.map(\.id)
        store?.shutdown();store=nil
        for id in profiles {try? await WKWebsiteDataStore.remove(forIdentifier:id)}
        try? FileManager.default.removeItem(at:root)
        return result
    }
    private static func verify(_ store:BrowserStore,root:URL) async throws {
        func expect(_ value:Bool,_ label:String)throws {
            guard value else{throw BrowserChecks.Failure.check(label)}
            print("PASS \(label)")
        }
        let id=store.addWorkspace(name:"Download fixture",url:"http://127.0.0.1:48761/download-page")
        let engine=store.engine(id,store.workspace(id)!.pages[0].id)!
        try await BrowserChecks.wait{engine.webView.title == "Download fixture" && !engine.webView.isLoading}
        let originalURL=engine.webView.url
        let expected=Data("Workspace Tabs download fixture\n".utf8)
        var selections=0
        var destination:URL?=root.appendingPathComponent("attachment.txt")
        store.downloadDestinationChooser={_,done in selections += 1;done(destination)}
        func trigger(_ script:String) async throws {
            let before=selections
            print("Starting: \(script)")
            _ = try await engine.webView.evaluateJavaScript(script)
            do {try await BrowserChecks.wait{selections > before}}
            catch {print("Download state: jobs=\(store.downloads.activeCount); page=\(engine.failure ?? "none"); notice=\(store.notice ?? "none")");throw error}
        }
        func settled() async throws {
            try await BrowserChecks.wait{store.downloads.activeCount == 0}
            try await Task.sleep(nanoseconds:150_000_000)
        }
        func intact(_ label:String) async throws {
            let draft=try await engine.webView.evaluateJavaScript("document.getElementById('draft')?.value") as? String
            try expect(engine.failure == nil && engine.loadingState != .failed && engine.webView.url == originalURL && draft == "keep unsent input",label+" preserves page and unsent input")
        }
        for link in ["attachment","text","attribute","blob","cookie","post","popup"] {
            destination=root.appendingPathComponent(link+".txt")
            if link == "cookie" {_ = try await engine.webView.evaluateJavaScript("document.cookie='download-profile=alpha; path=/'")}
            try await trigger(link == "post" ? "document.getElementById('post').submit()" : "document.getElementById('\(link)').click()")
            try await settled()
            let bytes=try Data(contentsOf:destination!)
            let wanted=link == "blob" ? Data("blob fixture content".utf8) : link == "post" ? Data("original POST response".utf8) : expected
            try expect(bytes == wanted,"\(link) saves original response bytes")
            try expect(store.downloads.records.first?.state == .completed && store.downloads.records.first?.fileURL == destination,"\(link) records the completed destination")
            try await intact(link)
            if link == "popup" {try expect(store.workspace(id)!.pages.count == 1 && store.workspace(id)!.selectedPageID == engine.pageID,"Download-only popup returns to its opener")}
        }
        destination=nil
        try await trigger("document.getElementById('attachment').click()")
        try await settled();try await intact("Cancel")
        try expect(store.downloads.records.first?.state == .cancelled,"Canceled save is identified in history")
        let target=root.appendingPathComponent("existing.txt")
        try Data("old contents".utf8).write(to:target)
        destination=target
        try await trigger("document.getElementById('attachment').click()")
        try await settled()
        try expect(try Data(contentsOf:target) == expected,"Confirmed overwrite replaces an existing file")
        let old=Data("preserve on failure".utf8)
        try old.write(to:target)
        try await trigger("document.getElementById('broken').click()")
        try await settled()
        try expect(try Data(contentsOf:target) == old,"Interrupted transfer preserves the previous file")
        try expect(store.noticeIsError,"Interrupted transfer reports a download error")
        try expect(store.downloads.records.first?.state == .failed && store.downloads.file(for:store.downloads.records[0]) == nil,"Failed overwrite cannot open the previous file as a completed download")
        try await intact("Interrupted transfer")
        try await trigger("document.getElementById('slow').click()")
        let concurrent=Data("another app changed this file".utf8)
        try concurrent.write(to:target)
        try await settled()
        try expect(try Data(contentsOf:target) == concurrent,"Download does not overwrite a concurrently changed file")

        var choices:[(URL?)->Void]=[]
        store.downloadDestinationChooser={_,done in choices.append(done)}
        _ = try await engine.webView.evaluateJavaScript("document.getElementById('attachment').click()")
        try await BrowserChecks.wait{choices.count == 1}
        _ = try await engine.webView.evaluateJavaScript("document.getElementById('text').click()")
        try await BrowserChecks.wait{store.downloads.activeCount == 2}
        try expect(choices.count == 1,"Concurrent downloads show one save dialog at a time")
        choices[0](nil)
        try await BrowserChecks.wait{choices.count == 2}
        let queued=root.appendingPathComponent("queued.txt")
        choices[1](queued)
        try await settled()
        try expect(try Data(contentsOf:queued) == expected,"Canceling a save dialog advances the next download")
        store.downloadDestinationChooser={_,done in selections += 1;done(destination)}
        destination=root.appendingPathComponent("after-close.txt")
        try await trigger("document.getElementById('slow').click()")
        store.closePage(engine.pageID,in:id)
        try await settled()
        try expect(try Data(contentsOf:destination!) == expected,"Download continues after its source tab closes")
        let application=NSApp as! BrowserApplication,oldAction=application.panelKeyAction
        defer {application.panelKeyAction=oldAction}
        func key(_ code:UInt16,_ text:String)->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:0,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!}
        store.downloadsPresented=true;store.downloads.selection=store.downloads.records.first?.id
        try expect(store.handleDownloadKey(key(125,"")) && store.downloads.selection == store.downloads.records[1].id,"Download Down key selects the next file without forwarding to WebKit")
        try expect(store.handleDownloadKey(key(126,"")) && store.downloads.selection == store.downloads.records.first?.id,"Download Up key selects the previous file")
        try expect(!store.handleDownloadKey(key(0,"a")),"Download keyboard handling never consumes ordinary text input")
        var dispatched=0
        application.panelKeyAction={event in dispatched += 1;return store.handleDownloadKey(event)}
        let space=key(49," ")
        application.sendEvent(space);application.sendEvent(space)
        try await BrowserChecks.wait{store.previewFile != nil}
        try expect(dispatched == 1 && store.previewFile?.url == destination,"Preview key is consumed once even if the same event is resent")
        store.previewFile=nil;application.panelKeyAction=oldAction
        let history=root.appendingPathComponent("download-history.json")
        let restored=DownloadHistory.read(history)
        try expect(restored.first?.fileURL == destination && restored.first?.state == .completed,"Completed download history survives restart")
        try expect(store.downloads.file(for:restored[0]) == destination,"Completed local file is available for Open and Finder")
        try FileManager.default.removeItem(at:destination!)
        try expect(store.downloads.file(for:restored[0]) == nil,"Moved or deleted file is unavailable")
        let retainedFile=root.appendingPathComponent("attachment.txt")
        store.downloads.clearHistory()
        try expect(store.downloads.records.isEmpty && DownloadHistory.read(history).isEmpty && FileManager.default.fileExists(atPath:retainedFile.path),"Clearing history persists without deleting downloaded files")
        let pending=DownloadRecord(name:"pending",state:.transferring)
        try DownloadHistory.write([pending]+(0..<120).map{DownloadRecord(name:"\($0)",state:.completed)},to:history)
        let bounded=DownloadHistory.read(history)
        try expect(bounded.count == DownloadHistory.limit && bounded.first?.state == .interrupted,"Restart marks unfinished transfers interrupted and bounds history")
        let sensitive=DownloadRecord(name:"private",state:.failed,error:"https://example.test/file?secret=do-not-persist")
        let encoded=try JSONEncoder().encode(sensitive)
        try expect(!String(decoding:encoded,as:UTF8.self).contains("do-not-persist"),"History never persists URLs embedded in runtime error details")
        print("PASS All local download checks")
    }
}
