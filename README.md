# Workspace Tabs

複数のログイン環境とブラウザタブを、一つのmacOSアプリで管理するWebKitベースのブラウザです。Notionの複数ワークスペースを使い分ける用途を中心に開発しています。

サイドバーの「アプリタブ」がワークスペースに相当し、それぞれの中にブラウザタブを持ちます。外部アプリのウインドウを取り込む方式ではなく、内蔵のWKWebViewでWebサイトを開きます。

## 主な機能

- **ログイン環境の分離**：プロファイルごとにCookieとサイトデータを分離。同じプロファイルを選ぶと共有できます。
- **タブ管理**：並べ替え、ピン留め、表示名・アイコン・色の変更、閉じたタブの復元。
- **Split View**：別のアプリタブに所属するページも左右に並べられます。
- **全タブ検索**：アプリタブを横断して検索し、上下キーとEnterで移動。
- **表示の切り替え**：上部／左側タブ、アイコンのみ、左端ホバーで展開、ライト／ダーク／システム。
- **お気に入り**：共通ランチャーから指定したアプリタブで開く。任意でNotion DBと同期。
- **Notion連携**：ワークスペースIDによる振り分け、サイドバーの着色、AIチャット・ページ・ミーティングノートなどの操作。
- **ショートカット**：同時押し・連続ストロークを記録し、操作単位でリセット。
- **セッション保存**：タブ・URL・選択状態・ログイン環境・Split Viewを保存・復元。
- **Raycast連携**：お気に入り・タブ・アプリタブの検索と、コマンドの直接実行。

## 動作・開発環境

- 実行：macOS 14以降
- ビルド：Xcode 26以降のmacOS SDK、Swift 6ツールチェーン
- Python 3（バンドル生成・ブラウザ検証）
- `rtk` コマンド（リポジトリのビルドスクリプトで使用）
- Raycast拡張：Raycast、Node.js 22.22.2以降、npm

Liquid GlassはmacOS 26以降で使用します。WebKitの動作や認証対応はmacOSのバージョンにも依存します。

## ビルドと起動

```sh
git clone https://github.com/satoshi0817/workspace-tab.git
cd workspace-tab
rtk proxy bash scripts/build.sh
```

`build/Workspace Tabs.app` を生成します。使用する場合は、起動中のWorkspace Tabsを終了してから `/Applications` にコピーしてください。

```sh
rtk proxy ditto "build/Workspace Tabs.app" "/Applications/Workspace Tabs.app"
rtk proxy open "/Applications/Workspace Tabs.app"
```

ローカルにApple Development証明書があれば署名に使用し、なければアドホック署名します。署名を指定する場合は `WORKSPACE_TABS_SIGN_IDENTITY` を設定します。公証済み配布バイナリを提供する手順ではありません。

## 使い始める

1. サイドバーの＋からアプリタブを追加します。
2. HOME URLとログイン環境を設定し、内蔵ブラウザでログインします。
3. アプリタブ内にブラウザタブを追加します。ページから開いた新しいタブも同じログイン環境を使います。
4. アプリタブを右クリックして、色・アイコン・名前・Split Viewなどを設定します。

HOME URLは新しいブラウザタブの開始先です。Notionでは、目的のワークスペース内のページURLを指定します。再起動時はHOME URLではなく、保存した各タブのURLを復元します。

詳しい操作と現在のキー割り当ては、サイドバーの「？」で確認できます。

## 主なショートカット（初期値）

| キー | 操作 |
| --- | --- |
| ⌃⌥1〜9 | アプリタブを番号で切り替え |
| ⌘⌥← / → | 前／次のアプリタブ |
| ⌃⌥Space | 全タブを検索 |
| ⌘⇧P | コマンド検索 |
| ⌘⇧L | お気に入りランチャー |
| ⌘T / ⌘W / ⌘⇧T | タブを追加／閉じる／復元 |
| ⌘L | URLバーを表示 |
| ⌘⇧C | 現在のURLをコピー |
| ⌘⌥A | Notionの新規AIチャット |
| ⌘⌥N | Notionの新規ページ作成メニュー |
| ⌘⌥M | Notionの新規ミーティングノート |
| ⌘⌥K | Notion内検索 |

設定 → ショートカットで変更できます。グローバルな修飾キーの連続ストロークにはmacOSのアクセシビリティ許可が必要です。通常のブラウザ利用には不要です。

## Raycast

```sh
cd raycast
npm ci
npm run dev
```

開発用拡張としてRaycastに登録します。初回は更新版のWorkspace Tabsを起動してください。

| コマンド | 操作 |
| --- | --- |
| Search Favorites | お気に入りを検索して指定環境で開く |
| Search All Tabs | 全アプリタブ横断のブラウザタブ検索 |
| Switch App Tab | アプリタブ切り替え |
| Run Command | 操作と実行先を選択 |
| New Notion AI Chat / Page / Meeting Note | 各作成操作 |
| Search in Notion | Notion内検索 |
| Show Workspace Tabs | アプリを表示 |
| Open Favorites Launcher | アプリのお気に入りランチャーを表示 |

RaycastのSettings → Extensions → Workspace TabsでHotkeyやAliasを設定できます。[連携の詳細](raycast/README.md)も参照してください。

## Notion保存と振り分け

初期状態はローカル保存です。設定 → Notion保存でPATとDBを登録すると、お気に入りを起動時・約1時間ごと・手動操作で同期できます。PATはKeychainに保存します。新規DBの作成にも対応します。

お気に入りのCategoryに `Workspace ID` を設定すると、アプリタブのNotion Workspace IDと本番／開発環境で照合します。未設定の場合はCategory名とアプリタブ名を照合します。不正なIDや候補の重複がある場合は推測で別のログイン環境を開きません。

タブ情報は任意でNotionへバックアップし、手動で復元できます。CookieやPATは含みません。別のMacでは再ログインが必要です。

## 保存と制約

設定は `~/Library/Application Support/WorkspaceTabs/`、サイトデータはWebKitの永続プロファイル、NotionのPATはKeychainに保存します。設定は変更後と約5秒ごとに保存し、変更前のセッションを直近20件保持します。

- 未送信の入力、ページ内部の一時状態、Splitの幅は復元対象外です。
- 外部ブラウザやNotionデスクトップアプリのCookieは引き継ぎません。
- Notionの着色・画面操作・ワークスペース判定はNotion側の画面や保存形式に依存します。変更や権限によって動作しない場合があります。
- 新規ページのショートカットは作成メニューを開きます。ミーティングノートは直接作成するため、試す場合もページが残ります。
- Raycast用のローカル一覧は名前・アイコン・IDなどに限定し、PAT・Cookie・アカウントメモを含めません。連携用トークンを含む一覧ファイルやURLは共有しないでください。

## テスト

先にアプリをビルドしてから実行します。

```sh
rtk proxy swift run --scratch-path /tmp/workspace-tabs-build WorkspaceCoreChecks
rtk proxy python3 scripts/browser_checks.py
rtk proxy "build/Workspace Tabs.app/Contents/MacOS/WorkspaceTabs" --notion-checks
cd raycast
npm run typecheck
npm run build
```

ブラウザ検証はローカルHTTP fixtureと一時WebKitプロファイルを使用します。Notionのチェックはモックを使用し、実際のワークスペースへの書き込みは行いません。

## ディレクトリ

| パス | 内容 |
| --- | --- |
| `Sources/WorkspaceTabs/` | macOSアプリ、WebKit、Notion・Raycast連携 |
| `Sources/WorkspaceCore/` | モデル・ルーティングなどの共通ロジック |
| `Tests/WorkspaceCoreTests/` | 共通ロジックの検証 |
| `raycast/` | Raycast拡張 |
| `scripts/` | ビルド・検証スクリプト |
| `docs/` | 設計・検証記録。旧ウインドウ管理版の資料も含む |

現在の仕様はこのREADMEとアプリ内ヘルプを参照してください。`LEGACY_NATIVE_README.md`などの旧方式の資料は履歴です。
