import SwiftUI

struct BrowserHelp: View {
    @Environment(\.dismiss) private var dismiss
    @State private var section = "features"
    @ObservedObject private var preferences=ShortcutPreferences.shared
    private var shortcuts:[(String,String)] {ShortcutPreferences.actions.map{($0.title,preferences.binding($0).label)} + [("URLバー・モーダルを閉じる","Esc")]}
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "questionmark.circle").font(.title2).foregroundStyle(.secondary)
                Text("使い方とショートカット").font(.title2.weight(.semibold))
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("表示する内容", selection: $section) {
                Text("基本操作").tag("features")
                Text("お気に入り").tag("favorites")
                Text("設定と保存").tag("settings")
                Text("ショートカット").tag("shortcuts")
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if section == "features" {
                        feature("square.stack", "アプリタブとログイン環境", "サイドバーの＋でアプリタブを追加します。各アプリタブの中にブラウザタブを開けます。右クリックの編集から名前・アイコン・色・ログイン環境を変更できます。同じログイン環境を選ぶとログイン状態を共有します。")
                        feature("arrow.left.arrow.right", "アプリタブをキーで切り替え", "\(key("previousWorkspace"))で前、\(key("nextWorkspace"))で次のアプリタブへ移動します。端まで進むと反対側へ回ります。番号指定の初期値は⌃⌥1〜9で、サイドバーの並び順に対応し、他アプリの使用中も有効です。変更後のキーは「ショートカット」で確認できます。")
                        feature("magnifyingglass", "すべてのタブを横断して探す", "\(key("search"))で全アプリタブのブラウザタブを一覧表示します。↑↓とEnterで移動し、⌘Fでアプリ名・ページ名・URLを検索できます。右クリックでSplit Viewにも開けます。")
                        feature("arrow.up.forward.app", "Raycastから呼び出す", "Workspace Tabs拡張のSearch Favorites・Search All Tabs・Switch App Tabで検索してEnterで開けます。Run Commandでは実行先のアプリタブを選べます。Notion操作とお気に入りランチャーは独立したコマンドにもなっており、Raycast側でホットキーやAliasを設定できます。一覧は自動更新され、ログイン情報やPATはRaycastに渡しません。")
                        feature("command", "コマンドとNotionの操作", "\(key("commands"))で操作を検索して実行できます。Notionの新しいAIチャット・新規ページ・ミーティングノート・検索にも対応します。表示中のNotionのボタンを操作するため、画面構成や権限によって実行できない場合は通知します。ミーティングの録音は自動開始しません。キーは設定で変更できます。")
                        feature("hand.draw", "タブの並べ替え", "アプリタブと上部のブラウザタブは、名前やアイコンをドラッグして並べ替えできます。相手の前半に落とすと前、後半に落とすと後ろへ移動します。ブラウザタブは同じアプリタブ内で、ピン留め／通常のそれぞれの中で移動できます。順番は保存されます。")
                        feature("pin", "ブラウザタブのピン留め", "ブラウザタブを右クリック →「タブをピン留め」で左端にまとめます。既定はアイコンのみです。右クリックから「アイコンと名前」に切り替えたり、表示名・アイコンを編集できます。ピン留め中は閉じる操作を防ぎます。")
                        feature("rectangle.split.2x1", "別のアプリタブとSplit View", "ページ上部の分割ボタンで、並べたいブラウザタブを選びます。アプリタブの右クリック →「右側に並べて表示」でも開けます。境界をドラッグして幅を調整し、右上で左右入替・解除ができます。")
                        feature("macwindow.on.rectangle", "アプリタブを一時的に切り離す", "アプリタブを右クリック →「別ウインドウに切り離す」で、その中のブラウザタブをまとめて別ウインドウへ移します。ページとログイン状態はそのままです。「元に戻す」またはウインドウの閉じるボタンで戻せます。再起動時はすべて元の画面に戻ります。")
                        feature("link", "URLの表示とコピー", "URLバーは普段は非表示です。\(key("location"))またはリンクボタンで開き、Escで閉じます。\(key("copyURL"))で現在のURLをコピーできます。完了は短い通知でお知らせします。")
                        feature("arrow.triangle.branch", "Notionのワークスペース振り分け", "アプリタブを右クリック → 編集 →「現在のNotionページから設定」でワークスペースIDとホームURLを登録します。自動振り分けを有効にして保存すると、判定できるリンクを対応するアプリタブで開きます。判定できない場合や候補が複数の場合は切り替えません。")
                    } else if section == "favorites" {
                        feature("star", "お気に入りを開く", "サイドバーの星、または\(key("favorites"))で開きます。先頭行が選択されるので、そのまま上下キーで移動し、Enterで開けます。検索欄をクリックすると検索できます。Escで閉じます。")
                        feature("pencil", "登録と編集", "「追加…」またはURLバーの星から、URL・名前・アイコン・カテゴリ・開くアプリタブを登録できます。鉛筆ボタンで編集し、右クリックでピン留めできます。開く先が未設定のリンクは、編集からアプリタブを選んでください。")
                        feature("person.crop.circle", "開くログイン環境", "お気に入りは指定したアプリタブのログイン環境で開きます。同じURLがそのアプリタブ内にあれば、既存のブラウザタブへ切り替えます。右クリックの「新しいブラウザタブで開く」で別タブにも開けます。")
                        feature("keyboard", "数字キーでアプリタブを選ぶ", "設定 → ショートカット → 数字でアプリタブを開くで、⌘・⌃・⌥・⇧を選択し「適用」を押します。1〜9はタブの並び順に対応します。このグループだけ初期値にも戻せます。")
                        feature("link", "リンクを新しいタブで開く", "ページ内のリンクを⌘＋クリックすると、同じアプリタブのログイン環境で新しいブラウザタブを開きます。")
                        feature("cloud", "Notionで管理する", "初期値は内蔵保存です。設定 → Notion保存で接続・同期を有効にすると、Notion宛てのお気に入りを1時間ごとに同期します。新規登録時は保存先を選べます。Notion側では名前・URL・カテゴリ・Pinned・Orderを編集できます。Categoriesにテキスト型「Workspace ID」を追加すると、アプリタブのNotion Workspace IDで照合します。IDが未設定の場合はCategory名で照合します。ID指定時に一致なし・複数一致・不正なIDなら開きません。同名タブが複数なら開かず、一致なしなら指定済みの開く先を使います。画像アイコンはこのMacに保持し、絵文字はNotionにも保存します。")
                        feature("exclamationmark.arrow.triangle.2.circlepath", "通信エラーと編集の競合", "送信待ちの変更はこのMacに残ります。Notion側でも変更された場合は上書きを停止します。設定 → Notion保存の「送信待ち・競合」で再試行やNotion側の内容の採用ができます。Notionのリンクを削除すると、元のページもゴミ箱に移動します。")
                    } else if section == "settings" {
                        feature("paintpalette", "見た目とNotionの色", "設定 → 表示でテーマ、タブの位置、サイドバーの表示方法を選べます。アプリタブの編集では色・文字色・Notionサイドバーの着色を設定できます。濃さはスライダーでも数値入力でも調整できます。")
                        feature("keyboard", "ショートカットを変更", "設定 → ショートカットの「記録」を押し、使いたいキーを入力して「登録」します。同時押しと、⌘ → ⌘など最大4回の連続入力に対応します。各入力は1.2秒以内に続けてください。各行の矢印ボタンで、その操作だけ初期値に戻せます。重複する入力は登録できません。")
                        feature("key", "連続入力とグローバル操作", "番号指定のアプリタブ切替と検索は、他アプリの使用中も使えます。これらに登録する連続入力は修飾キーのみ対応し、アクセシビリティ許可が必要です。前／次の切替など他の操作は、Workspace Tabsの使用中に有効です。")
                        feature("externaldrive", "このMacへの保存", "タブ・URL・選択状態・ログイン環境・Split Viewは自動保存し、再起動時に復元します。ホームURLは新しいタブの開始先です。設定 → バックアップでファイルへ書き出し・読み込みができます。未送信の入力内容やSplitの幅は復元対象外です。")
                        feature("cloud", "Notionの接続", "設定 → Notion保存 →「接続を管理…」から、PATと既存DBのURLを登録できます。「新しく作成」ではPATの所有者と作成先を確認し、プライベートに必要なDBを作成します。PATの更新も同じ画面から行えます。PATはこのMacのキーチェーンに保存します。")
                        feature("arrow.counterclockwise", "タブをNotionへバックアップ", "設定 → Notion保存 →「タブのバックアップ」を開きます。アプリタブの設定と、任意で開いているブラウザタブもMacごとに保存できます。復元は手動で、現在のタブを置き換えます。Cookie・PAT・アカウントのメモは含まれず、別のMacでは再ログインが必要です。")
                        feature("power", "終了", "アプリのメニューから終了するか、\(key("quit"))を押します。確認後に現在のタブを保存して終了します。")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(shortcuts, id: \.0) { item in
                                HStack {
                                    Text(item.0)
                                    Spacer()
                                    Text(item.1).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                                }.padding(.vertical, 9)
                                Divider()
                            }
                        }
                        Text("⌘はCommand、⌥はOption、⌃はControl、⇧はShiftです。Split ViewではURLコピー・URL入力・タブ追加／終了・再読み込みは最後に操作した側が対象です。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4).padding(.trailing, 10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 600, height: 580)
    }
    private func key(_ id:String)->String {
        guard let action=ShortcutPreferences.actions.first(where:{$0.id == id}) else{return ""}
        return preferences.binding(action).label
    }
    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
