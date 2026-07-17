# KANBAN Term

カンバンボード × Terminal の macOS アプリ。Claude Code を複数同時に走らせる際の「どのセッションが何をやっているか」を、カンバン上のカード＋Agent状態で一望するためのツール。

- 全体仕様: [`SPECIFICATION.md`](SPECIFICATION.md)
- 形式検証モデル (UI/ライフサイクル): [`kanban_ui.fsl`](kanban_ui.fsl)
- 設計ドキュメント: [`docs/superpowers/specs/`](docs/superpowers/specs/)

## 現在の実装状況

**実装済み（スライス1〜4）**
- カンバンボード: 列(状態)の追加・リネーム・削除・**色変更**、カードの追加・編集(モーダル)・削除(確認付き)
- カードの**ドラッグ&ドロップ**（列間移動＋並び替え、`DragGesture`ベース）／SwiftData 永続化
- **ターミナル**（SwiftTerm）: カードから全画面モーダルで起動、外クリック/Escで閉じる、閉じてもセッション保持
- **新規カード作成ショートカット**: 作業ディレクトリ GUI 選択・Agent(Claude)自動起動・危険モードスキップ
- **Agent状態の実検出**: Idle / Working / Blocked / Done（端末タイトル＋バッファ走査）
- **cwd 追従**（`proc_pidinfo`）、既存カードの cwd 手動変更
- **caffeinate** トグル（秒数入力・プロセス終了で自動OFF）
- **Markdownプレビュー**（ターミナルの上層に表示）
- **GitHub PRリンク**（`gh` で現在ブランチのPRを取得）
- **トークン使用量ダッシュボード**（`~/.claude/projects` を横断集計）

**未実装（BACKLOG.md 参照）**
- アプリ再起動後のセッション自動再開（正確な `--resume <session-id>`）
- 一度も開いていないカードの状態表示（バックグラウンド PTY）
- Unknown（素シェル/非claude）のプロセス識別
- 対応エージェントは Claude Code のみ（Codex 非対応）

## 構成

- `Sources/KanbanKit/` — Models (SwiftData) と BoardStore（ロジック層、フレームワーク）
- `Sources/KanbanTerm/` — SwiftUI アプリ（App / Views）
- `Tests/KanbanKitTests/` — BoardStore の Swift Testing 単体テスト（FSL 不変条件に対応）

## ビルド / テスト

Xcode プロジェクトは [XcodeGen](https://github.com/yonaskolb/XcodeGen) で `project.yml` から生成する（`.xcodeproj` は git 管理外）。

```sh
brew install xcodegen           # 未導入の場合
xcodegen generate               # KanbanTerm.xcodeproj を生成
open KanbanTerm.xcodeproj       # Xcode で開く

# CLI ビルド / テスト
xcodebuild build -project KanbanTerm.xcodeproj -scheme KanbanTerm -destination 'platform=macOS'
xcodebuild test  -project KanbanTerm.xcodeproj -scheme KanbanTerm -destination 'platform=macOS'
```

要件: macOS 26+, Xcode 26+, Swift 6。開発ツールとして **非サンドボックス**で動かす想定（後続スライスのプロセス列挙のため）。
