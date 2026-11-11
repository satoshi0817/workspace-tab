import AppKit
import WebKit
import WorkspaceCore

@MainActor enum GroupLoginChecks {
    static func run(root:URL) async throws {
        func expect(_ condition:Bool,_ name:String)throws {
            guard condition else{throw BrowserChecks.Failure.check(name)};print("PASS "+name)
        }
        let directory=root.appendingPathComponent("group-logins")
        let store=BrowserStore(directory:directory)
        defer{store.shutdown()}
        store.session=BrowserSession()
        let workspaceID=store.addWorkspace(name:"Accounts",url:"http://127.0.0.1:48761/"),original=store.selectedPage!.id
        var decisions=0
        store.loginEnvironmentChangeConfirmation={_ in decisions += 1;return true}
        let alpha=BrowserTabGroup(name:"Work account"),beta=BrowserTabGroup(name:"Personal account")
        try expect(store.saveTabGroup(alpha,in:workspaceID,createIndependentProfile:true) && store.saveTabGroup(beta,in:workspaceID,createIndependentProfile:true),"Account groups create independent login profiles without changing the app tab")
        let workspace=store.workspace(workspaceID)!
        let alphaProfile=workspace.profileID(forGroup:alpha.id),betaProfile=workspace.profileID(forGroup:beta.id)
        try expect(alphaProfile != betaProfile && alphaProfile != workspace.profileID && decisions == 0,"New empty account groups do not alter or reload existing login environments")
        let choices=store.accountChoices(in:workspaceID)
        try expect(choices.compactMap(\.groupID) == [workspaceID,alpha.id,beta.id] && choices.filter(\.current).count == 1,"An app tab with several login environments offers each account once when opening Notion")
        let single=store.addWorkspace(name:"Single",url:"http://127.0.0.1:48761/")
        try expect(store.accountChoices(in:single).isEmpty,"An app tab with one login environment opens Notion without asking for an account")
        store.selectWorkspace(workspaceID)
        let url="http://127.0.0.1:48761/?group-login=page"
        let a=store.addPage(to:workspaceID,url:url,groupID:alpha.id)!,b=store.addPage(to:workspaceID,url:url,groupID:beta.id)!
        try await BrowserChecks.wait{!a.webView.isLoading && !b.webView.isLoading && a.webView.url?.query == "group-login=page" && b.webView.url?.query == "group-login=page"}
        try expect(a.profileID == alphaProfile && b.profileID == betaProfile && a.webView.configuration.websiteDataStore !== b.webView.configuration.websiteDataStore,"Browser engines resolve group profiles into separate persistent WebKit data stores")
        _ = try await a.webView.evaluateJavaScript("document.cookie='groupLogin=work;path=/';localStorage.setItem('groupLogin','work');document.body.insertAdjacentHTML('beforeend','<input id=group-draft value=unsent>')")
        let privateCookie=try await b.webView.evaluateJavaScript("document.cookie.includes('groupLogin=work') || localStorage.getItem('groupLogin') !== null") as? Bool
        try expect(privateCookie == false,"Cookies and localStorage do not leak between account groups in the same app tab")
        _ = try await b.webView.evaluateJavaScript("document.cookie='groupLogin=personal;path=/';localStorage.setItem('groupLogin','personal')")
        store.selectPage(a.pageID,in:workspaceID)
        let starts=a.navigationStarts
        store.selectPage(b.pageID,in:workspaceID);store.selectPage(a.pageID,in:workspaceID)
        let draft=try await a.webView.evaluateJavaScript("document.getElementById('group-draft').value") as? String
        try expect(a.navigationStarts == starts && draft == "unsent","Switching account-group tabs retains live pages and unsent input without reloads")
        try expect(store.duplicatePages.isEmpty,"Identical URLs in different account groups are not treated as duplicate tabs")
        store.showTabGroup(beta.id,in:workspaceID)
        try expect(store.existingPage(url:url,in:workspaceID)?.id == b.pageID,"Favorite reuse resolves only within the displayed group login environment")
        let count=store.workspace(workspaceID)!.pages.count
        _ = try await a.webView.evaluateJavaScript("window.open('http://127.0.0.1:48761/child','_blank');true")
        try await BrowserChecks.wait{store.workspace(workspaceID)!.pages.count == count+1}
        let child=store.workspace(workspaceID)!.pages.last!
        try expect(store.engine(workspaceID,child.id)!.profileID == alphaProfile && store.workspace(workspaceID)!.groupID(for:child) == alpha.id,"Popup tabs inherit the opener group and credentials even when another group is previewed")
        var renamed=store.workspace(workspaceID)!.resolvedTabGroups.first{$0.id == alpha.id}!
        renamed.name="Work renamed"
        try expect(store.saveTabGroup(renamed,in:workspaceID) && store.engine(workspaceID,a.pageID) === a,"Renaming an account group preserves its login and live WebView")
        store.loginEnvironmentChangeConfirmation={_ in false}
        let before=store.session
        try expect(!store.movePageToGroup(a.pageID,in:workspaceID,groupID:beta.id) && store.session == before && store.engine(workspaceID,a.pageID) === a,"Cancelling a cross-account move preserves the original session and input")
        let profileCount=store.session.profiles.count
        try expect(!store.saveTabGroup(renamed,in:workspaceID,createIndependentProfile:true) && store.session.profiles.count == profileCount,"Cancelling group credential changes never leaves an orphan login profile")
        store.loginEnvironmentChangeConfirmation={_ in true}
        try expect(store.movePageToGroup(a.pageID,in:workspaceID,groupID:beta.id),"Cross-account moves require an accepted login-environment confirmation")
        let moved=store.engine(workspaceID,a.pageID)!
        try expect(moved !== a && moved.profileID == betaProfile && store.page(PageReference(workspaceID:workspaceID,pageID:a.pageID))?.url == url,"Accepted cross-account moves rebuild only the affected WebView using the destination credentials and saved URL")
        store.showTabGroup(beta.id,in:workspaceID)
        let idle=store.addPage(to:workspaceID,url:url)!,idleID=idle.pageID
        try await BrowserChecks.wait{!idle.webView.isLoading && idle.webView.url != nil}
        let shown=store.addPage(to:workspaceID,url:url)!
        try await BrowserChecks.wait{!shown.webView.isLoading}
        let start=ProcessInfo.processInfo.systemUptime
        try expect(store.discardIdleTabs(olderThan:1800,now:start) == 0 && store.engineIfLoaded(idleID) != nil,"Tabs shown recently keep their page in memory")
        let discarded=store.discardIdleTabs(olderThan:1800,now:start+1801)
        try expect(discarded>0 && store.engineIfLoaded(idleID) == nil && store.engineIfLoaded(shown.pageID) === shown && store.page(PageReference(workspaceID:workspaceID,pageID:idleID))?.url == url,"Idle background tabs release their page but stay in the strip with their URL, and the visible tab is untouched")
        let revived=store.engine(workspaceID,idleID)!
        try await BrowserChecks.wait{!revived.webView.isLoading && revived.webView.url?.query == "group-login=page"}
        try expect(revived !== idle,"Opening a rested tab loads it again from its saved URL")
        store.closePage(shown.pageID,in:workspaceID);store.closePage(idleID,in:workspaceID)
        let closing=store.addPage(to:workspaceID,url:"about:blank",load:false)!
        store.closePage(closing.pageID,in:workspaceID)
        var sharedBeta=store.workspace(workspaceID)!.resolvedTabGroups.first{$0.id == beta.id}!
        sharedBeta.profileID=nil
        try expect(store.saveTabGroup(sharedBeta,in:workspaceID) && !store.restoreClosedPage(closing.pageID),"Closed tabs never reopen under a group whose login environment has changed")
        let cookieAfterChange=try await b.webView.evaluateJavaScript("document.cookie") as? String
        try expect(cookieAfterChange?.contains("groupLogin=personal") == true,"Changing group credentials leaves the old profile cookie store intact")
        store.showTabGroup(alpha.id,in:workspaceID)
        store.saveWorkset(name:"Private group")
        let savedWorkset=store.worksets.last!.id
        var inherited=renamed;inherited.profileID=nil
        try expect(store.saveTabGroup(inherited,in:workspaceID) && !store.restoreWorkset(savedWorkset),"Worksets reject missing or changed account-group environments instead of using another login")
        try expect(store.engine(workspaceID,original,load:false)!.profileID == workspace.profileID,"Existing default-group pages continue using their original login environment")
        // Restore an independent group for persistence and backup checks.
        try expect(store.saveTabGroup(renamed,in:workspaceID),"An existing independent profile can be selected again")
        let encoded=try JSONEncoder().encode(store.session)
        let decoded=try JSONDecoder().decode(BrowserSession.self,from:encoded).validated()
        try expect(decoded.workspaces.first{$0.id == workspaceID}!.profileID(forGroup:alpha.id) == alphaProfile,"Independent group profile identifiers survive session serialization")
        let backup=try NotionLibrary.tabBackup(store:store,includePages:true)
        try expect(backup.session.workspaces.first{$0.id == workspaceID}!.profileID(forGroup:alpha.id) == alphaProfile,"Notion tab backups preserve group login-environment references")
        var invalid=decoded
        invalid.workspaces[0].tabGroups![0].profileID=UUID()
        try expect((try? invalid.validated()) == nil,"Unknown group profile references fail validation rather than falling back to another account")
        store.loginEnvironmentChangeConfirmation={_ in false}
        store.removeTabGroup(alpha.id,in:workspaceID)
        try expect(store.workspace(workspaceID)!.resolvedTabGroups.contains{$0.id == alpha.id},"Cancelling deletion of a private group preserves its tabs and login environment")
        store.loginEnvironmentChangeConfirmation={_ in true}
        store.removeTabGroup(alpha.id,in:workspaceID)
        try expect(!store.workspace(workspaceID)!.resolvedTabGroups.contains{$0.id == alpha.id},"Private groups can be removed after confirming the login-environment change")
        let lone=store.addWorkspace(name:"Last private tab",url:"about:blank")
        let loneGroup=BrowserTabGroup(name:"Only account")
        try expect(store.saveTabGroup(loneGroup,in:lone,createIndependentProfile:true),"A private group can be created in a fresh app tab")
        let last=store.workspace(lone)!.pages[0].id
        _=store.movePageToGroup(last,in:lone,groupID:loneGroup.id)
        let expected=store.workspace(lone)!.profileID(forGroup:loneGroup.id)
        store.closePage(last,in:lone)
        try expect(store.workspace(lone)!.profileID(for:store.workspace(lone)!.pages[0]) == expected,"Closing the last private tab keeps its replacement in the same login environment")
        let oldGroup=try JSONDecoder().decode(BrowserTabGroup.self,from:Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"Legacy\"}".utf8))
        try expect(oldGroup.profileID == nil,"Legacy groups without a profile field retain their original shared login behavior")
        store.shutdown()
        for profile in store.session.profiles {try? await WKWebsiteDataStore.remove(forIdentifier:profile.id)}
    }
}
