# Fleet-managed git worktrees Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** カードが「Fleet が所有する git worktree」に紐づけられるようにし、シェルを worktree で起動することで PR/branch 判定のズレを構造的に解消する。

**Architecture:** Card に worktree バインディング (`repoRoot` / `worktreePath` / `isFleetOwnedWorktree`) を持たせ、純ロジックを `WorktreeService`(KanbanKit) に集約して UI と MCP で共有する。cwd 解決は `worktreePath ?? workingDirPath`。撤去はカード削除時のみ・`--force` 禁止・dirty/未プッシュ/使用中は保護。

**Tech Stack:** Swift 6 / SwiftUI / SwiftData (macOS 26), XcodeGen, `git` CLI(Process 経由), swift-testing(KanbanKitTests)。

## Global Constraints

- Swift 6 / macOS 26 / `project.yml` が真実の源。ファイル新設時は `xcodegen generate` を実行。
- Co-author trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。
- **worktree 誤削除防止は最優先の不変条件**: `git worktree remove --force` を一切使わない／`isFleetOwnedWorktree == true` 以外は削除しない／dirty・未プッシュ/未マージ・使用中は削除しない／メインリポジトリ working dir を撤去しない。
- 削除系の破壊的操作を MCP ツールとして公開しない。
- 既存のフォルダ選択カード運用と共存（worktree は opt-in）。
- git 実行は既存 `GitHubService` と同じく login zsh 経由ではなく直接 `Process`/`git -C <dir>` で。cwd は明示。

---

### Task 1: Card モデルに worktree バインディング追加

**Files:**
- Modify: `Sources/KanbanKit/Models.swift`（Card プロパティと init）
- Modify: `Sources/KanbanKit/BoardStore.swift`（setter 追加）
- Test: `Tests/KanbanKitTests/WorktreeBindingTests.swift`（Create）

**Interfaces:**
- Produces:
  - `Card.repoRoot: String?`, `Card.worktreePath: String?`, `Card.isFleetOwnedWorktree: Bool`
  - `Card.effectiveCwd: String?`（`worktreePath ?? workingDirPath` を返す computed）
  - `BoardStore.setWorktree(_ card: Card, repoRoot: String, worktreePath: String, branch: String, fleetOwned: Bool)`
  - `BoardStore.clearWorktree(_ card: Card)`（バインディングのみ解除。ディスクは触らない）

- [ ] **Step 1: 失敗するテストを書く** — `Tests/KanbanKitTests/WorktreeBindingTests.swift`

```swift
import Testing
import SwiftData
@testable import KanbanKit

@Suite struct WorktreeBindingTests {
    @MainActor private func ctx() throws -> ModelContext {
        let c = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Board.self, Column.self, Card.self, Channel.self, configurations: c)
        return ModelContext(container)
    }

    @Test @MainActor func setAndClearWorktree() throws {
        let context = try ctx()
        let store = BoardStore(context: context)
        let board = store.ensureDefaultBoard()
        let card = store.addCard(to: board.columns[0], title: "t", agentKind: .claude)

        store.setWorktree(card, repoRoot: "/repo", worktreePath: "/repo/../.fleet-worktrees/x", branch: "x", fleetOwned: true)
        #expect(card.repoRoot == "/repo")
        #expect(card.worktreePath == "/repo/../.fleet-worktrees/x")
        #expect(card.branch == "x")
        #expect(card.isFleetOwnedWorktree == true)
        #expect(card.effectiveCwd == "/repo/../.fleet-worktrees/x")

        store.clearWorktree(card)
        #expect(card.worktreePath == nil)
        #expect(card.isFleetOwnedWorktree == false)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `xcodebuild test -scheme Fleet -destination 'platform=macOS' -only-testing:KanbanKitTests/WorktreeBindingTests 2>&1 | tail -20`
Expected: コンパイルエラー（プロパティ/メソッド未定義）。

- [ ] **Step 3: 最小実装** — `Models.swift` の Card に既存 optional 群と並べて追加（lightweight migration のため default 付き）:

```swift
var repoRoot: String? = nil
var worktreePath: String? = nil
var isFleetOwnedWorktree: Bool = false

var effectiveCwd: String? { worktreePath ?? workingDirPath }
```

`BoardStore.swift` に（`setCardDirectory` の近くに）:

```swift
func setWorktree(_ card: Card, repoRoot: String, worktreePath: String, branch: String, fleetOwned: Bool) {
    card.repoRoot = repoRoot
    card.worktreePath = worktreePath
    card.branch = branch
    card.isFleetOwnedWorktree = fleetOwned
    try? context.save()
}

func clearWorktree(_ card: Card) {
    card.worktreePath = nil
    card.repoRoot = nil
    card.isFleetOwnedWorktree = false
    try? context.save()
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `xcodebuild test -scheme Fleet -destination 'platform=macOS' -only-testing:KanbanKitTests/WorktreeBindingTests 2>&1 | tail -20`
Expected: PASS。

- [ ] **Step 5: コミット**

```bash
git add Sources/KanbanKit/Models.swift Sources/KanbanKit/BoardStore.swift Tests/KanbanKitTests/WorktreeBindingTests.swift
git commit -m "feat: Card に worktree バインディング(repoRoot/worktreePath/isFleetOwnedWorktree)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: WorktreeService — 純ロジック（配置パス・sanitize・作成前バリデーション・撤去前危険判定）

**Files:**
- Create: `Sources/KanbanKit/WorktreeService.swift`
- Test: `Tests/KanbanKitTests/WorktreeServiceLogicTests.swift`（Create）
- Modify: `project.yml` は不要（KanbanKit の sources はディレクトリ指定なので自動取り込み）だが、新規ファイル追加後 `xcodegen generate` を実行。

**Interfaces:**
- Produces:
  - `enum WorktreeBase { case current, defaultBranch }`
  - `struct WorktreeService`（git 実行は closure 注入でテスト可能に）:
    - `static func sanitizeBranch(_ raw: String) -> String`（`[^A-Za-z0-9._/-]`→`-`、連続 `-` 畳み、前後 `-`/`/` 除去、空なら `"work"`）
    - `static func worktreePath(repoRoot: String, branch: String, baseDir: String) -> String`（`baseDir` 既定 `"../.fleet-worktrees"` を repoRoot 基準で解決し `/<sanitized>` 付与。返り値は絶対パス）
    - `enum RemovalRisk { case clean, dirty, unpushed, inUse }`
    - `static func classifyRemoval(porcelain: String, aheadCount: Int, mergedIntoDefault: Bool, inUse: Bool) -> RemovalRisk`（優先度: inUse > dirty(porcelain 非空) > unpushed(ahead>0 または !merged) > clean）

- [ ] **Step 1: 失敗するテスト** — `Tests/KanbanKitTests/WorktreeServiceLogicTests.swift`

```swift
import Testing
@testable import KanbanKit

@Suite struct WorktreeServiceLogicTests {
    @Test func sanitize() {
        #expect(WorktreeService.sanitizeBranch("Fix: login bug!!") == "Fix-login-bug")
        #expect(WorktreeService.sanitizeBranch("  --a//b-- ") == "a/b")
        #expect(WorktreeService.sanitizeBranch("") == "work")
    }
    @Test func pathUnderFleetWorktrees() {
        let p = WorktreeService.worktreePath(repoRoot: "/Users/me/proj", branch: "feature/x", baseDir: "../.fleet-worktrees")
        #expect(p == "/Users/me/.fleet-worktrees/feature/x")
    }
    @Test func removalPriority() {
        #expect(WorktreeService.classifyRemoval(porcelain: " M a", aheadCount: 0, mergedIntoDefault: true, inUse: false) == .dirty)
        #expect(WorktreeService.classifyRemoval(porcelain: "", aheadCount: 2, mergedIntoDefault: false, inUse: false) == .unpushed)
        #expect(WorktreeService.classifyRemoval(porcelain: "", aheadCount: 0, mergedIntoDefault: true, inUse: false) == .clean)
        #expect(WorktreeService.classifyRemoval(porcelain: " M a", aheadCount: 0, mergedIntoDefault: true, inUse: true) == .inUse)
        #expect(WorktreeService.classifyRemoval(porcelain: "", aheadCount: 0, mergedIntoDefault: false, inUse: false) == .unpushed)
    }
}
```

- [ ] **Step 2: 失敗確認** — Run: `xcodebuild test -scheme Fleet -destination 'platform=macOS' -only-testing:KanbanKitTests/WorktreeServiceLogicTests 2>&1 | tail -20` / Expected: 未定義エラー。

- [ ] **Step 3: 実装** — `Sources/KanbanKit/WorktreeService.swift`

```swift
import Foundation

public enum WorktreeBase { case current, defaultBranch }

public struct WorktreeService {
    public static func sanitizeBranch(_ raw: String) -> String {
        var s = raw.map { c -> Character in
            c.isLetter || c.isNumber || "._/-".contains(c) ? c : "-"
        }.reduce(into: "") { acc, c in
            if c == "-" && acc.last == "-" { return }
            acc.append(c)
        }
        while let f = s.first, f == "-" || f == "/" { s.removeFirst() }
        while let l = s.last, l == "-" || l == "/" { s.removeLast() }
        return s.isEmpty ? "work" : s
    }

    public static func worktreePath(repoRoot: String, branch: String, baseDir: String) -> String {
        let base = URL(fileURLWithPath: repoRoot).appendingPathComponent(baseDir).standardizedFileURL
        return base.appendingPathComponent(sanitizeBranch(branch)).standardizedFileURL.path
    }

    public enum RemovalRisk { case clean, dirty, unpushed, inUse }

    public static func classifyRemoval(porcelain: String, aheadCount: Int, mergedIntoDefault: Bool, inUse: Bool) -> RemovalRisk {
        if inUse { return .inUse }
        if !porcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .dirty }
        if aheadCount > 0 || !mergedIntoDefault { return .unpushed }
        return .clean
    }
}
```

- [ ] **Step 4: 通過確認** — Run 同上 / Expected: PASS。ファイル新設したので `xcodegen generate` を先に実行してから test。

- [ ] **Step 5: コミット**

```bash
xcodegen generate
git add Sources/KanbanKit/WorktreeService.swift Tests/KanbanKitTests/WorktreeServiceLogicTests.swift project.yml
git commit -m "feat: WorktreeService 純ロジック(sanitize/path/撤去危険判定)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: WorktreeService — git 実行（作成・安全撤去・情報取得）

**Files:**
- Modify: `Sources/KanbanKit/WorktreeService.swift`
- Test: `Tests/KanbanKitTests/WorktreeServiceGitTests.swift`（Create、一時 git リポジトリで E2E）

**Interfaces:**
- Consumes: Task 2 の `sanitizeBranch`/`worktreePath`/`classifyRemoval`。
- Produces:
  - `struct GitError: Error { let message: String }`
  - `static func run(_ args: [String], in dir: String) throws -> String`（`git -C <dir> <args>`、非0終了で GitError、stdout trim 返し）
  - `static func defaultBranch(repoRoot: String) -> String`（`git symbolic-ref --quiet refs/remotes/origin/HEAD` → 末尾名、失敗時 `git rev-parse --abbrev-ref HEAD`、最終 fallback `"main"`）
  - `static func branchExists(repoRoot: String, branch: String) -> Bool`
  - `static func create(repoRoot: String, branch: String, base: WorktreeBase, baseDir: String) throws -> String`（バリデーション → `git worktree add -b <branch> <path> <baseRef>` → worktreePath 返し）。branch 既存なら `GitError`。
  - `static func removalRisk(worktreePath: String, repoRoot: String, inUse: Bool) -> RemovalRisk`
  - `static func removeSafely(worktreePath: String, repoRoot: String, inUse: Bool) throws`（risk != clean なら `GitError`。clean のみ `git worktree remove <path>`（--force 無し）＋ `git worktree prune`）

- [ ] **Step 1: 失敗するテスト** — 一時ディレクトリに git リポジトリを作って検証

```swift
import Testing
import Foundation
@testable import KanbanKit

@Suite struct WorktreeServiceGitTests {
    private func tmpRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "wt-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = try WorktreeService.run(["init", "-b", "main"], in: dir)
        _ = try WorktreeService.run(["config", "user.email", "t@t"], in: dir)
        _ = try WorktreeService.run(["config", "user.name", "t"], in: dir)
        FileManager.default.createFile(atPath: dir + "/README", contents: Data("hi".utf8))
        _ = try WorktreeService.run(["add", "."], in: dir)
        _ = try WorktreeService.run(["commit", "-m", "init"], in: dir)
        return dir
    }

    @Test func createThenCleanRemove() throws {
        let repo = try tmpRepo()
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/x", base: .current, baseDir: "../.fleet-worktrees")
        #expect(FileManager.default.fileExists(atPath: path))
        // clean なので撤去できる
        #expect(WorktreeService.removalRisk(worktreePath: path, repoRoot: repo, inUse: false) == .clean)
        try WorktreeService.removeSafely(worktreePath: path, repoRoot: repo, inUse: false)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func dirtyBlocksRemoval() throws {
        let repo = try tmpRepo()
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/y", base: .current, baseDir: "../.fleet-worktrees")
        FileManager.default.createFile(atPath: path + "/dirty.txt", contents: Data("x".utf8))
        #expect(WorktreeService.removalRisk(worktreePath: path, repoRoot: repo, inUse: false) == .dirty)
        #expect(throws: WorktreeService.GitError.self) {
            try WorktreeService.removeSafely(worktreePath: path, repoRoot: repo, inUse: false)
        }
        #expect(FileManager.default.fileExists(atPath: path)) // 残っている
    }

    @Test func duplicateBranchRejected() throws {
        let repo = try tmpRepo()
        _ = try WorktreeService.create(repoRoot: repo, branch: "dup", base: .current, baseDir: "../.fleet-worktrees")
        #expect(throws: WorktreeService.GitError.self) {
            _ = try WorktreeService.create(repoRoot: repo, branch: "dup", base: .current, baseDir: "../.fleet-worktrees")
        }
    }
}
```

- [ ] **Step 2: 失敗確認** — Run: `xcodebuild test -scheme Fleet -destination 'platform=macOS' -only-testing:KanbanKitTests/WorktreeServiceGitTests 2>&1 | tail -30` / Expected: 未定義エラー。

- [ ] **Step 3: 実装** — `WorktreeService` に追記

```swift
extension WorktreeService {
    public struct GitError: Error { public let message: String }

    @discardableResult
    public static func run(_ args: [String], in dir: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir] + args
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run(); p.waitUntilExit()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GitError(message: e.isEmpty ? o : e)
        }
        return o.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func defaultBranch(repoRoot: String) -> String {
        if let r = try? run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], in: repoRoot),
           let name = r.split(separator: "/").last { return String(name) }
        if let cur = try? run(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot), !cur.isEmpty { return cur }
        return "main"
    }

    public static func branchExists(repoRoot: String, branch: String) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], in: repoRoot)) != nil
            && ((try? run(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], in: repoRoot))?.isEmpty == false)
    }

    public static func create(repoRoot: String, branch: String, base: WorktreeBase, baseDir: String) throws -> String {
        let b = sanitizeBranch(branch)
        if branchExists(repoRoot: repoRoot, branch: b) {
            throw GitError(message: "branch '\(b)' は既に存在します。別名にしてください。")
        }
        let path = worktreePath(repoRoot: repoRoot, branch: b, baseDir: baseDir)
        if FileManager.default.fileExists(atPath: path) {
            throw GitError(message: "配置先が既に存在します: \(path)")
        }
        let baseRef: String
        switch base {
        case .current: baseRef = (try? run(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot)) ?? "HEAD"
        case .defaultBranch: baseRef = defaultBranch(repoRoot: repoRoot)
        }
        try run(["worktree", "add", "-b", b, path, baseRef], in: repoRoot)
        return path
    }

    public static func removalRisk(worktreePath: String, repoRoot: String, inUse: Bool) -> RemovalRisk {
        let porcelain = (try? run(["status", "--porcelain"], in: worktreePath)) ?? ""
        let ahead = Int((try? run(["rev-list", "--count", "@{u}..HEAD"], in: worktreePath)) ?? "0") ?? 0
        let hasUpstream = (try? run(["rev-parse", "--abbrev-ref", "@{u}"], in: worktreePath)) != nil
        let def = defaultBranch(repoRoot: repoRoot)
        let merged = (try? run(["merge-base", "--is-ancestor", "HEAD", def], in: worktreePath)) != nil
        // upstream があれば ahead を、無ければ「default にマージ済みか」を使う
        let mergedIntoDefault = hasUpstream ? true : merged
        let aheadCount = hasUpstream ? ahead : 0
        return classifyRemoval(porcelain: porcelain, aheadCount: aheadCount, mergedIntoDefault: mergedIntoDefault, inUse: inUse)
    }

    public static func removeSafely(worktreePath: String, repoRoot: String, inUse: Bool) throws {
        let risk = removalRisk(worktreePath: worktreePath, repoRoot: repoRoot, inUse: inUse)
        guard risk == .clean else {
            throw GitError(message: "撤去できません(\(risk))。--force は使いません。")
        }
        try run(["worktree", "remove", worktreePath], in: repoRoot)
        _ = try? run(["worktree", "prune"], in: repoRoot)
    }
}
```

> 注: `merge-base --is-ancestor` は終了コードで判定するため、成功時 `run` は空文字を返すが例外を投げない＝「祖先である」。upstream 無しローカルブランチで `@{u}` は失敗するので `hasUpstream` で分岐している。

- [ ] **Step 4: 通過確認** — Run 同上 / Expected: 3 テスト PASS。

- [ ] **Step 5: コミット**

```bash
git add Sources/KanbanKit/WorktreeService.swift Tests/KanbanKitTests/WorktreeServiceGitTests.swift
git commit -m "feat: WorktreeService の git 実行(作成/安全撤去/危険判定)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: cwd 解決を worktreePath 優先に（PR ズレ修正の本体）

**Files:**
- Modify: `Sources/KanbanTerm/Views/BoardView.swift`（`fetchGitInfo` の cwd 取得 :307 付近、`refreshVisibleGitInfo`、terminal に渡す directory :221）
- Modify: `Sources/KanbanTerm/Views/TerminalView.swift`（`refreshCwd` が worktree カードでは workingDirPath を上書きしないよう保護）

**Interfaces:**
- Consumes: `Card.effectiveCwd`（Task 1）。
- Produces: なし（挙動修正）。

- [ ] **Step 1: BoardView の cwd 取得を effectiveCwd に**

`fetchGitInfo(for:)` 内 `card?.workingDirPath` を参照している箇所（:307）を:

```swift
guard let cwd = BoardStore(context: context).card(withID: cardID)?.effectiveCwd else { return }
```

terminal overlay に渡す directory（:221 付近 `directory: card.workingDirPath`）を:

```swift
directory: card.effectiveCwd
```

- [ ] **Step 2: refreshCwd の worktree 保護** — `TerminalView.refreshCwd`（:487-495）で、対象カードが `worktreePath != nil` の場合は pid cwd による `workingDirPath` 上書きをスキップ（worktree の cwd は確定済みで、pid 追従は worktree を壊す方向にしか働かないため）:

```swift
// worktree 所有カードは cwd が確定しているので pid 追従で上書きしない
if card.worktreePath != nil { return }
```

- [ ] **Step 3: ビルド確認**

Run: `xcodebuild -scheme Fleet -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 4: 手動確認メモ（実機）** — worktree カードを開き、ターミナルを閉じて再表示 → カードの branch/PR が worktree のものになっていること。自動テスト対象外。

- [ ] **Step 5: コミット**

```bash
git add Sources/KanbanTerm/Views/BoardView.swift Sources/KanbanTerm/Views/TerminalView.swift
git commit -m "fix: cwd 解決を worktreePath 優先に(PR/branch のズレを構造的に解消)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: NewCardSheet に worktree 作成モード

**Files:**
- Modify: `Sources/KanbanTerm/Views/NewCardSheet.swift`
- Modify: `Sources/KanbanTerm/Views/ColumnView.swift`（新カード確定時に worktree を作成しバインド）

**Interfaces:**
- Consumes: `WorktreeService.create`（Task 3）, `BoardStore.setWorktree`（Task 1）。
- Produces: なし（UI）。

- [ ] **Step 1: シートにモード状態を追加** — `NewCardSheet` に:

```swift
enum Mode: String, CaseIterable { case folder = "既存フォルダ", worktree = "worktree を作る" }
@State private var mode: Mode = .folder
@State private var repoRoot: String? = nil
@State private var branchName: String = ""
@State private var base: WorktreeBase = .current
@State private var wtError: String? = nil
```

Picker（`Picker("", selection: $mode)` segmented）を追加し、`.worktree` のとき: repo 選択の `.fileImporter`、`TextField("ブランチ名", text: $branchName)`（`.onAppear` で `branchName = WorktreeService.sanitizeBranch(title)` を初期値に）、`Picker("ベース", selection: $base)`（current / defaultBranch）を表示。`wtError` があれば赤字表示。

- [ ] **Step 2: 確定ハンドラで worktree 作成** — 作成ボタンの action（ColumnView 側の onCreate、:43 付近）で mode により分岐:

```swift
if mode == .worktree, let repo = repoRoot {
    do {
        let path = try WorktreeService.create(repoRoot: repo, branch: branchName, base: base, baseDir: "../.fleet-worktrees")
        let card = store.addCard(to: column, title: title, agentKind: kind)
        store.setWorktree(card, repoRoot: repo, worktreePath: path, branch: WorktreeService.sanitizeBranch(branchName), fleetOwned: true)
    } catch let e as WorktreeService.GitError {
        wtError = e.message   // シートを閉じずにエラー表示
        return
    }
} else {
    let card = store.addCard(to: column, title: title, agentKind: kind)
    if let dir = workingDirPath { store.setCardDirectory(card, path: dir) }
}
```

- [ ] **Step 3: ビルド確認** — Run: `xcodebuild -scheme Fleet -destination 'platform=macOS' build 2>&1 | tail -5` / Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 手動確認メモ** — 新カード作成で worktree モード → `.fleet-worktrees/<branch>` が生成され、カードがそれにバインドされる。重複ブランチ名だとシート内にエラー表示され作成されない。

- [ ] **Step 5: コミット**

```bash
git add Sources/KanbanTerm/Views/NewCardSheet.swift Sources/KanbanTerm/Views/ColumnView.swift
git commit -m "feat: 新カードで worktree 作成モード(repo/ブランチ名/ベース選択)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: カード削除時の安全な worktree 撤去フロー

**Files:**
- Modify: `Sources/KanbanTerm/Views/CardView.swift`（削除メニュー/確認）または削除を担う箇所
- Modify: `Sources/KanbanTerm/Views/BoardView.swift`（削除確認ダイアログの提示）

**Interfaces:**
- Consumes: `WorktreeService.removalRisk` / `removeSafely`（Task 3）, `sessions.hasSession`（inUse 判定）。
- Produces: なし（UI + 破壊防止フロー）。

- [ ] **Step 1: 削除ハンドラの分岐** — カード削除時、`card.isFleetOwnedWorktree`, `card.worktreePath`, `card.repoRoot` が揃うとき:

```swift
let inUse = sessions.hasSession(card.id)
let risk = WorktreeService.removalRisk(worktreePath: wt, repoRoot: repo, inUse: inUse)
switch risk {
case .clean:
    // 確認ダイアログ「worktree も削除しますか？」→ はい: removeSafely, いいえ: clearWorktree のみ
case .inUse, .dirty, .unpushed:
    // 警告ダイアログ: 失う/ブロック理由を明示し、選択肢を提示
    //  - 「カードだけ削除(worktree はディスクに残す)」→ clearWorktree + カード削除
    //  - 「ターミナルを開いて手動処理」→ 削除中止しカードを開く
    //  - キャンセル
}
```

`--force` に相当する経路は作らない。危険時は Fleet からは絶対に消えない。

- [ ] **Step 2: ダイアログ実装** — `.confirmationDialog` / `.alert` で上記選択肢を提示。`removeSafely` が throw したら「削除できませんでした」を表示しカードは残す（worktree も残す）。

- [ ] **Step 3: ビルド確認** — Run: `xcodebuild -scheme Fleet -destination 'platform=macOS' build 2>&1 | tail -5` / Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 手動確認メモ** — (a) clean な worktree カード削除→確認後にディスクからも消える。(b) dirty な worktree→警告が出て「カードだけ削除」を選ぶと worktree は残る。(c) セッション起動中→inUse で消せない。

- [ ] **Step 5: コミット**

```bash
git add Sources/KanbanTerm/Views/CardView.swift Sources/KanbanTerm/Views/BoardView.swift
git commit -m "feat: カード削除時の安全な worktree 撤去(dirty/未プッシュ/使用中は保護)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: fleet-bridge に worktree MCP ツール（read + create のみ）

**Files:**
- Modify: `Sources/fleet-bridge/main.swift`

**Interfaces:**
- Consumes: binding.json（`--card` からチャンネル/カード解決）, `WorktreeService`（fleet-bridge は KanbanKit をリンクしていないため、必要な git ロジックは main.swift 内に最小移植 or カードのバインディング情報を channel 経由で読む）。
- Produces:
  - MCP tool `fleet_worktree_info`（引数なし）→ 自カードの `repoRoot`/`branch`/`worktreePath`/`isFleetOwnedWorktree`。
  - MCP tool `fleet_worktree_create`（`branch: string`, `base: "current"|"default"`）→ 作成し結果パスを返す。
- **削除系ツールは追加しない。**

> 注: fleet-bridge が Card の SwiftData を直接読めないため、バインディング情報の受け渡し方法（既存の binding.json / status ファイルにカードの repoRoot/worktreePath を含めて Hub 側から書き出す）を実装前に確認する。最小案: `A2AChannelHub.writeBoardSnapshot` にカードの worktree 情報を含め、bridge はそれを読む。create は bridge から `git worktree add` を実行し、完了を Hub が検知してカードにバインド（既存の Codex セッション捕捉と同じ「ファイル監視で反映」パターン）。

- [ ] **Step 1: board snapshot に worktree 情報を含める** — `BoardStore.writeBoardSnapshot`/`BoardSnapshot`(ChannelStore) に `repoRoot`/`worktreePath`/`branch` を追加。

- [ ] **Step 2: bridge に `fleet_worktree_info` を実装** — snapshot/binding から自カード分を返す read-only ツール。

- [ ] **Step 3: bridge に `fleet_worktree_create` を実装** — `git worktree add -b` を実行。作成後 Hub がファイル監視で検知しカードに `setWorktree`。

- [ ] **Step 4: プロトコルテスト** — 既存の fleet-bridge プロトコルテスト手順で `tools/list` に両ツールが出ること、`fleet_worktree_info` が JSON を返すことを確認。

- [ ] **Step 5: コミット**

```bash
git add Sources/fleet-bridge/main.swift Sources/KanbanKit/ChannelStore.swift Sources/KanbanKit/BoardStore.swift Sources/KanbanTerm/Views/A2AChannelHub.swift
git commit -m "feat: fleet_worktree_info/create MCP(削除系は非公開)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:** データモデル(Task1) / 作成フロー(Task5) / 配置(Task2,3) / PR 修正(Task4) / MCP(Task7) / 撤去と安全(Task3,6) / 非ゴール(エディタ連携は含めず)。全 spec 節にタスクが対応。

**Placeholder scan:** Task 7 は fleet-bridge が SwiftData を直接読めない制約のため、実装前確認事項を明記した上で最小案を提示（純粋な placeholder ではなく設計上の分岐点）。他タスクは具体コードあり。

**Type consistency:** `effectiveCwd`, `setWorktree`, `clearWorktree`, `WorktreeService.create/removalRisk/removeSafely/sanitizeBranch/worktreePath/classifyRemoval`, `WorktreeBase`, `RemovalRisk`, `GitError` はタスク間で一貫。

**リスク/未確定:** Task 7 の bridge 越しの worktree 情報受け渡しが最も不確実。Task 1–6 だけでも「Fleet 本体で worktree 所有 + PR 修正」は完結する（MCP は追加価値）。実装は Task 順に、Task 6 まででいったん動作確認するのが安全。
