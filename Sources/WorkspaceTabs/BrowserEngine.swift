import AppKit
import WebKit
import SwiftUI
import WorkspaceCore

@MainActor final class BrowserEngine: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let workspaceID: UUID
    let pageID: UUID
    let profileID: UUID
    let webView: WKWebView
    let notionAccount=NotionAccountMonitor()
    weak var store: BrowserStore?
    @Published var address = ""
    @Published var title = ""
    @Published var loading = false
    @Published var progress: Double = 0
    @Published var canBack = false
    @Published var canForward = false
    @Published var failure: String?
    @Published private(set) var lastHTTPStatus:Int?
    @Published var detectedNotionSpaceID: String?
    enum LoadingState:Equatable {case none, loading, failed}
    @Published private(set) var loadingState:LoadingState = .none
    @Published private(set) var nativeLoadingPlaceholderVisible=false
    private(set) var needsRestore=false
    private(set) var navigationStarts=0
    private var loadingGeneration=0
    private var loadingTask:Task<Void,Never>?
    private(set) var documentGeneration:UInt=0
    private var expectingDownloadInterruption=false
    private var downloadOpener:PageReference?
    private var currentNavigation:WKNavigation?
    private var pendingActionNavigation:WKNavigation?
    private var detectionRequest:UUID?
    private var actionRunID:UUID?
    private var hasCommittedDocument=false
    private var mainGET:URL?
    private(set) var connectionRetryURL:URL?
    private(set) var failedURL:URL?
    func acceptsDocumentResult(_ generation:UInt)->Bool {!disposed && documentGeneration == generation}
    func cancelNotionAction(clearPending:Bool=true) {
        if actionRunID != nil {
            actionRunID=nil
            webView.evaluateJavaScript("globalThis.__workspaceTabsCancelAction?.()",completionHandler:nil)
        }
        if clearPending,pendingNotionAction != nil {clearPendingNotionAction()}
    }
    private func invalidateDocument(cancelAction:Bool=true) {
        notionAccount.invalidate()
        documentGeneration &+= 1;detectionRequest=nil
        if cancelAction {cancelNotionAction(clearPending:false)}
        detectedNotionSpaceID=nil;detectedURL=nil
    }
    private func acceptsNavigation(_ navigation:WKNavigation?)->Bool {
        !disposed && (navigation == nil || currentNavigation == nil || navigation === currentNavigation)
    }
    func retryAfterConnectionReturns() {
        guard store?.isPageSuspended(pageID) != true,store?.networkOffline != true,!disposed,!hasCommittedDocument,!webView.isLoading,
              let url=connectionRetryURL else{return}
        connectionRetryURL=nil;failure=nil
        // Only a failed initial GET is retried. Never resubmit a form or repeat a creation command.
        currentNavigation=webView.load(URLRequest(url:url))
    }
    private var navigationStarted:Double?
    private var lastAutomaticRecovery=Date.distantPast
    private static let contentReadyScript = #"""
    (()=>{
      const skeleton=document.getElementById('skeleton');
      const style=skeleton && getComputedStyle(skeleton);
      const native=!!(skeleton && skeleton.getAttribute('role')==='progressbar' && skeleton.getClientRects().length && style.display!=='none' && style.visibility!=='hidden' && Number(style.opacity)>0);
      if(document.readyState==='loading' || !document.body)return {ready:false,native};
      const main=document.querySelector('main,[role="main"],.notion-frame');
      if(native && !main)return {ready:false,native:true};
      const root=main || document.body;
      const text=(root.innerText||'').replace(/\s+/g,' ').trim();
      const ready=!!text && !/^(loading[.\s…]*|読み込み中[.\s…]*)$/i.test(text) && root.getClientRects().length>0;
      return {ready,native:native && !ready};
    })()
    """#
    private func beginLoadingPlaceholder() {
        loadingTask?.cancel();loadingTask=nil;loadingGeneration += 1
        nativeLoadingPlaceholderVisible=false;loadingState = .loading
    }
    private func clearLoadingPlaceholder() {
        loadingTask?.cancel();loadingTask=nil;loadingGeneration += 1
        nativeLoadingPlaceholderVisible=false;loadingState = .none
    }
    func prepareForDisplay() {
        guard store?.isPageSuspended(pageID) != true else{return}
        notionAccount.refresh(in:webView)
        retryAfterConnectionReturns()
        guard store?.networkOffline != true,!disposed,needsRestore,!webView.isLoading,Date().timeIntervalSince(lastAutomaticRecovery)>30 else{return}
        lastAutomaticRecovery=Date();needsRestore=false;failure=nil
        if let url=webView.url?.absoluteString ?? store?.page(PageReference(workspaceID:workspaceID,pageID:pageID))?.url {
            beginLoadingPlaceholder()
            if webView.url != nil {webView.reload()}
            else if let target=BrowserAddress.url(url){webView.load(URLRequest(url:target))}
        }
    }
    func retryLoading() {
        needsRestore=false;failure=nil
        if let target=failedURL {navigate(target.absoluteString)}
        else if webView.url != nil {beginLoadingPlaceholder();webView.reload()}
        else {navigate(address)}
    }
    func stopLoading() {webView.stopLoading();clearLoadingPlaceholder()}
    func resumeStoredPage(_ text:String) {
        // Restoration preserves the saved login environment; link rules only
        // apply to explicit link navigation, not restoring an existing tab.
        guard !disposed,webView.url == nil,!webView.isLoading,let url=BrowserAddress.url(text) else{return}
        failure=nil;needsRestore=false;beginLoadingPlaceholder()
        currentNavigation=webView.load(URLRequest(url:url))
    }
    private func settleLoadingPlaceholder() {
        guard loadingState == .loading,loadingTask == nil else{return}
        let generation=loadingGeneration
        loadingTask=Task { [weak self] in
            for _ in 0..<60 {
                guard !Task.isCancelled,let self,!self.disposed,self.loadingGeneration == generation else{return}
                let status=(try? await self.webView.evaluateJavaScript(Self.contentReadyScript)) as? [String:Bool]
                guard !Task.isCancelled,!self.disposed,self.loadingGeneration == generation else{return}
                let native=status?["native"] == true
                if self.nativeLoadingPlaceholderVisible != native {self.nativeLoadingPlaceholderVisible=native}
                if status?["ready"] == true || self.webView.url?.absoluteString == "about:blank" {
                    self.nativeLoadingPlaceholderVisible=false;self.loadingState = .none;self.loadingTask=nil
                    return
                }
                try? await Task.sleep(for:.milliseconds(200))
            }
            // Unknown SPA layout: reveal the actual page without claiming data sync completed.
            if let self,!self.disposed,self.loadingGeneration == generation {
                self.nativeLoadingPlaceholderVisible=false;self.loadingState = .none;self.loadingTask=nil
            }
        }
    }
    var workspaceIdentityLabel:String? {
        guard let workspace=store?.workspace(workspaceID),let expected=NotionWorkspace.normalizedID(workspace.notionSpaceID),
              let url=webView.url,NotionWorkspace.environment(url) != nil else{return nil}
        if workspaceMismatch {return L("Workspace IDが設定と一致しません")}
        return detectedURL == url.absoluteString && detectedNotionSpaceID == expected ? L("Workspace IDは設定と一致しています") : L("Workspace IDを確認できていません")
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
            store?.notify(L("一致する移動先がありません。アプリタブのWorkspace IDと自動振り分け設定を確認してください"),isError:true);return
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
                    self.store?.notify((response?["message"] as? String).map(NotionActions.localizedMessage) ?? L("操作対象を見つけられませんでした"),isError:response?["ok"] as? Bool != true)
                case .failure:
                    self.store?.notify(L("Notionの操作を完了できませんでした。タブを確認してください"),isError:true)
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
        disposed=true;faviconTask?.cancel();faviconTask=nil;loadingTask?.cancel();loadingTask=nil;nativeLoadingPlaceholderVisible=false;loadingState = .none;clearPendingNotionAction()
        observations.forEach{$0.invalidate()};observations.removeAll()
        webView.stopLoading();webView.navigationDelegate=nil;webView.uiDelegate=nil
        webView.removeFromSuperview();store=nil
    }
    init(store: BrowserStore, workspace: BrowserWorkspace, page: BrowserPage, configuration: WKWebViewConfiguration? = nil) {
        self.store = store; workspaceID = workspace.id; pageID = page.id; profileID = workspace.profileID(for:page)
        let config = configuration ?? WKWebViewConfiguration()
        config.websiteDataStore = store.dataStore(profileID)
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController = WKUserContentController()
        if let seed=store.notionAccountSeeds.removeValue(forKey:page.id).flatMap(NotionAccount.seedScript) {
            config.userContentController.addUserScript(WKUserScript(source:seed,injectionTime:.atDocumentStart,forMainFrameOnly:true,in:.defaultClient))
        }
        config.userContentController.addUserScript(WKUserScript(source: Self.style(workspace), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = BrowserWebView(frame: .zero, configuration: config)
        super.init()
        address = page.url; title = page.title
        styleScript=Self.style(workspace)
        if page.isStartPage != true,page.url != "about:blank" {loadingState = .loading}
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
            if self.store?.visiblePageIDs.contains(self.pageID) == true {self.notionAccount.refresh(in:self.webView)}
        }
    }
    func navigate(_ text: String,notionAction:String? = nil) {
        invalidateDocument();connectionRetryURL=nil;failedURL=nil
        clearLoadingPlaceholder();needsRestore=false
        clearPendingNotionAction()
        guard let url = BrowserAddress.url(text) else { failure = L("http / httpsのURLを入力してください。"); return }
        if notionAction == nil,store?.routeLink(url,from:PageReference(workspaceID:workspaceID,pageID:pageID)) == true {return}
        if store?.routeNotion(url,from:PageReference(workspaceID:workspaceID,pageID:pageID)) == true {return}
        store?.allowPageLoad(pageID)
        if let action=notionAction,NotionActions.creationIDs.contains(action) {
            pendingNotionAction=action;notionReadyToken=UUID().uuidString
            webView.configuration.userContentController.add(NotionReadyHandler(self),contentWorld:.defaultClient,name:"workspaceNotionReady")
            resetUserScripts()
        }
        store?.leaveStartPage(workspaceID,pageID,url:url)
        failure = nil;beginLoadingPlaceholder();currentNavigation=webView.load(URLRequest(url: url))
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
        navigationStarts += 1;failure=nil;failedURL=nil;lastHTTPStatus=nil;beginLoadingPlaceholder()
    }
    func webView(_ webView:WKWebView,didCommit navigation:WKNavigation!) {
        guard acceptsNavigation(navigation) else{return}
        hasCommittedDocument=true;connectionRetryURL=nil
        notionAccount.refresh(in:webView)
        if let store,let url=webView.url,let value=store.sites.preference(profileID:profileID,url:url) {webView.pageZoom=value.zoom}
        settleLoadingPlaceholder()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard acceptsNavigation(navigation) else{return}
        let generation=documentGeneration
        if let start=navigationStarted {store?.recordTiming("ページ読み込み",since:start);navigationStarted=nil}
        failure = nil;failedURL=nil;refresh()
        notionAccount.refresh(in:webView,force:true)
        DispatchQueue.main.async { [weak self] in guard let self,self.acceptsDocumentResult(generation) else{return};self.firstLoadFinished=true;self.detectNotionWorkspace() }
        if let workspace = store?.workspace(workspaceID) { updateStyle(workspace) }
        startPendingNotionAction()
        discoverFavicon()
        settleLoadingPlaceholder()
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self] in guard let self,self.acceptsDocumentResult(generation) else{return};self.discoverFavicon() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if acceptsNavigation(navigation) {failed(error)} }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if acceptsNavigation(navigation) {failed(error)} }
    private func failed(_ error: Error) {
        guard !disposed else{return}
        let networkError=error as NSError
        if expectingDownloadInterruption,["WebKitErrorDomain","WKErrorDomain"].contains(networkError.domain),networkError.code == 102 {
            expectingDownloadInterruption=false
            clearLoadingPlaceholder();failure=nil;failedURL=nil;navigationStarted=nil;refresh()
            return
        }
        // Cancelling an HTTP error response can produce WebKit's secondary
        // policy-interruption error. Preserve the useful server response instead.
        if loadingState == .failed,lastHTTPStatus.map({(500...599).contains($0)}) == true,
           ["WebKitErrorDomain","WKErrorDomain"].contains(networkError.domain),networkError.code == 102 {return}
        if networkError.domain == NSURLErrorDomain,networkError.code == NSURLErrorCancelled {
            if !webView.isLoading && loadingState == .loading {clearLoadingPlaceholder();refresh()}
            return
        }
        failedURL=(networkError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (networkError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
            ?? mainGET ?? webView.url
        if !hasCommittedDocument,networkError.domain == NSURLErrorDomain,
           [NSURLErrorNotConnectedToInternet,NSURLErrorNetworkConnectionLost,NSURLErrorCannotFindHost,NSURLErrorCannotConnectToHost,NSURLErrorDNSLookupFailed].contains(networkError.code),
           let url=networkError.userInfo[NSURLErrorFailingURLErrorKey] as? URL,url == mainGET {connectionRetryURL=url}
        cancelNotionAction(clearPending:false)
        if pendingNotionAction != nil {clearPendingNotionAction();store?.notify(L("新しいタブを読み込めなかったためNotionの操作を中止しました"),isError:true)}
        loadingTask?.cancel();loadingTask=nil;loadingGeneration += 1
        nativeLoadingPlaceholderVisible=false;loadingState = .failed
        failure = error.localizedDescription; refresh()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !disposed else{return}
        cancelNotionAction();invalidateDocument()
        loadingTask?.cancel();loadingTask=nil;loadingGeneration += 1;needsRestore=true
        nativeLoadingPlaceholderVisible=false;loadingState = .failed;failedURL=webView.url
        failure = L("ページの処理が終了しました。再読み込みしてください。")
        if store?.visiblePageIDs.contains(pageID) == true {prepareForDisplay()}
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !disposed,let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        // Handle an explicit download before Cmd-click and workspace routing. Those
        // paths would replace the original request and lose POST/blob/download data.
        if navigationAction.shouldPerformDownload,["http","https","about","blob","data"].contains(scheme) {
            if navigationAction.targetFrame?.isMainFrame != false {expectingDownloadInterruption=true}
            decisionHandler(.download);return
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            expectingDownloadInterruption=false
            mainGET=navigationAction.request.httpMethod == "GET" && ["http","https"].contains(url.scheme ?? "") ? url:nil
        }
        if navigationAction.navigationType == .linkActivated,navigationAction.targetFrame != nil,
           navigationAction.request.httpMethod == "GET",store?.routeLink(url,from:PageReference(workspaceID:workspaceID,pageID:pageID),newTab:navigationAction.modifierFlags.contains(.command)) == true {decisionHandler(.cancel);return}
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
        if ["http","https","about","blob","data"].contains(scheme) { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        let alert = NSAlert(); alert.messageText = L("外部アプリで開きますか？"); alert.informativeText = L("\(scheme) リンクを対応するアプリへ渡します。")
        alert.addButton(withTitle: L("キャンセル")); alert.addButton(withTitle: L("開く"))
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard !disposed else {decisionHandler(.cancel);return}
        if navigationResponse.isForMainFrame,let response=navigationResponse.response as? HTTPURLResponse {
            lastHTTPStatus=response.statusCode
            if (500...599).contains(response.statusCode) {
                let text=response.statusCode == 504
                    ? L("接続先のサーバーから応答がありません（HTTP 504）。時間をおいて再試行してください。")
                    : L("接続先のサーバーでエラーが発生しました（HTTP \(response.statusCode)）。時間をおいて再試行してください。")
                var info:[String:Any]=[NSLocalizedDescriptionKey:text]
                if let url=response.url {info[NSURLErrorFailingURLErrorKey]=url}
                failed(NSError(domain:"WorkspaceTabs.HTTP",code:response.statusCode,userInfo:info))
                decisionHandler(.cancel);return
            }
        }
        let disposition=(navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField:"Content-Disposition")?
            .split(separator:";",maxSplits:1).first?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        let download=disposition == "attachment" || !navigationResponse.canShowMIMEType
        if download,navigationResponse.isForMainFrame {expectingDownloadInterruption=true}
        decisionHandler(download ? .download : .allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Keep the opener's exact persistent data store, including across app-tab switches.
        guard let store, navigationAction.targetFrame == nil else { return nil }
        if navigationAction.navigationType == .linkActivated,navigationAction.request.httpMethod == "GET",let url=navigationAction.request.url,
           !navigationAction.shouldPerformDownload,store.routeLink(url,from:PageReference(workspaceID:workspaceID,pageID:pageID),newTab:true) {return nil}
        let child = store.addPage(to: workspaceID, url: "about:blank", configuration: configuration,groupID:store.workspace(workspaceID).flatMap{w in w.pages.first(where:{$0.id == pageID}).map{w.groupID(for:$0)}})
        child?.downloadOpener=PageReference(workspaceID:workspaceID,pageID:pageID)
        if store.split?.pageID == pageID, let child {
            store.setSplit(PageReference(workspaceID: workspaceID, pageID: child.pageID))
        }
        return child?.webView
    }
    func webViewDidClose(_ webView: WKWebView) { store?.closePage(pageID, in: workspaceID) }
    func webView(_ webView:WKWebView,requestMediaCapturePermissionFor origin:WKSecurityOrigin,initiatedByFrame frame:WKFrameInfo,type:WKMediaCaptureType,decisionHandler:@escaping(WKPermissionDecision)->Void) {
        var parts=URLComponents();parts.scheme=origin.protocol;parts.host=origin.host;parts.port=origin.port == 0 ? nil:origin.port
        guard let url=parts.url,let store else{decisionHandler(.prompt);return}
        decisionHandler(store.sites.decision(profileID:profileID,url:url,type:type))
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = frame.securityOrigin.host; alert.informativeText = message; alert.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = frame.securityOrigin.host; alert.informativeText = message
        alert.addButton(withTitle: L("キャンセル")); alert.addButton(withTitle: "OK"); completionHandler(alert.runModal() == .alertSecondButtonReturn)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = frame.securityOrigin.host; alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? ""); field.frame = NSRect(x:0,y:0,width:300,height:24); alert.accessoryView = field
        alert.addButton(withTitle: L("キャンセル")); alert.addButton(withTitle: "OK"); completionHandler(alert.runModal() == .alertSecondButtonReturn ? field.stringValue : nil)
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
    func webView(_ webView:WKWebView,navigationAction:WKNavigationAction,didBecome download:WKDownload) {handoff(download)}
    func webView(_ webView:WKWebView,navigationResponse:WKNavigationResponse,didBecome download:WKDownload) {handoff(download)}
    private func handoff(_ download:WKDownload) {
        guard let store else {download.cancel(nil);return}
        store.downloads.adopt(download)
        if expectingDownloadInterruption {clearLoadingPlaceholder();failure=nil;failedURL=nil;navigationStarted=nil;refresh()}
        // A target=_blank attachment needs a WebView for WebKit's original request,
        // but must not leave a useless empty/error tab behind after the handoff.
        if !hasCommittedDocument,let opener=downloadOpener {
            let child=PageReference(workspaceID:workspaceID,pageID:pageID)
            DispatchQueue.main.async { [weak store] in
                guard let store,store.page(child) != nil,store.page(opener) != nil else{return}
                let wasSelected=store.workspace(child.workspaceID)?.selectedPageID == child.pageID
                store.closePage(child.pageID,in:child.workspaceID)
                if wasSelected {store.selectPage(opener.pageID,in:opener.workspaceID)}
            }
        }
    }

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
