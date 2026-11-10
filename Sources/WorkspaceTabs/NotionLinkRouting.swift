import WorkspaceCore
import AppKit
import SwiftUI

@MainActor protocol LinkRoutingSystem {
    func application(for scheme:String)->URL?
    func setApplication(_ application:URL,for scheme:String) async throws
}
@MainActor final class MacLinkRoutingSystem:LinkRoutingSystem {
    func application(for scheme:String)->URL? {
        guard let url=URL(string:scheme+"://workspace-tabs-routing.invalid") else{return nil}
        return NSWorkspace.shared.urlForApplication(toOpen:url)
    }
    func setApplication(_ application:URL,for scheme:String) async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            NSWorkspace.shared.setDefaultApplication(at:application,toOpenURLsWithScheme:scheme) {error in
                if let error {continuation.resume(throwing:error)} else {continuation.resume()}
            }
        }
    }
}
/// This Mac's default-browser preference is deliberately excluded from session/Notion backups.
@MainActor final class NotionLinkRouting:ObservableObject {
    struct Record:Codable {var previous:[String:String]=[:]}
    @Published private(set) var enabled=false
    @Published private(set) var busy=false
    @Published private(set) var message:String?
    private let system:LinkRoutingSystem
    private let file:URL
    let application:URL
    let canConfigure:Bool
    private var record=Record()
    private static let schemes=["https","http"]
    init(directory:URL,system:LinkRoutingSystem?=nil,application:URL=Bundle.main.bundleURL,canConfigure:Bool?=nil) {
        self.system=system ?? MacLinkRoutingSystem();self.application=application
        self.canConfigure=canConfigure ?? (Bundle.main.bundleIdentifier == "com.ssuzuki.WorkspaceTabs" && application.path == "/Applications/Workspace Tabs.app")
        file=directory.appendingPathComponent("link-routing.json")
        do {if FileManager.default.fileExists(atPath:file.path) {record=try JSONDecoder().decode(Record.self,from:Data(contentsOf:file))}}
        catch {message=L("元のブラウザの設定を読み込めませんでした。")}
        refresh()
    }
    private func owns(_ url:URL?)->Bool {url?.standardizedFileURL.resolvingSymlinksInPath().path == application.standardizedFileURL.resolvingSymlinksInPath().path}
    func refresh() {enabled=Self.schemes.contains{owns(system.application(for:$0))}}
    private func persist()throws {
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(record).write(to:file,options:.atomic)
    }
    func setEnabled(_ wanted:Bool)async {
        guard !busy,canConfigure else{return}
        busy=true;message=nil;defer{busy=false;refresh()}
        do {
            if wanted {
                // Snapshot *both* handlers before macOS changes either of them. Its
                // browser preference may update http and https in the same operation.
                for scheme in Self.schemes where !owns(system.application(for:scheme)) {
                    guard let previous=system.application(for:scheme) else{throw LVError(L("元のブラウザを確認できません。システム設定で既定のブラウザを選んでください。"))}
                    record.previous[scheme]=previous.path
                }
                guard Self.schemes.allSatisfy({record.previous[$0] != nil}) else{throw LVError(L("元のブラウザを復元する情報がありません。システム設定で一度別のブラウザを選んでください。"))}
                try persist()
                do {
                    for scheme in Self.schemes where !owns(system.application(for:scheme)) {try await system.setApplication(application,for:scheme)}
                    guard Self.schemes.allSatisfy({owns(system.application(for:$0))}) else{throw LVError(L("既定のブラウザの変更が反映されませんでした。"))}
                } catch {
                    // Restore only handlers still owned by us; do not undo a newer
                    // explicit choice made in System Settings or another browser.
                    var failures:[String]=[]
                    for scheme in Self.schemes where owns(system.application(for:scheme)) {
                        if let old=record.previous[scheme] {
                            do {try await system.setApplication(URL(fileURLWithPath:old),for:scheme)}
                            catch {failures.append(scheme)}
                        }
                    }
                    if !failures.isEmpty {throw LVError(L("変更を完了できず、元のブラウザへの復元も完了していません。オフを再実行するか、システム設定で既定のブラウザを選んでください。"))}
                    throw error
                }
                message=L("Notionリンクを受け取る設定にしました。")
            } else {
                for scheme in Self.schemes where owns(system.application(for:scheme)) {
                    guard let old=record.previous[scheme],old != application.path else{throw LVError(L("元のブラウザの情報がありません。システム設定で既定のブラウザを選んでください。"))}
                    let target=URL(fileURLWithPath:old)
                    guard FileManager.default.fileExists(atPath:target.path) else{throw LVError(L("元のブラウザが見つかりません。システム設定で既定のブラウザを選んでください。"))}
                    try await system.setApplication(target,for:scheme)
                }
                guard !Self.schemes.contains(where:{owns(system.application(for:$0))}) else{throw LVError(L("元のブラウザへの復元を確認できません。"))}
                message=L("元のブラウザに戻しました。")
            }
        } catch {message=error.localizedDescription}
    }
    func browser(for url:URL)->URL? {
        guard ["http","https"].contains(url.scheme ?? "") else{return nil}
        let scheme=url.scheme!
        if let current=system.application(for:scheme),!owns(current) {return current}
        guard let old=record.previous[scheme] else{return nil}
        let target=URL(fileURLWithPath:old)
        return !owns(target) && FileManager.default.fileExists(atPath:target.path) ? target:nil
    }
    func openInBrowser(_ url:URL,onError:@escaping(String)->Void) {
        guard let target=browser(for:url) else {let text=L("リンクの転送先ブラウザが見つかりません。設定 → リンクの受け取りを確認してください。");message=text;onError(text);return}
        NSWorkspace.shared.open([url],withApplicationAt:target,configuration:NSWorkspace.OpenConfiguration()) { [weak self] _,error in
            if let error {Task{@MainActor in self?.message=error.localizedDescription;onError(error.localizedDescription)}}
        }
    }
}
struct NotionLinkRoutingSettings:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var routing:NotionLinkRouting
    var body:some View {
        Section {
            Toggle(L("NotionのWebリンクをWorkspace Tabsで開く"),isOn:Binding(get:{routing.enabled},set:{value in Task{await routing.setEnabled(value)}}))
                .disabled(routing.busy || !routing.canConfigure)
            if routing.busy {ProgressView(L("macOSの設定を変更中…"))}
            Text(L("オンにすると、このMacの既定のブラウザをWorkspace Tabsに変更します。Notionのリンクはこのアプリで開き、それ以外のWebリンクは変更前のブラウザへ渡します。オフにすると元のブラウザへ戻します。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(L("Notion専用アプリを直接指定するリンクや、サイト側の「アプリで開く」は、この設定だけでは置き換えられない場合があります。"))
                .font(.caption).foregroundStyle(.secondary)
            if !routing.canConfigure {Text(L("/ApplicationsにインストールしたWorkspace Tabsから設定してください。")).font(.caption)}
            if let message=routing.message {Text(message).font(.callout).textSelection(.enabled)}
            Button(L("現在の設定を確認")) {routing.refresh()}.disabled(routing.busy)
        } header:{Text(L("リンクの受け取り"))} footer:{Text(L("初期状態ではOSの既定アプリを変更しません。macOSから確認が表示された場合は、内容を確認して選択してください。"))}
        .onAppear{routing.refresh()}
    }
}
