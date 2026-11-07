# Workspace Tabs for Raycast

Workspace Tabsのローカル一覧を検索し、URLスキームで実行します。NotionトークンやCookieは読み取りません。

## インストール

Workspace Tabsを起動後、このディレクトリで `npm install`、`npm run dev` を実行します。
RaycastのExtensions設定で各コマンドにHotkey / Aliasを割り当てられます。

- Search Favorites: Category / Workspace IDによる既存の振り分けで開く
- Search All Tabs: 全アプリタブのブラウザタブへ移動
- Switch App Tab: アプリタブの切り替え
- Run Command: 最後に操作したタブ、または右上で選択したアプリタブで実行

一覧はWorkspace Tabsの保存時（通常0.4秒後・最大約5秒）に更新、Raycastは2秒ごとに再読込します。
アプリ終了中は最後の保存状態を表示し、操作するとアプリを起動します。
作成系のNotionコマンドはNotionの画面構成・ログイン・権限に依存します。

`~/Library/Application Support/WorkspaceTabs/raycast-index.json` は所有者のみ読み書き可能です。
URLにはローカル連携用トークンを含むため共有しないでください。任意URL・JavaScriptの実行は受け付けません。
