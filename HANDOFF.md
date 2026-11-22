# HANDOFF

2026-11-22 時点の引き継ぎメモです。

## 目的

Workspace Tabs(macOS、Swift / SwiftUI + AppKit + WKWebView)に「Notion AIのチャット一覧」を足す作業の途中です。
複数のワークスペース・アカウントにある自分の Notion AI チャットを、アプリタブとは別の1画面で見て、状況を確認し、追加指示を送れるようにします。

## 今どこまでできたか

チャット一覧は実装済みで、ビルドと自動チェックは通っています(コミット `1e1953a`)。

- **開き方:** ⌘⇧J、タブバーの吹き出しボタン、アプリメニューの3通りです。ショートカットは設定で記録し直せます。
- **アカウント登録:** ワークスペースごとに Notion の個人用アクセストークン(PAT)を登録します。トークンは Mac のキーチェーンだけに保存し、`agent-chats.json` にはラベルだけを書きます。
- **一覧:** 登録した全ワークスペースから、自分が始めた Notion AI のチャットだけを取得します。検索、状況での絞り込み、ワークスペースでの絞り込みができます。30秒ごとに更新します。
- **詳細:** メッセージを読む、追加指示を送る(⌘Enter)、承認待ちに答える、実行を止める、新しいチャットを始める、Notion で開く、ができます。実行中のチャットは2.5秒ごとに更新します。
- **対象外にしたもの:** カスタムエージェントの実行と他の人のチャットは取得しません(ユーザーの指示)。

主なファイル:

| ファイル | 役割 |
| --- | --- |
| `Sources/WorkspaceCore/AgentChat.swift` | API 応答の読み取り、状況の並び順、チャット URL の組み立て |
| `Sources/WorkspaceTabs/AgentChatHub.swift` | アカウント管理、取得、ポーリング、送信・承認・停止 |
| `Sources/WorkspaceTabs/AgentChatPage.swift` | 一覧ページ、詳細、入力欄、アカウント登録の画面 |
| `Sources/WorkspaceTabs/AgentChatChecks.swift` | 偽の API を使った自動チェック |
| `docs/FEATURES.md` | 「Notion AIのチャット一覧」の節 |

使っている API は Notion Agent API(`https://api.notion.com/v1`、`Notion-Version: 2026-03-11`)の `users/me`、`sessions/query`、`sessions/{id}`、`sessions/{id}/events/query`、`sessions`、`sessions/{id}/cancel` です。

最後に通したチェック:

- `swift run --scratch-path /tmp/workspace-tabs-build WorkspaceCoreChecks`: 17 checks 通過
- `python3 scripts/browser_checks.py`: 通過
- `python3 scripts/localization_checks.py`: 1084 訳で通過
- `bash scripts/build.sh --install`: `/Applications/Workspace Tabs.app` に入れ済み

## 未完了タスク

- 本物の PAT での動作確認(一覧に出るか、内容が読めるか、追加指示が送れるか、承認と停止が効くか)。
- Notion の表示調整(目次の固定、全幅表示など)。プレビュー用ブラウザが Notion にログインしていないため保留中で、着手の指示もまだありません。

## 既知の問題

- チャット一覧は実際の API に対して一度も動かしていません。確認したのは偽の API を使った自動チェックだけです。
- 「Notionで開く」の URL(`https://<host>/chat?t=<32桁のID>`)は推測です。API はチャットの URL を返しません。
- PAT は1つのワークスペースに結び付き、そのユーザーが始めたチャットにしか書き込めません。
- `sessions/query` は `has_more` が true のまま空のページを返すことがあります。続きを読む処理はこれを前提にしています。
- アカウント切り替えシートの写真表示(前のコミット `ed3ecd5`)は、実機で確認していません。
- データベースの検索・設定に引っ張られる不具合の修正(同じく `ed3ecd5`)は、コードを読んで原因を決めたもので、実機で再現と解消を確認していません。
- 自動チェックの「Favicon discovery recovers after an earlier network failure」は通信の状態でまれに落ちます。再実行で通ります。

## 次にやること(優先順)

1. 本物の PAT を1つ登録し(⌘⇧J → アカウント)、一覧、詳細、追加指示、承認、停止を確かめる。
2. 「Notionで開く」が正しいチャットを開くか確かめ、違っていれば `AgentChat.chatURL` を直す。
3. 2つ目のワークスペースの PAT を足し、並び順とワークスペースでの絞り込みを確かめる。
4. アカウント切り替えシートの写真と、Notion 全体の検索・設定(⌘⇧,)を実機で確かめる。
5. 指示があれば Notion の表示調整に着手する。

## 作業上の決まり

- シェルのコマンドには `rtk` を前に付ける。
- コミット前にどの git 利用者で行うか、push 前にどの GitHub アカウントで行うかを、セッションごとにユーザーへ確認する。このリポジトリは今 `satoshi0817` に設定してあります。
- ビルドの後は `bash scripts/build.sh --install` を実行する。アプリは終了も再起動もせず、ユーザーに開き直してもらう。
- main に直接 push する。
- ユーザーへの返事は日本語で書く。

## ブランチ名と最終コミット

- ブランチ: `main`(`origin/main` へ push)
- 機能の最終コミット: `1e1953a` Add a Notion AI chat list across workspaces and accounts
- その次のコミットが、この HANDOFF.md を足したものです(`git log -1` で確認してください)。
