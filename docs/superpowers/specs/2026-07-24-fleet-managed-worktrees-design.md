# Fleet-managed git worktrees — 設計

作成日: 2026-07-24
ステータス: レビュー待ち（実装未着手）

## 背景と動機

現状 Fleet では、カードの作業ディレクトリ (`Card.workingDirPath`) が
branch / PR 判定の唯一の入力になっている。しかし cwd の追従は
「ログインシェルの pid の cwd を読む」方式 (`TerminalView.refreshCwd`) のため、
**AI や利用者がシェル内で `git worktree add ../wt && cd ../wt` しても親シェルの
cwd は動かず**、Fleet は元フォルダ（＝メインリポジトリ root）を cwd と信じ続ける。
結果、`GitHubService` が **メインブランチの PR を拾う＝ズレる**。

根本原因は「worktree に入ったことを Fleet が構造的に検知できない」こと。
逆に言えば **Fleet が worktree を所有し、シェルを最初からその worktree で
起動する**なら、cwd は推測不要の確定値になり、この PR バグは副作用として消える。

参考: Zed は一級市民として git worktree 作成機能を持つ
（`git.worktree_directory` 設定・デフォルト `../worktrees/<name>`、ベースは
「現在/デフォルトブランチ」の2択、detached HEAD で作りブランチ作成は別ステップ、
使用中は削除不可、`create_worktree` フックで `.env` コピー等）。本設計は
配置・ベース選択の考え方をここから借りる。

## 決定事項（確定）

| 項目 | 決定 |
|---|---|
| 所有範囲 | 作成〜削除まで Fleet が所有 |
| 適用範囲 | opt-in（カードごと）。従来のフォルダ選択カードと共存 |
| ベース ref | 「現在のブランチ」or「デフォルトブランチ」の2択 |
| デフォルト配置 | `<repo>/../.fleet-worktrees/<branch>`（設定で変更可） |
| 撤去タイミング | カード削除時のみ・確認付き。Done では消さない |
| 安全性 | `--force` 禁止。dirty/未プッシュ/使用中は削除しない |
| エディタ連携 | 非ゴール（次段に切り出し） |

## データモデル（`Sources/KanbanKit/Models.swift`）

`Card` に追加（すべて lightweight migration 可能な optional / default 付き）:

- `repoRoot: String?` — メインリポジトリの working dir
- `worktreePath: String?` — このカードの worktree 実体パス
- `isFleetOwnedWorktree: Bool = false` — **Fleet が作った worktree のみ true**。
  撤去責任の境界。false のカード（既存フォルダ運用・外部で作った worktree を
  バインドしただけ）は Fleet が絶対に削除しない。

`branch` は既存プロパティを流用。
cwd 解決は `worktreePath ?? workingDirPath` を基本とする。

## 作成フロー（opt-in）

`NewCardSheet` にモード切替を追加：
- 「既存フォルダを選ぶ」（従来どおり `.fileImporter`）
- 「worktree を作る」:
  1. repo を選択（`.fileImporter`）→ `repoRoot` に。git リポジトリか検証。
  2. ブランチ名入力（デフォルト = カードタイトルを sanitize）。
  3. ベース = 「現在のブランチ / デフォルトブランチ」の2択。

作成コマンド（`git -C <repoRoot>` で実行）:
```
git worktree add -b <branch> <worktreePath> <baseRef>
```
- Zed の detached 方式ではなく「1カード=1ブランチ」に寄せてブランチ即作成。
- `worktreePath` = 設定の配置ベース + `/<sanitized-branch>`。
- **事前バリデーション**:
  - 同名ブランチが既に存在／別 worktree でチェックアウト済み → 拒否し改名を促す
    （git の "already checked out" エラーを事前に防ぐ）。
  - 配置先ディレクトリが既に存在 → 拒否。
- 作成後 `repoRoot` / `worktreePath` / `branch` / `isFleetOwnedWorktree=true` を保存。
- （将来）`create_worktree` 相当のセットアップフック（`.env` コピー等）は次段。

## 配置

デフォルト `<repo>/../.fleet-worktrees/<branch>`。
- repo の兄弟、かつ Fleet 専用ディレクトリに集約 → 他ツールの worktree と混ざらない。
- repo 外なので `.gitignore` 追記不要（git は `.git/worktrees/` で管理）。
- 設定で変更可（`../worktrees` に寄せて Zed と共有する運用も選べる）。

## PR / branch 判定の修正（本命の効用）

- セッションのシェルを最初から `worktreePath` で起動
  （`TerminalView` の `directory` 供給元を `worktreePath ?? workingDirPath` に）。
- `BoardView.fetchGitInfo` / `refreshVisibleGitInfo` の cwd 入力も同様に
  `worktreePath ?? workingDirPath` を使う。
- これにより `refreshCwd` の pid 追従に依存せず cwd が確定し、`GitHubService` が
  worktree のブランチ / PR を確実に引く。既存の `gh pr list --head <branch>` は
  そのまま活きる（worktree セーフ）。

## MCP ツール（`Sources/fleet-bridge/main.swift`）

AI が自カードの worktree を扱えるようにする。**削除系は出さない**（AI に消させない）。
- `fleet_worktree_info` — 自カードの `repoRoot` / `branch` / `worktreePath` /
  `isFleetOwnedWorktree` を返す（read-only）。
- `fleet_worktree_create` — `branch` / `base`（current|default）を受け、
  worktree を作成して自カードにバインド。バリデーションは UI と同一ロジックを共有。

## 撤去と安全性（最優先要件: 誤削除の防止）

**Done では絶対に消さない。** 撤去はカード削除操作のときだけ、かつ
`isFleetOwnedWorktree == true` のカードのみを候補にする。

削除前チェック（すべて `git -C <worktreePath>` / `git -C <repoRoot>`）:
1. **使用中**（ライブセッションあり）→ 削除不可。
2. **未コミット**: `git status --porcelain` が非空 → 危険。
3. **未プッシュ / 未マージ**: upstream があれば `git log @{u}..` が非空、
   なければ「デフォルトブランチにマージ済みか」を確認。非マージ → 危険。

判定結果に応じて:
- クリーン → 確認ダイアログの上で `git worktree remove <path>`（**`--force` 無し**）
  ＋ 必要に応じ `git worktree prune`。ブランチ自体は消さない（誤削除防止。
  ブランチ削除は別途明示操作）。
- 危険（2 or 3 に該当）→ **失う内容を列挙した警告ダイアログ**。選択肢:
  - 「カードだけ削除（worktree はディスクに残す＝unlink）」
  - 「ターミナルを開いて手動で処理」
  - キャンセル
  いずれの場合も Fleet は `--force` しない。

不変条件:
- Fleet は `isFleetOwnedWorktree == false` の worktree / フォルダを削除しない。
- Fleet は `--force` 系の破壊的フラグを一切使わない。
- メインリポジトリ working dir を worktree として撤去しない。

## 非ゴール

- エディタ連携（Open in Zed / `zed <path>`）— 次段。
- `create_worktree` セットアップフック — 次段。
- 既存ブランチの一括 worktree 化 UI / base ref の自由入力 — 現時点では2択のみ。
- ブランチの自動削除 — worktree 撤去とブランチ削除は分離。

## 影響ファイル（想定）

- `Sources/KanbanKit/Models.swift` — Card フィールド追加。
- `Sources/KanbanKit/BoardStore.swift` — worktree バインド設定 / setter。
- 新規 `Sources/KanbanKit/WorktreeService.swift`（案）— 作成・削除・検証の純ロジック
  （UI/MCP で共有、単体テスト対象）。
- `Sources/KanbanTerm/Views/NewCardSheet.swift` — モード切替 UI。
- `Sources/KanbanTerm/Views/BoardView.swift` — cwd 入力を worktreePath 優先に、
  カード削除時の撤去フロー / 警告ダイアログ。
- `Sources/KanbanTerm/Views/TerminalView.swift` — シェル起動 directory を
  worktreePath 優先に。
- `Sources/KanbanTerm/Views/GitHubService.swift` — 変更不要（cwd を渡すだけ）。
- `Sources/fleet-bridge/main.swift` — `fleet_worktree_info` / `fleet_worktree_create`。
- `Tests/KanbanKitTests/` — WorktreeService の検証ロジックのテスト。

## テスト方針

- `WorktreeService` の純ロジック（配置パス生成、ブランチ名 sanitize、
  作成前バリデーション、削除前の危険判定の分岐）を単体テスト。
- git 実行を伴う部分は、一時 git リポジトリを作って E2E 的に検証
  （dirty / 未プッシュ / 使用中の各ケースで削除がブロックされること）。
- FSL 候補: worktree のライフサイクル（未作成→作成→使用中→撤去可/不可）と
  「dirty または未プッシュのとき撤去不可」という安全不変条件は state machine +
  invariant で表現でき、検証ペイオフがある。実装計画で要否を判断。
