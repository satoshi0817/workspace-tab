import WorkspaceCore
import SwiftUI
import AppKit

struct NotionLibrarySettings:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var library:NotionLibrary
    @State private var pat=""
    @State private var label=""
    @State private var databaseURL=""
    @State private var tabURL=""
    @State private var tabToken=""
    @State private var replacementToken=""
    @State private var pageTitle="Workspace Tabs"
    @State private var identity:ConnectionIdentity?
    @State private var mode="existing"
    @State private var restore:NotionSnapshotRow?
    @State private var manageConnections=false
    var body:some View {
        Section {
            Toggle(L("Notionと同期"),isOn:Binding(get:{library.state.enabled},set:{library.state.enabled=$0;library.save();if $0 {Task{await library.sync()}}})).disabled(library.busy || library.state.sources.isEmpty)
            HStack {
                if library.busy {ProgressView().controlSize(.small);Text(L("同期中…")).foregroundStyle(.secondary)}
                else {Text(library.state.enabled ? L("1時間ごとに自動同期"):L("このMacに保存")).foregroundStyle(.secondary)}
                Spacer()
                if library.state.enabled {Button(L("今すぐ同期")){Task{await library.sync()}}.disabled(library.busy)}
            }
            if !library.message.isEmpty {
                Text(library.message).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                if library.message.count > 100 {DisclosureGroup(L("詳細")){Text(library.message).font(.caption).textSelection(.enabled)}}
            }
        }
        Section(L("お気に入りの保存先")) {
            if library.state.sources.isEmpty {
                Text(L("Notionは未接続です。")).foregroundStyle(.secondary)
            } else {
                ForEach(library.state.sources){source in
                    HStack {
                        Label(source.title,systemImage:"externaldrive")
                        Spacer()
                        if let raw=source.databaseUrl,let url=URL(string:raw) {
                            Button(L("Notionで開く")){NSWorkspace.shared.open(url)}.buttonStyle(.link)
                        }
                    }
                }
            }
            Button(library.state.sources.isEmpty ? L("Notionに接続…"):L("接続を管理…")){manageConnections=true}
        }
        if !library.state.edits.isEmpty {
            Section(L("送信待ち・競合")) {
                ForEach(library.state.edits){edit in
                    VStack(alignment:.leading,spacing:6){Text(edit.value.title);Text(edit.failure ?? L("送信待ち")).font(.caption).foregroundStyle(.secondary)
                        if edit.failure != nil {Button(L("Notionの内容を採用（この変更を取り消す）")){library.discard(edit.id)}.disabled(library.busy)}
                    }
                }
                Button(L("再試行")){library.retry()}.disabled(library.busy || !library.state.enabled)
            }
        }
        Section {
            tabBackup
        }
        .alert(L("保存したタブへ戻しますか？"),isPresented:Binding(get:{restore != nil},set:{if !$0 {restore=nil}})) {
            Button(L("キャンセル"),role:.cancel){restore=nil}
            Button(L("タブを復元")) {if let row=restore {perform{let backup=try await library.readSnapshot(row.id);try library.store?.restoreTabBackup(backup);library.message=L("タブを復元しました。")}};restore=nil}
        } message:{Text(L("現在のタブを置き換えます。未送信の入力は失われます。お気に入りは保持します。別のMacではサイトへの再ログインが必要です。"))}
        .sheet(isPresented:$manageConnections,onDismiss:{pat="";identity=nil}) {
            VStack(spacing:0) {
                HStack {Text(L("Notion接続")).font(.title2.weight(.semibold));Spacer();Button(L("完了")){manageConnections=false}.keyboardShortcut(.cancelAction).disabled(library.busy)}.padding(20)
                Form {
                    if !library.state.sources.isEmpty {
                        Section(L("接続済み")) {
                            ForEach(library.state.sources){source in
                                DisclosureGroup(source.title){
                                    Text(source.databaseUrl ?? source.id).font(.caption).textSelection(.enabled)
                                    Button(L("接続を確認")){perform{let count=try await library.checkConnection(source);library.message=L("接続できました（\(count)件）。")}}.disabled(library.busy)
                                }
                            }
                        }
                    }
                    connectionSetup
                    if library.busy {ProgressView().controlSize(.small)}
                    if !library.message.isEmpty {Text(library.message).font(.caption).textSelection(.enabled)}
                }.formStyle(.grouped)
            }.frame(width:570,height:570).interactiveDismissDisabled(library.busy)
        }
    }
    private var connectionSetup:some View {
        Section(L("接続を追加・変更")) {
            Picker(L("接続方法"),selection:$mode){Text(L("既存DB")).tag("existing");Text(L("新しく作成")).tag("create");Text(L("PATを更新")).tag("token")}.pickerStyle(.segmented)
            SecureField("Notion PAT",text:$pat).onChange(of:pat){_,_ in identity=nil}
            Text(L("PATはこのMacのキーチェーンに保存します。")).font(.caption).foregroundStyle(.secondary)
            if mode == "existing" {
                TextField(L("接続名"),text:$label)
                TextField(L("NotionデータベースURL"),text:$databaseURL)
                Button(L("接続を確認して追加")) {perform{try await library.register(label:label,secret:pat,input:databaseURL);pat="";databaseURL="";library.message=L("DBを接続しました。Notion保存をオンにすると同期します。")}}.disabled(library.busy || pat.isEmpty || databaseURL.isEmpty)
            } else if mode == "create" {
                TextField(L("親ページ名"),text:$pageTitle)
                Text(L("プライベートに、お気に入り・カテゴリ・タブの保存先を作ります。")).font(.caption).foregroundStyle(.secondary)
                Button(L("PATの作成先を確認")) {perform{identity=try await library.setup.inspect(token:pat)}}.disabled(library.busy || pat.isEmpty)
                if let identity {
                    Text(L("作成先：\(identity.workspaceName) / \(identity.ownerName) のプライベート")).font(.callout)
                    Button(L("このプライベート領域に作成")) {perform{try await library.create(secret:pat,title:pageTitle);pat=""}}.disabled(library.busy)
                }
                ForEach(library.pendingCreations()){creation in
                    HStack {Text(creation.title+"："+creation.status).font(.caption);Spacer();Button(L("再開")){perform{try await library.resume(creation)}}.disabled(library.busy)}
                }
            } else {
                Picker(L("更新する接続"),selection:$replacementToken){Text(L("選択してください")).tag("");ForEach(library.state.tokens){Text($0.label).tag($0.id)}}
                Button(L("PATを確認して更新")){perform{try await library.replaceToken(id:replacementToken,secret:pat);pat="";library.message=L("PATを更新しました。")}}.disabled(library.busy || pat.isEmpty || replacementToken.isEmpty)
            }
        }
    }
    private var tabBackup:some View {
        DisclosureGroup(L("タブのバックアップ")) {
            Toggle(L("このMacのタブをNotionにも保存"),isOn:Binding(get:{library.state.saveTabs},set:{library.state.saveTabs=$0;library.save()})).disabled(library.state.tabSourceID == nil || library.busy)
            Toggle(L("開いているブラウザタブも含める"),isOn:Binding(get:{library.state.includePages},set:{library.state.includePages=$0;library.state.lastTabDigest=nil;library.save()})).disabled(library.busy)
            Text(L("Macごとに保存します。ログイン情報は含みません。")).font(.caption).foregroundStyle(.secondary)
            if let url=library.state.tabDatabaseURL {Text(url).font(.caption).textSelection(.enabled)}
            DisclosureGroup(L("既存のTabs DBに接続")) {
                TextField(L("Tabs DBのURL"),text:$tabURL)
                Picker(L("接続"),selection:$tabToken){Text(L("選択してください")).tag("");ForEach(library.state.tokens){Text($0.label).tag($0.id)}}
                Button(L("接続")){perform{try await library.connectTabDatabase(input:tabURL,tokenID:tabToken);library.message=L("Tabs DBに接続しました。")}}.disabled(library.busy || tabToken.isEmpty || tabURL.isEmpty)
            }
            HStack {
                Button(L("タブを今すぐ保存")){perform{try await library.saveTabs();library.message=L("タブをNotionに保存しました。")}}.disabled(library.busy || !library.state.enabled || library.state.tabSourceID == nil)
                Button(L("保存済みのタブを表示")){perform{try await library.listSnapshots()}}.disabled(library.busy || library.state.tabSourceID == nil)
            }
            ForEach(library.snapshots){row in HStack{VStack(alignment:.leading){Text(row.name);Text(row.updated).font(.caption).foregroundStyle(.secondary)};Spacer();Button(L("復元…")){restore=row}.disabled(library.busy)}}
        }
    }
    private func perform(_ operation:@escaping ()async throws->Void){
        guard !library.busy else{return};library.busy=true;library.message=""
        Task{@MainActor in
            defer{library.busy=false}
            do {try await operation()}catch{library.message=error.localizedDescription.replacingOccurrences(of:pat.isEmpty ? "__no_secret__":pat,with:"[redacted]")}
        }
    }
}
