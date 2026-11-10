import AppKit
import WebKit
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceCore

@MainActor enum ProductivityChecks {
    static func run(root:URL) async throws {
        let directory=root.appendingPathComponent("productivity")
        var store:BrowserStore?=BrowserStore(directory:directory)
        var safe:BrowserStore?
        let profiles: [UUID]
        do {
            try await verify(store!,safe:&safe,root:directory)
            profiles=store!.session.profiles.map(\.id)
        } catch {
            let ids=store!.session.profiles.map(\.id)
            safe?.shutdown();safe=nil;store?.shutdown();store=nil
            for id in ids {try? await WKWebsiteDataStore.remove(forIdentifier:id)}
            throw error
        }
        safe?.shutdown();safe=nil;store?.shutdown();store=nil
        for id in profiles {try? await WKWebsiteDataStore.remove(forIdentifier:id)}
    }
    private static func verify(_ store:BrowserStore,safe:inout BrowserStore?,root:URL) async throws {
        func expect(_ value:Bool,_ label:String)throws {
            guard value else{throw BrowserChecks.Failure.check(label)};print("PASS "+label)
        }
        let url=URL(string:"http://127.0.0.1:48761/download-page")!
        let a=store.addWorkspace(name:"Alpha",url:url.absoluteString)
        let b=store.addWorkspace(name:"Beta",url:"http://127.0.0.1:48761/child")
        let first=store.workspace(a)!.pages[0].id
        let engine=store.engine(a,first)!
        try await BrowserChecks.wait{engine.webView.title == "Download fixture" && !engine.webView.isLoading}
        _ = try await engine.webView.evaluateJavaScript("window.productivityDraft='keep';document.getElementById('draft').value='unsent productivity draft'")
        let initialStarts=engine.navigationStarts
        let favorite=FavoriteLink(title:"Unique favorite",url:"http://127.0.0.1:48761/docs",workspaceID:b)
        store.session.favorites=[favorite]
        let closed=store.addPage(to:a,url:"http://127.0.0.1:48761/closed",load:false)!.pageID
        store.closePage(closed,in:a)
        try expect(store.universalResults("Unique favorite",scope:.all).contains{$0.id == "favorite:"+favorite.id.uuidString},"Unified search includes favorites across app tabs")
        try expect(store.universalResults("Alpha",scope:.tabs).contains{$0.id == "tab:"+first.uuidString},"Unified search matches app names")
        try expect(store.universalResults("closed",scope:.closed).contains{$0.id == "closed:"+closed.uuidString},"Unified search includes individual closed tabs")
        try expect(store.restoreClosedPage(closed) && store.page(PageReference(workspaceID:a,pageID:closed)) != nil,"Search can restore a specific closed tab")
        try expect(store.universalResults("",scope:.commands).allSatisfy{$0.scope == .commands} && store.universalResults("",scope:.commands).contains{$0.id == "command:downloads"},"Search scopes keep command identities independent of language")
        let sample=root.appendingPathComponent("preview.txt");try Data("Local preview fixture".utf8).write(to:sample)
        let provider=NSItemProvider(object:sample as NSURL)
        try expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),"Downloaded file drag advertises a real file URL")
        store.previewDownload(DownloadRecord(name:"preview.txt",state:.completed,fileURL:sample))
        try await BrowserChecks.wait{store.previewFile?.url == sample}
        try expect(store.anyPanelPresented,"Quick Look participates in panel focus management")
        store.previewFile=nil

        let group=BrowserTabGroup(name:"Tools");_=store.saveTabGroup(group,in:b)
        let rule=BrowserLinkRule(domain:"localhost",workspaceID:b,groupID:group.id)
        store.session.linkRules=[rule]
        try expect(BrowserLinkRule.candidates(for:URL(string:"http://localhost:48761/child")!,rules:[rule]).count == 1,"Domain rule supports explicit local test hosts")
        var parent=BrowserLinkRule(domain:"example.com",workspaceID:a);parent.includeSubdomains=true
        let child=BrowserLinkRule(domain:"docs.example.com",workspaceID:b)
        try expect(BrowserLinkRule.candidates(for:URL(string:"https://docs.example.com/page")!,rules:[parent,child]).first?.workspaceID == b,"Most-specific domain rule wins")
        try expect(!parent.matches(URL(string:"https://example.com.evil.test")!) && !parent.matches(URL(string:"https://evil-example.com")!),"Domain rules reject hostname lookalikes")
        try expect(["https://example.com","example.com/path","user@example.com","*.example.com","example.com?x=1"].allSatisfy{BrowserLinkRule.normalizedDomain($0) == nil},"Rule editor rejects URL syntax and wildcard ambiguity")
        let notion=BrowserLinkRule(domain:"app.notion.com",workspaceID:b)
        try expect(BrowserLinkRule.candidates(for:URL(string:"https://app.notion.com/page")!,rules:[notion]).isEmpty,"Notion identity routing takes precedence over domain rules")
        store.selectWorkspace(a);store.selectPage(first,in:a)
        _ = try await engine.webView.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend','<a id=rule-link href=http://localhost:48761/child>Routed link</a>');document.getElementById('rule-link').click()")
        try await BrowserChecks.wait{store.selected?.id == b}
        let routed=store.selectedPage!
        try expect(routed.url == "http://localhost:48761/child" && store.workspace(b)!.groupID(for:routed) == group.id,"A real WebKit link opens in its configured app tab and group")
        try expect(engine.webView.url == url && engine.navigationStarts == initialStarts,"Routing leaves source page and unsent input loaded")
        let target=store.engine(b,routed.id)!
        try await BrowserChecks.wait{target.webView.title == "Browser fixture" && !target.webView.isLoading}
        try expect(engine.webView.configuration.websiteDataStore !== target.webView.configuration.websiteDataStore,"Routed tab uses the destination login profile")
        var duplicate=rule;duplicate.id=UUID();duplicate.workspaceID=a
        store.session.linkRules=[rule,duplicate]
        let before=store.session.workspaces
        try expect(store.routeLink(URL(string:"http://localhost:48761/ambiguous")!) && store.session.workspaces == before,"Ambiguous routing fails closed without opening in another profile")
        var missing=rule;missing.workspaceID=UUID();store.session.linkRules=[missing]
        try expect(store.routeLink(URL(string:"http://localhost:48761/missing")!) && store.session.workspaces == before,"Missing rule destination never falls back to the current profile")
        store.session.linkRules=[rule]

        var preference=store.sites.preference(profileID:engine.profileID,url:url)!
        preference.zoom=1.25;preference.microphone = .deny
        store.updateSitePreference(preference)
        try expect(engine.webView.pageZoom == 1.25 && engine.navigationStarts == initialStarts,"Site zoom applies without reloading live input")
        try expect(store.sites.decision(profileID:engine.profileID,url:url,type:.microphone) == .deny,"Microphone block is enforced for the configured origin")
        try expect(store.sites.decision(profileID:target.profileID,url:url,type:.microphone) == .prompt,"Site permissions stay isolated by login profile")
        try expect(store.sites.decision(profileID:engine.profileID,url:URL(string:"http://127.0.0.1:48762/")!,type:.microphone) == .prompt,"Site permissions distinguish ports")
        try expect(SitePreference.origin(URL(string:"https://EXAMPLE.com:443/path?token=private")!) == "https://example.com","Site preferences store origins without paths or token queries")
        let reloaded=SitePreferences(directory:root)
        try expect(reloaded.preference(profileID:engine.profileID,url:url)?.zoom == 1.25,"Site display preferences survive restart")
        store.updateSitePreference(SitePreference(profileID:engine.profileID,origin:preference.origin))
        try expect(engine.webView.pageZoom == 1 && store.sites.decision(profileID:engine.profileID,url:url,type:.microphone) == .prompt,"Per-site reset restores zoom and prompts without reloading")

        store.selectWorkspace(a);store.selectPage(first,in:a);store.setSplit(PageReference(workspaceID:b,pageID:routed.id))
        store.session.splitOrientation="vertical";store.session.splitFraction=0.35
        store.saveWorkset(name:"Split geometry")
        store.session.splitOrientation="horizontal";store.session.splitFraction=0.6
        try expect(store.restoreWorkset(store.worksets.last!.id) && store.session.splitOrientation == "vertical" && store.session.splitFraction == 0.35,"Worksets restore split orientation and ratio")
        let splitView=PersistentSplitView(frame:NSRect(x:0,y:0,width:1000,height:800))
        splitView.addArrangedSubview(NSView());splitView.addArrangedSubview(NSView())
        let ratioHost=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:800),styleMask:[.borderless],backing:.buffered,defer:false)
        ratioHost.isReleasedWhenClosed=false;ratioHost.contentView=splitView
        defer {ratioHost.contentView=nil;ratioHost.close()}
        splitView.layoutSubtreeIfNeeded()
        splitView.isVertical=true;splitView.fraction=0.35;splitView.applyFraction()
        try expect(abs(splitView.arrangedSubviews[0].frame.width/(splitView.axisLength-splitView.dividerThickness)-0.35)<0.01,"Native split divider restores a saved horizontal ratio")
        splitView.isVertical=false;splitView.applyFraction()
        try expect(abs(splitView.arrangedSubviews[0].frame.height/(splitView.axisLength-splitView.dividerThickness)-0.35)<0.01,"Native split divider restores a saved vertical ratio")
        let host=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:800),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        host.isReleasedWhenClosed=false
        host.contentView=NSHostingView(rootView:BrowserSplit(store:store,left:PageReference(workspaceID:a,pageID:first),right:PageReference(workspaceID:b,pageID:routed.id)))
        defer {host.contentView=nil;host.close()}
        host.contentView?.layoutSubtreeIfNeeded()
        store.session.splitOrientation="horizontal";store.session.splitFraction=0.6;store.changed()
        try await Task.sleep(for:.milliseconds(200));host.contentView?.layoutSubtreeIfNeeded()
        let draft=try await engine.webView.evaluateJavaScript("document.getElementById('draft').value") as? String
        try expect(draft == "unsent productivity draft" && engine.navigationStarts == initialStarts,"Split orientation changes preserve the live page and unsent input")
        try expect(engine.webView.superview != nil && target.webView.superview != nil,"Both split panes keep their live WebViews mounted")
        try expect(store.session.splitFraction == 0.6,"Initial native split layout cannot overwrite the saved ratio")
        func nativeSplit(in view:NSView)->PersistentSplitView? {
            if let split=view as? PersistentSplitView{return split}
            return view.subviews.lazy.compactMap{nativeSplit(in:$0)}.first
        }
        guard let hosted=nativeSplit(in:host.contentView!) else{throw BrowserChecks.Failure.check("Hosted native split exists")}
        let desired=(hosted.axisLength-hosted.dividerThickness)*0.4
        hosted.trackingDivider=true;hosted.setPosition(desired,ofDividerAt:0);hosted.trackingDivider=false
        try expect(abs((store.session.splitFraction ?? 0)-0.4)<0.01,"Native divider movement updates the persisted ratio")
        store.saveBeforeExit()
        let saved=try JSONDecoder().decode(BrowserSession.self,from:Data(contentsOf:root.appendingPathComponent("browser-session.json"))).validated()
        try expect(saved.splitFraction == store.session.splitFraction && saved.linkRules == [rule],"Split geometry and routing rules are persisted with the session")

        let safeRoot=root.appendingPathComponent("safe-mode")
        try FileManager.default.createDirectory(at:safeRoot,withIntermediateDirectories:true)
        try JSONEncoder().encode(saved).write(to:safeRoot.appendingPathComponent("browser-session.json"))
        let health=StartupRecovery(directory:safeRoot)
        try expect(!health.interruptedStartup,"Fresh installation does not enter Safe Mode")
        health.mark("starting")
        safe=BrowserStore(directory:safeRoot,trackStartup:true)
        try expect(safe!.safeMode && safe!.session.workspaces == saved.workspaces,"Interrupted initial startup restores configuration in Safe Mode")
        let paused=safe!.engine(a,first)!
        paused.prepareForDisplay()
        try await Task.sleep(for:.milliseconds(150))
        try expect(paused.webView.url == nil && paused.navigationStarts == 0,"Safe Mode starts without loading a saved website")
        let pausedRight=safe!.engine(b,routed.id)!
        safe!.session.linkRules=[BrowserLinkRule(domain:"127.0.0.1",workspaceID:b)]
        safe!.resumePage(PageReference(workspaceID:a,pageID:first))
        try await BrowserChecks.wait{paused.webView.title == "Download fixture" && !paused.webView.isLoading}
        try expect(pausedRight.navigationStarts == 0 && safe!.isPageSuspended(routed.id),"Resuming one tab keeps other saved pages suspended")
        try expect(paused.webView.url == url && safe!.session.selectedWorkspaceID == a,"Safe Mode restoration preserves the saved profile despite matching link rules")
        safe!.resumeBrowsing()
        try await BrowserChecks.wait{pausedRight.navigationStarts>0}
        try expect(!safe!.safeMode,"Normal loading can be resumed explicitly")
        safe!.startupRecovery?.mark("ready")
        try expect(!StartupRecovery(directory:safeRoot).interruptedStartup,"A successful startup does not trigger Safe Mode after a later force quit")
        let brokenRoot=root.appendingPathComponent("unreadable-session")
        try FileManager.default.createDirectory(at:brokenRoot,withIntermediateDirectories:true)
        try Data("invalid json".utf8).write(to:brokenRoot.appendingPathComponent("browser-session.json"))
        let broken=BrowserStore(directory:brokenRoot)
        try expect(broken.safeMode && !broken.canPersist,"Unreadable settings enter read-only Safe Mode without overwriting the source")
        broken.shutdown()
        print("PASS Productivity checks complete")
    }
}
