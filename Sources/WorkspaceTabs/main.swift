import AppKit
import SwiftUI
import WorkspaceCore

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    private var uiCheckDirectory:String? {ProcessInfo.processInfo.environment["WORKSPACE_TABS_UI_CHECK_DIRECTORY"]}
    var pendingLauncherURLs:[URL]=[]
    var store:BrowserStore!
    var window:NSWindow!
    private let hotkeys=Hotkeys()
    private let sequences=ShortcutSequenceMonitor()
    private var clickMonitor:Any?
    private var shortcutObservers:[NSObjectProtocol]=[]
    func applicationDidFinishLaunching(_ notification:Notification){
        store=BrowserStore(directory:uiCheckDirectory.map{URL(fileURLWithPath:$0)})
        // Deterministic, isolated visual QA of the initial loading view; never used for normal sessions.
        if uiCheckDirectory != nil,ProcessInfo.processInfo.environment["WORKSPACE_TABS_UI_CHECK_PAUSE_LOADING"] == "1",
           let workspace=store.selected,let page=store.selectedPage {
            _=store.engine(workspace.id,page.id,load:false)
        }
        window=BrowserWindow(contentRect:NSRect(x:100,y:100,width:1280,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Workspace Tabs";window.isReleasedWhenClosed=false;window.minSize=NSSize(width:800,height:520)
        window.collectionBehavior=[.fullScreenPrimary];window.delegate=self
        window.contentView=NSHostingView(rootView:BrowserRoot(store:store));store.window=window
        if let saved=store.session.windowFrame?.cgRect,let screen=NSScreen.screens.max(by:{a,b in let x=a.frame.intersection(saved),y=b.frame.intersection(saved);return (x.isNull ? 0:x.width*x.height)<(y.isNull ? 0:y.width*y.height)}) {
            window.setFrame(WorkspaceRules.fit(saved,inside:screen.visibleFrame,barHeight:0,minimum:CGSize(width:800,height:520)),display:false)
        }else{window.center()}
        clickMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.leftMouseDragged,.scrollWheel,.keyDown,.flagsChanged]) { [weak self] event in
            guard let self else{return event}
            self.store.handleWorkspaceHintEvent(event)
            if self.store.handleRecentEvent(event) {return nil}
            if event.type == .leftMouseDown || event.type == .rightMouseDown {self.store.trackClick(event)}
            return event
        }
        store.startRuntimeMonitoring()
        store.exportLauncherIndex()
        createMenu();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        hotkeys.action={[weak self] code in
            guard let self else{return}
            if code==3 {self.show();self.store.searchForSplit=false;self.store.searchPresented=true}
            else if (11...19).contains(code),self.store.session.workspaces.indices.contains(Int(code-11)){self.show();self.store.selectWorkspace(self.store.session.workspaces[Int(code-11)].id)}
        }
        shortcutObservers.append(NotificationCenter.default.addObserver(forName:ShortcutPreferences.changed,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated {self?.refreshShortcuts()} })
        shortcutObservers.append(NotificationCenter.default.addObserver(forName:ShortcutPreferences.recording,object:nil,queue:.main){[weak self] note in MainActor.assumeIsolated {self?.store.workspaceHintsSuspended=note.object as? Bool == true;self?.store.resetWorkspaceHints();if note.object as? Bool == true {self?.hotkeys.unregister()} else {self?.refreshShortcuts()}} })
        (NSApp as? BrowserApplication)?.escapeAction={[weak self] in self?.sequences.resetInput();self?.store.notionCreationMenu?.dismiss()}
        sequences.canHandleLocal={
            guard let key=NSApp.keyWindow as? BrowserWindow else{return false}
            return key.attachedSheet == nil
        }
        sequences.action={[weak self] action in self?.performShortcut(action)};sequences.start()
        if uiCheckDirectory == nil {store.importLinkViewerOnce();store.notion.start()}
        let failures=uiCheckDirectory == nil ? hotkeys.register():[];if !failures.isEmpty{store.error=failures.joined(separator:"\n")}
        if store.firstLaunch,(uiCheckDirectory == nil || ProcessInfo.processInfo.environment["WORKSPACE_TABS_UI_CHECK_FIRST_LAUNCH"] == "1") {DispatchQueue.main.async { [weak self] in self?.store.onboardingPresented=true}}
        let pending=pendingLauncherURLs;pendingLauncherURLs=[];pending.forEach(handleLauncherURL)
    }
    func createMenu(){
        let menu=NSMenu(),appItem=NSMenuItem(),appMenu=NSMenu()
        appMenu.addItem(withTitle:"Workspace Tabsについて",action:#selector(about),keyEquivalent:"").target=self
        appMenu.addItem(withTitle:"設定…",action:#selector(settings),keyEquivalent:",").target=self
        appMenu.addItem(.separator());appMenu.addItem(withTitle:"Workspace Tabsを隠す",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(withTitle:"Workspace Tabsを終了…",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu=appMenu;menu.addItem(appItem)
        let fileItem=NSMenuItem();fileItem.title="ファイル";let file=NSMenu(title:"ファイル")
        for (title,action,key) in [("新しいブラウザタブ",#selector(newTab),"t"),("ブラウザタブを閉じる",#selector(closeTab),"w"),("URLを入力",#selector(location),"l"),("再読み込み",#selector(reload),"r")] {file.addItem(withTitle:title,action:action,keyEquivalent:key).target=self}
        let reopen=file.addItem(withTitle:"閉じたタブを戻す",action:#selector(reopenTab),keyEquivalent:"t");reopen.keyEquivalentModifierMask=[.command,.shift];reopen.target=self
        let favorites=file.addItem(withTitle:"お気に入りランチャー",action:#selector(favorites),keyEquivalent:"l");favorites.keyEquivalentModifierMask=[.command,.shift];favorites.target=self
        let copy=file.addItem(withTitle:"現在のURLをコピー",action:#selector(copyURL),keyEquivalent:"c");copy.keyEquivalentModifierMask=[.command,.shift];copy.target=self
        fileItem.submenu=file;menu.addItem(fileItem)
        let editItem=NSMenuItem();editItem.title="編集";let edit=NSMenu(title:"編集")
        for (title,action,key) in [("取り消す","undo:","z"),("カット","cut:","x"),("コピー","copy:","c"),("ペースト","paste:","v"),("すべて選択","selectAll:","a")] {edit.addItem(withTitle:title,action:Selector(action),keyEquivalent:key)}
        editItem.submenu=edit;menu.addItem(editItem)
        let windowItem=NSMenuItem();windowItem.title="ウインドウ";let windows=NSMenu(title:"ウインドウ")
        windows.addItem(withTitle:"ブラウザを表示",action:#selector(show),keyEquivalent:"0").target=self
        let full=windows.addItem(withTitle:"フルスクリーンを切り替える",action:#selector(fullscreen),keyEquivalent:"f");full.keyEquivalentModifierMask=[.control,.command];full.target=self
        windows.addItem(.separator())
        windows.addItem(withTitle:"前のアプリタブ",action:#selector(previousWorkspace),keyEquivalent:"").target=self
        windows.addItem(withTitle:"次のアプリタブ",action:#selector(nextWorkspace),keyEquivalent:"").target=self
        windowItem.submenu=windows;menu.addItem(windowItem)
        let commandItem=NSMenuItem();commandItem.title="操作";let commands=NSMenu(title:"操作")
        for action in ShortcutPreferences.actions where BrowserCommands.ids.contains(action.id) {
            let item=commands.addItem(withTitle:action.title,action:#selector(extraCommand(_:)),keyEquivalent:"");item.target=self;item.representedObject=action.id
        }
        let allTabs=commands.addItem(withTitle:"すべてのタブを検索",action:#selector(allTabs),keyEquivalent:"");allTabs.target=self
        commandItem.submenu=commands;menu.addItem(commandItem);NSApp.mainMenu=menu;applyShortcutMenu(menu)
    }
    func applyShortcutMenu(_ menu:NSMenu){
        for item in menu.items {
            if let action=ShortcutPreferences.actions.first(where:{$0.globalID == nil && $0.title == item.title}) {let binding=ShortcutPreferences.shared.binding(action);item.keyEquivalent=binding.sequence == nil ? binding.key:"";item.keyEquivalentModifierMask=binding.flags}
            if let submenu=item.submenu {applyShortcutMenu(submenu)}
        }
    }
    func performShortcut(_ action:ShortcutAction){
        let started=ProcessInfo.processInfo.systemUptime
        if let event=NSApp.currentEvent,[NSEvent.EventType.keyDown,.flagsChanged].contains(event.type),started-event.timestamp>=0,started-event.timestamp<5 {
            store.timings.add("キーイベントから受付",milliseconds:(started-event.timestamp)*1000)
        }
        defer {store.recordTiming("ショートカット処理: "+action.id,since:started)}
        if let code=action.globalID {hotkeys.action?(code);return}
        // Do not invoke browser commands while a settings/editor sheet owns focus.
        guard window.attachedSheet == nil else{return}
        switch action.id {
        case "previousWorkspace":previousWorkspace();case "nextWorkspace":nextWorkspace()
        case "new":newTab();case "close":closeTab();case "reopen":reopenTab();case "location":location()
        case "reload":reload();case "favorites":favorites();case "copyURL":copyURL();case "settings":settings()
        case "show":show();case "fullscreen":fullscreen();case "quit":NSApp.terminate(nil);default:store.runCommand(action.id)
        }
    }
    func refreshShortcuts(){
        store.resetWorkspaceHints()
        if let menu=NSApp.mainMenu {applyShortcutMenu(menu)}
        let failures=uiCheckDirectory == nil ? hotkeys.register():[];if !failures.isEmpty {store.error=failures.joined(separator:"\n")}
    }
    @objc func extraCommand(_ sender:NSMenuItem) {guard window.attachedSheet == nil,let id=sender.representedObject as? String else{return};store.runCommand(id)}
    @objc func allTabs(){store.capturePanelFocus();show();store.searchForSplit=false;store.searchPresented=true}
    @objc func previousWorkspace(){store.cycleWorkspace(-1)}
    @objc func nextWorkspace(){store.cycleWorkspace(1)}
    @objc func show(){window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func favorites(){store.capturePanelFocus();show();store.favoritesPresented=true}
    @objc func settings(){store.capturePanelFocus();show();store.showSettings=true}
    @objc func about(){NSApp.orderFrontStandardAboutPanel(nil)}
    @objc func fullscreen(){(NSApp.keyWindow ?? window).toggleFullScreen(nil)}
    @objc func copyURL(){store.copyPageURL()}
    @objc func newTab(){
        store.newTabRequest=store.commandPage
    }
    @objc func closeTab(){if let ref=store.commandPage{store.closePage(ref.pageID,in:ref.workspaceID)}}
    @objc func reopenTab(){store.reopenPage()}
    @objc func location(){store.addressFocus=UUID()}
    @objc func reload(){if let ref=store.commandPage{store.engine(ref.workspaceID,ref.pageID)?.webView.reload()}}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{show();return true}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
        let alert=NSAlert();alert.messageText="Workspace Tabsを終了しますか？";alert.informativeText="タブとログイン環境は保存されます。ページ内の未送信の入力内容は保存されません。";alert.addButton(withTitle:"キャンセル");alert.addButton(withTitle:"終了")
        guard alert.runModal() == .alertSecondButtonReturn else {return .terminateCancel}
        guard store.saveBeforeExit() else {
            let failure=NSAlert();failure.messageText="設定を保存できないため終了を中止しました";failure.informativeText=store.error ?? "";failure.runModal();return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification:Notification){store.shutdown()}
    func windowDidEnterFullScreen(_ notification:Notification){(notification.object as? BrowserWindow)?.trace("entered-fullscreen")}
    func windowDidExitFullScreen(_ notification:Notification){(notification.object as? BrowserWindow)?.trace("exited-fullscreen")}
    func applicationDidResignActive(_ notification:Notification){store.resetWorkspaceHints()}
    func windowDidResignKey(_ notification:Notification){store.resetWorkspaceHints()}
    func windowDidBecomeKey(_ notification:Notification){store.focusedPage=nil}
    func windowWillClose(_ notification:Notification){store.resetWorkspaceHints();store.saveBeforeExit()}
    func windowDidResize(_ notification:Notification){store.snapshot();store.changed()}
    func windowDidMove(_ notification:Notification){store.snapshot();store.changed()}
}
MainActor.assumeIsolated {
    let app=BrowserApplication.shared
    precondition(app is BrowserApplication,"Custom application event routing is required")
    if CommandLine.arguments.contains("--notion-connection-check") {
        app.setActivationPolicy(.accessory)
        Task {
            do {
                let state=try JSONDecoder().decode(NotionLibraryState.self,from:Data(contentsOf:Storage.root.appendingPathComponent("notion-library.json")))
                let client=NotionClient()
                guard !state.sources.isEmpty else{throw LVError("接続先がありません")}
                for source in state.sources {
                    guard let secret=NotionVault.read(source.tokenId,interactive:false) else{throw LVError("PATにアクセスできません")}
                    let count=try await client.pages(token:secret,id:source.id).count
                    print("PASS Notion database read: \(count) rows")
                }
                print("Local default preserved:",!state.enabled);exit(0)
            }catch{print("FAIL",error.localizedDescription);exit(1)}
        };app.run()
    } else if CommandLine.arguments.contains("--notion-checks") {
        Task { do {try await NotionSetupChecks.run();try await NotionCloudChecks.run();exit(0)}catch{print("FAIL",error);exit(1)} };app.run()
    } else if CommandLine.arguments.contains("--startup-checks") {
        app.setActivationPolicy(.accessory)
        Task {let result=await StartupChecks.run();exit(result)}
        app.run()
    } else if CommandLine.arguments.contains("--browser-checks") {
        app.setActivationPolicy(.accessory)
        Task { let result = await BrowserChecks.run(); exit(result) }
        app.run()
    } else {
        let delegate=AppDelegate();app.delegate=delegate;app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate){app.run()}
    }
}
