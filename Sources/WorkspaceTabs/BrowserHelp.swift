import WorkspaceCore
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
        let text=([title,summary,Localization.text(category)]+steps).joined(separator:" ")
        return terms.allSatisfy{text.localizedStandardContains(String($0))}
    }
}
enum HelpCatalog {
    static let categories=["すべて","タブ","お気に入り","設定・保存","ショートカット"]
    static var topics:[HelpTopic] { [
        .init(id:"group-logins",category:"タブ",icon:"person.2",title:L("グループごとにログインを分ける"),summary:L("同じアプリタブで仕事用・個人用を独立。"),steps:[L("グループ選択 →「新しいグループ…」または「グループを編集…」を開きます。"),L("ログイン環境で「新しい環境で独立させる」を選んで保存し、そのグループの新しいタブでログインします。Cookieとサイトデータは別々に保存されます。"),L("「アプリタブと共有」は従来のログインを使います。同じ名前の既存環境を選んだグループ同士はログインを共有します。"),L("別のログイン環境へタブを移動すると読み込み直します。確認でキャンセルすれば、元の入力と環境を保ちます。グループの名前・アイコンだけの変更では再読み込みしません。"),L("ログイン環境が複数あるアプリタブでは、新しいタブでNotionを選ぶと、どのアカウントで開くかを選べます。")]),
        .init(id:"notion-account",category:"タブ",icon:"person.crop.circle",title:L("Notionのログインアカウント"),summary:L("右上に、このタブのユーザー名とアイコンを表示。"),steps:[L("Notionを開くと、ブラウザ右上に現在のアカウントを表示します。マウスを重ねると名前とメールアドレスを確認できます。"),L("アカウントはブラウザタブごとに確認します。設定のアカウントメモからは推測せず、取得できない場合は「アカウント未確認」と表示します。"),L("表示中のタブを定期的に確認し、アカウント情報はメモリ内だけで保持します。Notionの内部仕様変更で取得できなくなる場合があります。"),L("未確認のときは表示に矢印が付きます。クリックすると、ページを読み込み直さずにアカウントを再確認します。"),L("右隣の@ボタンで、このタブのメールアドレスをページ上に大きく表示できます。切り替えはブラウザタブごとに保存します。"),L("アプリタブ内のすべてのNotionタブに表示するには、アプリタブを右クリックして編集画面の「メールアドレスをページ上に大きく表示」をオンにします。@ボタンでタブごとに上書きできます。"),L("表示位置（右下・中央）、文字サイズ、濃さは、アプリタブの編集画面の「表示」タブでアプリタブごとに変えられます。"),L("アカウントは、Notionが表示中のページについて記録しているユーザーを優先して判定します。同じログイン環境で複数のアカウントを使っていても、タブごとに表示が分かれます。")]),
        .init(id:"unified-search",category:"ショートカット",icon:"magnifyingglass",title:L("まとめて検索する"),summary:L("タブ・お気に入り・ファイル・操作を検索"),steps:[L("サイドバーの検索、または全タブ検索のキーから統合検索を開きます。コマンドのキーは操作分類で開きます。"),L("分類をクリック、またはリストで左右キーを押して切り替えます。上下キーで選択し、Enterで実行します。⌘Fで入力欄へ戻ります。"),L("閉じたタブはこの起動中の直近20件が対象です。お気に入り専用の画面も引き続き使えます。")]),
        .init(id:"link-rules",category:"設定・保存",icon:"arrow.triangle.branch",title:L("リンクの自動振り分け"),summary:L("ドメインごとに開く環境とグループを指定。"),steps:[L("設定 → リンクの受け取りから、ドメインと移動先のアプリタブ・グループを登録します。"),L("NotionはWorkspace IDの判定を優先します。候補が重複する場合や移動先がない場合は通知し、別のログイン環境で開きません。")]),
        .init(id:"site-settings",category:"設定・保存",icon:"slider.horizontal.3",title:L("サイト設定"),summary:L("ズーム・マイク・ログイン環境を確認。"),steps:[L("タブ列右端の「…」メニューの「サイト設定」から開きます。ズームとマイク・カメラのブロック設定はサイトとログイン環境ごとに保存します。"),L("表示の変更はページを再読み込みしません。Notionの着色設定は同じアプリタブで共有します。")]),
        .init(id:"safe-startup",category:"設定・保存",icon:"shield.lefthalf.filled",title:L("セーフモード"),summary:L("ページを読み込まずに起動し、原因を確認。"),steps:[L("設定 → 診断で次回のセーフモードを予約できます。起動時にOptionキーを押す方法もあります。"),L("保存済みのタブは残り、「このタブを読み込む」で個別に再開できます。通常の読み込みを再開するとバックグラウンド同期も再開します。")]),

        .init(id:"downloads",category:"設定・保存",icon:"arrow.down.doc",title:L("ファイルをダウンロードする"),summary:L("保存先を選び、元のページで作業を続けます。"),steps:[L("一覧は↑↓で選択し、SpaceでQuick Look、Enterで開く、⌘EnterでFinderに表示します。保存済みファイルは外へドラッグできます。"),L("サイドバーのダウンロードから履歴を開けます。ファイル名をクリックして開くか、フォルダボタンでFinderに表示します。"),L("履歴はこのMacに最大100件保存します。履歴を消してもファイルは削除されません。"),L("ページのダウンロードリンクを開き、保存画面で名前と保存先を選びます。キャンセルしても元のページはそのままです。"),L("元のタブを閉じても転送は続き、完了・失敗を通知します。アプリを終了すると進行中の転送は中止されます。"),L("既存ファイルへの上書きはダウンロード完了後に行います。通信に失敗した場合は元のファイルを残します。")]),
        .init(id:"language",category:"設定・保存",icon:"globe",title:L("表示言語を変更する"),summary:L("日本語・英語・韓国語から選べます。"),steps:[L("初回ガイドの最初、または設定 → 表示 → 言語から選びます。切り替えはすぐ反映され、再起動後も保持されます。"),L("システムはMacの優先言語に従います。対応言語がなければ英語を使います。"),L("言語を変えてもページは再読み込みしません。サイトの言語、ログイン状態、自分で付けた名前は変更しません。macOSの権限確認などはOSの言語設定に従います。")]),
        .init(id:"apps",category:"タブ",icon:"square.stack",title:L("ログイン環境を分ける"),summary:L("仕事用・個人用のNotionを分けて開く。"),steps:[L("左の＋からアプリタブを追加します。"),L("アプリタブごとにログイン環境を作れます。同じ環境を選んだアプリタブはログイン状態を共有します。"),L("名前・色・ホームURLはアプリタブを右クリックして編集できます。"),L("編集画面は「基本」「ログイン」「表示」「Notion」のタブに分かれています。ホームURLとワークスペースIDは「Notion」タブで変更します。")]),
        .init(id:"groups",category:"タブ",icon:"folder",title:L("タブグループ"),summary:L("Notionと外部ツールをまとめて整理。"),steps:[L("ブラウザタブ列の左端にあるグループ名の選択欄 →「新しいグループ…」で作成します。"),L("タブを右クリック →「グループへ移動」で所属を変更します。＋は表示中のグループへ追加します。"),L("グループ選択欄のメニュー、またはブラウザタブ列の上下スクロールで切り替えます。ページ内やサイドバーのスクロールは対象外です。"),L("グループを選んだだけではページは変わりません。タブをクリックすると切り替わります。左右スクロールは長いタブ列の移動に使います。"),L("「グループを編集…」から名前とアイコンを変えられます。画像またはNotionのプリセットを選べます。グループ削除時はタブを閉じず、先頭グループに戻します。")]),
        .init(id:"reorder",category:"タブ",icon:"hand.draw",title:L("タブを並べ替える"),summary:L("名前やアイコンをドラッグして移動。"),steps:[L("移動したいタブの名前・アイコンをドラッグします。"),L("相手の左半分に落とすと前へ、右半分なら後ろへ移動します。"),L("ブラウザタブは同じグループ内で並べ替えます。ピン留めタブと通常タブはそれぞれの中で移動します。サイドバーのアプリタブも並べ替えできます。"),L("順番は自動保存されます。"),L("表示中のタブを閉じると、1つ左のタブに切り替わります。いちばん左のタブを閉じたときは右隣のタブになります。")]),
        .init(id:"icons",category:"タブ",icon:"photo",title:L("名前・アイコン・ピン留め"),summary:L("プリセット・画像・絵文字を設定できます。"),steps:[L("ブラウザタブは右クリック →「表示名・アイコンを編集…」を開きます。アプリタブ・グループ・お気に入りも、それぞれの編集画面から同じアイコン選択を使えます。"),L("「プリセット…」で885個のNotionアイコンを検索・カテゴリから選べます。プリセットは文字と同じ色で表示します。「画像…」ではPNG・JPEG・HEICを設定できます。アプリ内へコピーするので元ファイルを移動しても残ります。"),L("画像・プリセット → 絵文字 → サイトのfaviconの順で表示します。「解除」で元に戻せます。"),L("ピン留めはグループの左端に表示します。初期値はアイコンのみで、名前付きにも変更できます。閉じるときはピン留めを解除してください。")]),
        .init(id:"search",category:"タブ",icon:"magnifyingglass",title:L("すべてのタブを探す"),summary:L("アプリタブをまたいで検索・移動。"),steps:[L("サイドバーの検索ボタンから全タブを開きます。"),L("↑↓で選び、Enterで移動。⌘Fで名前・URLを検索します。"),L("右クリックからSplit Viewにも開けます。")],shortcut:"search"),
        .init(id:"split",category:"タブ",icon:"rectangle.split.2x1",title:L("2つのページを並べる"),summary:L("別のアプリタブ同士でもSplit View。"),steps:[L("タブ列右端の「…」メニューで左右・上下を切り替え、境界をドラッグして比率を調整できます。方向と比率は次回起動と作業セットに引き継ぎます。"),L("タブ列右端の「…」メニューの「別の環境のページを並べて表示」から並べたいタブを選びます。"),L("境界をドラッグして調整し、タブ列右端の「…」メニューで表示位置の入れ替えや解除ができます。"),L("URLコピー・再読み込みなどの操作は、最後に操作した側が対象です。")]),
        .init(id:"detach",category:"タブ",icon:"macwindow.on.rectangle",title:L("別ウインドウに切り離す"),summary:L("アプリタブを一時的に独立させる。"),steps:[L("アプリタブを右クリック →「別ウインドウに切り離す」を選びます。"),L("「元に戻す」またはウインドウを閉じると戻ります。ログインやページの状態は保持します。"),L("再起動時には元のウインドウへ戻します。")]),
        .init(id:"new-tab",category:"タブ",icon:"plus",title:L("新しいタブで検索"),summary:L("Notion、URL、Google検索を選べます。"),steps:[L("⌘Tまたはタブ列の＋で選択画面を開きます。←でNotion、→でURL・検索のタブをすぐに作成します。各カードのクリックでも開けます。Escでキャンセルできます。"),L("Notionを選ぶと、この環境のHome URLを開けます。"),L("URL・Google検索ではURLを入力すると直接開き、キーワードならGoogle検索します。Enterで開きます。"),L("Notionに複数のアカウントでログインしている、またはログイン環境が複数あるアプリタブでは、Notionを選ぶとアカウントの一覧が出ます。数字キーですぐに開くか、↑↓で選んでEnterで開きます。←で前の画面に戻ります。")],shortcut:"new"),
        .init(id:"notion",category:"タブ",icon:"sparkles",title:L("Notionの新規ページ・AI"),summary:L("ページ・AI・会議・データベースを新しいタブで。"),steps:[L("Notionを表示中に⌘⇧Nで、マウスカーソル付近に作成メニューを開きます。↑↓＋Enter、数字の1〜5、またはクリックで選べます。Escで閉じます。"),L("新規ページ・AIチャット・ミーティングノート・データベース・カスタムページは新しいブラウザタブで開きます。データベースとカスタムページはNotionに作成ボタンがある場合に利用できます。録音は自動開始しません。"),L("Notion内の検索と設定は現在のタブで開きます。"),L("Notionの画面や権限によって操作できない場合は通知します。メニューのキーは設定 → ショートカットで変更できます。")],shortcut:"notionCreateMenu"),
        .init(id:"microphone",category:"設定・保存",icon:"mic",title:L("ミーティングノートのマイク"),summary:L("文字起こしが始まらない場合の確認。"),steps:[L("Notion上で文字起こしを開始し、macOSとサイトのマイク確認を許可します。起動時に自動で録音することはありません。"),L("設定 → 診断でマイク権限を確認できます。「macOSのマイク設定を開く」からWorkspace Tabsを許可してください。管理端末で制限されている場合は管理者へ確認します。"),L("権限を変更したらページを再読み込みしてください。反映されない場合は入力内容を保存してアプリを再起動します。"),L("Web版のマイク入力を利用します。Zoomなど別アプリのシステム音声を直接取り込む機能はありません。ヘッドホンで聞いている相手の声は通常マイクに入りません。"),L("許可済みでも失敗する場合は、Notion側のAI利用条件・ページ権限・選択したマイク・ネットワーク接続も確認します。")]),
        .init(id:"workspace",category:"設定・保存",icon:"arrow.triangle.branch",title:L("Notionのワークスペース判定"),summary:L("Workspace IDとホームURLを設定。"),steps:[L("アプリタブを右クリック → 編集 →「現在のNotionページから設定」を使います。"),L("Home URLには対象ワークスペースの通常ページを指定するのがおすすめです。"),L("IDが一致する環境へ自動で振り分けます。判定できない場合や候補が複数の場合は勝手に切り替えません。"),L("ページ作成直前にも照合します。不一致や判定不能の場合は作成を止めます。")]),
        .init(id:"favorite",category:"お気に入り",icon:"star",title:L("お気に入りを開く"),summary:L("カテゴリを選んで、↑↓とEnterですぐ開く。"),steps:[L("サイドバーの星から開きます。最初からリストを選択しているので、↑↓とEnterで操作できます。"),L("←→でカテゴリを切り替えます。検索は検索欄をクリック、または⌘Fで開始します。"),L("同じアプリタブに同じURLがあれば再利用します。右クリックから別タブにも開けます。")],shortcut:"favorites"),
        .init(id:"favorite-edit",category:"お気に入り",icon:"pencil",title:L("お気に入りを登録する"),summary:L("URL・アイコン・開く環境をまとめて保存。"),steps:[L("お気に入りの「追加…」、またはURLバーの星から登録します。"),L("名前・URL・カテゴリ・アイコン・開くアプリタブを設定します。"),L("カテゴリ内はピン留め、Order、名前の順に並びます。")]),
        .init(id:"notion-sync",category:"お気に入り",icon:"cloud",title:L("Notionでお気に入りを管理"),summary:L("内蔵保存が標準。Notion接続は任意です。"),steps:[L("設定 → Notion保存 → 接続を管理でPATとデータベースURLを登録します。PATはキーチェーンに保存します。"),L("新規セットアップでは作成先を確認してから必要なデータベースを作ります。同期は約1時間ごとです。"),L("Categoriesのテキスト型Workspace IDと、アプリタブのNotion Workspace IDで照合します。IDが空ならCategory名で照合します。"),L("IDが不正・一致なし・複数一致なら開きません。名前も複数一致なら停止します。一致なしの場合は登録済みの開く先を使います。"),L("競合は設定 → Notion保存の「送信待ち・競合」で確認します。Notion保存のリンクを削除すると、元のページもゴミ箱へ移ります。")]),
        .init(id:"color",category:"設定・保存",icon:"paintpalette",title:L("見た目とサイドバーの色"),summary:L("ライト・ダーク・システムに対応。"),steps:[L("新しい環境の初期色はグレーです。色プリセットはグレー・青・紫・ローズ・アンバー・緑の順です。設定 → 表示でテーマとサイドバーの位置・表示方法を選びます。"),L("アプリタブの編集で色や文字色を変更できます。Notionのサイドバー着色はトグルで切り替えます。"),L("濃さはスライダーまたは数値入力で調整します。組織コンソールの左列も同じ設定で着色します。")]),
        .init(id:"save",category:"設定・保存",icon:"externaldrive",title:L("保存・復元・バックアップ"),summary:L("タブやグループは自動保存します。"),steps:[L("開いているタブ・グループ・アイコン・ログイン環境・Split Viewを保存し、次回起動時に戻します。"),L("未送信の入力内容とSplitの幅は復元対象外です。"),L("現在状態は変更時に自動保存します。復元履歴は通常5分間隔で、設定の読み込み・復元前にも残します。同じ状態の履歴は重複させません。設定 → バックアップから直近20件を復元できます。"),L("Notionへのタブバックアップは任意です。Cookie・PAT・アカウントのメモは含まれず、別のMacでは再ログインが必要です。"),L("設定ファイルが壊れた場合は正常なバックアップから復旧し、元ファイルをRecoveryフォルダへ保管します。")]),
        .init(id:"loading",category:"設定・保存",icon:"rectangle.dashed",title:L("読み込み中の表示"),summary:L("再読み込み中はシマーと案内を表示。"),steps:[L("再起動・ページの再読み込み・Webページ処理の復旧中は、標準の読み込み画面が描画されるまではシマーを表示し、その後はサイト側の表示を使います。"),L("下部の「読み込み直しています」が消えたら、実際のページを操作できます。読み込みに失敗したら「再試行」で開き直せます。HTTP 504は接続先の応答待ち、503などは接続先のサーバーエラーとして案内します。時間をおいて再試行してください。"),L("ページのスクリーンショットは撮影・保存しません。旧バージョンが保存したページの画像だけを起動時に削除します。タブのURLやログイン環境は引き続き保存します。"),L("通常のタブ切り替えではページを保持し、自動タブ破棄は行いません。"),L("表示していないタブは一定時間（初期値30分）で休止してメモリを解放します。開くと読み込み直します。設定 → 作業 →「メモリの節約」で時間の変更やオフにできます。"),L("Macのメモリが不足したときは、5〜10分表示していないタブも休止します。")]),
        .init(id:"worksets",category:"設定・保存",icon:"square.grid.2x2",title:L("作業セットと診断"),summary:L("よく使う組み合わせを保存。"),steps:[L("設定 → 作業で作業セットを保存・復元できます。現在のタブを残したまま開きます。"),L("同じ画面で重複タブを確認できます。"),L("設定 → 診断では直近200件の処理時間を確認・CSV出力できます。")]),
        .init(id:"raycast",category:"ショートカット",icon:"arrow.up.forward.app",title:L("Raycastから操作"),summary:L("お気に入り・タブ検索・Notion操作を呼び出す。"),steps:[L("Workspace Tabs拡張のSearch Favorites、Search All Tabs、Switch App Tabから検索します。"),L("Run Commandでは実行するアプリタブを選べます。作業セットも呼び出せます。"),L("Raycast側でホットキーやAliasを設定できます。ログイン情報やPATは渡しません。")]),
        .init(id:"workspace-keys",category:"ショートカット",icon:"command",title:L("アプリタブの切り替えキーを見る"),summary:L("修飾キーの長押しで切り替え先を表示。"),steps:[L("⌘、または設定したアプリタブ切り替え用の修飾キーを約0.5秒長押しします。"),L("先頭9個のアプリタブにキーを表示します。数字との組み合わせは設定 → ショートカットの指定に従います。⌘を押すだけで割り当ては変わりません。"),L("キーを離すと消えます。通常のキー操作・クリック・スクロール中や設定画面では表示しません。自動収納のサイドバーは表示中だけ展開します。")]),
        .init(id:"custom-keys",category:"ショートカット",icon:"keyboard",title:L("ショートカットを変更"),summary:L("同時押し・連続入力を記録して登録。"),steps:[L("設定 → ショートカットの「記録」を押して入力します。"),L("同時押しと最大4回の連続入力に対応します。連続入力は各1.2秒以内に続けます。"),L("各行のリセットで、その操作だけ初期値に戻せます。数字キーとの組み合わせも設定できます。"),L("アプリタブの番号切替と検索は他アプリ使用中にも有効です。グローバルな連続入力は修飾キーのみで、アクセシビリティ許可が必要です。")]),
        .init(id:"link-routing",category:"設定・保存",icon:"arrow.triangle.branch",title:L("Notionリンクを受け取る"),summary:L("OSで開いたNotionリンクをこのアプリへ。"),steps:[L("設定 → リンクの受け取りを開きます。初期状態ではOSの設定を変更しません。"),L("オンにするとWorkspace TabsがこのMacの既定のブラウザになります。app.notion.com・app.dev.notion.com・notion.so・www.notion.soのHTTPSリンクはこのアプリで開き、それ以外のWebリンクは元のブラウザへ渡します。"),L("オフにすると元のブラウザへ戻します。別のブラウザを自分で既定にした場合は、その選択を上書きしません。"),L("Notionリンクの開き先を一意に決められない場合は、アプリタブを選びます。サイト側が専用アプリを直接指定したリンクには対応できない場合があります。"),L("Notionのデスクトップアプリを入れていると、Slackなどのリンクがそちらで開くことがあります。Notionアプリの設定 → 基本設定で「デスクトップアプリでリンクを開く」をオフにしてください。"),L("開発環境（app.dev.notion.com）など、その環境をホームURLにしているアプリタブが1つだけなら、リンクは常にそのアプリタブで開きます。"),L("URLからワークスペースが分からないリンクは、ログイン済みのNotionタブを通じてページの所属ワークスペースを確認し、Workspace IDが一致するアプリタブで開きます。確認できないときだけ開き先を選びます。"),L("設定などのダイアログを開いている間にリンクを受け取ると、アプリを前面に出して、ダイアログを閉じるよう案内します。")]),
        .init(id:"url",category:"ショートカット",icon:"link",title:L("URLを表示・コピー"),summary:L("URLバーは必要なときだけ表示。"),steps:[L("タブ列右端の「…」メニューの「URLを表示」またはURL表示ショートカットで開きます。Escで閉じます。"),L("URLコピーの初期値は⌘⇧Cです。完了すると小さな通知を表示します。"),L("ページ内リンクの⌘クリックで、同じ環境・グループの新しいタブへ開きます。")],shortcut:"copyURL"),
        .init(id:"recent",category:"ショートカット",icon:"clock",title:L("最近使ったタブへ"),summary:L("アプリタブをまたいで素早く戻る。"),steps:[L("初期値は⌃Tabです。修飾キーを押したままTabで次、Shift+Tabで前へ進みます。"),L("修飾キーを離すかEnterで決定、Escでキャンセルします。"),L("終了はアプリメニューから。確認後にタブを保存して終了します。")],shortcut:"recentTabs")
    ] }
}

struct BrowserHelp:View {
    @ObservedObject private var localization = AppLocalization.shared
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
                VStack(alignment:.leading,spacing:3) {Text(L("ヘルプ")).font(.title2.bold());Text(L("知りたい操作を検索")).font(.callout).foregroundStyle(.secondary)}
                Spacer()
                Button(L("はじめに")) {guide=true}
                Button {dismiss()} label:{Image(systemName:"xmark").frame(width:24,height:24)}.buttonStyle(.plain).keyboardShortcut(.cancelAction).help(L("閉じる"))
            }
            HStack {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField(L("タブ、画像、Notion、ショートカット…"),text:$query).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel(L("ヘルプを検索"))
                if !query.isEmpty {Button {query=""} label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).help(L("検索をクリア"))}
            }.padding(12).background(.background.opacity(0.6),in:RoundedRectangle(cornerRadius:12))
            Picker(L("カテゴリ"),selection:$category) {ForEach(HelpCatalog.categories,id:\.self){Text(Localization.text($0)).tag($0)}}.pickerStyle(.segmented)
            ScrollView {
                if results.isEmpty {
                    VStack(spacing:10) {Image(systemName:"magnifyingglass").font(.largeTitle);Text(L("見つかりませんでした")).font(.headline);Text(L("別の言葉で検索するか、カテゴリを「すべて」にしてください。")).foregroundStyle(.secondary)}.padding(40).frame(maxWidth:.infinity)
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
            Text(L("⌘Fで検索 · Escで閉じる")).font(.caption).foregroundStyle(.secondary)
            Button("") {searchFocused=true}.keyboardShortcut("f",modifiers:.command).hidden().frame(height:0)
        }.padding(24).frame(width:730,height:620).background(.regularMaterial)
            .sheet(item:$detail) {topic in HelpDetail(topic:topic)}
            .sheet(isPresented:$guide) {BrowserOnboarding(store:store,firstRun:false)}
    }
    private var shortcutList:some View {
        let actions=ShortcutPreferences.actions.filter{query.isEmpty || $0.title.localizedStandardContains(query) || preferences.binding($0).label.localizedStandardContains(query)}
        return VStack(alignment:.leading,spacing:0) {
            if !actions.isEmpty {Text(L("現在のショートカット")).font(.headline).padding(.bottom,10)}
            ForEach(actions,id:\.id) {action in
                HStack {Text(action.title);Spacer();Text(preferences.binding(action).label).font(.system(.callout,design:.monospaced)).foregroundStyle(.secondary)}.padding(.vertical,8)
                Divider()
            }
        }.padding(16)
    }
}
private struct HelpDetail:View {
    @ObservedObject private var localization = AppLocalization.shared
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
            HStack {Spacer();Button(L("戻る")) {dismiss()}.keyboardShortcut(.cancelAction)}
        }.padding(24).frame(width:560,height:440)
    }
}
