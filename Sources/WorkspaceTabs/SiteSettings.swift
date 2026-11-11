import SwiftUI
import WebKit
import AVFoundation
import WorkspaceCore

struct SitePreference:Codable,Identifiable {
    enum Access:String,Codable {case ask,deny}
    let profileID:UUID
    let origin:String
    var zoom=1.0
    var microphone:Access = .ask
    var camera:Access = .ask
    var id:String {profileID.uuidString+" "+origin}
    static func origin(_ url:URL)->String? {
        guard ["http","https"].contains(url.scheme ?? ""),let host=url.host?.lowercased() else{return nil}
        let port=url.port.flatMap{($0 == 443 && url.scheme == "https") || ($0 == 80 && url.scheme == "http") ? nil:$0}
        var components=URLComponents();components.scheme=url.scheme;components.host=host;components.port=port
        return components.url?.absoluteString
    }
}
@MainActor final class SitePreferences:ObservableObject {
    @Published private(set) var values:[SitePreference]=[]
    private let file:URL
    init(directory:URL) {
        file=directory.appendingPathComponent("site-preferences.json")
        if let data=try? Data(contentsOf:file),let entries=try? JSONDecoder().decode([SitePreference].self,from:data) {
            var ids=Set<String>()
            values=entries.filter{$0.zoom.isFinite && (0.5...3).contains($0.zoom) && URL(string:$0.origin).flatMap(SitePreference.origin) == $0.origin && ids.insert($0.id).inserted}
        }
    }
    func preference(profileID:UUID,url:URL)->SitePreference? {
        guard let origin=SitePreference.origin(url) else{return nil}
        return values.first{$0.profileID == profileID && $0.origin == origin} ?? SitePreference(profileID:profileID,origin:origin)
    }
    func set(_ value:SitePreference)throws {
        guard value.zoom.isFinite,(0.5...3).contains(value.zoom),URL(string:value.origin).flatMap(SitePreference.origin) == value.origin else{throw BrowserSessionError.invalid}
        var next=values.filter{$0.id != value.id}
        if value.zoom != 1 || value.microphone != .ask || value.camera != .ask {next.append(value)}
        let data=try JSONEncoder().encode(next)
        try data.write(to:file,options:.atomic);values=next
    }
    func decision(profileID:UUID,url:URL,type:WKMediaCaptureType)->WKPermissionDecision {
        guard let value=preference(profileID:profileID,url:url) else{return .prompt}
        switch type {
        case .microphone:return value.microphone == .deny ? .deny:.prompt
        case .camera:return value.camera == .deny ? .deny:.prompt
        case .cameraAndMicrophone:return value.microphone == .deny || value.camera == .deny ? .deny:.prompt
        @unknown default:return .prompt
        }
    }
}
extension BrowserStore {
    func updateSitePreference(_ value:SitePreference) {
        do {
            try sites.set(value)
            for engine in loadedEngines where engine.profileID == value.profileID && engine.webView.url.flatMap(SitePreference.origin) == value.origin {
                engine.webView.pageZoom=value.zoom
                if value.microphone == .deny {engine.webView.setMicrophoneCaptureState(.none,completionHandler:nil)}
                if value.camera == .deny {engine.webView.setCameraCaptureState(.none,completionHandler:nil)}
            }
        } catch {notify(L("サイト設定を保存できませんでした。"),isError:true)}
    }
}
struct SiteSettingsSheet:View {
    @ObservedObject private var localization=AppLocalization.shared
    @ObservedObject var store:BrowserStore
    @ObservedObject var sites:SitePreferences
    let ref:PageReference
    @Environment(\.dismiss) private var dismiss
    private var url:URL? {store.engineIfLoaded(ref.pageID)?.webView.url ?? store.page(ref).flatMap{URL(string:$0.url)}}
    private var workspace:BrowserWorkspace? {store.workspace(ref.workspaceID)}
    private var profileID:UUID? {workspace.flatMap{w in store.page(ref).map{w.profileID(for:$0)}}}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {Text(L("サイト設定")).font(.title2.bold());Spacer();Button(L("完了")){dismiss()}.keyboardShortcut(.cancelAction)}
            if let workspace,let profileID,let url,let preference=sites.preference(profileID:profileID,url:url) {
                Text(preference.origin).font(.callout.monospaced()).textSelection(.enabled)
                Form {
                    Section(L("ログイン環境")) {
                        LabeledContent(L("アプリタブ"),value:workspace.name)
                        LabeledContent(L("ログイン環境"),value:store.profile(profileID)?.name ?? "")
                        if let note=store.profile(profileID)?.accountNote,!note.isEmpty {Text(note).foregroundStyle(.secondary)}
                        Text(L("アカウントの表示は確認用のメモです。サイトのログイン状態を保証するものではありません。")).font(.caption).foregroundStyle(.secondary)
                    }
                    Section(L("このサイトの表示・権限")) {
                        Picker(L("ズーム"),selection:Binding(get:{preference.zoom},set:{var next=preference;next.zoom=$0;store.updateSitePreference(next)})) {
                            ForEach([0.5,0.75,0.9,1,1.1,1.25,1.5,1.75,2,2.5,3],id:\.self){Text("\(Int($0*100))%").tag($0)}
                        }
                        accessPicker(L("マイク"),value:preference.microphone){var next=preference;next.microphone=$0;store.updateSitePreference(next)}
                        accessPicker(L("カメラ"),value:preference.camera){var next=preference;next.camera=$0;store.updateSitePreference(next)}
                        Text(L("許可の確認はWebKitとmacOSが行います。ブロックすると、この環境の同じサイトで進行中の入力も停止します。")).font(.caption).foregroundStyle(.secondary)
                        Button(L("このサイトの設定をリセット")){store.updateSitePreference(SitePreference(profileID:profileID,origin:preference.origin))}
                    }
                    if BrowserAddress.isNotion(url) {
                        Section(L("サイドバーの色")) {
                            Toggle(L("Notionのサイドバーを着色"),isOn:Binding(get:{store.workspace(workspace.id)?.cssEnabled ?? false},set:{var next=workspace;next.cssEnabled=$0;store.updateWorkspace(next)}))
                            Slider(value:Binding(get:{store.workspace(workspace.id)?.cssStrength ?? 0.18},set:{var next=workspace;next.cssStrength=$0;store.updateWorkspace(next)}),in:0...1) {Text(L("濃さ"))}.disabled(!workspace.cssEnabled)
                            Text(L("着色設定は同じアプリタブのNotionページで共有します。")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.formStyle(.grouped)
            } else {Text(L("httpまたはhttpsのページを開いてください。")).foregroundStyle(.secondary)}
        }.padding(20).frame(width:530,height:590)
    }
    private func accessPicker(_ title:String,value:SitePreference.Access,set:@escaping(SitePreference.Access)->Void)->some View {
        Picker(title,selection:Binding(get:{value},set:set)) {Text(L("確認する")).tag(SitePreference.Access.ask);Text(L("ブロック")).tag(SitePreference.Access.deny)}
    }
}
