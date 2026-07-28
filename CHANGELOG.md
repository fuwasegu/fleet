# Changelog

タグの注記から抜粋(各バージョン1行)。

## v0.7.1
- A2A セキュリティ強化

## v0.7.0
- カード別 Claude プロファイル(CLAUDE_CONFIG_DIR)

## v0.6.4
- worktree 作成中の進捗表示

## v0.6.3
- worktree の git-lfs PATH 修正

## v0.6.2
- worktree セッション自動復帰の修正

## v0.6.1
- worktree 作成 UI の改善(現在ブランチ表示・トグル化・ブランチ一覧)

## v0.6.0
- Fleet-managed git worktrees

## v0.7.3
- 使用中セッションのカードでも「セッションを終了して worktree も削除」を選べるように(従来は削除手段が無く詰んでいた)
- 終了済みシェルを「使用中」扱いしない

## v0.8.0
- worktree のベースを origin から最新化して作成(古いベースからの派生を防止)。fetch 失敗/リモート無しは警告を出してフォールバック

## v0.8.1
- worktree のベース最新化で認証ヘルパーを無効化しないよう修正(HTTPS リモートで必ず fetch 失敗していた)
- fetch に 20 秒タイムアウト、ssh は BatchMode で fail-fast
