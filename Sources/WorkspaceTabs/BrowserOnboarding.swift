import SwiftUI
import WorkspaceCore

struct BrowserOnboarding:View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store:BrowserStore
    let firstRun:Bool
    @Environment(\.dismiss) private var dismiss
    @State private var step=0
    @State private var name="Notion"
    @State private var homeURL="https://app.notion.com"
    @State private var color="gray"
    @State private var sidebar="icons"
    @State private var theme="system"
    @State private var previewGroup=0
    @State private var previewPage=0
    private var titles:[String] { [L("使う環境を決める"),L("見た目を選ぶ"),L("タブの使い方")] }
    private var valid:Bool {!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && BrowserAddress.url(homeURL) != nil}
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack {
                Text(firstRun ? L("Workspace Tabsをはじめる"):L("はじめに")).font(.title2.bold())
                Spacer()
                Text("\(step+1) / 4").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing:8) {ForEach(0..<4) {i in Capsule().fill(i<=step ? Color.accentColor:Color.secondary.opacity(0.18)).frame(height:4)}}
            HStack(alignment:.top,spacing:28) {
                VStack(alignment:.leading,spacing:16) {
                    Text(step == 0 ? L("言語を選ぶ") : titles[step-1]).font(.title3.bold())
                    if step == 0 {languageStep}
                    else if step == 1 {environmentStep}
                    else if step == 2 {appearanceStep}
                    else {tabsStep}
                    Spacer(minLength:0)
                }.frame(width:310)
                preview.frame(width:280,height:320)
            }.frame(height:340)
            Divider()
            HStack {
                Button(firstRun ? L("あとで設定"):L("閉じる")) {dismiss()}.keyboardShortcut(.cancelAction)
                Spacer()
                if step>0 {Button(L("戻る")) {step-=1}}
                Button(step == 3 ? (firstRun ? L("はじめる"):L("完了")):L("次へ")) {
                    if step<3 {step+=1} else {finish()}
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(firstRun && step > 0 && !valid)
            }
        }.padding(28).frame(width:690).background(.regularMaterial)
            .onAppear {
                if let w=store.selected {name=w.name;homeURL=w.homeURL;color=w.color}
                sidebar=store.session.sidebarMode;theme=store.session.theme
            }
    }
    private var languageStep:some View {
        VStack(alignment:.leading,spacing:20) {
            Text("日本語 · English · 한국어").font(.title3)
            LanguagePicker().pickerStyle(.radioGroup)
            Text(L("アプリの表示言語を変更します。Webサイトの言語は変更しません。")).font(.callout).foregroundStyle(.secondary)
            Text(L("あとから設定 → 表示で変更できます。")).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var environmentStep:some View {
        Text(L("アプリタブごとにログイン環境を分けられます。仕事用と個人用のNotionも、同時に開けます。")).font(.callout).foregroundStyle(.secondary)
        if firstRun {
            TextField(L("アプリタブの名前"),text:$name).textFieldStyle(.roundedBorder)
            TextField(L("ホームURL"),text:$homeURL).textFieldStyle(.roundedBorder)
            Text(L("特定のワークスペースを使う場合は、その中の通常ページのURLがおすすめです。")).font(.caption).foregroundStyle(.secondary)
            if !valid {Text(L("名前と有効なURLを入力してください。")).font(.caption).foregroundStyle(.red)}
        } else {
            guideLine("plus",L("サイドバーの＋で環境を追加"))
            guideLine("person.crop.circle",L("各環境でNotionにログイン"))
            guideLine("link",L("編集画面でHome URLとWorkspace IDを設定"))
        }
        Text(L("ログインはセットアップ後、ページ上で行います。パスワードやPATの入力はここでは不要です。")).font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private var appearanceStep:some View {
        Text(L("色とサイドバーを選ぶと、開いている環境を見分けやすくなります。")).font(.callout).foregroundStyle(.secondary)
        HStack {ForEach(Palette.names,id:\.self) {value in
            Button {color=value} label:{
                Circle().fill(Palette.color(value)).frame(width:29,height:29)
                    .overlay {if color == value {Image(systemName:"checkmark").font(.caption.bold()).foregroundStyle(Palette.ink(value))}}
            }.buttonStyle(.plain).accessibilityLabel(value).accessibilityAddTraits(color == value ? .isSelected:[])
        }}
        Picker(L("サイドバー"),selection:$sidebar) {
            Text(L("アイコン")).tag("icons");Text(L("名前付き")).tag("full");Text(L("ホバー")).tag("hover")
        }.pickerStyle(.segmented)
        Picker(L("テーマ"),selection:$theme) {
            Text(L("システム")).tag("system");Text(L("ライト")).tag("light");Text(L("ダーク")).tag("dark")
        }.pickerStyle(.segmented)
        Text(firstRun ? L("この設定は「はじめる」を押すと保存されます。あとから設定画面でも変更できます。"):L("ここはプレビューです。実際の変更は「設定 → 表示」とアプリタブの編集から行えます。")).font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private var tabsStep:some View {
        Text(L("グループとページの切り替えは別の操作です。右のプレビューで試せます。")).font(.callout).foregroundStyle(.secondary)
        guideLine("folder",L("グループ名で表示するタブ列を選ぶ"))
        guideLine("cursorarrow",L("タブをクリックするとページが切り替わる"))
        guideLine("hand.draw",L("タブをドラッグして並べ替え"))
        guideLine("magnifyingglass",L("全タブ検索で環境をまたいで移動"))
        Text(L("グループ切り替えの上下スクロールは、ブラウザタブ列の内側だけ。ページ内は通常どおりスクロールできます。")).font(.caption).foregroundStyle(.secondary)
    }
    private func guideLine(_ icon:String,_ text:String)->some View {
        HStack(alignment:.top,spacing:9) {Image(systemName:icon).frame(width:18).foregroundStyle(Color.accentColor);Text(text).font(.callout)}
    }
    private var preview:some View {
        VStack(spacing:0) {
            HStack(spacing:5) {ForEach(0..<3) {_ in Circle().fill(.secondary.opacity(0.3)).frame(width:7,height:7)};Spacer();Text(L("プレビュー")).font(.caption2).foregroundStyle(.secondary)}.padding(12)
            HStack(spacing:0) {
                VStack(spacing:12) {
                    Image(systemName:"square.stack").padding(.top,12)
                    Image(systemName:"doc.text").frame(width:30,height:30).background(.white.opacity(0.25),in:RoundedRectangle(cornerRadius:7))
                    if sidebar == "full" {Text(name).font(.caption).lineLimit(1)}
                    Spacer()
                    Image(systemName:"plus").padding(.bottom,12)
                }.frame(width:sidebar == "full" ? 78:42).foregroundStyle(Palette.ink(color)).background(Palette.color(color))
                VStack(spacing:0) {
                    HStack(spacing:5) {
                        Button(previewGroup == 0 ? "Notion":L("外部ツール")) {previewGroup=1-previewGroup}
                            .font(.caption2.bold()).padding(5).background(.white.opacity(0.25),in:Capsule())
                            .accessibilityLabel(L("プレビューのグループを切り替える"))
                        Button {previewPage=previewGroup} label:{Image(systemName:previewGroup == 0 ? "doc.text":"globe");Text(previewGroup == 0 ? L("ページ"):L("ツール")).font(.caption2)}
                            .accessibilityLabel(L("プレビューのタブを開く"))
                        Spacer(minLength:0)
                    }.padding(7).buttonStyle(.plain).foregroundStyle(Palette.ink(color)).background(Palette.color(color))
                    VStack(alignment:.leading,spacing:12) {
                        Image(systemName:previewPage == 0 ? "doc.text":"globe").font(.title)
                        Text(previewPage == 0 ? L("Notionのページ"):L("外部ツール")).font(.headline)
                        ForEach(0..<4) {i in RoundedRectangle(cornerRadius:3).fill(.secondary.opacity(0.12)).frame(width:i == 3 ? 80:nil,height:7)}
                        Spacer()
                    }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
                        .foregroundStyle(theme == "dark" ? Color.white:Color.black)
                        .background(theme == "dark" ? Color(white:0.13):Color.white)
                }
            }
        }.background(.background).clipShape(RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(.primary.opacity(0.10)))
    }
    private func finish() {
        if firstRun {
            guard valid,var workspace=store.selected else{return}
            let changedURL=workspace.homeURL != homeURL
            workspace.name=name.trimmingCharacters(in:.whitespacesAndNewlines)
            workspace.homeURL=BrowserAddress.url(homeURL)!.absoluteString
            workspace.color=color;store.updateWorkspace(workspace)
            store.session.sidebarMode=sidebar;store.session.theme=theme;store.applyTheme();store.changed()
            if changedURL,let pageID=workspace.selectedPageID {store.engine(workspace.id,pageID)?.navigate(workspace.homeURL)}
        }
        dismiss()
    }
}
