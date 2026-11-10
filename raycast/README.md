# Workspace Tabs for Raycast

[English](README.en.md)

Workspace Tabsのローカル一覧を検索し、URLスキームで実行します。NotionトークンやCookieは読み取りません。

## インストール

Workspace Tabsを起動後、このディレクトリで `npm ci`、`npm run dev` を実行します。
RaycastのExtensions設定で各コマンドにHotkey / Aliasを割り当てられます。

- Search Favorites: Category / Workspace IDによる既存の振り分けで開く
- Search All Tabs: 全アプリタブのブラウザタブへ移動
- Switch App Tab: アプリタブの切り替え
- Open Notion Link: NotionのHTTPSリンクを、対応するアプリタブで開く
- Run Command: 最後に操作したタブ、または右上で選択したアプリタブで実行

一覧はWorkspace Tabsの保存時（通常0.4秒後・最大約5秒）に更新、Raycastは2秒ごとに再読込します。
アプリ終了中は最後の保存状態を表示し、操作するとアプリを起動します。
作成系のNotionコマンドはNotionの画面構成・ログイン・権限に依存します。

`~/Library/Application Support/WorkspaceTabs/raycast-index.json` は所有者のみ読み書き可能です。
URLにはローカル連携用トークンを含むため共有しないでください。任意URL・JavaScriptの実行は受け付けません。

お気に入りはカテゴリ別に表示し、CategoriesのOrder順、各カテゴリ内はピン留め・リンクのOrder・名前順です。未分類は最後に表示します。⌘←／⌘→でカテゴリを切り替え、検索欄の左右キーは文字カーソルの移動に使います。設定した画像・プリセットのアイコンを優先し、なければ絵文字を表示します。単色プリセットはRaycastの文字色に合わせて表示します。


作業セットはアプリの「設定 → 作業」で保存すると、Run Commandの一覧に表示されます。現在のタブを残したまま復元します。

Open Notion LinkはNotion URLを引数で受け取り、対応する環境で開きます。判定できなければアプリで環境を選択します。

OSからNotionのWebリンクを受け取る設定は、本体の「設定 → リンクの受け取り」で変更できます。RaycastのOpen Notion Linkは、既定ブラウザを変更せずに利用できます。
