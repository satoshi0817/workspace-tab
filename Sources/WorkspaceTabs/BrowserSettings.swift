import SwiftUI
import AppKit
import WebKit
import WorkspaceCore

struct WorkspaceEditor:View {
    @ObservedObject var store:BrowserStore
    @State var draft:BrowserWorkspace
    @State private var detectionMessage=""
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("アプリタブを編集").font(.title2.weight(.semibold))
            Form {
                TextField("名前",text:$draft.name)
                TextField("ホームURL",text:$draft.homeURL)
                TextField("NotionワークスペースID（任意）",text:Binding(get:{draft.notionSpaceID ?? ""},set:{draft.notionSpaceID=$0.isEmpty ? nil:$0}))
                Toggle("このワークスペースのリンクを自動で振り分ける",isOn:Binding(get:{draft.notionAutoRoute ?? false},set:{draft.notionAutoRoute=$0}))
                Button("現在のNotionページから設定") {
                    guard let pageID=store.workspace(draft.id)?.selectedPageID,let engine=store.engine(draft.id,pageID) else {return}
                    let url=engine.webView.url
                    detectionMessage="確認中…"
                    engine.detectNotionWorkspace { id in
                        guard let id,let url,engine.webView.url == url else {detectionMessage="現在のページに一致するワークスペースIDを取得できませんでした。Notionのページを開いて再試行するか、IDを手入力してください。";return}
                        draft.notionSpaceID=id;draft.homeURL=BrowserAddress.savedURL(url);draft.notionAutoRoute=true
                        detectionMessage="ワークスペースIDとホームURLを設定しました。保存で適用します。"
                    }
                }
                if !detectionMessage.isEmpty {Text(detectionMessage).font(.caption).foregroundStyle(.secondary)}
                Text("IDとホームURLの環境（本番／開発）を照合します。判定不能・複数候補では切り替えません。Notionの内部仕様変更で自動取得できなくなる場合があります。").font(.caption).foregroundStyle(.secondary)
                TextField("絵文字・文字",text:$draft.emoji)
                HStack {Text("画像アイコン");Spacer();Button("選ぶ…") {if let file=store.chooseIcon(){draft.iconFile=file}};if draft.iconFile != nil {Button("解除"){draft.iconFile=nil}}}
                ColorPickerRow(selection:$draft.color)
                Picker("文字色",selection:Binding(get:{draft.textColor ?? "auto"},set:{draft.textColor=$0 == "auto" ? nil:$0})) {
                    Text("自動").tag("auto");Text("白").tag("white");Text("黒").tag("black")
                }.pickerStyle(.segmented)
                Picker("ログイン環境",selection:$draft.profileID) {ForEach(store.session.profiles){profile in Text(profile.name).tag(profile.id)}}
                HStack {Text("同じ環境を選んだアプリタブはログイン状態を共有します。").font(.caption).foregroundStyle(.secondary);Spacer();Button("新しい環境") {draft.profileID=store.createProfile(name:draft.name+" の新しい環境")}}
                Toggle("Notionのサイドバーを着色",isOn:$draft.cssEnabled)
                HStack {
                    Text("濃さ")
                    Slider(value:$draft.cssStrength,in:0...1)
                    TextField("濃さ",value:Binding(get:{draft.cssStrength*100},set:{value in
                        guard value.isFinite else {return}
                        draft.cssStrength=min(100,max(0,value))/100
                    }),format:.number.precision(.fractionLength(0...1)))
                        .labelsHidden().textFieldStyle(.roundedBorder).monospacedDigit()
                        .multilineTextAlignment(.trailing).frame(width:58)
                        .accessibilityLabel("濃さ（0〜100パーセント）")
                        .help("0〜100を入力。スライダーと連動します")
                    Text("%")
                }.disabled(!draft.cssEnabled)
                Text("指定したNotionドメインだけに適用します。ページ本文や画像の透明度は変更しません。Notionの更新で着色が効かなくなる場合はオフにできます。").font(.caption).foregroundStyle(.secondary)
                Text(draft.name).padding(10).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(Palette.ink(draft.color,preference:draft.textColor)).background(Palette.color(draft.color),in:RoundedRectangle(cornerRadius:8))
                Toggle("タブを固定",isOn:$draft.pinned)
            }.formStyle(.grouped)
            HStack {Spacer();Button("キャンセル"){dismiss()}.keyboardShortcut(.cancelAction);Button("保存") {
                if store.workspace(draft.id)?.profileID != draft.profileID {
                    let alert=NSAlert();alert.messageText="ログイン環境を切り替えますか？";alert.informativeText="このアプリタブのページを新しい環境で読み直します。元の環境のログイン情報は残します。入力途中の内容は保存されません。";alert.addButton(withTitle:"キャンセル");alert.addButton(withTitle:"切り替える")
                    guard alert.runModal() == .alertSecondButtonReturn else{return}
                }
                draft.notionSpaceID=NotionWorkspace.normalizedID(draft.notionSpaceID);draft.homeURL=BrowserAddress.url(draft.homeURL)!.absoluteString;draft.emoji=String(draft.emoji.prefix(4));store.updateWorkspace(draft);dismiss()
            }.keyboardShortcut(.defaultAction).disabled(draft.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || BrowserAddress.url(draft.homeURL) == nil || (draft.notionAutoRoute == true && NotionWorkspace.normalizedID(draft.notionSpaceID) == nil))}
        }.padding(20).frame(width:540,height:740)
    }
}
struct BrowserSettings:View {
    @ObservedObject var store:BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var editingProfile:LoginProfile?
    @State private var section="表示"
    private let sections=[("表示","paintpalette"),("ログイン環境","person.crop.circle"),("ショートカット","keyboard"),("Notion保存","cloud"),("バックアップ","externaldrive")]
    var body:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:8) {
                Text("設定").font(.title2.bold()).padding(12)
                ForEach(sections,id:\.0){item in
                    Button {section=item.0} label:{
                        Label(item.0,systemImage:item.1).frame(maxWidth:.infinity,alignment:.leading).padding(12)
                            .foregroundStyle(section == item.0 ? Color.white:Color.primary)
                            .background(section == item.0 ? Color.accentColor:Color.clear,in:RoundedRectangle(cornerRadius:10))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(10).frame(width:190).settingsGlass().padding(12)
            VStack(alignment:.leading,spacing:0) {
                HStack {Text(section).font(.title2.weight(.semibold));Spacer();Button("完了"){dismiss()}.keyboardShortcut(.cancelAction)}.padding(24)
                Form {
                    if section == "表示" {
                        Section("外観") {
                            Picker("テーマ",selection:$store.session.theme){Text("システム").tag("system");Text("ライト").tag("light");Text("ダーク").tag("dark")}
                            Picker("アプリタブの位置",selection:$store.session.sidebarPosition){Text("左側").tag("left");Text("上部").tag("top")}
                            Picker("サイドバー",selection:$store.session.sidebarMode){Text("通常").tag("full");Text("アイコンのみ").tag("icons");Text("左端で展開").tag("hover")}.disabled(store.session.sidebarPosition != "left")
                        }
                    } else if section == "ログイン環境" {
                        Section {
                            ForEach(store.session.profiles){profile in
                                HStack {VStack(alignment:.leading,spacing:4){Text(profile.name);Text(profile.accountNote.isEmpty ? "アカウントのメモなし":profile.accountNote).font(.caption).foregroundStyle(.secondary)};Spacer();Button("編集…"){editingProfile=profile}}
                            }
                        } footer:{Text("同じ環境を選んだアプリタブはログイン状態を共有します。アカウント名は確認用のメモです。")}
                    } else if section == "ショートカット" {
                        ShortcutSettings()
                    } else if section == "Notion保存" {
                        NotionLibrarySettings(library:store.notion)
                    } else {
                        Section("このMacのデータ") {
                            Text("タブの状態は自動保存されます。ファイルへの書き出し・読み込みはこちらから。").font(.callout)
                            Button("保存フォルダを開く"){NSWorkspace.shared.activateFileViewerSelecting([store.directory])}
                            Button("設定を書き出す…"){store.exportSettings()}
                            Button("設定を読み込む…"){store.importSettings()}
                        }
                    }
                }.formStyle(.grouped)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.frame(width:800,height:650).background(Color(nsColor:.windowBackgroundColor))
            .onChange(of:store.session.theme){_,_ in store.applyTheme();store.changed()}
            .onChange(of:store.session.sidebarPosition){_,_ in store.changed()}
            .onChange(of:store.session.sidebarMode){_,_ in store.changed()}
            .sheet(item:$editingProfile){profile in ProfileEditor(store:store,draft:profile)}
    }
}

struct ProfileEditor:View {
    @ObservedObject var store:BrowserStore
    @State var draft:LoginProfile
    @State private var sites:[String]=[]
    @State private var loading=true
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("ログイン環境").font(.title2.weight(.semibold))
            TextField("環境の名前",text:$draft.name)
            TextField("アカウントのメモ（例：仕事用・name@example.com）",text:$draft.accountNote)
            Text("保存データがあるサイト").font(.headline)
            if loading {ProgressView()} else if sites.isEmpty {Text("まだ保存データはありません。").foregroundStyle(.secondary)} else {ScrollView{VStack(alignment:.leading){ForEach(sites,id:\.self){Text($0).font(.callout)}}.frame(maxWidth:.infinity,alignment:.leading)}}
            Text("この一覧はサイトデータの存在を示します。現在ログイン中であることや、ログインしているユーザー名を示すものではありません。").font(.caption).foregroundStyle(.secondary)
            HStack {Button("更新"){refresh()};Spacer();Button("キャンセル"){dismiss()}.keyboardShortcut(.cancelAction);Button("保存"){store.updateProfile(draft);dismiss()}.disabled(draft.name.isEmpty).keyboardShortcut(.defaultAction)}
        }.padding(24).frame(width:500,height:370).onAppear{refresh()}
    }
    private func refresh(){loading=true;store.dataStore(draft.id).fetchDataRecords(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes()){records in sites=Array(Set(records.map(\.displayName))).sorted();loading=false}}
}

extension BrowserStore {
    func exportSettings(){
        let panel=NSSavePanel();panel.nameFieldStringValue="WorkspaceTabs-browser.json";panel.allowedContentTypes=[.json]
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            var icons:[String:Data]=[:]
            for w in session.workspaces {if let file=w.iconFile,file == URL(fileURLWithPath:file).lastPathComponent {icons[file]=try? Data(contentsOf:directory.appendingPathComponent("Icons").appendingPathComponent(file))}}
            for link in favorites {if let file=link.iconFile,file == URL(fileURLWithPath:file).lastPathComponent {icons[file]=try? Data(contentsOf:directory.appendingPathComponent("Icons").appendingPathComponent(file))}}
            let backup=BrowserBackup(session:session,icons:icons)
            try JSONEncoder().encode(backup).write(to:url,options:.atomic)
        } catch {self.error=error.localizedDescription}
    }
    func importSettings(){
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            let data=try Data(contentsOf:url);guard data.count<30_000_000 else{throw BrowserSessionError.invalid}
            let backup=try JSONDecoder().decode(BrowserBackup.self,from:data);_ = try backup.session.validated()
            var importedProfiles:[LoginProfile]=[], importedWorkspaces:[BrowserWorkspace]=[]
            var profileMap:[UUID:UUID]=[:], workspaceMap:[UUID:UUID]=[:]
            for profile in backup.session.profiles {var copy=profile;copy.id=UUID();profileMap[profile.id]=copy.id;importedProfiles.append(copy)}
            let icons=directory.appendingPathComponent("Icons");try FileManager.default.createDirectory(at:icons,withIntermediateDirectories:true)
            for workspace in backup.session.workspaces {
                var copy=workspace;copy.id=UUID();workspaceMap[workspace.id]=copy.id;copy.profileID=profileMap[workspace.profileID]!
                copy.pages=workspace.pages.map{page in var page=page;page.id=UUID();return page};copy.selectedPageID=copy.pages.first?.id
                if let name=workspace.iconFile,let imageData=backup.icons[name],imageData.count<2_000_000,NSImage(data:imageData) != nil {let new=UUID().uuidString+".png";try imageData.write(to:icons.appendingPathComponent(new));copy.iconFile=new}else{copy.iconFile=nil}
                importedWorkspaces.append(copy)
            }
            var importedFavorites: [FavoriteLink] = []
            for link in backup.session.favorites ?? [] {
                var copy=link;copy.id=UUID();copy.workspaceID=workspaceMap[link.workspaceID] ?? UUID();copy.notionSourceID=nil;copy.notionPageID=nil;copy.notionEditedTime=nil;copy.importKey=nil
                if let name=link.iconFile,let imageData=backup.icons[name],imageData.count<2_000_000,NSImage(data:imageData) != nil {let new=UUID().uuidString+".png";try imageData.write(to:icons.appendingPathComponent(new));copy.iconFile=new}else{copy.iconFile=nil}
                importedFavorites.append(copy)
            }
            session.favorites = favorites + importedFavorites
            session.profiles.append(contentsOf:importedProfiles);session.workspaces.append(contentsOf:importedWorkspaces)
            if session.selectedWorkspaceID == nil {session.selectedWorkspaceID=session.workspaces.first?.id};changed()
        }catch{self.error=error.localizedDescription}
    }
}
struct BrowserBackup:Codable {var session:BrowserSession;var icons:[String:Data]}
