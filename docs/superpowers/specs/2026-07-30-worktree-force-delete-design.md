# 差分確認つき worktree 強制削除

## 背景

Fleet 所有 worktree の削除は `WorktreeService.removeSafely` が `risk == .clean` 以外をすべて拒否し、`git worktree remove --force` を一切使わない設計だった。UI(`CardView`)の警告ダイアログが用意する逃げ場は「カードだけ削除(worktree はディスクに残す)」と「ターミナルを開いて手動で処理」の2つだけ。

この設計は「未コミットの変更を失わない」という安全性を確実に満たすが、`.serena/` のような捨てて構わない未追跡ファイルが1つあるだけで削除ルートが完全に塞がる。`git status --porcelain` は untracked も dirty として報告するため、ゴミと本物の作業を区別しない。

結果として「安全のために何もしない」が成立してしまい、許されるべき結末(捨てていい差分なら worktree を消せる)への到達性が失われている。

## ゴール

未コミットの差分を見やすく提示し、それを捨てて構わないと利用者が判断したときに worktree を強制削除できるルートを追加する。

## 非ゴール

- diff のレビュー機能(行単位の閲覧・コメント・ステージング)。判断に必要なのは「これは捨てていいゴミか」の即断であり、精読ではない
- ファイルを選んで一部だけ捨てる/残す選択。強制削除は worktree ディレクトリ丸ごとの操作
- 未プッシュコミットの破棄。ブランチは常に残す(後述)

## スコープ

強制削除ルートに入れるのは `risk == .dirty` のときだけ。

- `.unpushed` — 現行のまま(worktree を消してもブランチが残るのでコミットは失われず、そもそも別の問題)
- `.inUse` — 現行のまま。既存の「セッションを終了して worktree も削除」を経由し、セッション終了後の再評価が `.dirty` になれば `warningWorktreeRisk = .dirty` が立つので、そこから強制ルートへ自動的に合流する
- `.clean` — 従来どおり普通に消せるので不要

## 何を壊し、何を絶対に壊さないか

**失われるもの**

- 未コミットの変更(tracked の modify / delete / staged / conflicted)
- 未追跡ファイル
- `.gitignore` 対象ファイル(`.build/` など)。`git worktree remove --force` は worktree ディレクトリを丸ごと削除するため

**絶対に失われないもの**

- **コミット** — ブランチ ref は削除しない。`classifyRemoval` は dirty を unpushed より優先するため、dirty な worktree に未プッシュコミットが同居していることは普通にある。ブランチを残せば、強制削除で失うものを「未コミットの変更だけ」に限定できる
- **使用中セッションの足元** — `inUse` なら強制でも削除しない。走っているプロセスの cwd を消すのは、差分を失うのとは別種の事故

**許容する副作用**

ブランチが残るため、同名ブランチでの worktree 再作成は `create` の "branch '<b>' は既に存在します" で弾かれる。これは許容する。ブランチ削除は未プッシュコミットの破棄と同義であり、「dirty のみ」というスコープに反する。

## 安全性の不変条件の組み替え

既存の形式仕様 `worktree_deletion_fixed.fsl` の invariant `NeverRemoveWhileDirtyOrUnpushed` は、この設計では偽になる。「状態」の不変条件から「損失」の不変条件へ組み替える。

| 旧 (`worktree_deletion_fixed.fsl`) | 新 (`worktree_force_delete.fsl`) |
|---|---|
| `removed => not dirty and not unpushed` | `discarded_uncommitted => reviewed_diff` — 差分シートを通らずに未コミット変更は捨てられない |
| — | `removed => branch_kept` — コミットは失われない |
| `removed => not session_live` | 維持 |
| `(clean and requested) ~> removed` | `(dirty and requested and not session_live) ~> removed` — いま塞がっている到達性 |

`worktree_force_delete.fsl` を新規追加する。旧ファイルは v0.7.3 時点の設計記録として残し、ヘッダコメントに後継への参照を1行足す。

安全性の担保レイヤーが移動することに注意する。`removeForcibly` 自体は dirty を許すので、「差分を見せた後にだけ捨てる」を守るのは UI 層(このシートを通らないと `removeForcibly` に到達しない)である。`removeForcibly` が守るのは「使用中は消さない」「ブランチは消さない」の2つだけ。

## API (`Sources/KanbanKit/WorktreeForceDelete.swift`)

`extension WorktreeService` として新規ファイルに置く。既存 `WorktreeService.swift` は 351 行で、削除の安全ロジックに集中しているので混ぜない。

```swift
public struct DirtyPreview: Sendable {
    public struct Entry: Sendable, Identifiable {
        public enum Kind: Sendable { case modified, deleted, staged, conflicted, untracked }
        public let id: String        // path をそのまま ID に使う
        public let kind: Kind
        public let path: String
        public let code: String      // porcelain の XY 2文字(表示・デバッグ用)
        public var isDirectory: Bool { path.hasSuffix("/") }
    }
    public let entries: [Entry]
    public let statusError: String?  // 非nil なら「中身を確認せずに削除」警告へ切替
}

public static func parsePorcelain(_ s: String) -> [DirtyPreview.Entry]
public static func dirtyPreview(worktreePath: String) -> DirtyPreview
public static func fileDiff(worktreePath: String, path: String) throws -> String
public static func removeForcibly(worktreePath: String, repoRoot: String, inUse: Bool) throws
```

- `dirtyPreview` は `git -C <wt> -c core.quotePath=false status --porcelain` を実行する。`core.quotePath=false` が無いと日本語ファイル名が `"\346\227\245..."` にエスケープされて読めない。失敗しても throw せず `statusError` に詰める(UI は必ず何かを表示できる)
- `parsePorcelain` の分類優先順位: `??` → untracked / X か Y に `U` → conflicted / `D` を含む → deleted / Y が空白で X が非空白 → staged / それ以外 → modified。rename の `old -> new` は new 側を path に採る
- `fileDiff` は `git diff HEAD -- <path>`。staged 分も HEAD 比較で1本化する(worktree を丸ごと捨てるので index と worktree を分けて見せる意味がない)。untracked に対しては呼ばない
- `removeForcibly` は `inUse` なら即 `GitError` を throw。それ以外は `worktree remove --force` → `worktree prune`。`removeSafely` の対として並べる

## UI (`Sources/KanbanTerm/Views/WorktreeForceDeleteSheet.swift`)

グループ化リスト + インライン展開。種類ごとに畳んだ1枚のリストで、未追跡は既定で閉じる。

- ヘッダ: 「差分を確認して worktree を強制削除」+ worktree パス
- 赤い警告バンド: 「未コミットの変更と未追跡ファイルは復元できません。ブランチ `<name>` は残るのでコミットは失われません。」
- セクション: 変更 / 削除 / ステージ済み / 衝突 は展開既定、**未追跡は折りたたみ既定**(ゴミの大半はここに来るので、畳んでおけば本命の modified が最初から目に入る)
- tracked 行は `DisclosureGroup`。開いたときに初めて `fileDiff` を `Task.detached` で取得して monospace 表示する。全 diff の事前ロードはしない(巨大 diff でも固まらない)
- `statusError` 時はリストの代わりに「差分を取得できませんでした: `<msg>`」+「再試行」ボタン。警告バンドを「**中身を確認せずに削除します**」に差し替え、削除ボタンは有効のまま残す。差分が取れないことを行き止まりにはしない — index.lock 競合で永久に塞がるのが、まさに今回直している罠だから
- フッタヒント: 「`.gitignore` 対象のファイル(`.build/` など)も worktree ごと削除されます」(差分一覧には出ないので明示する)
- `[キャンセル]` `[破棄して削除]`(destructive)

`CardView.swift` への追加は最小に留める(既に 879 行で Views 最大)。

- `@State private var forceDeleting = false`
- dirty 警告ダイアログに `Button("差分を確認して強制削除…")` を追加。`role: .destructive` にはしない(次に確認シートが出るので、ここはまだ破壊操作ではない)
- `.sheet` 1つ
- ハンドラ1つ。既存 `removeWorktreeThenDeleteCard` と同形 — `Task.detached` で `removeForcibly` → 成功なら `clearWorktree` + `deleteCard`、失敗は既存の `worktreeDeleteError` alert へ流す、`worktreeBusy` を再利用して二重実行を防ぐ、await 中にカードが消えていたら SwiftData に触らない

## テスト (`Tests/KanbanKitTests/WorktreeForceDeleteTests.swift`)

既存 `WorktreeServiceGitTests` の `tmpRepo()` パターン(swift-testing + 実 git)に乗る。

- `parsePorcelain` の純関数テスト: `??` / ` M` / `M ` / `MM` / ` D` / `D ` / `R  a -> b` / `UU` / 日本語パス / 空行・末尾改行
- `dirtyPreview` の `statusError` パス。既存 `statusFailureBlocksRemoval` の「worktree gitdir の index のパーミッションを 0o000 にする」テクを流用する
- `removeForcibly` の inUse ガード: throw して worktree が残る
- 実 git 統合テスト: 未追跡 + tracked 変更 + 未プッシュコミットを持つ worktree を作り、`removeForcibly` 後に **ディレクトリは消え / ブランチは残り / そのコミットも残る** ことを確認する。これが `branch_kept` 不変条件の実行可能な証拠になる

## ドキュメント

`README.ja.md` は現状「削除も安全設計: … `--force` は使わず、未コミット/未 push の変更やセッション動作中は削除を拒否して」と明言しているので、この記述は事実に反することになる。

- `README.md` / `README.ja.md` の該当記述を更新(既定は拒否のまま、差分を確認したうえで強制削除するルートがあることを追記)
- `docs/index.html`(LP)の対応箇所
- `CHANGELOG.md` に1行
- `project.yml` の `MARKETING_VERSION` を 0.9.3 へ
