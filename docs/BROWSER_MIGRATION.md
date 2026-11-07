# 内蔵ブラウザ版の検証記録

2026-11-06 / 0.2.0 build 2 / macOS・WebKit

## 実装

外部ウインドウのAX管理を内蔵WebKitへ置換。アプリタブ → ブラウザタブの構成、UUID単位の永続ログイン環境、環境を跨ぐSplit View、NotionのサイドバーCSS、名前付き環境、既存設定の移行を実装。

## 確認済み

- releaseビルド成功、インストール先の署名検証成功。buildと/Applicationsの実行ファイルSHA-256一致。
- WebKitの自動検証18項目成功（browser-checks.log）。一時環境でCookie・localStorage分離、子タブの環境共有、Splitの環境保持・入替・実WebViewサイズ、状態再読込、CSSの生成・除去を確認。
- 旧Core検証15 checks / 60 assertions成功。外部ウインドウ動作の現行保証ではなく移行元モデル等の回帰確認。
- 実ユーザー設定の8アプリタブを移行。名前・色・アイコンを引継ぎ。
- 実GUIでapp.notion.comとapp.dev.notion.comのログイン画面を同時表示し、左右入替を確認。
- 実GUIで環境名・アカウントメモ・サイトデータ一覧、CSSトグル・濃さ・色設定を確認。変更せずキャンセル。

## 未検証・制限

- 実アカウントのログイン、SSO、ログイン後のNotion編集・本物のサイドバー着色は未検証。
- Cookieの永続確認は同プロセス内の同UUIDデータストア再取得。認証済み状態でプロセスを跨ぐ再起動検証は未実施。
- CSSの許可host試験はローカルfixture上でhost判定を模擬。本物のNotionのDOMとの適合確認ではない。
- Split幅はnative HSplitView。幅の比率を保存しない。キーボードのT/W/L/R操作は左ペイン対象。
- セッション復元はURL・タブ設定・環境の対応。未送信の入力やスクロール位置は保証しない。
- ログイン環境のアカウント名は手入力メモ。ドメイン一覧からログイン中かは判定しない。

## 再実行

`rtk proxy python3 scripts/browser_checks.py`。ローカル127.0.0.1:48761を使用し、終了時にサーバーを停止。一時WebKit環境はテスト終了時に削除。

過去のRESEARCH / VERIFICATION / STABILITY_AUDIT / LEGACY_NATIVE_READMEは外部ウインドウ版の履歴です。

## お気に入り・表示の更新（2026-11-06）

- 共通ランチャー（⌘⇧L・サイドバーの星）、ページから登録、カテゴリ・検索・ピン、宛先アプリタブを追加。
- お気に入りの永続化、旧JSON互換、宛先内だけの既存URL再利用、別タブ指定、宛先不明時の停止を実WebKitテストで確認。結果はaudit/favorites-checks.log。
- 設定export/importはお気に入り画像と宛先UUIDの付け替えに対応。ファイルダイアログ経由の往復は未検証。
- 実GUIでランチャー起動、登録項目、現在ページのURL・タイトル・宛先の自動入力を確認（ユーザーデータへ試験リンクは追加していない）。
- アイコンモード42×42ptをスクリーンショットで確認。URLバーの収納と⌘L表示、環境名の上部非表示を確認。ホバー操作はコード実装済みだが独立したGUI試験は未実施。
- 更新後にログイン済みNotionページを再表示。サイドバー着色の表示も確認。その他のSSO方式は未検証。
- releaseビルド・署名検証成功、buildと/Applications実行ファイルのSHA-256一致。
- Link ViewerのNotion DB同期と既存データ移行は今回の共通ランチャーには含まない。

## ワークスペース判定・終了保存・URL操作（2026-11-06）

- NotionWorkspaceでURL環境と明示登録IDを照合。現在のページIDと一致したlastVisitedRouteだけからIDを取得。公開ページ、別ページの古いメタデータ、候補重複では推測しない。
- ローカルのnotion-nextを読み取り専用で調査。参照：src/client/navigation/helpers/lastVisitedRouteData.ts、src/client/routing/actions/handleRouteActions/recordLastVisitedRoute.ts、src/shared/LocalStorageStore.ts。これは公開API契約ではなく内部保存形式であり、将来の互換性は保証しない。
- 実GUIで開発用NotionページのID取得成功。現在の開発用アプリタブに保存し、Lumi Labs側のURL入力から登録した開発用タブへの切り替えを確認。元の本番ページは保持。
- URLバーはホバー展開を削除。⌘Lとリンクボタンで明示表示、Escで収納を確認。
- ⌘⇧Cのコピー完了通知をスクリーンショットで確認。通知は2秒で消え、クリックを透過する。
- Split中のキーボード操作は最後に操作した表示ペインへ追従。WebKit自動検証で参照と一時PasteboardへのURLコピーを確認。実GUIでの左右フォーカス往復は未検証。
- 終了確定前に同期保存。Split参照もセッションJSONへ移し、主設定と一体でatomic write。保存失敗時は終了をキャンセル。旧splitファイルは旧設定の移行にのみ使用する。
- 通常終了・再起動を実施。8アプリタブ・8ブラウザタブのID、URL、選択、プロファイル対応、ホームURL、Notion IDを終了後と再起動後で比較し一致。選択していた認証済みNotionページの実表示を確認。
- 自動検証33項目成功：audit/routing-checks.log。署名検証成功、インストール先とbuild実行ファイルのSHA-256一致。
- ID取得・自動振り分けは設定したタブのみ有効。全サイト・全Notionルートの判定やSSO互換を保証するものではない。

## ヘルプと一時切り離し（2026-11-06）

- サイドバーの「？」から機能ガイド／ショートカット一覧を開くsheetを追加。実GUIで両画面とEscで閉じる操作を確認。
- アプリタブ全体の一時切り離しと復帰を追加。別ウインドウを閉じてもページは削除しない。再起動時はメイン画面へ戻る。
- 初回の実GUI検証でWebViewの表示先競合による白画面を検出。WebContentのマウント条件を切り離し状態と照合し、旧画面がWebViewを取り戻さないよう修正。
- 修正版で、認証済みNotionのDocumentsページを別ウインドウへ表示し、「元に戻す」で同じページがメイン画面へ復帰することをAXで確認。
- 自動検証37項目成功。別ウインドウの実WebView所属・同一インスタンス維持・ページ一覧維持・閉じる動作・連続キーボード操作の宛先を検証。ログ：audit/detach-checks.log。

## タブ表示・ピン留め・濃さ入力（2026-11-06）

- アプリ名の上段を削除し、操作ボタンをブラウザタブと同じ行へ統合。タブの背景をアプリタブ色に揃え、白／黒の文字色を自動選択。
- ブラウザタブのピン留め、左端への表示、アイコンのみ（既定）／名前付き表示、個別名・絵文字編集、保存を追加。ピン留め中の誤閉鎖を防止。自動検証42項目成功（audit/pinned-tabs-checks.log）。
- 濃さのパーセントを数値入力欄へ変更。スライダーと双方向連動、有限値のみ受け付け、0〜100へ制限。小数第1位まで表示。
- releaseビルド・署名検証成功。実機操作が継続中だったため再起動せず、旧バンドルを隠しバックアップへ移して更新版を/Applicationsへ配置。実行中バイナリのinodeは書き換えていない。次回起動で反映する。
- これら最新UI変更の実機表示確認は未実施。

## 2026-11-06 Settings, shortcuts, Link Viewer

- Native Liquid Glass navigation and sidebar controls on macOS 26+, material fallback. Settings split into five categories.
- Per-action shortcut overrides with key recording, reset, conflict/prefix detection and persistent UserDefaults. Menu and Carbon registrations refresh immediately.
- Sequential recording supports modifier taps and chords, up to four strokes with 1.2-second gaps. Global sequences accept modifier taps only; NSEvent global observation requires Accessibility permission.
- 53 browser checks passed, including importer idempotency/unassigned destinations, persistence/reset/conflicts, modifier release and chord suppression.
- GUI verified recording Command-K then Command-J, registering, executing URL copy with toast, and per-action reset. Modifier-only CUA injection is unsupported; modifier taps verified via event parser tests, not physical double-Command execution.
- Imported 11 real Link Viewer links. Three exact Notion Dev destinations mapped; eight remain unassigned. Original Link Viewer file and credentials untouched.

## 2026-11-06 Optional Notion storage and launcher focus

- Favorites initially selects/focuses the first list row. GUI verified Down/Up changes selection and Return opens the assigned app tab without first clicking the list.
- Native Link Viewer connection metadata and its Keychain PAT migrated. Read-only live Notion API query returned 11 rows. Existing source data was not written during validation; Notion storage remains disabled by default.
- Settings → Notion保存 supports existing DB URL + PAT, credential replacement, and private workspace-root creation with Links/Categories/Tabs. PAT stored only in the Workspace Tabs Keychain service.
- New private DB creation was exercised with a fault-injecting mock API, not against the user's workspace. All six creation steps tested for rejected writes and lost responses, with reconciliation/no duplicate creation.
- Favorites use a persisted outgoing queue, remote edit-revision guard, opt-in 60-second synchronization, and manual conflict dismissal. Browser tab snapshots are per-device, with manual restore confirmation. They exclude account notes, auth query parameters, cookies and PATs. Snapshots are not a Notion-column editor for app tabs.
- Additional mock checks cover create/retry without duplicates, conflicts, local default, stable config-only snapshots, secret-free JSON, and unreadable-file preservation. Existing 53 browser checks passed.
- Tab snapshots are capped at 160KB and include resized 48px icons. Large rich-text properties are read through property pagination. Favorite image uploads are not implemented; local images remain local and emoji can be written to Notion.
