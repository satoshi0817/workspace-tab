import Foundation
import SwiftUI
import WorkspaceCore

/// Detect only an interrupted initial UI startup, not a slow website or a force
/// quit after a successful launch. The marker contains no browsing information.
final class StartupRecovery {
    private struct State:Codable {let phase:String;let date:Date}
    private let file:URL
    let interruptedStartup:Bool
    init(directory:URL) {
        file=directory.appendingPathComponent("startup-state.json")
        let state=(try? Data(contentsOf:file)).flatMap{try? JSONDecoder().decode(State.self,from:$0)}
        interruptedStartup=state?.phase == "starting"
    }
    func mark(_ phase:String) {
        guard ["starting","ready","clean"].contains(phase) else{return}
        do {
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(State(phase:phase,date:Date())).write(to:file,options:.atomic)
        } catch {NSLog("Workspace Tabs: could not write startup marker (%@)",String((error as NSError).code))}
    }
}
extension BrowserStore {
    func isPageSuspended(_ pageID:UUID)->Bool {safeMode && !safeLoadedPages.contains(pageID)}
    func allowPageLoad(_ pageID:UUID) {if safeMode {safeLoadedPages.insert(pageID);objectWillChange.send()}}
    func resumePage(_ ref:PageReference) {
        guard let page=page(ref),let engine=engine(ref.workspaceID,ref.pageID,load:false) else{return}
        allowPageLoad(ref.pageID);suspendedPages.remove(ref.pageID)
        if engine.webView.url == nil {engine.resumeStoredPage(page.url)}
    }
    func resumeBrowsing() {
        safeMode=false
        for id in Array(suspendedPages) where visiblePageIDs.contains(id) {
            if let engine=engineIfLoaded(id) {resumePage(PageReference(workspaceID:engine.workspaceID,pageID:id))}
        }
        onResumeFromSafeMode?();notify(L("通常の読み込みを再開しました"))
    }
}
struct SafeModeBanner:View {
    @ObservedObject var store:BrowserStore
    var body:some View {
        HStack(spacing:12) {
            Label(L("セーフモード：ページの自動読み込みを停止しています"),systemImage:"shield.lefthalf.filled").font(.callout)
            Spacer()
            Button(L("設定")){store.showSettings=true}
            Button(L("通常の読み込みを再開")){store.resumeBrowsing()}
        }.padding(12).background(.regularMaterial)
    }
}
struct SafeStartupSettings:View {
    @ObservedObject var store:BrowserStore
    @State private var nextLaunch=false
    var body:some View {
        Section(L("セーフモード")) {
            Toggle(L("次回はページを読み込まずに起動"),isOn:$nextLaunch)
            Text(L("入力内容を保存してからアプリを終了し、再度起動してください。タブやログイン情報は保持し、選んだページだけ読み込みを再開できます。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("起動直後に異常終了した場合も、次回はセーフモードになります。Webサイトの読み込みエラーだけでは切り替わりません。"))
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear{nextLaunch=AppLocalization.shared.safeModeNextLaunch}
            .onChange(of:nextLaunch){_,value in AppLocalization.shared.safeModeNextLaunch=value}
    }
}
