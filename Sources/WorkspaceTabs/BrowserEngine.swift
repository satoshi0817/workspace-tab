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
    private var detectedURL: String?
    private var firstLoadFinished=false
    private var mayRoute=false
    private var detectionRunning=false
    func detectNotionWorkspace(completion: ((String?) -> Void)? = nil) {
        guard !detectionRunning, let url=webView.url,NotionWorkspace.environment(url) != nil else {completion?(nil);return}
        detectionRunning=true
        webView.evaluateJavaScript(NotionWorkspace.detectionScript) { [weak self] result,_ in
            guard let self else {return};self.detectionRunning=false
            guard let result=result as? [String:String],result["url"] == self.webView.url?.absoluteString,
                  let id=NotionWorkspace.normalizedID(result["spaceID"]) else {self.detectedNotionSpaceID=nil;self.detectedURL=nil;completion?(nil);return}
            self.detectedNotionSpaceID=id;self.detectedURL=result["url"];completion?(id)
            if self.mayRoute, let url=self.webView.url {
                self.mayRoute=false
                _ = self.store?.routeNotion(url,detectedID:id,from:PageReference(workspaceID:self.workspaceID,pageID:self.pageID))
            }
        }
    }
    private var observations: [NSKeyValueObservation] = []
    init(store: BrowserStore, workspace: BrowserWorkspace, page: BrowserPage, configuration: WKWebViewConfiguration? = nil) {
        self.store = store; workspaceID = workspace.id; pageID = page.id; profileID = workspace.profileID
        let config = configuration ?? WKWebViewConfiguration()
        config.websiteDataStore = store.dataStore(workspace.profileID)
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.userContentController = WKUserContentController()
        config.userContentController.addUserScript(WKUserScript(source: Self.style(workspace), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        address = page.url; title = page.title
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let url = self.webView.url {
                if self.address != url.absoluteString {
                    self.detectedNotionSpaceID=nil;self.detectedURL=nil
                    if self.firstLoadFinished {self.mayRoute=true}
                }
                if self.address != url.absoluteString {self.address = url.absoluteString}
            }
            let title=self.webView.title ?? ""
            if self.title != title {self.title=title}
            if self.loading != self.webView.isLoading {self.loading=self.webView.isLoading}
            if self.progress != self.webView.estimatedProgress {self.progress=self.webView.estimatedProgress}
            if self.canBack != self.webView.canGoBack {self.canBack=self.webView.canGoBack}
            if self.canForward != self.webView.canGoForward {self.canForward=self.webView.canGoForward}
            self.store?.updatePage(self.workspaceID, self.pageID, url: self.webView.url, title: self.webView.title)
        }
    }
    func navigate(_ text: String) {
        guard let url = BrowserAddress.url(text) else { failure = "http / httpsのURLを入力してください。"; return }
        if store?.routeNotion(url,from:PageReference(workspaceID:workspaceID,pageID:pageID)) == true {return}
        failure = nil; webView.load(URLRequest(url: url))
    }
    func updateStyle(_ workspace: BrowserWorkspace) {
        let script = Self.style(workspace)
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        failure = nil; refresh()
        DispatchQueue.main.async { [weak self] in self?.firstLoadFinished=true;self?.detectNotionWorkspace() }
        if let workspace = store?.workspace(workspaceID) { updateStyle(workspace) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        failure = error.localizedDescription; refresh()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure = "ページの処理が終了しました。再読み込みしてください。" }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           navigationAction.targetFrame != nil,
           navigationAction.request.httpMethod == "GET",
           ["http","https"].contains(url.scheme?.lowercased() ?? "") {
            // target=_blank is handled by createWebView; intercept normal links only once.
            decisionHandler(.cancel)
            _ = store?.addPage(to:workspaceID,url:url.absoluteString)
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
        let child = store.addPage(to: workspaceID, url: "about:blank", configuration: configuration)
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
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
