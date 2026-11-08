import AppKit
import WebKit
import SwiftUI
import WorkspaceCore

@MainActor final class BrowserEngine: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let workspaceID: UUID
    let pageID: UUID
    let profileID: UUID
    let webView: WKWebView
    weak var store: BrowserStore?
    @Published var address = ""
    @Published var title = ""
    @Published var loading = false
    @Published var progress: Double = 0
    @Published var canBack = false
    @Published var canForward = false
    @Published var failure: String?
    @Published var detectedNotionSpaceID: String?
    enum PreviewPhase {case none,loading,updated,failed}
    @Published private(set) var previewImage:NSImage?
    @Published private(set) var previewCapturedAt:Date?
    @Published private(set) var previewPhase:PreviewPhase = .none
    private var previewURL:String?
    private(set) var needsRestore=false
    private(set) var navigationStarts=0
    private var previewGeneration=0
    private var previewTask:Task<Void,Never>?
    private var capturePending=false
    private(set) var documentGeneration:UInt=0
    private var currentNavigation:WKNavigation?
    private var pendingActionNavigation:WKNavigation?
    private var detectionRequest:UUID?
    private var actionRunID:UUID?
    private var hasCommittedDocument=false
    private var mainGET:URL?
    private(set) var connectionRetryURL:URL?
    func acceptsDocumentResult(_ generation:UInt)->Bool {!disposed && documentGeneration == generation}
    func cancelNotionAction(clearPending:Bool=true) {
        if actionRunID != nil {
            actionRunID=nil
            webView.evaluateJavaScript("globalThis.__workspaceTabsCancelAction?.()",completionHandler:nil)
        }
        if clearPending,pendingNotionAction != nil {clearPendingNotionAction()}
    }
    private func invalidateDocument(cancelAction:Bool=true) {
        documentGeneration &+= 1;detectionRequest=nil;capturePending=false
        if cancelAction {cancelNotionAction(clearPending:false)}
        detectedNotionSpaceID=nil;detectedURL=nil
    }
    private func acceptsNavigation(_ navigation:WKNavigation?)->Bool {
        !disposed && (navigation == nil || currentNavigation == nil || navigation === currentNavigation)
    }
    func retryAfterConnectionReturns() {
        guard store?.networkOffline != true,!disposed,!hasCommittedDocument,!webView.isLoading,
              let url=connectionRetryURL else{return}
        connectionRetryURL=nil;failure=nil
        // Only a failed initial GET is retried. Never resubmit a form or repeat a creation command.
        currentNavigation=webView.load(URLRequest(url:url))
    }
    private var navigationStarted:Double?
    private var lastCapture=Date.distantPast
    private var lastAutomaticRecovery=Date.distantPast
    private static let contentReadyScript = #"""
    (()=>{
      if(document.readyState==='loading' || !document.body)return false;
      const root=document.querySelector('main,[role="main"],.notion-frame') || document.body;
      const text=(root.innerText||'').replace(/\s+/g,' ').trim();
      if(!text || /^(loading[.\s…]*|読み込み中[.\s…]*)$/i.test(text))return false;
      return root.getClientRects().length>0;
    })()
    """#
    func capturePreview(force:Bool=false) {
        guard store?.previewsEnabled(workspaceID) == true,store?.previewsMayCapture == true,!disposed,!capturePending,!webView.isLoading,!needsRestore,previewImage == nil,
              webView.window?.isVisible == true,webView.window?.isMiniaturized == false,!webView.isHidden,webView.bounds.width>100,webView.bounds.height>100,
              force || Date().timeIntervalSince(lastCapture)>30,
              let url=webView.url.map(BrowserAddress.savedURL) else{return}
        let generation=documentGeneration
        capturePending=true;lastCapture=Date()
        webView.evaluateJavaScript(Self.contentReadyScript) { [weak self] value,_ in
            guard let self,self.acceptsDocumentResult(generation) else{return}
            guard !self.disposed,value as? Bool == true,self.webView.url.map(BrowserAddress.savedURL) == url else {self.capturePending=false;return}
            let config=WKSnapshotConfiguration();config.snapshotWidth=640;config.afterScreenUpdates=false
            self.webView.takeSnapshot(with:config) { [weak self] image,_ in
                guard let self,self.acceptsDocumentResult(generation) else{return};self.capturePending=false
                guard !self.disposed,self.store?.previewsEnabled(self.workspaceID) == true,let image,self.webView.url.map(BrowserAddress.savedURL) == url else{return}
                self.store?.previewCache.save(image,profile:self.profileID,page:self.pageID,url:url)
            }
        }
    }
    func prepareForDisplay() {
        retryAfterConnectionReturns()
        guard store?.networkOffline != true,!disposed,needsRestore,!webView.isLoading,Date().timeIntervalSince(lastAutomaticRecovery)>30 else{return}
        lastAutomaticRecovery=Date();needsRestore=false;failure=nil
        if let url=webView.url?.absoluteString ?? store?.page(PageReference(workspaceID:workspaceID,pageID:pageID))?.url {
            restorePreview(url)
            previewPhase = .loading
            if webView.url != nil {webView.reload()}
            else if let target=BrowserAddress.url(url){webView.load(URLRequest(url:target))}
        }
    }
    private func restorePreview(_ url:String) {
        guard store?.previewsEnabled(workspaceID) == true else {dismissPreview();return}
        let saved=BrowserAddress.url(url).map(BrowserAddress.savedURL) ?? url
        previewURL=saved
        previewImage=store?.previewCache.image(profile:profileID,page:pageID,url:saved)
        previewCapturedAt=store?.previewCache.capturedAt(profile:profileID,page:pageID,url:saved)
        if previewImage != nil {previewPhase = .loading}
    }
    func dismissPreview(){previewImage=nil;if previewPhase != .updated {previewPhase = .none}}
    func retryPreview(){needsRestore=false;failure=nil;previewPhase = .loading;webView.reload()}
    private func settlePreview() {
        guard previewPhase == .loading else{return}
        previewTask?.cancel()
        let generation=previewGeneration
        previewTask=Task { [weak self] in
            for _ in 0..<60 {
                guard !Task.isCancelled,let self,!self.disposed,self.previewGeneration == generation else{return}
                let ready=try? await self.webView.evaluateJavaScript(Self.contentReadyScript)
                guard !Task.isCancelled,!self.disposed,self.previewGeneration == generation else{return}
                if ready as? Bool == true {
                    self.previewImage=nil;self.previewPhase = .updated
                    DispatchQueue.main.asyncAfter(deadline:.now()+2) { [weak self] in
                        guard let self,!self.disposed,self.previewGeneration == generation else{return}
                        self.previewPhase = .none;self.capturePreview(force:true)
                    }
                    return
                }
                try? await Task.sleep(for:.milliseconds(200))
            }
            // Unknown SPA layout: reveal the actual page, never claim fresh data.
            if let self,!self.disposed,self.previewGeneration == generation {self.dismissPreview()}
        }
    }
    var workspaceIdentityLabel:String? {
        guard let workspace=store?.workspace(workspaceID),let expected=NotionWorkspace.normalizedID(workspace.notionSpaceID),
              let url=webView.url,NotionWorkspace.environment(url) != nil else{return nil}
        if workspaceMismatch {return "Workspace IDが設定と一致しません"}
        return detectedURL == url.absoluteString && detectedNotionSpaceID == expected ? "Workspace IDは設定と一致しています" : "Workspace IDを確認できていません"
    }
    var workspaceMismatch:Bool {
        guard let workspace=store?.workspace(workspaceID),let expected=NotionWorkspace.normalizedID(workspace.notionSpaceID),
              let url=webView.url,NotionWorkspace.environment(url) != nil else{return false}
        if let home=BrowserAddress.url(workspace.homeURL),NotionWorkspace.environment(home) != NotionWorkspace.environment(url) {return true}
        return detectedURL == url.absoluteString && detectedNotionSpaceID.map{$0 != expected} == true
    }
    func openMatchingWorkspace() {
        guard let store,let url=webView.url,let id=detectedNotionSpaceID,
              let destination=NotionWorkspace.target(url:url,detectedID:id,workspaces:store.session.workspaces) else {
            store?.notify("一致する移動先がありません。アプリタブのWorkspace IDと自動振り分け設定を確認してください",isError:true);return
        }
        _=store.openFavorite(FavoriteLink(title:title,url:url.absoluteString,workspaceID:destination))
    }
    private var detectedURL: String?
    private(set) var pendingNotionAction:String?
    private var notionReadyToken:String?
    private func resetUserScripts() {
        let controller=webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source:styleScript,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        if let token=notionReadyToken {
            controller.addUserScript(WKUserScript(source:"window.webkit.messageHandlers.workspaceNotionReady.postMessage('\(token)')",injectionTime:.atDocumentEnd,forMainFrameOnly:true,in:.defaultClient))
        }
    }
    private func clearPendingNotionAction() {
        pendingActionNavigation=nil
        pendingNotionAction=nil;notionReadyToken=nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName:"workspaceNotionReady",contentWorld:.defaultClient)
        resetUserScripts()
    }
    fileprivate func notionDocumentReady(_ message:WKScriptMessage) {
        guard message.frameInfo.isMainFrame,message.body as? String == notionReadyToken else{return}
        startPendingNotionAction()
    }
    private func startPendingNotionAction() {
        guard !disposed,let action=pendingNotionAction else{return}
        // Remove the hook before clicking anything, so subsequent navigations cannot repeat creation.
        clearPendingNotionAction()
        runNotionAction(action,waitForReady:true)
    }
    func runNotionAction(_ action:String,waitForReady:Bool=false) {
        guard !disposed else{return}
        cancelNotionAction(clearPending:false)
        let token=UUID(),generation=documentGeneration,url=webView.url
        actionRunID=token
        webView.callAsyncJavaScript(NotionActions.script,arguments:["action":action,"waitForReady":waitForReady,"expectedSpaceID":NotionWorkspace.normalizedID(store?.workspace(workspaceID)?.notionSpaceID) ?? "","expectedEnvironment":store?.workspace(workspaceID).flatMap{BrowserAddress.url($0.homeURL)}.flatMap{NotionWorkspace.environment($0)} ?? ""],in:nil,in:.page) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,self.actionRunID == token else{return}
                self.actionRunID=nil
                guard self.acceptsDocumentResult(generation),self.webView.url == url else{return}
                switch result {
                case .success(let value):
                    let response=value as? [String:Any]
                    self.store?.notify(response?["message"] as? String ?? "操作対象を見つけられませんでした",isError:response?["ok"] as? Bool != true)
                case .failure:
                    self.store?.notify("Notionの操作を完了できませんでした。タブを確認してください",isError:true)
                }
            }
        }
    }
    private var faviconTask:Task<Void,Never>?
    private func discoverFavicon() {
        guard !disposed,let url=webView.url,FaviconCache.fallback(url.absoluteString) != nil else{return}
        let generation=documentGeneration
        webView.evaluateJavaScript("""
        (()=>{const links=[...document.querySelectorAll('link[rel]')].filter(e=>e.rel.toLowerCase().split(/\\s+/).includes('icon') && (!e.media || matchMedia(e.media).matches));return links.at(-1)?.href || new URL('/favicon.ico',location.href).href})()
        """) { [weak self] result,_ in
            guard let self,self.acceptsDocumentResult(generation),self.webView.url == url,let source=result as? String,let cache=self.store?.faviconCache else{return}
            let profile=self.profileID,pageURL=BrowserAddress.savedURL(url)
            self.faviconTask=Task {await cache.load(profile:profile,pageURL:pageURL,declared:source)}
        }
    }
    private var firstLoadFinished=false
    private var mayRoute=false
    func detectNotionWorkspace(completion: ((String?) -> Void)? = nil) {
        guard !disposed,detectionRequest == nil, let url=webView.url,NotionWorkspace.environment(url) != nil else {completion?(nil);return}
        let request=UUID(),generation=documentGeneration
        detectionRequest=request
        webView.evaluateJavaScript(NotionWorkspace.detectionScript) { [weak self] result,_ in
            guard let self,self.acceptsDocumentResult(generation),self.detectionRequest == request,self.webView.url == url else {completion?(nil);return}
            self.detectionRequest=nil
            guard let result=result as? [String:String],result["url"] == self.webView.url?.absoluteString,
                  let id=NotionWorkspace.normalizedID(result["spaceID"]) else {if self.detectedNotionSpaceID != nil {self.detectedNotionSpaceID=nil};self.detectedURL=nil;completion?(nil);return}
            if self.detectedNotionSpaceID != id {self.detectedNotionSpaceID=id};self.detectedURL=result["url"];completion?(id)
            if self.mayRoute, let url=self.webView.url {
                self.mayRoute=false
                _ = self.store?.routeNotion(url,detectedID:id,from:PageReference(workspaceID:self.workspaceID,pageID:self.pageID))
            }
        }
    }
    private var observations: [NSKeyValueObservation] = []
    private var refreshPending=false
    private var disposed=false
    private var styleScript=""
    private(set) var refreshPasses=0
    func dispose() {
        guard !disposed else{return}
        cancelNotionAction();invalidateDocument();connectionRetryURL=nil
        disposed=true;faviconTask?.cancel();faviconTask=nil;previewTask?.cancel();previewTask=nil;previewImage=nil;clearPendingNotionAction()
        observations.forEach{$0.invalidate()};observations.removeAll()
        webView.stopLoading();webView.navigationDelegate=nil;webView.uiDelegate=nil
        webView.removeFromSuperview();store=nil
    }
    init(store: BrowserStore, workspace: BrowserWorkspace, page: BrowserPage, configuration: WKWebViewConfiguration? = nil) {
        self.store = store; workspaceID = workspace.id; pageID = page.id; profileID = workspace.profileID
        let config = configuration ?? WKWebViewConfiguration()
        config.websiteDataStore = store.dataStore(workspace.profileID)
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController = WKUserContentController()
        config.userContentController.addUserScript(WKUserScript(source: Self.style(workspace), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = BrowserWebView(frame: .zero, configuration: config)
        super.init()
        address = page.url; title = page.title
        styleScript=Self.style(workspace)
        restorePreview(page.url)
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
                        webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
                        webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
                        webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
                        webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
                        webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }]
    }
    static func style(_ workspace: BrowserWorkspace) -> String {
        BrowserStyle.script(hex: Palette.hex(Palette.color(workspace.color)), enabled: workspace.cssEnabled, strength: workspace.cssStrength)
    }
    func refresh() {
        guard !disposed,!refreshPending else{return}
        refreshPending=true
        DispatchQueue.main.async { [weak self] in
            guard let self,!self.disposed else { return }
            self.refreshPending=false;self.refreshPasses += 1
            if let url = self.webView.url {
                if self.address != url.absoluteString {
                    // A SPA route change can be a step of the requested Notion action.
                    self.invalidateDocument(cancelAction:false)
                    self.detectedNotionSpaceID=nil;self.detectedURL=nil
                    if self.firstLoadFinished {self.mayRoute=true}
                }
                if self.address != url.absoluteString {self.address = url.absoluteString}
            }
            let title=self.webView.title ?? ""
            if self.title != title {self.title=title;if !self.webView.isLoading {self.discoverFavicon()}}
            if self.loading != self.webView.isLoading {self.loading=self.webView.isLoading}
            if self.progress != self.webView.estimatedProgress {self.progress=self.webView.estimatedProgress}
            if self.canBack != self.webView.canGoBack {self.canBack=self.webView.canGoBack}
            if self.canForward != self.webView.canGoForward {self.canForward=self.webView.canGoForward}
            self.store?.updatePage(self.workspaceID, self.pageID, url: self.webView.url, title: self.webView.title)
        }
    }
    func navigate(_ text: String,notionAction:String? = nil) {
        invalidateDocument();connectionRetryURL=nil
        previewTask?.cancel();previewGeneration += 1;dismissPreview();previewPhase = .none;needsRestore=false
        clearPendingNotionAction()
        guard let url = BrowserAddress.url(text) else { failure = "http / httpsのURLを入力してください。"; return }
        if store?.routeNotion(url,from:PageReference(workspaceID:workspaceID,pageID:pageID)) == true {return}
        if let action=notionAction,NotionActions.creationIDs.contains(action) {
            pendingNotionAction=action;notionReadyToken=UUID().uuidString
            webView.configuration.userContentController.add(NotionReadyHandler(self),contentWorld:.defaultClient,name:"workspaceNotionReady")
            resetUserScripts()
        }
        failure = nil;currentNavigation=webView.load(URLRequest(url: url))
        if pendingNotionAction != nil {pendingActionNavigation=currentNavigation}
    }
    func updateStyle(_ workspace: BrowserWorkspace) {
        let script = Self.style(workspace)
        guard script != styleScript else{return}
        styleScript=script
        resetUserScripts()
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
    func webView(_ webView:WKWebView,didStartProvisionalNavigation navigation:WKNavigation!) {
        guard !disposed else{return}
        if pendingNotionAction != nil,navigation !== pendingActionNavigation {clearPendingNotionAction()}
        invalidateDocument();currentNavigation=navigation;connectionRetryURL=nil
        navigationStarted=ProcessInfo.processInfo.systemUptime
        navigationStarts += 1;previewGeneration += 1;previewTask?.cancel()
        if previewImage != nil {previewPhase = .loading}
    }
    func webView(_ webView:WKWebView,didCommit navigation:WKNavigation!) {
        guard acceptsNavigation(navigation) else{return}
        hasCommittedDocument=true;connectionRetryURL=nil
        if previewImage != nil,webView.url.map(BrowserAddress.savedURL) != previewURL {previewImage=nil}
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard acceptsNavigation(navigation) else{return}
        let generation=documentGeneration
        if let start=navigationStarted {store?.recordTiming("ページ読み込み",since:start);navigationStarted=nil}
        failure = nil; refresh()
        DispatchQueue.main.async { [weak self] in guard let self,self.acceptsDocumentResult(generation) else{return};self.firstLoadFinished=true;self.detectNotionWorkspace() }
        if let workspace = store?.workspace(workspaceID) { updateStyle(workspace) }
        startPendingNotionAction()
        discoverFavicon()
        settlePreview()
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self] in guard let self,self.acceptsDocumentResult(generation) else{return};self.capturePreview();self.discoverFavicon() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if acceptsNavigation(navigation) {failed(error)} }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if acceptsNavigation(navigation) {failed(error)} }
    private func failed(_ error: Error) {
        guard !disposed,(error as NSError).code != NSURLErrorCancelled else { return }
        let networkError=error as NSError
        if !hasCommittedDocument,networkError.domain == NSURLErrorDomain,
           [NSURLErrorNotConnectedToInternet,NSURLErrorNetworkConnectionLost,NSURLErrorCannotFindHost,NSURLErrorCannotConnectToHost,NSURLErrorDNSLookupFailed].contains(networkError.code),
           let url=networkError.userInfo[NSURLErrorFailingURLErrorKey] as? URL,url == mainGET {connectionRetryURL=url}
        cancelNotionAction(clearPending:false)
        if pendingNotionAction != nil {clearPendingNotionAction();store?.notify("新しいタブを読み込めなかったためNotionの操作を中止しました",isError:true)}
        previewTask?.cancel();previewGeneration += 1
        previewPhase = previewImage != nil ? .failed : .none
        failure = error.localizedDescription; refresh()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !disposed else{return}
        cancelNotionAction();invalidateDocument()
        previewTask?.cancel();previewGeneration += 1;needsRestore=true
        if let url=webView.url?.absoluteString {restorePreview(url)}
        if previewImage != nil {previewPhase = .failed}
        failure = "ページの処理が終了しました。再読み込みしてください。"
        if store?.visiblePageIDs.contains(pageID) == true {prepareForDisplay()}
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !disposed,let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == true {
            mainGET=navigationAction.request.httpMethod == "GET" && ["http","https"].contains(url.scheme ?? "") ? url:nil
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           navigationAction.targetFrame != nil,
           navigationAction.request.httpMethod == "GET",
           ["http","https"].contains(url.scheme?.lowercased() ?? "") {
            // target=_blank is handled by createWebView; intercept normal links only once.
            decisionHandler(.cancel)
            _ = store?.addPage(to:workspaceID,url:url.absoluteString,groupID:store?.workspace(workspaceID).flatMap{w in w.pages.first(where:{$0.id == pageID}).map{w.groupID(for:$0)}})
            return
        }
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.request.httpMethod == "GET",
           store?.routeNotion(url,from:PageReference(workspaceID:workspaceID,pageID:pageID)) == true {decisionHandler(.cancel);return}
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http","https","about","blob","data"].contains(scheme) { decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow); return }
        decisionHandler(.cancel)
        let alert = NSAlert(); alert.messageText = "外部アプリで開きますか？"; alert.informativeText = "\(scheme) リンクを対応するアプリへ渡します。"
        alert.addButton(withTitle: "キャンセル"); alert.addButton(withTitle: "開く")
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Keep the opener's exact persistent data store, including across app-tab switches.
        guard let store, navigationAction.targetFrame == nil else { return nil }
        let child = store.addPage(to: workspaceID, url: "about:blank", configuration: configuration,groupID:store.workspace(workspaceID).flatMap{w in w.pages.first(where:{$0.id == pageID}).map{w.groupID(for:$0)}})
        if store.split?.pageID == pageID, let child {
            store.setSplit(PageReference(workspaceID: workspaceID, pageID: child.pageID))
        }
        return child?.webView
    }
    func webViewDidClose(_ webView: WKWebView) { store?.closePage(pageID, in: workspaceID) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = frame.securityOrigin.host; alert.informativeText = message; alert.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = frame.securityOrigin.host; alert.informativeText = message
        alert.addButton(withTitle: "キャンセル"); alert.addButton(withTitle: "OK"); completionHandler(alert.runModal() == .alertSecondButtonReturn)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = frame.securityOrigin.host; alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? ""); field.frame = NSRect(x:0,y:0,width:300,height:24); alert.accessoryView = field
        alert.addButton(withTitle: "キャンセル"); alert.addButton(withTitle: "OK"); completionHandler(alert.runModal() == .alertSecondButtonReturn ? field.stringValue : nil)
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = suggestedFilename
        completionHandler(panel.runModal() == .OK ? panel.url : nil)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { failure = "ダウンロード失敗：" + error.localizedDescription }
}

struct WebContent: NSViewRepresentable {
    let webView: WKWebView
    let store: BrowserStore
    let workspaceID: UUID
    let detached: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ container: NSView, context: Context) {
        guard store.detachedWorkspaceIDs.contains(workspaceID) == detached else {
            if webView.superview === container {webView.removeFromSuperview()}
            return
        }
        guard webView.superview !== container else { return }
        for child in container.subviews { child.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        store.recordDisplay(pageID:store.pageID(for:webView))
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

/// WebKit runs unhandled Escape as an AppKit cancelOperation command after DOM
/// dispatch. Stop that command at the web view, before NSResponder's default
/// behavior can leave native fullscreen without calling NSWindow.toggleFullScreen.
@MainActor final class BrowserWebView: WKWebView {
    override func cancelOperation(_ sender:Any?) {
        (window as? BrowserWindow)?.trace("webview-cancel-consumed")
    }
}

@MainActor private final class NotionReadyHandler:NSObject,WKScriptMessageHandler {
    weak var engine:BrowserEngine?
    init(_ engine:BrowserEngine){self.engine=engine}
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage){engine?.notionDocumentReady(message)}
}
