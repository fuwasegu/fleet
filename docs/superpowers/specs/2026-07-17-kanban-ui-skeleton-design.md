# KANBAN Term — UI骨格スライス 設計

作成日: 2026-07-17
対象: KANBAN Term アプリの最初の実装スライス（カンバンボードUIの骨格）

関連: `SPECIFICATION.md`（全体仕様）, `kanban_ui.fsl`（UI/ライフサイクルの形式検証済みモデル）

## 1. スコープ

このスライスは「見える成果が早い」ことを重視し、ターミラル/Agent検出などの重量級サブシステムはモックで置く。

**含む**
- Xcode macOS アプリ雛形（SwiftUI + SwiftData、非サンドボックス）
- カンバンボード: 列(状態)の追加・リネーム・削除、カードの追加・タイトル編集・削除
- カードのドラッグ&ドロップ（列間移動＋列内並び替え）
- SwiftData による永続化
- カード表示: タイトル ＋ プレースホルダー（cwd パス=モック文字列、Agent状態バッジ=モックで4状態＋Done表示）

**含まない（モック/後続スライス）**
- 実 PTY / SwiftTerm ターミナル、Agent状態検出、プロセス識別
- caffeinate、Markdownプレビュー、GitHub PRリンク、トークンダッシュボード

## 2. アーキテクチャ（モジュール境界）

```
KanbanTerm/
  App/            アプリエントリ (KanbanTermApp, ModelContainer 設定)
  Models/         SwiftData @Model: BoardColumn, Card ／ enum AgentState
  Store/          BoardStore: ModelContext を包む操作 API (fsl アクションに1:1対応)
  Views/          BoardView, ColumnView, CardView, 補助シート
  Resources/      (将来) xterm系は使わない。今スライスは空
```

### Models
- `enum AgentState: String, Codable { case unknown, idle, working, blocked }`
  - `AgentState` は herdr 実装準拠（`kanban_ui.fsl` の `AgentSt`）。"Done" は独立状態でなく派生。
- `@Model final class BoardColumn`
  - `id: UUID`, `name: String`, `order: Int`, `cards: [Card]`(relationship, deleteRule)
- `@Model final class Card`
  - `id: UUID`, `title: String`, `order: Int`, `column: BoardColumn?`(relationship, inverse)
  - 将来用フィールド（今スライスは表示のみ/デフォルト値）:
    - `workingDirPath: String?`（cwd プレースホルダ）
    - `agentStateRaw: String`（`AgentState` バック, default `unknown`）
    - `dangerSkip: Bool`（default false）
    - `seen: Bool`（default true）
  - 表示用 computed: `agentState: AgentState`（raw変換）, `isDone: Bool = (agentState == .idle && !seen)`

### Store — BoardStore
`kanban_ui.fsl` のアクションに対応する操作を集約し、不変条件をここで担保する。

| メソッド | fsl アクション | ガード / 不変条件 |
|---|---|---|
| `addColumn(name:)` | add_column | 名前空でない |
| `removeColumn(_:)` | remove_column | **カードが残っていると削除不可**（`CardInExistingColumn`）|
| `renameColumn(_:to:)` | (状態編集) | 名前空でない |
| `addCard(title:to:)` | add_card | 対象列が存在 |
| `deleteCard(_:)` | delete_card | （将来: Terminal/Agent 停止。今はモデル削除のみ）|
| `moveCard(_:to:at:)` | move_card | 移動先列が存在、order 正規化 |

- 順序は整数 `order`。移動/削除時に対象コレクション内で 0..n-1 に正規化する。
- `removeColumn` はカードが1枚でもあれば `false`（または throw）を返し、UI 側は削除ボタンを無効化＋理由表示。

### Views（SwiftUI）
- `BoardView`: 列を `order` 昇順で横スクロール表示。列追加ボタン。空状態（列0個）で「列を追加してください」。
- `ColumnView`: ヘッダ（名前、リネーム、削除ボタン=非空時 disabled）＋ カードを `order` 昇順で縦リスト ＋ ドロップ先。カード追加ボタン（対象列へ）。
- `CardView`: タイトル（インライン編集）、cwd プレースホルダ行、Agent状態バッジ（色＋アイコン。Working は将来アニメ、今は静的）、Done バッジ（`isDone` 時）。draggable。

### DnD
- SwiftUI `.draggable(card.id)` + `.dropDestination(for: UUID.self)`。ドロップ位置から挿入 index を決め `moveCard` を呼ぶ。
- 代替案（フォールバック）: `onDrag`/`onDrop` + `NSItemProvider`。`.dropDestination` の並び替えが不安定なら切替。

## 3. データフロー
Views は `@Query`（`order` ソート）で SwiftData を購読 → ユーザー操作は `BoardStore` メソッド → `ModelContext` 変更 → autosave → 再描画。

## 4. 不変条件の担保（`kanban_ui.fsl` 対応）
- 空でない列は削除不可 → `removeColumn` ガード ＋ UI で削除ボタン無効化。
- 孤児カードなし → カードは常に列に属す（`moveCard` は移動先列必須、`removeColumn` が非空をブロック）。
- Agent状態/Done/cwd は表示プレースホルダ。モデルにフィールドを用意し、後続スライスでスキーマ変更を最小化。

## 5. エラー処理
- 非空列の削除 → ブロック（ボタン無効＋ツールチップ/理由表示）。
- 列0個 → カード追加不可、空状態表示。
- SwiftData 保存失敗 → 軽量エラーバナー＋ログ（`os.Logger`）。

## 6. テスト（Swift Testing）
`BoardStore` をインメモリ `ModelContainer`（`isStoredInMemoryOnly: true`）で単体テスト。`kanban_ui.fsl` の不変条件に対応:
- `addColumn` / `renameColumn`（空名拒否）
- `removeColumn`: 空列は削除可、非空列は削除不可（孤児防止）
- `addCard` / `deleteCard`
- `moveCard`: 列間移動、列内並び替え、order 正規化、移動後もカードは必ず列に属す

将来 `fslc testgen` の適合テストをこの層に接続する。

## 7. プロジェクト設定
- `.xcodeproj`（生成は XcodeGen の `project.yml`。未導入なら brew 導入、それも不可ならフォールバックで手生成）。
- アプリ名 `KanbanTerm`、bundle id `dev.hirosugu.KanbanTerm`、最小ターゲット macOS 26、Swift 6。
- **App Sandbox 無効**（開発ツール／後続スライスのプロセス列挙に必要）。
- ビルド/テストは `xcodebuild`（CLI）で実行し検証。
- git init ＋ `.gitignore`（Xcode/SwiftPM 標準）。

## 8. 決定ログ（自律実行中の判断）
- bundle id は `dev.hirosugu.KanbanTerm` を採用（後で変更容易）。
- 順序管理は整数 `order` の正規化方式（分数キー等は使わない、単純さ優先）。
- DnD の Transferable は `Card.id`（UUID）を運ぶ。
