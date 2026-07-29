# 差分確認つき worktree 強制削除 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `.serena/` のような捨てて構わない差分で worktree 削除が塞がる問題を、差分を見やすく提示したうえで強制削除できるルートを足して解消する。

**Architecture:** `WorktreeService` に「差分プレビュー取得」と「強制撤去」を新ファイルで追加し、UI は新しいシート(`WorktreeForceDeleteSheet`)がそれを見せてから確定させる。安全性の担保は「dirty なら消さない」というサービス層の状態不変条件から、「差分を見せずに未コミット変更を捨てない/コミットは失わない」という損失ベースの不変条件へ移す。サービス層が守るのは「使用中は消さない」「ブランチ ref は消さない」の2点のみ。

**Tech Stack:** Swift 6 / SwiftUI / SwiftData / XcodeGen(`project.yml`)/ swift-testing(`import Testing`)/ 形式仕様は FizzBee 風 FSL(`fslc`)

## Global Constraints

- 設計の出典: `docs/superpowers/specs/2026-07-30-worktree-force-delete-design.md`。迷ったらこれが正
- 強制削除ルートに入れるのは `risk == .dirty` のときだけ。`.unpushed` / `.inUse` / `.clean` の既存挙動は変えない
- **ブランチ ref は絶対に削除しない。** `git branch -D` に相当する操作をこの機能で一切追加しない
- **`inUse` なら強制でも削除しない。** 走っているプロセスの cwd を消すのは差分を失うのとは別種の事故
- 外部 CLI は必ず `WorktreeService.run` 経由(`/bin/zsh -lc` でユーザー PATH を継承する既存の仕組み)。`Process` を直接組まない
- `git status` / `git diff` を叩くときは常に `-c core.quotePath=false` を付ける。無いと日本語パスが `"\346\227\245..."` にエスケープされて読めない
- git 呼び出しは MainActor で直接実行しない。既存パターンどおり `Task.detached(priority: .userInitiated)` に逃がし、渡すのは値型のみ(`Card` / `ModelContext` をキャプチャしない)
- コメントは日本語。既存コードの密度に合わせ、「なぜそうしたか」を書く(何をしているかの逐語訳は書かない)
- ビルド: `xcodegen generate` → `xcodebuild build -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS'`
- テスト: `xcodebuild test -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS'`
- `Sources/` はディレクトリ単位で glob されているので、新規ファイルを足したら `xcodegen generate` を再実行する(`Fleet.xcodeproj` は gitignore 対象なので commit しない)

---

### Task 1: `DirtyPreview` 型と `parsePorcelain`(純関数)

**Files:**
- Create: `Sources/KanbanKit/WorktreeForceDelete.swift`
- Test: `Tests/KanbanKitTests/WorktreeForceDeleteTests.swift`

**Interfaces:**
- Consumes: `WorktreeService`(`Sources/KanbanKit/WorktreeService.swift` の既存 struct。`extension` で足す)
- Produces:
  - `WorktreeService.DirtyPreview.Entry.Kind`: `enum { conflicted, deleted, staged, modified, untracked }`
  - `WorktreeService.DirtyPreview.Entry`: `init(kind:path:code:)` / `var id: String`(= path)/ `var isDirectory: Bool`
  - `WorktreeService.DirtyPreview`: `init(entries:statusError:)` / `let entries: [Entry]` / `let statusError: String?` / `func entries(of: Entry.Kind) -> [Entry]`
  - `WorktreeService.parsePorcelain(_ s: String) -> [DirtyPreview.Entry]`

- [ ] **Step 1: Write the failing test**

`Tests/KanbanKitTests/WorktreeForceDeleteTests.swift` を新規作成:

```swift
import Testing
import Foundation
@testable import KanbanKit

@Suite struct WorktreeForceDeleteParseTests {
    /// porcelain v1 の XY コードが表示グループへ正しく畳まれること。
    /// 分類は安全性の判定ではなく「これは捨てていいゴミか」を即断させるためのグルーピング。
    @Test func classifiesPorcelainCodes() {
        let out = """
        ?? .serena/
        ?? .DS_Store
         M Sources/KanbanKit/WorktreeService.swift
        M  Sources/KanbanTerm/Views/CardView.swift
        MM Sources/KanbanTerm/Views/ColumnView.swift
         D docs/old-note.md
        D  docs/removed.md
        UU Sources/conflict.swift
        """
        let e = WorktreeService.parsePorcelain(out)
        #expect(e.count == 8)
        #expect(e.first(where: { $0.path == ".serena/" })?.kind == .untracked)
        #expect(e.first(where: { $0.path == ".DS_Store" })?.kind == .untracked)
        #expect(e.first(where: { $0.path == "Sources/KanbanKit/WorktreeService.swift" })?.kind == .modified)
        #expect(e.first(where: { $0.path == "Sources/KanbanTerm/Views/CardView.swift" })?.kind == .staged)
        #expect(e.first(where: { $0.path == "Sources/KanbanTerm/Views/ColumnView.swift" })?.kind == .modified)
        #expect(e.first(where: { $0.path == "docs/old-note.md" })?.kind == .deleted)
        #expect(e.first(where: { $0.path == "docs/removed.md" })?.kind == .deleted)
        #expect(e.first(where: { $0.path == "Sources/conflict.swift" })?.kind == .conflicted)
    }

    /// 未追跡ディレクトリは porcelain が末尾スラッシュ付きで畳んで返す。
    /// UI はこれを「ディレクトリ」として表示し、diff の展開対象にしない。
    @Test func detectsUntrackedDirectory() {
        let e = WorktreeService.parsePorcelain("?? .serena/\n?? scratch.md\n")
        #expect(e[0].isDirectory)
        #expect(!e[1].isDirectory)
    }

    /// rename は "old -> new"。ディスク上に存在する new 側を表示する。
    @Test func renameUsesNewPath() {
        let e = WorktreeService.parsePorcelain("R  docs/a.md -> docs/b.md\n")
        #expect(e.count == 1)
        #expect(e[0].path == "docs/b.md")
        #expect(e[0].kind == .staged)
    }

    /// 日本語パスは `core.quotePath=false` 前提でそのまま通る(エスケープ解除は自前でやらない)。
    @Test func keepsNonASCIIPathAsIs() {
        let e = WorktreeService.parsePorcelain("?? docs/日本語メモ.md\n")
        #expect(e[0].path == "docs/日本語メモ.md")
    }

    /// 空行・末尾改行・XY だけでパスが無い壊れた行は捨てる(クラッシュしない)。
    @Test func ignoresBlankAndMalformedLines() {
        let e = WorktreeService.parsePorcelain("\n?? a.txt\n\n?? \nM\n")
        #expect(e.count == 1)
        #expect(e[0].path == "a.txt")
    }

    /// kind ごとの取り出しヘルパ(UI のセクション分けが使う)。
    @Test func groupsByKind() {
        let p = WorktreeService.DirtyPreview(
            entries: WorktreeService.parsePorcelain("?? a\n?? b/\n M c\n"),
            statusError: nil
        )
        #expect(p.entries(of: .untracked).count == 2)
        #expect(p.entries(of: .modified).count == 1)
        #expect(p.entries(of: .deleted).isEmpty)
        #expect(p.statusError == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodegen generate
xcodebuild test -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS' \
  -only-testing:KanbanKitTests/WorktreeForceDeleteParseTests 2>&1 | tail -25
```

Expected: コンパイルエラー(`parsePorcelain` / `DirtyPreview` が存在しない)

- [ ] **Step 3: Write minimal implementation**

`Sources/KanbanKit/WorktreeForceDelete.swift` を新規作成:

```swift
import Foundation

// 差分を確認したうえでの worktree 強制削除。
//
// `WorktreeService.removeSafely` は risk == .clean 以外を必ず拒否するが、`git status --porcelain`
// は `.serena/` のような未追跡ゴミも dirty として報告するため、それ1つで削除ルートが完全に塞がる
// (= 「安全のために何もしない」だけが成立し、許されるべき結末に到達できない)。
//
// ここが提供するのは、捨てられる差分を提示する `dirtyPreview` / `fileDiff` と、それを見たうえで
// 実行する `removeForcibly`。「差分を見せてから捨てる」の担保は UI 層(WorktreeForceDeleteSheet を
// 通らないと removeForcibly に到達しない)にあり、この層が守るのは
// 「使用中は消さない」「ブランチ ref は消さない」の2点だけ。
// 詳細は docs/superpowers/specs/2026-07-30-worktree-force-delete-design.md と
// worktree_force_delete.fsl を参照。
extension WorktreeService {
    /// 強制削除で捨てられるものの一覧。レビュー用ではなく「これは捨てていいゴミか」の即断用に絞る。
    public struct DirtyPreview: Sendable {
        public struct Entry: Sendable, Identifiable, Equatable {
            /// 表示グルーピングの単位。porcelain の XY コードをユーザー向けに畳んだもの。
            public enum Kind: Sendable, Equatable {
                case conflicted, deleted, staged, modified, untracked
            }

            public let kind: Kind
            public let path: String
            /// porcelain の XY 2文字。分類の根拠を UI/デバッグで示せるよう保持する。
            public let code: String

            public var id: String { path }

            /// porcelain は未追跡ディレクトリを "dir/" と末尾スラッシュ付きで1行に畳んで返す。
            /// これが true の行は diff の展開対象にしない(中身は git が追跡していない)。
            public var isDirectory: Bool { path.hasSuffix("/") }

            public init(kind: Kind, path: String, code: String) {
                self.kind = kind
                self.path = path
                self.code = code
            }
        }

        public let entries: [Entry]
        /// `git status` 自体が失敗した場合のみ非nil(index.lock 競合など)。
        /// このとき entries は空で、UI は「中身を確認せずに削除する」警告へ切り替える。
        public let statusError: String?

        public init(entries: [Entry], statusError: String? = nil) {
            self.entries = entries
            self.statusError = statusError
        }

        public func entries(of kind: Entry.Kind) -> [Entry] {
            entries.filter { $0.kind == kind }
        }
    }

    /// `git status --porcelain` (v1) の出力を表示用エントリへ分類する純関数。
    ///
    /// 優先順位: untracked(`??`) > conflicted(X/Y に U、または AA/DD) > deleted(D を含む) >
    /// staged(Y が空白 = worktree 側は変更なし) > modified。
    /// これは安全性の判定ではなく、リストのグルーピングのための分類。
    public static func parsePorcelain(_ s: String) -> [DirtyPreview.Entry] {
        s.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let raw = String(line)
            // "XY path" — XY は必ず2文字、続く1文字は区切りの空白。それより短い行は壊れているので捨てる。
            guard raw.count > 3 else { return nil }
            let code = String(raw.prefix(2))
            var path = String(raw.dropFirst(3))
            // rename/copy は "old -> new"。今ディスクにあるのは new 側なのでそちらを表示する。
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            guard !path.isEmpty else { return nil }
            guard let x = code.first, let y = code.last else { return nil }

            let kind: DirtyPreview.Entry.Kind
            if code == "??" {
                kind = .untracked
            } else if x == "U" || y == "U" || code == "AA" || code == "DD" {
                kind = .conflicted
            } else if x == "D" || y == "D" {
                kind = .deleted
            } else if y == " " {
                kind = .staged
            } else {
                kind = .modified
            }
            return DirtyPreview.Entry(kind: kind, path: path, code: code)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodegen generate
xcodebuild test -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS' \
  -only-testing:KanbanKitTests/WorktreeForceDeleteParseTests 2>&1 | tail -25
```

Expected: PASS(6 テスト)

- [ ] **Step 5: Commit**

```bash
git add Sources/KanbanKit/WorktreeForceDelete.swift Tests/KanbanKitTests/WorktreeForceDeleteTests.swift
git commit -m "feat: worktree の捨てられる差分を分類する DirtyPreview / parsePorcelain

git status --porcelain を untracked / conflicted / deleted / staged / modified
へ畳む純関数。未追跡ディレクトリの末尾スラッシュと rename の old -> new を扱う。"
```

---

### Task 2: `dirtyPreview` と `fileDiff`(実 git)

**Files:**
- Modify: `Sources/KanbanKit/WorktreeForceDelete.swift`(Task 1 の extension に追記)
- Test: `Tests/KanbanKitTests/WorktreeForceDeleteTests.swift`(新しい `@Suite` を追記)

**Interfaces:**
- Consumes: `WorktreeService.run(_:in:)`(既存、`internal`〜`public`。`@testable import` で到達可)/ `WorktreeService.parsePorcelain` / `WorktreeService.DirtyPreview`
- Produces:
  - `WorktreeService.dirtyPreview(worktreePath: String) -> DirtyPreview`(**throw しない**)
  - `WorktreeService.fileDiff(worktreePath: String, path: String) throws -> String`

- [ ] **Step 1: Write the failing test**

`Tests/KanbanKitTests/WorktreeForceDeleteTests.swift` の末尾に追記:

```swift
@Suite struct WorktreeForceDeleteGitTests {
    /// 既存 WorktreeServiceGitTests と同じ流儀の一時リポジトリ。
    private func tmpRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "wtf-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = try WorktreeService.run(["init", "-b", "main"], in: dir)
        _ = try WorktreeService.run(["config", "user.email", "t@t"], in: dir)
        _ = try WorktreeService.run(["config", "user.name", "t"], in: dir)
        FileManager.default.createFile(atPath: dir + "/README", contents: Data("hi\n".utf8))
        _ = try WorktreeService.run(["add", "."], in: dir)
        _ = try WorktreeService.run(["commit", "-m", "init"], in: dir)
        return dir
    }

    /// 未追跡ファイルと tracked 変更が混ざった worktree を、種類別に見分けられること。
    @Test func previewsUntrackedAndModified() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/preview", baseRef: "main", baseDir: ".fleet-worktrees")

        // 捨てて構わない未追跡ゴミ(この機能の動機そのもの)
        try FileManager.default.createDirectory(atPath: path + "/.serena", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/.serena/cache.json", contents: Data("{}".utf8))
        // tracked ファイルへの本物の変更
        try "hi\nchanged\n".write(toFile: path + "/README", atomically: true, encoding: .utf8)

        let p = WorktreeService.dirtyPreview(worktreePath: path)
        #expect(p.statusError == nil)
        #expect(p.entries(of: .untracked).contains { $0.path == ".serena/" && $0.isDirectory })
        #expect(p.entries(of: .modified).contains { $0.path == "README" })
    }

    /// tracked ファイルの diff が HEAD 比較で取れること。未追跡には呼ばない前提なので
    /// ここでは tracked のみを確認する。
    @Test func fileDiffShowsChangedLines() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/diff", baseRef: "main", baseDir: ".fleet-worktrees")
        try "hi\nchanged\n".write(toFile: path + "/README", atomically: true, encoding: .utf8)

        let d = try WorktreeService.fileDiff(worktreePath: path, path: "README")
        #expect(d.contains("+changed"))
        #expect(d.contains("@@"))
    }

    /// ステージ済みの変更も HEAD 比較で1本化して見えること
    /// (worktree ごと捨てるので index と worktree を分けて見せる意味がない)。
    @Test func fileDiffIncludesStagedChanges() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/staged", baseRef: "main", baseDir: ".fleet-worktrees")
        try "hi\nstaged\n".write(toFile: path + "/README", atomically: true, encoding: .utf8)
        _ = try WorktreeService.run(["add", "README"], in: path)

        let p = WorktreeService.dirtyPreview(worktreePath: path)
        #expect(p.entries(of: .staged).contains { $0.path == "README" })
        let d = try WorktreeService.fileDiff(worktreePath: path, path: "README")
        #expect(d.contains("+staged"))
    }

    /// fail-open ではなく fail-visible: git status が失敗しても throw せず statusError に載せる。
    /// 差分が取れないことを行き止まりにしないため(index.lock 競合で永久に塞がるのが直したい罠)。
    /// 既存 WorktreeServiceGitTests.statusFailureBlocksRemoval と同じく index の権限を剥奪して再現する。
    @Test func statusFailureSurfacesAsStatusError() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/lock", baseRef: "main", baseDir: ".fleet-worktrees")

        let gitFile = try String(contentsOfFile: path + "/.git", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(gitFile.hasPrefix("gitdir: "))
        let indexPath = String(gitFile.dropFirst("gitdir: ".count)) + "/index"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: indexPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: indexPath) }

        let p = WorktreeService.dirtyPreview(worktreePath: path)
        #expect(p.statusError != nil)
        #expect(p.entries.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS' \
  -only-testing:KanbanKitTests/WorktreeForceDeleteGitTests 2>&1 | tail -25
```

Expected: コンパイルエラー(`dirtyPreview` / `fileDiff` が存在しない)

- [ ] **Step 3: Write minimal implementation**

`Sources/KanbanKit/WorktreeForceDelete.swift` の `extension WorktreeService { ... }` 内、`parsePorcelain` の後に追記:

```swift
    /// 強制削除前のプレビューを取得する。**決して throw しない。**
    ///
    /// 差分が取れないことを行き止まりにしないため、失敗は `statusError` に載せて UI に判断させる
    /// (index.lock 競合で永久に削除できなくなるのが、この機能で直している罠そのもの)。
    ///
    /// `core.quotePath=false` が必須: 既定では非ASCIIパスが "\346\227\245..." と C エスケープされて
    /// 出力され、日本語ファイル名がまったく読めなくなる。
    public static func dirtyPreview(worktreePath: String) -> DirtyPreview {
        do {
            let out = try run(["-c", "core.quotePath=false", "status", "--porcelain"], in: worktreePath)
            return DirtyPreview(entries: parsePorcelain(out), statusError: nil)
        } catch let e as GitError {
            let msg = e.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return DirtyPreview(entries: [], statusError: msg.isEmpty ? "git status が失敗しました" : msg)
        } catch {
            return DirtyPreview(entries: [], statusError: "\(error)")
        }
    }

    /// 1ファイル分の diff。UI は行を開いたときだけ呼ぶ(巨大 diff の事前ロードで固まらせない)。
    ///
    /// index と worktree を分けず HEAD 比較で1本化する — worktree ごと捨てるので
    /// 「ステージ済みかどうか」は捨てて良いかの判断に効かない。
    /// 未追跡ファイルに対しては呼ばない(git が追跡していないので diff は空)。
    public static func fileDiff(worktreePath: String, path: String) throws -> String {
        try run(["-c", "core.quotePath=false", "diff", "HEAD", "--", path], in: worktreePath)
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS' \
  -only-testing:KanbanKitTests/WorktreeForceDeleteGitTests 2>&1 | tail -25
```

Expected: PASS(4 テスト)

- [ ] **Step 5: Commit**

```bash
git add Sources/KanbanKit/WorktreeForceDelete.swift Tests/KanbanKitTests/WorktreeForceDeleteTests.swift
git commit -m "feat: worktree の差分プレビュー取得(dirtyPreview / fileDiff)

dirtyPreview は throw せず失敗を statusError に載せる(差分が取れないことを
行き止まりにしない)。日本語パスのため core.quotePath=false を必ず付ける。"
```

---

### Task 3: `removeForcibly`(inUse ガード + ブランチ保持)

**Files:**
- Modify: `Sources/KanbanKit/WorktreeForceDelete.swift`
- Test: `Tests/KanbanKitTests/WorktreeForceDeleteTests.swift`(`WorktreeForceDeleteGitTests` に追記)

**Interfaces:**
- Consumes: `WorktreeService.run(_:in:)` / `WorktreeService.GitError(message:)`
- Produces: `WorktreeService.removeForcibly(worktreePath: String, repoRoot: String, inUse: Bool) throws`

- [ ] **Step 1: Write the failing test**

`WorktreeForceDeleteGitTests` の末尾(閉じ括弧の直前)に追記:

```swift
    /// 使用中(inUse)は強制でも削除しない。走っているプロセスの cwd を消すのは
    /// 差分を失うのとは別種の事故なので、このガードは強制ルートでも外さない。
    @Test func inUseBlocksForceRemoval() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/inuse", baseRef: "main", baseDir: ".fleet-worktrees")
        FileManager.default.createFile(atPath: path + "/dirty.txt", contents: Data("x".utf8))

        #expect(throws: WorktreeService.GitError.self) {
            try WorktreeService.removeForcibly(worktreePath: path, repoRoot: repo, inUse: true)
        }
        #expect(FileManager.default.fileExists(atPath: path))   // 残っている
    }

    /// この機能の本命: 未追跡ゴミ + tracked 変更 + 未プッシュコミットを抱えた worktree を
    /// 強制削除すると、ディレクトリは消えるが **ブランチとそのコミットは残る**。
    /// これが不変条件 NeverLoseCommits(removed => branch_kept)の実行可能な証拠。
    @Test func forceRemovalDiscardsWorkingTreeButKeepsBranchAndCommits() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/force", baseRef: "main", baseDir: ".fleet-worktrees")

        // 未プッシュのコミットを1つ作る(強制削除でも失われてはいけないもの)
        FileManager.default.createFile(atPath: path + "/kept.txt", contents: Data("keep me\n".utf8))
        _ = try WorktreeService.run(["add", "kept.txt"], in: path)
        _ = try WorktreeService.run(["commit", "-m", "unpushed work"], in: path)
        let sha = try WorktreeService.run(["rev-parse", "HEAD"], in: path)

        // 捨てられるべきもの: 未追跡ゴミ + tracked 変更
        try FileManager.default.createDirectory(atPath: path + "/.serena", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/.serena/cache.json", contents: Data("{}".utf8))
        try "hi\nthrow away\n".write(toFile: path + "/README", atomically: true, encoding: .utf8)

        // dirty が unpushed より優先されることの確認(強制ルートの入口は .dirty だけ)
        #expect(WorktreeService.removalRisk(worktreePath: path, repoRoot: repo, inUse: false) == .dirty)

        try WorktreeService.removeForcibly(worktreePath: path, repoRoot: repo, inUse: false)

        #expect(!FileManager.default.fileExists(atPath: path))                        // worktree は消えた
        #expect(WorktreeService.branchExists(repoRoot: repo, branch: "feat/force"))    // ブランチは残る
        let keptSHA = try WorktreeService.run(["rev-parse", "feat/force"], in: repo)
        #expect(keptSHA == sha)                                                        // コミットも残る
        // worktree の登録も掃除されている(prune 済み)
        let list = try WorktreeService.run(["worktree", "list"], in: repo)
        #expect(!list.contains(path))
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS' \
  -only-testing:KanbanKitTests/WorktreeForceDeleteGitTests 2>&1 | tail -25
```

Expected: コンパイルエラー(`removeForcibly` が存在しない)

- [ ] **Step 3: Write minimal implementation**

`Sources/KanbanKit/WorktreeForceDelete.swift` の extension 内、`fileDiff` の後に追記:

```swift
    /// worktree を強制的に撤去する(`git worktree remove --force`)。
    ///
    /// `removeSafely` と違い dirty / unpushed を許す。この層が守るのは2点だけ:
    ///
    /// - **使用中(inUse)は消さない。** 走っているプロセスの cwd を消すのは、差分を失うのとは
    ///   別種の事故。強制ルートでもこのガードは外さない。
    /// - **ブランチ ref は消さない。** `classifyRemoval` は dirty を unpushed より優先するため
    ///   dirty な worktree に未プッシュコミットが同居しているのは普通で、ブランチを残せば
    ///   強制削除で失うものを「未コミットの変更だけ」に限定できる。
    ///
    /// 「差分を見せてから捨てる」の担保はここではなく UI 層(WorktreeForceDeleteSheet を
    /// 通らないとこの関数に到達しない)にある。
    ///
    /// なお `--force` は worktree ディレクトリを丸ごと削除するので、`.gitignore` 対象の
    /// ファイル(`.build/` など)も一緒に消える。差分一覧には出ないので UI 側で明示すること。
    public static func removeForcibly(worktreePath: String, repoRoot: String, inUse: Bool) throws {
        if inUse {
            throw GitError(message: "セッションが使用中の worktree は強制削除もしません。先にセッションを終了してください。")
        }
        try run(["worktree", "remove", "--force", worktreePath], in: repoRoot)
        _ = try? run(["worktree", "prune"], in: repoRoot)
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS' \
  -only-testing:KanbanKitTests/WorktreeForceDeleteGitTests 2>&1 | tail -25
```

Expected: PASS(6 テスト)

- [ ] **Step 5: Commit**

```bash
git add Sources/KanbanKit/WorktreeForceDelete.swift Tests/KanbanKitTests/WorktreeForceDeleteTests.swift
git commit -m "feat: worktree の強制撤去 removeForcibly

dirty/unpushed は許すが inUse は拒否し、ブランチ ref は削除しない。
失うものを「未コミットの変更だけ」に限定する。"
```

---

### Task 4: 差分確認シート(`WorktreeForceDeleteSheet`)

**Files:**
- Create: `Sources/KanbanTerm/Views/WorktreeForceDeleteSheet.swift`

**Interfaces:**
- Consumes: `WorktreeService.dirtyPreview(worktreePath:)` / `WorktreeService.fileDiff(worktreePath:path:)` / `WorktreeService.DirtyPreview` / `WorktreeService.DirtyPreview.Entry.Kind`
- Produces: `WorktreeForceDeleteSheet(worktreePath: String, branchLabel: String, onConfirm: () -> Void)`

SwiftUI View なのでユニットテストは書かない(このリポジトリに View のテストは存在しない)。検証はビルド + Task 6 の手動確認。

- [ ] **Step 1: 実装を書く**

`Sources/KanbanTerm/Views/WorktreeForceDeleteSheet.swift` を新規作成:

```swift
import SwiftUI
import KanbanKit

/// 捨てられる差分を確認したうえで Fleet 所有 worktree を強制削除するシート。
///
/// `risk == .dirty` のときだけ到達する。**このシートを通らずに `removeForcibly` は呼ばれない**
/// — 「差分を見せずに未コミット変更を捨てない」という不変条件を担保しているのは、
/// サービス層のガードではなくこのシートの存在そのもの(worktree_force_delete.fsl の
/// NeverDiscardUncommittedWithoutReview に対応)。
///
/// 表示方針: 判断に必要なのは diff の精読ではなく「これは捨てていいゴミか」の即断なので、
/// 種類別のグルーピングと件数を主役にし、**未追跡は既定で畳む**(ゴミの大半がそこに来るため、
/// 畳んでおけば本命の modified が最初から目に入る)。diff 本文は行を開いたときだけ遅延ロードする。
struct WorktreeForceDeleteSheet: View {
    let worktreePath: String
    /// 「ブランチ <名前> は残る」と示すための表示名。
    let branchLabel: String
    /// 「破棄して削除」が押された。実際の削除は呼び出し側(CardView)が行う。
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var preview: WorktreeService.DirtyPreview?
    @State private var loading = true
    @State private var untrackedExpanded = false

    /// tracked 側のセクション(既定で展開)。未追跡だけ別扱いにする。
    private static let trackedKinds: [(WorktreeService.DirtyPreview.Entry.Kind, String)] = [
        (.conflicted, "衝突"),
        (.modified, "変更"),
        (.staged, "ステージ済み"),
        (.deleted, "削除"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            warningBand
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 460)
        .task { await loadPreview() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("差分を確認して worktree を強制削除")
                .font(.headline)
            Text(worktreePath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    /// 何が失われ、何が失われないかを最初に言い切る。
    /// statusError のときは「中身を確認せずに削除する」ことを隠さない。
    private var warningBand: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(warningText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
    }

    /// `Text` は String 変数を渡すと Markdown を解釈しないので、強調は記法ではなく語順で作る
    /// (先頭に危険側を置く)。
    private var warningText: String {
        if preview?.statusError != nil {
            return "中身を確認せずに削除します — 差分を取得できませんでした。ブランチ「\(branchLabel)」は残るのでコミットは失われません。"
        }
        return "未コミットの変更と未追跡ファイルは復元できません。ブランチ「\(branchLabel)」は残るのでコミットは失われません。"
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("差分を確認中…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let p = preview, let err = p.statusError {
            statusErrorPane(err)
        } else if let p = preview, p.entries.isEmpty {
            // 確認ダイアログを出した後に別プロセスが片付けた等。空を空として見せる。
            Text("捨てられる差分はありません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let p = preview {
            fileList(p)
        }
    }

    private func statusErrorPane(_ message: String) -> some View {
        VStack(spacing: 9) {
            Text("差分を取得できませんでした")
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
            Button("再試行") { Task { await loadPreview() } }
                .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileList(_ p: WorktreeService.DirtyPreview) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Self.trackedKinds, id: \.1) { kind, label in
                    let entries = p.entries(of: kind)
                    if !entries.isEmpty {
                        sectionHeader(label, count: entries.count)
                        ForEach(entries) { entry in
                            DiffRow(worktreePath: worktreePath, entry: entry)
                                .padding(.leading, 10)
                        }
                    }
                }
                let untracked = p.entries(of: .untracked)
                if !untracked.isEmpty {
                    DisclosureGroup(isExpanded: $untrackedExpanded) {
                        ForEach(untracked) { entry in
                            HStack(spacing: 7) {
                                Text(entry.code)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.orange)
                                Text(entry.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                if entry.isDirectory {
                                    Text("ディレクトリ")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 1)
                            .padding(.leading, 20)
                        }
                    } label: {
                        HStack {
                            Text("未追跡").font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(untracked.count) 件").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func sectionHeader(_ label: String, count: Int) -> some View {
        HStack {
            Text(label).font(.caption.weight(.semibold))
            Spacer()
            Text("\(count) 件").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 2)
    }

    private var footer: some View {
        HStack {
            Text("`.gitignore` 対象のファイル(`.build/` など)も worktree ごと削除されます")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("キャンセル") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("破棄して削除") {
                dismiss()
                onConfirm()
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            // 差分を見る前に押せてしまわないよう、プレビューの解決まで無効化する。
            .disabled(loading)
        }
        .padding(12)
    }

    // MARK: - Loading

    /// `git status` は数千件の未追跡を返すこともあるので MainActor では走らせない。
    private func loadPreview() async {
        loading = true
        let wt = worktreePath
        let p = await Task.detached(priority: .userInitiated) {
            WorktreeService.dirtyPreview(worktreePath: wt)
        }.value
        preview = p
        loading = false
    }
}

/// tracked な1ファイルの行。開いたときに初めて diff を取りに行く。
private struct DiffRow: View {
    let worktreePath: String
    let entry: WorktreeService.DirtyPreview.Entry

    /// 巨大 diff をそのまま流し込むと描画が固まるので、表示行数に上限を置く。
    /// 「捨てていいか」の判断に必要なのは冒頭なので、続きはターミナルで見ればよい。
    private static let maxLines = 400

    @State private var expanded = false
    @State private var diff: String?
    @State private var loadError: String?
    @State private var loading = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            diffBody
                .padding(.leading, 14)
                .padding(.top, 3)
        } label: {
            HStack(spacing: 7) {
                Text(entry.code)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(color)
                Text(entry.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
        }
        .padding(.trailing, 12)
        .padding(.vertical, 1)
        .onChange(of: expanded) { _, now in
            if now, diff == nil, loadError == nil, !loading { load() }
        }
    }

    private var color: Color {
        switch entry.kind {
        case .conflicted: return .purple
        case .deleted: return .red
        case .staged: return .green
        case .modified: return .blue
        case .untracked: return .orange
        }
    }

    @ViewBuilder
    private var diffBody: some View {
        if loading {
            ProgressView().controlSize(.small)
        } else if let e = loadError {
            Text("diff を取得できませんでした: \(e)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let d = diff {
            let lines = d.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(Self.maxLines).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Self.lineColor(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if lines.count > Self.maxLines {
                    Text("… 以下 \(lines.count - Self.maxLines) 行省略")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .textSelection(.enabled)
            .padding(6)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private static func lineColor(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("@@") { return .purple }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .secondary
    }

    private func load() {
        loading = true
        let wt = worktreePath, p = entry.path
        Task {
            let result: Result<String, WorktreeService.GitError> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try WorktreeService.fileDiff(worktreePath: wt, path: p))
                } catch let e as WorktreeService.GitError {
                    return .failure(e)
                } catch {
                    return .failure(WorktreeService.GitError(message: "\(error)"))
                }
            }.value
            loading = false
            switch result {
            case .success(let d):
                diff = d.isEmpty ? "(テキスト差分なし — バイナリ、または権限/改行のみの変更)" : d
            case .failure(let e):
                loadError = e.message
            }
        }
    }
}
```

- [ ] **Step 2: ビルドが通ることを確認**

```bash
xcodegen generate
xcodebuild build -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add Sources/KanbanTerm/Views/WorktreeForceDeleteSheet.swift
git commit -m "feat: 差分確認 + 強制削除シート

種類別グルーピングで未追跡を既定で畳み、tracked 行は開いたときだけ
diff を遅延ロードする。statusError 時も行き止まりにせず、
中身を確認せずに削除することを明示したうえで進める。"
```

---

### Task 5: `CardView` から強制削除ルートを繋ぐ

**Files:**
- Modify: `Sources/KanbanTerm/Views/CardView.swift`(`@State` 追加 / `confirmationDialog` にボタン追加 / `.sheet` 追加 / ハンドラ追加)

**Interfaces:**
- Consumes: `WorktreeForceDeleteSheet(worktreePath:branchLabel:onConfirm:)` / `WorktreeService.removeForcibly(worktreePath:repoRoot:inUse:)` / 既存の `BoardStore.clearWorktree(_:)` / `BoardStore.card(withID:)` / 既存 `@State worktreeBusy` / `worktreeDeleteError`
- Produces: なし(この機能の最終結線)

- [ ] **Step 1: `@State` を追加**

`CardView.swift` の `@State private var worktreeBusy = false`(現 428 行目付近)の直後に追加:

```swift
    /// 差分確認 + 強制削除シートの表示。risk == .dirty の警告ダイアログからのみ立つ。
    @State private var forceDeleting = false
```

- [ ] **Step 2: dirty 警告ダイアログに入口を足す**

`CardView.swift` の警告 `confirmationDialog`(現 553-572 行目付近)のボタン群、`if case .inUse = warningWorktreeRisk { ... }` ブロックの直後に追加:

```swift
                if case .dirty = warningWorktreeRisk {
                    Button("差分を確認して強制削除…") {
                        warningWorktreeRisk = nil
                        // ダイアログの dismiss と同一トランザクションで sheet を出すと SwiftUI が
                        // 片方を取り落とすことがあるため、次のメインループへ回してから提示する。
                        Task { @MainActor in forceDeleting = true }
                    }
                }
```

`role: .destructive` は付けない。ここはまだ破壊操作ではなく、次に確認シートが出るだけ。

- [ ] **Step 3: `.sheet` を追加**

`CardView.swift` の警告 `confirmationDialog` の直後(「削除できませんでした」alert の前)に追加:

```swift
            .sheet(isPresented: $forceDeleting) {
                if let worktreePath = card.worktreePath {
                    WorktreeForceDeleteSheet(
                        worktreePath: worktreePath,
                        // card.branch は検出済みの現在ブランチ。取れない場合は worktree の
                        // ディレクトリ名(sanitizeBranch 済みのブランチ名)で代替する。
                        branchLabel: card.branch ?? URL(fileURLWithPath: worktreePath).lastPathComponent,
                        onConfirm: forceRemoveWorktreeThenDeleteCard
                    )
                }
            }
```

- [ ] **Step 4: ハンドラを追加**

`CardView.swift` の `clearWorktreeThenDeleteCard()`(現 827 行目付近)の直前に追加:

```swift
    /// 差分確認シートで「破棄して削除」が押されたときの実行部。
    /// `removeWorktreeThenDeleteCard` と同形だが `removeForcibly` を呼ぶ。
    ///
    /// 未コミット変更を捨てて良いという判断はシート側で済んでいるので、ここでは risk の
    /// 再チェックをしない(再チェックすると dirty で必ず弾かれ、この機能が成立しない)。
    /// `removeForcibly` が守るのは inUse ガードとブランチ保持だけ。
    private func forceRemoveWorktreeThenDeleteCard() {
        guard let worktreePath = card.worktreePath, let repoRoot = card.repoRoot else {
            deleteCard()
            return
        }
        guard !worktreeBusy else { return }
        worktreeBusy = true
        let inUse = sessions.hasSession(card.id)
        let cardID = card.id
        Task {
            let outcome: Result<Void, WorktreeService.GitError> = await Task.detached(priority: .userInitiated) {
                do {
                    try WorktreeService.removeForcibly(worktreePath: worktreePath, repoRoot: repoRoot, inUse: inUse)
                    return .success(())
                } catch let e as WorktreeService.GitError {
                    return .failure(e)
                } catch {
                    return .failure(WorktreeService.GitError(message: "\(error)"))
                }
            }.value
            worktreeBusy = false
            // await の間にカードが削除されていたら、これ以上 SwiftData には触れない。
            guard BoardStore(context: context).card(withID: cardID) != nil else { return }
            switch outcome {
            case .success:
                do {
                    try BoardStore(context: context).clearWorktree(card)
                    deleteCard()
                } catch {
                    worktreeDeleteError = "\(error)"
                }
            case .failure(let e):
                worktreeDeleteError = e.message
            }
        }
    }
```

- [ ] **Step 5: ビルドと全テスト**

```bash
xcodebuild build -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS' 2>&1 | tail -20
xcodebuild test -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS' 2>&1 | tail -25
```

Expected: `BUILD SUCCEEDED` / 既存テストを含め全て PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/KanbanTerm/Views/CardView.swift
git commit -m "feat: dirty 警告から差分確認 + 強制削除シートへ繋ぐ

risk == .dirty のときだけ「差分を確認して強制削除…」を出す。
シートで判断済みなので実行時に risk を再チェックしない
(すると dirty で必ず弾かれて機能が成立しない)。"
```

---

### Task 6: 形式仕様(`worktree_force_delete.fsl`)

**Files:**
- Create: `worktree_force_delete.fsl`
- Modify: `worktree_deletion_fixed.fsl`(ヘッダコメントに後継への1行)

**Interfaces:**
- Consumes: なし(独立した設計記録)
- Produces: なし

既存 `worktree_deletion_fixed.fsl` の invariant `NeverRemoveWhileDirtyOrUnpushed` は新設計では偽になる。旧ファイルは v0.7.3 時点の記録として残し、不変条件を「状態」から「損失」へ組み替えた新スペックを別ファイルで追加する。

- [ ] **Step 1: 新スペックを書く**

`worktree_force_delete.fsl` を新規作成:

```
// Fleet: 差分を確認したうえでの worktree 強制削除(v0.9.3)。
// worktree_deletion_fixed.fsl(v0.7.3)の後継。
//
// 旧設計の問題: risk 分類は untracked も dirty として報告するため、`.serena/` のような
//   捨てて構わないゴミ1つで削除ルートが完全に塞がる。invariant
//   NeverRemoveWhileDirtyOrUnpushed は「何もしない」で常に満たせてしまい、許されるべき
//   結末(捨てていい差分なら消せる)への到達性が失われていた。
//
// THE CHANGE: 安全性を「状態」の不変条件から「損失」の不変条件へ組み替える。
//   旧: removed => not dirty and not unpushed
//   新: discarded_uncommitted => reviewed_diff   (差分を見せずに未コミット変更は捨てない)
//     + removed => branch_kept                  (ブランチ ref を消さないのでコミットは失われない)
//   NeverRemoveWhileInUse はそのまま維持する(走っているプロセスの cwd を消すのは別種の事故)。
//   実装では reviewed_diff の担保が UI 層(WorktreeForceDeleteSheet を通らないと
//   removeForcibly に到達しない)にあり、サービス層は inUse ガードとブランチ保持だけを守る。
//
// ASSUME-1(表現のみ): カードは1枚。worktree の bound、session 生存、汚れ具合を状態に持つ。
// ASSUME-2(worktree_deletion_*.fsl と同一): delete_requested が立っている間は
//   make_dirty/make_unpushed を無効化する。要求後も環境が無限に汚し続ければ進行性は
//   原理的に成立しないため、スコープを揃えるための前提。
// ASSUME-3(この版で追加): delete_requested が立っている間は start_session も無効化する。
//   review_diff / force_remove_after_review はどちらも `not session_live` を要求するので、
//   start_session と end_session が交互に発火し続けると弱公平性の前提(継続的 enabled)が
//   途切れ、leadsTo に偽の反例が出る。バグではなくモデル上の干渉なので前提で切る
//   (worktree_deletion_fixed.fsl の MODELING NOTE と同じ性質の話)。
spec WorktreeForceDelete "design: v0.9.3 差分確認つき強制削除ルート" {
  state {
    bound:            Bool,
    session_live:     Bool,
    dirty:            Bool,   // 未コミット変更(未追跡を含む)がある
    unpushed:         Bool,   // 未プッシュ/未マージのコミットがある
    delete_requested: Bool,   // ユーザーが削除を要求した(sticky)
    reviewed_diff:    Bool,   // 差分確認シートで中身を提示した
    removed:          Bool,
    branch_kept:      Bool,   // 撤去後もブランチ ref が残っている
    discarded_uncommitted: Bool  // ghost: 未コミット変更を実際に捨てたか(履歴)
  }
  init {
    bound             = true
    session_live      = false
    dirty             = false
    unpushed          = false
    delete_requested  = false
    reviewed_diff     = false
    removed           = false
    branch_kept       = true
    discarded_uncommitted = false
  }

  action make_dirty()      { requires bound and not dirty and not delete_requested     dirty = true }
  action make_unpushed()   { requires bound and not unpushed and not delete_requested  unpushed = true }
  action commit_and_push() { requires bound and (dirty or unpushed)   dirty = false  unpushed = false }

  action request_delete() {
    requires bound and not delete_requested
    delete_requested = true
  }

  // ASSUME-3: 削除要求中は新しいセッションを開かない。
  action start_session() {
    requires bound and not session_live and not delete_requested
    session_live = true
  }

  // 既存 clean ルート: risk == clean のときだけ普通に撤去する。
  fair action remove_when_clean() {
    requires bound and delete_requested and (not session_live) and (not dirty) and (not unpushed)
    bound   = false
    removed = true
  }

  // 既存 inUse ルート(v0.7.3): セッションを終了して risk を再評価する。
  fair action end_session() {
    requires bound and delete_requested and session_live
    session_live = false
  }

  // 差分確認シートを開いて中身を提示する。これ自体は何も壊さない。
  fair action review_diff() {
    requires bound and delete_requested and dirty and not session_live
    reviewed_diff = true
  }

  // THE NEW ROUTE: 差分を見たうえで未コミット変更を捨てて撤去する。ブランチ ref は残す
  // (branch_kept を false にするアクションはこのスペックに存在しない = コミットは失われない)。
  fair action force_remove_after_review() {
    requires bound and delete_requested and dirty and reviewed_diff and not session_live
    bound   = false
    removed = true
    discarded_uncommitted = true
  }

  // ---- 安全性 ----
  invariant NeverDiscardUncommittedWithoutReview { discarded_uncommitted => reviewed_diff }
  invariant NeverLoseCommits { removed => branch_kept }
  invariant NeverRemoveWhileInUse { removed => not session_live }
  invariant RemovedImpliesUnbound { removed => not bound }

  // ---- 到達性/進行性 ----
  reachable CleanRemovalDiscardsNothing { removed and not discarded_uncommitted }
  // v0.7.3 では原理的に到達不能だった結末(これが今回の目的)
  reachable DirtyWorktreeCanBeRemoved { dirty and removed }

  leadsTo DirtyDeletionEventuallyHappens {
    (bound and delete_requested and dirty and not session_live) ~> removed
  }

  terminal { removed }
}
```

- [ ] **Step 2: 検証する**

```bash
fslc verify --depth 8 worktree_force_delete.fsl
```

Expected: 全 invariant / reachable / leadsTo が SATISFIED または PASS。

反例が出た場合は、まずそれが**実装の欠陥**か**モデル上の干渉**かを見分ける。実装の欠陥なら Task 3〜5 に戻って直す。モデル上の干渉(公平性の前提が途切れる類)なら ASSUME コメントを足してガードを `requires` に上げる — 既存 `worktree_deletion_fixed.fsl` の MODELING NOTE と同じ判断。**反例を消すために不変条件そのものを弱めてはいけない。**

- [ ] **Step 3: 旧スペックに後継への参照を足す**

`worktree_deletion_fixed.fsl` の 1 行目のコメント直後(2行目)に挿入:

```
// 後継: worktree_force_delete.fsl(v0.9.3)。invariant NeverRemoveWhileDirtyOrUnpushed は
//   そこでは成立しない — 未追跡ゴミ1つで削除が塞がる問題への対処として、安全性を
//   「状態」から「損失」(差分を見せずに捨てない / コミットは失わない)へ組み替えたため。
//   このファイルは v0.7.3 時点の設計記録として残す。
```

- [ ] **Step 4: 旧スペックがまだ通ることを確認**

```bash
fslc verify --depth 8 worktree_deletion_fixed.fsl
```

Expected: 変更前と同じ結果(コメントしか触っていないので挙動不変)

- [ ] **Step 5: Commit**

```bash
git add worktree_force_delete.fsl worktree_deletion_fixed.fsl
git commit -m "spec: 強制削除ルートの形式仕様(損失ベースの不変条件へ組み替え)

removed => not dirty を捨て、discarded_uncommitted => reviewed_diff と
removed => branch_kept に置き換える。v0.7.3 では到達不能だった
(dirty and removed) の到達性と leadsTo を追加。"
```

---

### Task 7: ドキュメントとバージョン

**Files:**
- Modify: `README.ja.md:52`
- Modify: `README.md:53`
- Modify: `docs/index.html:161`
- Modify: `CHANGELOG.md`(末尾に追記)
- Modify: `project.yml:56`

現状の記述は「`--force` は使わず」「never with `--force`」「未コミット/未プッシュのものは消さない」と明言しており、この機能を入れると事実に反する。

- [ ] **Step 1: `README.ja.md` を更新**

`README.ja.md:52` の以下の部分:

```
削除も安全設計: Fleet が作った worktree しか削除せず、`--force` は使わず、未コミット/未 push の変更やセッション動作中は削除を拒否してカードだけ削除する選択肢を出す。
```

を次に置き換える:

```
削除も安全設計: Fleet が作った worktree しか削除せず、未コミット/未 push の変更やセッション動作中は既定で削除を拒否してカードだけ削除する選択肢を出す。未コミットの変更が `.serena/` のような捨てて構わないゴミだけのときは、捨てられる差分(種類別の一覧 + ファイルごとの diff)を確認したうえで強制削除できる。その場合もブランチは残すのでコミットは失われない。
```

- [ ] **Step 2: `README.md` を更新**

`README.md:53` の以下の部分:

```
Deletion is safe: Fleet only removes worktrees it created, never with `--force`, and refuses when there are uncommitted/unpushed changes or an active session (offering to delete just the card instead).
```

を次に置き換える:

```
Deletion is safe: Fleet only removes worktrees it created, and by default refuses when there are uncommitted/unpushed changes or an active session (offering to delete just the card instead). When the uncommitted changes are only throwaway junk like `.serena/`, you can review exactly what would be discarded — grouped by kind, with per-file diffs — and force the removal from there. Even then the branch is kept, so no commits are ever lost.
```

- [ ] **Step 3: `docs/index.html`(LP)を更新**

`docs/index.html:161` の英日ペアを更新する。英語側:

```
and Fleet only removes worktrees it made — never ones with uncommitted or unpushed work.
```

を:

```
and Fleet only removes worktrees it made — uncommitted work is kept unless you review the diff and force it, and the branch always survives.
```

日本語側:

```
撤去も Fleet が作ったものだけ・未コミット/未プッシュのものは消さない。
```

を:

```
撤去も Fleet が作ったものだけ・未コミットのものは差分を確認して強制削除したときだけ消える(ブランチは常に残る)。
```

- [ ] **Step 4: `CHANGELOG.md` に追記**

ファイル末尾(v0.9.2 のブロックの後、新しいものが下に積まれる順序)に追加:

```markdown
## v0.9.3
- worktree 削除で、捨てられる差分(種類別一覧 + ファイルごとの diff)を確認したうえで強制削除できるルートを追加。`.serena/` のような未追跡ゴミ1つで削除が完全に塞がる問題への対処。ブランチ ref は残すのでコミットは失われず、使用中セッションがある worktree は強制でも削除しない
```

- [ ] **Step 5: バージョンを上げる**

`project.yml:56` の `MARKETING_VERSION: "0.9.2"` を `MARKETING_VERSION: "0.9.3"` にする。

- [ ] **Step 6: ビルドと全テストを最終確認**

```bash
xcodegen generate
xcodebuild build -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS' 2>&1 | tail -10
xcodebuild test -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS' 2>&1 | tail -25
```

Expected: `BUILD SUCCEEDED` / 全テスト PASS

- [ ] **Step 7: Commit**

```bash
git add README.md README.ja.md docs/index.html CHANGELOG.md project.yml
git commit -m "docs: 差分確認つき worktree 強制削除を反映(v0.9.3)

README(EN/JA)と LP の「--force は使わない」記述を、既定は拒否のまま
差分確認を経た強制削除ルートがある形へ更新。"
```

---

## 手動確認(全タスク完了後)

実機で1周回して確認する。

- [ ] Fleet を起動し、worktree カードを1枚作る
- [ ] その worktree に `mkdir .serena && touch .serena/cache.json` でゴミを置く
- [ ] カードを削除しようとして「未コミットの変更があります」が出ることを確認
- [ ] 「差分を確認して強制削除…」→ シートが開き、**未追跡セクションが畳まれた状態**で `.serena/` が 1 件と数えられていることを確認
- [ ] tracked ファイルも1つ変更しておき、その行を開くと diff が遅延ロードされることを確認
- [ ] 「破棄して削除」でカードと worktree が消え、`git branch` にブランチが残っていることを確認
