import SwiftUI

struct HelpTopic:Identifiable {
    let id:String
    let category:String
    let icon:String
    let title:String
    let summary:String
    let steps:[String]
    var shortcut:String? = nil
    func matches(_ query:String)->Bool {
        let terms=query.split(whereSeparator:{$0.isWhitespace})
        let text=([title,summary,category]+steps).joined(separator:" ")
        return terms.allSatisfy{text.localizedStandardContains(String($0))}
    }
}
enum HelpCatalog {
    static let categories=["すべて","タブ","お気に入り","設定・保存","ショートカット"]
    static let topics:[HelpTopic]=[
        .init(id:"apps",category:"タブ",icon:"square.stack",title:"ログイン環境を分ける",summary:"仕事用・個人用のNotionを分けて開く。",steps:["左の＋からアプリタブを追加します。","アプリタブごとにログイン環境を作れます。同じ環境を選んだアプリタブはログイン状態を共有します。","名前・色・ホームURLはアプリタブを右クリックして編集できます。"]),
        .init(id:"groups",category:"タブ",icon:"folder",title:"タブグループ",summary:"Notionと外部ツールをまとめて整理。",steps:["ブラウザタブ列の左端にあるグループ名の選択欄 →「新しいグループ…」で作成します。","タブを右クリック →「グループへ移動」で所属を変更します。＋は表示中のグループへ追加します。","グループ選択欄のメニュー、またはブラウザタブ列の上下スクロールで切り替えます。ページ内やサイドバーのスクロールは対象外です。","グループを選んだだけではページは変わりません。タブをクリックすると切り替わります。左右スクロールは長いタブ列の移動に使います。","「グループを編集…」から名前とアイコンを変えられます。画像またはNotionのプリセットを選べます。グループ削除時はタブを閉じず、先頭グループに戻します。"]),
        .init(id:"reorder",category:"タブ",icon:"hand.draw",title:"タブを並べ替える",summary:"名前やアイコンをドラッグして移動。",steps:["移動したいタブの名前・アイコンをドラッグします。","相手の左半分に落とすと前へ、右半分なら後ろへ移動します。","ブラウザタブは同じグループ内で並べ替えます。ピン留めタブと通常タブはそれぞれの中で移動します。サイドバーのアプリタブも並べ替えできます。","順番は自動保存されます。"]),
        .init(id:"icons",category:"タブ",icon:"photo",title:"名前・アイコン・ピン留め",summary:"プリセット・画像・絵文字を設定できます。",steps:["ブラウザタブは右クリック →「表示名・アイコンを編集…」を開きます。アプリタブ・グループ・お気に入りも、それぞれの編集画面から同じアイコン選択を使えます。","「プリセット…」で885個のNotionアイコンを検索・カテゴリから選べます。プリセットは文字と同じ色で表示します。「画像…」ではPNG・JPEG・HEICを設定できます。アプリ内へコピーするので元ファイルを移動しても残ります。","画像・プリセット → 絵文字 → サイトのfaviconの順で表示します。「解除」で元に戻せます。","ピン留めはグループの左端に表示します。初期値はアイコンのみで、名前付きにも変更できます。閉じるときはピン留めを解除してください。"]),
        .init(id:"search",category:"タブ",icon:"magnifyingglass",title:"すべてのタブを探す",summary:"アプリタブをまたいで検索・移動。",steps:["サイドバーの検索ボタンから全タブを開きます。","↑↓で選び、Enterで移動。⌘Fで名前・URLを検索します。","右クリックからSplit Viewにも開けます。"],shortcut:"search"),
        .init(id:"split",category:"タブ",icon:"rectangle.split.2x1",title:"2つのページを並べる",summary:"別のアプリタブ同士でもSplit View。",steps:["ブラウザタブ列の分割ボタンから並べたいタブを選びます。","境界をドラッグして幅を調整できます。右側のボタンで左右を入れ替えたり解除できます。","URLコピー・再読み込みなどの操作は、最後に操作した側が対象です。"]),
        .init(id:"detach",category:"タブ",icon:"macwindow.on.rectangle",title:"別ウインドウに切り離す",summary:"アプリタブを一時的に独立させる。",steps:["アプリタブを右クリック →「別ウインドウに切り離す」を選びます。","「元に戻す」またはウインドウを閉じると戻ります。ログインやページの状態は保持します。","再起動時には元のウインドウへ戻します。"]),
        .init(id:"new-tab",category:"タブ",icon:"plus",title:"新しいタブで検索",summary:"Notion、URL、Google検索を選べます。",steps:["⌘Tまたはタブ列の＋で選択画面を開きます。←でNotion、→でURL・検索のタブをすぐに作成します。各カードのクリックでも開けます。Escでキャンセルできます。","Notionを選ぶと、この環境のHome URLを開けます。","URL・Google検索ではURLを入力すると直接開き、キーワードならGoogle検索します。Enterで開きます。"],shortcut:"new"),
        .init(id:"notion",category:"タブ",icon:"sparkles",title:"Notionの新規ページ・AI",summary:"ページ・AI・会議・データベースを新しいタブで。",steps:["Notionを表示中に⌘⇧Nで、マウスカーソル付近に作成メニューを開きます。↑↓＋Enter、数字の1〜5、またはクリックで選べます。Escで閉じます。","新規ページ・AIチャット・ミーティングノート・データベース・カスタムページは新しいブラウザタブで開きます。データベースとカスタムページはNotionに作成ボタンがある場合に利用できます。録音は自動開始しません。","Notion内の検索と設定は現在のタブで開きます。","Notionの画面や権限によって操作できない場合は通知します。メニューのキーは設定 → ショートカットで変更できます。"],shortcut:"notionCreateMenu"),
        .init(id:"workspace",category:"設定・保存",icon:"arrow.triangle.branch",title:"Notionのワークスペース判定",summary:"Workspace IDとホームURLを設定。",steps:["アプリタブを右クリック → 編集 →「現在のNotionページから設定」を使います。","Home URLには対象ワークスペースの通常ページを指定するのがおすすめです。","IDが一致する環境へ自動で振り分けます。判定できない場合や候補が複数の場合は勝手に切り替えません。","ページ作成直前にも照合します。不一致や判定不能の場合は作成を止めます。"]),
        .init(id:"favorite",category:"お気に入り",icon:"star",title:"お気に入りを開く",summary:"カテゴリを選んで、↑↓とEnterですぐ開く。",steps:["サイドバーの星から開きます。最初からリストを選択しているので、↑↓とEnterで操作できます。","←→でカテゴリを切り替えます。検索は検索欄をクリック、または⌘Fで開始します。","同じアプリタブに同じURLがあれば再利用します。右クリックから別タブにも開けます。"],shortcut:"favorites"),
        .init(id:"favorite-edit",category:"お気に入り",icon:"pencil",title:"お気に入りを登録する",summary:"URL・アイコン・開く環境をまとめて保存。",steps:["お気に入りの「追加…」、またはURLバーの星から登録します。","名前・URL・カテゴリ・アイコン・開くアプリタブを設定します。","カテゴリ内はピン留め、Order、名前の順に並びます。"]),
        .init(id:"notion-sync",category:"お気に入り",icon:"cloud",title:"Notionでお気に入りを管理",summary:"内蔵保存が標準。Notion接続は任意です。",steps:["設定 → Notion保存 → 接続を管理でPATとデータベースURLを登録します。PATはキーチェーンに保存します。","新規セットアップでは作成先を確認してから必要なデータベースを作ります。同期は約1時間ごとです。","Categoriesのテキスト型Workspace IDと、アプリタブのNotion Workspace IDで照合します。IDが空ならCategory名で照合します。","IDが不正・一致なし・複数一致なら開きません。名前も複数一致なら停止します。一致なしの場合は登録済みの開く先を使います。","競合は設定 → Notion保存の「送信待ち・競合」で確認します。Notion保存のリンクを削除すると、元のページもゴミ箱へ移ります。"]),
        .init(id:"color",category:"設定・保存",icon:"paintpalette",title:"見た目とサイドバーの色",summary:"ライト・ダーク・システムに対応。",steps:["新しい環境の初期色はグレーです。色プリセットはグレー・青・紫・ローズ・アンバー・緑の順です。設定 → 表示でテーマとサイドバーの位置・表示方法を選びます。","アプリタブの編集で色や文字色を変更できます。Notionのサイドバー着色はトグルで切り替えます。","濃さはスライダーまたは数値入力で調整します。組織コンソールの左列も同じ設定で着色します。"]),
        .init(id:"save",category:"設定・保存",icon:"externaldrive",title:"保存・復元・バックアップ",summary:"タブやグループは自動保存します。",steps:["開いているタブ・グループ・アイコン・ログイン環境・Split Viewを保存し、次回起動時に戻します。","未送信の入力内容とSplitの幅は復元対象外です。","現在状態は変更時に自動保存します。復元履歴は通常5分間隔で、設定の読み込み・復元前にも残します。同じ状態の履歴は重複させません。設定 → バックアップから直近20件を復元できます。","Notionへのタブバックアップは任意です。Cookie・PAT・アカウントのメモは含まれず、別のMacでは再ログインが必要です。","設定ファイルが壊れた場合は正常なバックアップから復旧し、元ファイルをRecoveryフォルダへ保管します。"]),
        .init(id:"loading",category:"設定・保存",icon:"rectangle.dashed",title:"読み込み中の表示",summary:"再読み込み中はシマーと案内を表示。",steps:["再起動・ページの再読み込み・Webページ処理の復旧中は、標準の読み込み画面が描画されるまではシマーを表示し、その後はサイト側の表示を使います。","下部の「読み込み直しています」が消えたら、実際のページを操作できます。読み込みに失敗したら「再試行」で開き直せます。HTTP 504は接続先の応答待ち、503などは接続先のサーバーエラーとして案内します。時間をおいて再試行してください。","ページのスクリーンショットは撮影・保存しません。旧バージョンが保存したページの画像だけを起動時に削除します。タブのURLやログイン環境は引き続き保存します。","通常のタブ切り替えではページを保持し、自動タブ破棄は行いません。"]),
        .init(id:"worksets",category:"設定・保存",icon:"square.grid.2x2",title:"作業セットと診断",summary:"よく使う組み合わせを保存。",steps:["設定 → 作業で作業セットを保存・復元できます。現在のタブを残したまま開きます。","同じ画面で重複タブを確認できます。","設定 → 診断では直近200件の処理時間を確認・CSV出力できます。"]),
        .init(id:"raycast",category:"ショートカット",icon:"arrow.up.forward.app",title:"Raycastから操作",summary:"お気に入り・タブ検索・Notion操作を呼び出す。",steps:["Workspace Tabs拡張のSearch Favorites、Search All Tabs、Switch App Tabから検索します。","Run Commandでは実行するアプリタブを選べます。作業セットも呼び出せます。","Raycast側でホットキーやAliasを設定できます。ログイン情報やPATは渡しません。"]),
        .init(id:"workspace-keys",category:"ショートカット",icon:"command",title:"アプリタブの切り替えキーを見る",summary:"修飾キーの長押しで切り替え先を表示。",steps:["⌘、または設定したアプリタブ切り替え用の修飾キーを約0.5秒長押しします。","先頭9個のアプリタブにキーを表示します。数字との組み合わせは設定 → ショートカットの指定に従います。⌘を押すだけで割り当ては変わりません。","キーを離すと消えます。通常のキー操作・クリック・スクロール中や設定画面では表示しません。自動収納のサイドバーは表示中だけ展開します。"]),
        .init(id:"custom-keys",category:"ショートカット",icon:"keyboard",title:"ショートカットを変更",summary:"同時押し・連続入力を記録して登録。",steps:["設定 → ショートカットの「記録」を押して入力します。","同時押しと最大4回の連続入力に対応します。連続入力は各1.2秒以内に続けます。","各行のリセットで、その操作だけ初期値に戻せます。数字キーとの組み合わせも設定できます。","アプリタブの番号切替と検索は他アプリ使用中にも有効です。グローバルな連続入力は修飾キーのみで、アクセシビリティ許可が必要です。"]),
        .init(id:"link-routing",category:"設定・保存",icon:"arrow.triangle.branch",title:"Notionリンクを受け取る",summary:"OSで開いたNotionリンクをこのアプリへ。",steps:["設定 → リンクの受け取りを開きます。初期状態ではOSの設定を変更しません。","オンにするとWorkspace TabsがこのMacの既定のブラウザになります。app.notion.com・app.dev.notion.com・notion.so・www.notion.soのHTTPSリンクはこのアプリで開き、それ以外のWebリンクは元のブラウザへ渡します。","オフにすると元のブラウザへ戻します。別のブラウザを自分で既定にした場合は、その選択を上書きしません。","Notionリンクの開き先を一意に決められない場合は、アプリタブを選びます。サイト側が専用アプリを直接指定したリンクには対応できない場合があります。"]),
        .init(id:"url",category:"ショートカット",icon:"link",title:"URLを表示・コピー",summary:"URLバーは必要なときだけ表示。",steps:["リンクボタンまたはURL表示ショートカットで開きます。Escで閉じます。","URLコピーの初期値は⌘⇧Cです。完了すると小さな通知を表示します。","ページ内リンクの⌘クリックで、同じ環境・グループの新しいタブへ開きます。"],shortcut:"copyURL"),
        .init(id:"recent",category:"ショートカット",icon:"clock",title:"最近使ったタブへ",summary:"アプリタブをまたいで素早く戻る。",steps:["初期値は⌃Tabです。修飾キーを押したままTabで次、Shift+Tabで前へ進みます。","修飾キーを離すかEnterで決定、Escでキャンセルします。","終了はアプリメニューから。確認後にタブを保存して終了します。"],shortcut:"recentTabs")
    ]
}

struct BrowserHelp:View {
    @ObservedObject var store:BrowserStore
    @ObservedObject private var preferences=ShortcutPreferences.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query=""
    @State private var category="すべて"
    @State private var detail:HelpTopic?
    @State private var guide=false
    @FocusState private var searchFocused:Bool
    private var results:[HelpTopic] {HelpCatalog.topics.filter{(category == "すべて" || $0.category == category) && $0.matches(query)}}
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:12) {
                Image(systemName:"questionmark.circle").font(.system(size:26)).foregroundStyle(.secondary)
                VStack(alignment:.leading,spacing:3) {Text("ヘルプ").font(.title2.bold());Text("知りたい操作を検索").font(.callout).foregroundStyle(.secondary)}
                Spacer()
                Button("はじめに") {guide=true}
                Button {dismiss()} label:{Image(systemName:"xmark").frame(width:24,height:24)}.buttonStyle(.plain).keyboardShortcut(.cancelAction).help("閉じる")
            }
            HStack {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("タブ、画像、Notion、ショートカット…",text:$query).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("ヘルプを検索")
                if !query.isEmpty {Button {query=""} label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).help("検索をクリア")}
            }.padding(12).background(.background.opacity(0.6),in:RoundedRectangle(cornerRadius:12))
            Picker("カテゴリ",selection:$category) {ForEach(HelpCatalog.categories,id:\.self){Text($0).tag($0)}}.pickerStyle(.segmented)
            ScrollView {
                if results.isEmpty {
                    VStack(spacing:10) {Image(systemName:"magnifyingglass").font(.largeTitle);Text("見つかりませんでした").font(.headline);Text("別の言葉で検索するか、カテゴリを「すべて」にしてください。").foregroundStyle(.secondary)}.padding(40).frame(maxWidth:.infinity)
                } else {
                    LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12) {
                        ForEach(results) {topic in
                            Button {detail=topic} label:{
                                VStack(alignment:.leading,spacing:9) {
                                    HStack {Image(systemName:topic.icon).font(.system(size:19)).foregroundStyle(Color.accentColor);Spacer();Image(systemName:"arrow.up.right").font(.caption).foregroundStyle(.tertiary)}
                                    Text(topic.title).font(.headline).foregroundStyle(.primary)
                                    Text(topic.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth:.infinity,minHeight:104,alignment:.topLeading).padding(16)
                                    .background(.background.opacity(0.65),in:RoundedRectangle(cornerRadius:16))
                                    .overlay(RoundedRectangle(cornerRadius:16).strokeBorder(.primary.opacity(0.07)))
                                    .contentShape(RoundedRectangle(cornerRadius:16))
                            }.buttonStyle(.plain).accessibilityLabel(topic.title+"。"+topic.summary)
                        }
                    }
                }
                if category == "ショートカット" || !query.isEmpty {
                    shortcutList.padding(.top,16)
                }
            }
            Text("⌘Fで検索 · Escで閉じる").font(.caption).foregroundStyle(.secondary)
            Button("") {searchFocused=true}.keyboardShortcut("f",modifiers:.command).hidden().frame(height:0)
        }.padding(24).frame(width:730,height:620).background(.regularMaterial)
            .sheet(item:$detail) {topic in HelpDetail(topic:topic)}
            .sheet(isPresented:$guide) {BrowserOnboarding(store:store,firstRun:false)}
    }
    private var shortcutList:some View {
        let actions=ShortcutPreferences.actions.filter{query.isEmpty || $0.title.localizedStandardContains(query) || preferences.binding($0).label.localizedStandardContains(query)}
        return VStack(alignment:.leading,spacing:0) {
            if !actions.isEmpty {Text("現在のショートカット").font(.headline).padding(.bottom,10)}
            ForEach(actions,id:\.id) {action in
                HStack {Text(action.title);Spacer();Text(preferences.binding(action).label).font(.system(.callout,design:.monospaced)).foregroundStyle(.secondary)}.padding(.vertical,8)
                Divider()
            }
        }.padding(16)
    }
}
private struct HelpDetail:View {
    let topic:HelpTopic
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var preferences=ShortcutPreferences.shared
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Image(systemName:topic.icon).font(.title2).foregroundStyle(Color.accentColor);Text(topic.title).font(.title2.bold());Spacer()}
            Text(topic.summary).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    ForEach(Array(topic.steps.enumerated()),id:\.offset) {index,text in
                        HStack(alignment:.top,spacing:12) {
                            Text("\(index+1)").font(.caption.bold()).frame(width:24,height:24).background(.quaternary,in:Circle())
                            Text(text).font(.callout).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
                        }
                    }
                }
            }
            if let id=topic.shortcut,let action=ShortcutPreferences.actions.first(where:{$0.id == id}) {
                HStack {Text(action.title).foregroundStyle(.secondary);Spacer();Text(preferences.binding(action).label).font(.system(.body,design:.monospaced))}
            }
            HStack {Spacer();Button("戻る") {dismiss()}.keyboardShortcut(.cancelAction)}
        }.padding(24).frame(width:560,height:440)
    }
}
