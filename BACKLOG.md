# Backlog（優先度順ではなく発生順のメモ）

## セッションの永続化 / 再接続（アプリ再起動後も前回セッションを自動再開）※要注意
- 要望: アプリを終了→再起動しても、各カードが前回のターミナル/Agentセッションを自動的に選んで起動する。
- **試して撤去**: 起動時に `claude --continue` で自動再開を実装したが、`--continue` は「その cwd の“直近”会話」を拾うだけで **別のカードの/意図しない会話を引っ張る事故**が起きた（cwd が被る/曖昧なケース）。→ 撤去済み。
- **正しくやるには**: カード毎に実際の **`session_id` を保存**し、`claude --resume <session-id>` でピンポイント再開する。
  - Claude のセッションは `~/.claude/projects/<project>/<session-id>.jsonl`。起動した claude の session_id を取得する手段が要る（stream-json の system/init に session_id が出る／rollout ファイル監視 等）。
  - 加えて「起動時に自動再開する / しない」をカード or 全体でトグルにする（重さ・API消費対策）。
- 関連: 「一度も開いてないカードの状態表示」= バックグラウンド PTY 起動。これも上記と一緒に設計（起動時に裏で session を立てる）。今は撤去したので、状態が見えるのは一度開いたカードのみ。

## その他
- 既存カードの cwd を後から変更できるようにする（今は作成時のみ）。→ 実装済み（右クリック）
- ターミナル自動起動タイミング → 実装済み。固定 700ms をやめ、シェル初回出力(プロンプト)が落ち着いてから送信。

## ターミナルの最低限の設定機能 → 実装済み（フォント + 配色テーマ）
- フォント（ファミリ/サイズ）と配色テーマ（背景/文字/カーソル）を設定できるツールバーを追加。
- テーマ: Midnight / Solarized Dark / Dracula / Nord / Light。UserDefaults 永続化、開いている全ターミナルへ即時反映。
- 残（任意）: ANSI16色パレット（SwiftTerm に一括 installColors API が無いため保留）。

## Markdown プレビューの強化 → 実装済み(オフライン完全対応)
- **WKWebView + marked.js + highlight.js + mermaid.js + DOMPurify**。mermaid 図・コードのシンタックスハイライト対応。
- ライブラリはアプリ**同梱**(Resources/markdown)をインライン展開。**ネットワーク不要・CDN 非依存・オフライン動作**。
- セキュリティ: DOMPurify でサニタイズ、mermaid securityLevel=strict、baseURL=nil(不透明オリジン)、
  Markdown 埋め込み時の "<"/U+2028/2029 エスケープで script ブレイクアウト遮断。

## トークン使用量: API 経由（低優先）
- 現状はローカル transcript(jsonl) 集計で十分（Claude Code のセッション使用量が取れるのはこれ）。
- 組織 Admin API キーがあれば Anthropic の Usage/Cost Admin API で組織横断の集計も可能（個人用途には過剰）。必要時のみ。

## 多言語化 → 実装済み(英語 / 日本語)
- 基準言語=日本語(日本語文字列をローカライズキーに)、en.lproj/ja.lproj を variant group で用意。
- Text/Button/Label/help 等は自動ローカライズ。動的 String は String(localized:) / LocalizedStringKey で対応。
- カード名・列名はユーザーデータのため翻訳対象外(入力どおり表示)。
