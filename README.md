# KANBAN Term

カンバンボード × Terminal の macOS アプリ。Claude Code を複数同時に走らせる際の「どのセッションが何をやっているか」を、カンバン上のカード＋Agent状態で一望するためのツール。

- 全体仕様: [`SPECIFICATION.md`](SPECIFICATION.md)
- 形式検証モデル (UI/ライフサイクル): [`kanban_ui.fsl`](kanban_ui.fsl)
- 設計ドキュメント: [`docs/superpowers/specs/`](docs/superpowers/specs/)

## 現在の実装状況

**スライス1: UI骨格**（実装済み）
- カンバンボード: 列(状態)の追加・リネーム・削除、カードの追加・タイトル編集・削除
- カードのドラッグ&ドロップ（列間移動＋列内並び替え）
- SwiftData 永続化
- カード表示: タイトル ＋ cwd/Agent状態バッジ（プレースホルダ）
- ※ Terminal / Agent検出 / caffeinate / Markdownプレビュー等は後続スライス

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
