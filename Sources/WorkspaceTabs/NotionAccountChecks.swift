import AppKit
import SwiftUI
import WebKit
import WorkspaceCore

/// Empty HTML documents, fake identities and a mocked fetch in an isolated world.
/// No real Notion request, OS key events, or user profile access.
@MainActor enum NotionAccountChecks {
    static func run() async throws {
        func expect(_ condition:Bool,_ name:String)throws {
            guard condition else{throw BrowserChecks.Failure.check(name)}
            print("PASS "+name)
        }
        let a="11111111111111111111111111111111",b="22222222222222222222222222222222"
        func evaluate(_ view:WKWebView,script:String,arguments:[String:Any]=[:]) async throws->Any {
            try await withCheckedThrowingContinuation { continuation in
                view.callAsyncJavaScript(script,arguments:arguments,in:nil,in:.defaultClient) {continuation.resume(with:$0)}
            }
        }
        func fixture(_ host:String="app.notion.com") async throws->WKWebView {
            let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
            let view=WKWebView(frame:NSRect(x:0,y:0,width:600,height:400),configuration:config)
            view.loadHTMLString("<main>Local account fixture</main><input id=draft value='keep unsent input'>",baseURL:URL(string:"https://\(host)/account-fixture")!)
            try await BrowserChecks.wait{!view.isLoading && view.url != nil}
            _ = try await evaluate(view,script:#"""
            globalThis.fixture={calls:0,mode:'ok',delay:0};
            globalThis.fetch=async (url,options)=>{
              if(typeof url === 'string' && url.startsWith('/image/')) {
                if(!url.startsWith('/image/'+encodeURIComponent('https://photos.example.test/alice.png')+'?table=notion_user&id=11111111-') || options.credentials !== 'same-origin') throw new Error('Unexpected photo request');
                fixture.photos=(fixture.photos||0)+1;
                if(fixture.photo === 'html') return {ok:true,blob:async()=>new Blob(['<html>'],{type:'text/html'})};
                const png=Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='),c=>c.charCodeAt(0));
                return {ok:true,blob:async()=>new Blob([png],{type:'image/png'})};
              }
              const request=JSON.parse(options.body);
              const id=request.requests?.[0]?.pointer?.id;
              if(url !== '/api/v3/syncRecordValues' || options.headers['x-notion-active-user-header'] !== id || request.requests.length !== 1 || request.requests[0].pointer.table !== 'notion_user' || options.credentials !== 'same-origin') throw new Error('Unexpected account request');
              fixture.calls++;
              const mode=fixture.mode,delay=fixture.delay;
              if(delay) await new Promise(resolve=>setTimeout(resolve,delay));
              if(mode === 'fail') return {ok:false};
              const other=id.startsWith('11111111') ? '22222222-2222-2222-2222-222222222222':'11111111-1111-1111-1111-111111111111';
              const record={id:mode === 'wrong' ? other:id,given_name:id.startsWith('11111111') ? 'Alice':'Bob',family_name:'Fixture',email:id.startsWith('11111111') ? 'alice@example.test':'bob@example.test'};
              if(id.startsWith('11111111')) record.profile_photo='https://photos.example.test/alice.png';
              if(mode === 'redacted') delete record.email;
              return {ok:true,json:async()=>({recordMap:{notion_user:{[id]:{role:mode === 'denied' ? 'none':'reader',value:record}}}})};
            };
            """#)
            return view
        }
        func setUser(_ id:String?,in view:WKWebView) async throws {
            _ = try await evaluate(view,script:"if(id)sessionStorage.setItem('activeUserId',id);else sessionStorage.removeItem('activeUserId');",arguments:["id":id as Any? ?? NSNull()])
        }
        func configure(_ view:WKWebView,mode:String="ok",delay:Int=0) async throws {
            _ = try await evaluate(view,script:"fixture.mode=mode;fixture.delay=delay;",arguments:["mode":mode,"delay":delay])
        }
        func calls(_ view:WKWebView) async throws->Int {
            let value=try await evaluate(view,script:"return fixture.calls;")
            guard let count=value as? Int else{throw BrowserChecks.Failure.check("Account fixture counter is invalid")}
            return count
        }
        func waitForCall(_ view:WKWebView,after count:Int) async throws {
            let deadline=Date().addingTimeInterval(5)
            while try await calls(view)<=count {
                guard Date()<deadline else{throw BrowserChecks.Failure.check("Account fixture request did not start")}
                try await Task.sleep(for:.milliseconds(20))
            }
        }
        let first=try await fixture(),second=try await fixture("app.dev.notion.com"),external=try await fixture("example.com")
        defer{first.stopLoading();second.stopLoading();external.stopLoading()}
        let monitor=NotionAccountMonitor(),other=NotionAccountMonitor()
        defer{monitor.invalidate();other.invalidate()}
        try await setUser(a,in:first);try await setUser(b,in:second);try await setUser(a,in:external)
        monitor.refresh(in:first,force:true)
        try await BrowserChecks.wait{!monitor.isRefreshing}
        try expect(monitor.account?.id == a && monitor.account?.email == "alice@example.test" && monitor.account?.name == "Alice Fixture","Notion account pill resolves the exact active tab account using a single user record")
        try expect(monitor.account?.displayName == "Alice Fixture" && monitor.account?.avatar.flatMap {NSImage(data:$0)}?.isValid == true,"Notion account shows the user name and the profile photo from Notion's same-origin image proxy")
        _ = try await evaluate(first,script:"fixture.photo='html';")
        monitor.refresh(in:first,force:true);try await BrowserChecks.wait{!monitor.isRefreshing}
        try expect(monitor.account?.id == a && monitor.account?.avatar == nil,"A non-image photo response keeps the account and falls back to the initial")
        _ = try await evaluate(first,script:"fixture.photo='';")
        other.refresh(in:second,force:true)
        try await BrowserChecks.wait{!other.isRefreshing}
        try expect(other.account?.id == b && other.account?.avatar == nil && monitor.account?.id == a,"Notion account displays stay isolated between browser tabs and environments")
        let previousCalls=try await calls(first)
        monitor.refresh(in:first)
        try await Task.sleep(for:.milliseconds(80))
        let unchangedCalls=try await calls(first)
        try expect(unchangedCalls == previousCalls,"Frequent page updates do not repeatedly fetch Notion account data")
        try await setUser(b,in:first);monitor.refresh(in:first,force:true)
        try await BrowserChecks.wait{!monitor.isRefreshing}
        try expect(monitor.account?.id == b && monitor.account?.email == "bob@example.test","Switching the active Notion account replaces the pill instead of reusing another account cache")
        for mode in ["wrong","redacted","denied","fail"] {
            try await configure(first,mode:mode);monitor.refresh(in:first,force:true)
            try await BrowserChecks.wait{!monitor.isRefreshing}
            try expect(monitor.account == nil,"Notion account is unknown for \(mode) responses instead of guessing an identity")
        }
        let beforeRetry=try await calls(first)
        try await Task.sleep(for:.milliseconds(4650))
        monitor.refresh(in:first);try await BrowserChecks.wait{!monitor.isRefreshing}
        let afterRetry=try await calls(first)
        try expect(beforeRetry == afterRetry,"Unavailable account APIs back off while lightweight identity checks continue")
        try await configure(first);try await setUser(nil,in:first)
        _ = try await evaluate(first,script:"document.cookie='notion_user_id=11111111-1111-1111-1111-111111111111';")
        let beforeMissing=try await calls(first)
        monitor.refresh(in:first,force:true);try await BrowserChecks.wait{!monitor.isRefreshing}
        let afterMissing=try await calls(first)
        try expect(monitor.account == nil && afterMissing == beforeMissing,"Missing per-tab identity never falls back to shared account cookies or a saved email")
        _ = try await evaluate(first,script:"localStorage.setItem('LRU:KeyValueStore2:current-user-id',JSON.stringify({id:'KeyValueStore2:current-user-id',value:'22222222-2222-2222-2222-222222222222'}));")
        monitor.refresh(in:first,force:true);try await BrowserChecks.wait{!monitor.isRefreshing}
        try expect(monitor.account?.id == b,"A tab without its own account choice uses Notion's current user")
        try await setUser(a,in:first);monitor.refresh(in:first,force:true);try await BrowserChecks.wait{!monitor.isRefreshing}
        try expect(monitor.account?.id == a,"The account chosen in the tab wins over Notion's current user")
        _ = try await evaluate(first,script:"localStorage.removeItem('LRU:KeyValueStore2:current-user-id');")
        let routed=URL(string:"https://app.notion.com/Fixture-cccccccccccccccccccccccccccccccc")!
        _ = try await evaluate(first,script:"history.replaceState(null,'','/Fixture-cccccccccccccccccccccccccccccccc');const put=(k,v)=>localStorage.setItem('LRU:KeyValueStore2:'+k,JSON.stringify({id:'KeyValueStore2:'+k,value:v}));put('lastVisitedRoute',{name:'page',blockId:'cccccccc-cccc-cccc-cccc-cccccccccccc'});put('lastVisitedRouteUserId','22222222-2222-2222-2222-222222222222');")
        try await BrowserChecks.wait{first.url == routed}
        monitor.refresh(in:first,force:true);try await BrowserChecks.wait{!monitor.isRefreshing}
        try expect(monitor.account?.id == b,"The account Notion recorded for the page being shown wins over a stale tab or shared value")
        _ = try await evaluate(first,script:"localStorage.setItem('LRU:KeyValueStore2:lastVisitedRoute',JSON.stringify({value:{name:'page',blockId:'dddddddd-dddd-dddd-dddd-dddddddddddd'}}));")
        monitor.refresh(in:first,force:true);try await BrowserChecks.wait{!monitor.isRefreshing}
        try expect(monitor.account?.id == a,"A route recorded for a different page is ignored")
        _ = try await evaluate(first,script:"localStorage.removeItem('LRU:KeyValueStore2:lastVisitedRoute');localStorage.removeItem('LRU:KeyValueStore2:lastVisitedRouteUserId');")
        let rows=try await evaluate(first,script:NotionAccount.directoryScript,arguments:["ids":[a,b,"not-an-id"]]) as? [[String:Any]] ?? []
        try expect(rows.compactMap{$0["email"] as? String}.sorted() == ["alice@example.test","bob@example.test"],"The account chooser reads the name and email of each signed-in Notion account")
        try expect(NotionAccount.userIDs(fromCookie:"%5B%2211111111-1111-1111-1111-111111111111%22%2C%2222222222-2222-2222-2222-222222222222%22%2C%2211111111111111111111111111111111%22%5D") == [a,b] && NotionAccount.userIDs(fromCookie:"oops").isEmpty,"Signed-in Notion accounts are read from Notion's own list, without duplicates")
        let seeded=try await fixture()
        _ = try await evaluate(seeded,script:"sessionStorage.clear();")
        _ = try await seeded.evaluateJavaScript(NotionAccount.seedScript(b)!+";true")
        let seededUser=try await evaluate(seeded,script:"return sessionStorage.getItem('activeUserId');") as? String
        _ = try await evaluate(seeded,script:"sessionStorage.setItem('activeUserId','11111111-1111-1111-1111-111111111111');")
        _ = try await seeded.evaluateJavaScript(NotionAccount.seedScript(b)!+";true")
        let keptUser=try await evaluate(seeded,script:"return sessionStorage.getItem('activeUserId');") as? String
        try expect(NotionWorkspace.normalizedID(seededUser) == b && NotionWorkspace.normalizedID(keptUser) == a,"A new tab starts Notion as the chosen account once and never overrides a later switch")
        try await setUser(a,in:first);try await configure(first,delay:250)
        let beforeSwitch=try await calls(first)
        monitor.refresh(in:first,force:true)
        try await waitForCall(first,after:beforeSwitch)
        try await setUser(b,in:first)
        try await BrowserChecks.wait{!monitor.isRefreshing}
        try expect(monitor.account == nil,"Account changes during a pending request discard the old response")
        try await configure(first);monitor.refresh(in:first,force:true)
        try await BrowserChecks.wait{!monitor.isRefreshing}
        try expect(monitor.account?.id == b,"Account verification recovers with the new identity after a discarded response")
        try await configure(first,delay:250)
        let beforeInvalidation=try await calls(first)
        monitor.refresh(in:first,force:true);try await waitForCall(first,after:beforeInvalidation)
        monitor.invalidate();try await configure(first);monitor.refresh(in:first,force:true)
        try await BrowserChecks.wait{!monitor.isRefreshing}
        try await Task.sleep(for:.milliseconds(300))
        try expect(monitor.account?.id == b,"Invalidated document requests cannot overwrite a later account result")
        monitor.refresh(in:external,force:true)
        let externalCalls=try await calls(external)
        try expect(!monitor.supported && monitor.account == nil && externalCalls == 0,"External sites clear the account pill and never trigger Notion account requests")
        let draft=try await first.evaluateJavaScript("document.getElementById('draft').value") as? String
        try expect(draft == "keep unsent input" && !first.isLoading,"Account checks never reload the page or modify unsent input")
        try expect(NotionAccount.decode(["id":a,"name":"Alice","email":"a@example.test"],matching:b) == nil && NotionAccount.decode(["id":a,"email":"invalid"],matching:a) == nil,"Native account validation rejects mismatched IDs and malformed emails")
        try expect(NotionAccount.decode(["id":a,"name":"spoof\nheader","email":"a@example.test"],matching:a) == nil,"Account display fields reject control characters")
        try expect(NotionWorkspace.pageID(URL(string:"https://www.notion.so/team/Plan-CCCCCCCCcccccccccccccccccccccccc?pvs=4")!) == "cccccccccccccccccccccccccccccccc" && NotionWorkspace.pageID(URL(string:"https://app.notion.com/p/team/board?p=dddddddd-dddd-dddd-dddd-dddddddddddd")!) == "dddddddddddddddddddddddddddddddd" && NotionWorkspace.pageID(URL(string:"https://www.notion.so/")!) == nil && NotionWorkspace.pageID(URL(string:"https://example.com/cccccccccccccccccccccccccccccccc")!) == nil,"Notion links yield the page ID used to look up their workspace")
        let page=BrowserPage(url:"https://app.notion.com/")
        let decoded=try JSONDecoder().decode(BrowserPage.self,from:JSONEncoder().encode(page))
        var appTab=BrowserWorkspace(name:"Fixture",profileID:UUID())
        try expect(decoded.showAccountEmail == nil && !appTab.showsAccountEmail(for:page),"The large account email is off until the app tab or the browser tab turns it on")
        try expect(appTab.accountEmailStyle == BrowserWorkspace(name:"x",profileID:UUID()).accountEmailStyle && !appTab.accountEmailStyle.centered && appTab.accountEmailStyle.opacity == 0.1,"The account email starts at the bottom right at 10 percent")
        appTab.accountEmailOpacity=7;appTab.accountEmailSize=1;appTab.accountEmailPosition="center"
        try expect(appTab.accountEmailStyle.opacity == 1 && appTab.accountEmailStyle.size == 8 && appTab.accountEmailStyle.centered,"Each app tab keeps its own position, size and opacity within safe limits")
        appTab.showAccountEmail=true
        var hidden=page;hidden.showAccountEmail=false
        try expect(appTab.showsAccountEmail(for:page) && !appTab.showsAccountEmail(for:hidden),"The app tab setting applies to its browser tabs, and a browser tab's own choice wins")
        if let output=ProcessInfo.processInfo.environment["WORKSPACE_TABS_ACCOUNT_PREVIEW_DIRECTORY"] {
            try await render(other,directory:URL(fileURLWithPath:output,isDirectory:true))
        }
    }
    private static func render(_ monitor:NotionAccountMonitor,directory:URL) async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for dark in [false,true] {
            let view=NSHostingView(rootView:HStack {Spacer();NotionAccountPill(monitor:monitor);Image(nsImage:Palette.symbolGlyph("ellipsis",dark ? .white:.black)).renderingMode(.original)}.padding(.horizontal,12).frame(width:420,height:48).foregroundStyle(dark ? Color.white:Color.black).background(dark ? Color(white:0.13):Color(white:0.94)))
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:420,height:48),styleMask:[],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=view
            view.layoutSubtreeIfNeeded();try await Task.sleep(for:.milliseconds(100))
            let image=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:image)
            try image.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(dark ? "account-dark.png":"account-light.png"))
            window.contentView=nil;window.close()
        }
    }
}
