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
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/x", baseRef: "main", baseDir: ".fleet-worktrees")
        #expect(FileManager.default.fileExists(atPath: path))
        // clean なので撤去できる
        #expect(WorktreeService.removalRisk(worktreePath: path, repoRoot: repo, inUse: false) == .clean)
        try WorktreeService.removeSafely(worktreePath: path, repoRoot: repo, inUse: false)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func dirtyBlocksRemoval() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/y", baseRef: "main", baseDir: ".fleet-worktrees")
        FileManager.default.createFile(atPath: path + "/dirty.txt", contents: Data("x".utf8))
        #expect(WorktreeService.removalRisk(worktreePath: path, repoRoot: repo, inUse: false) == .dirty)
        #expect(throws: WorktreeService.GitError.self) {
            try WorktreeService.removeSafely(worktreePath: path, repoRoot: repo, inUse: false)
        }
        #expect(FileManager.default.fileExists(atPath: path)) // 残っている
    }

    /// fail-closed 回帰テスト: `git status --porcelain` 自体が失敗する状況
    /// (index.lock 競合など、実行中エージェントが同じ worktree で git を触っているケースの模擬) で、
    /// removalRisk が "" (クリーン) にフォールバックせず .dirty を返す(= 撤去をブロックする)ことを確認する。
    @Test func statusFailureBlocksRemoval() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/lockcheck", baseRef: "main", baseDir: ".fleet-worktrees")

        // worktree の gitdir (.git/worktrees/<name>/index) のパーミッションを剥奪し、
        // git status --porcelain を確実に失敗させる。
        let gitFileContents = try String(contentsOfFile: path + "/.git", encoding: .utf8)
        let gitDirLine = gitFileContents.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(gitDirLine.hasPrefix("gitdir: "))
        let gitDir = String(gitDirLine.dropFirst("gitdir: ".count))
        let indexPath = gitDir + "/index"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: indexPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: indexPath) }

        // まず本当に git status --porcelain が失敗することを確認する(前提の検証)。
        #expect(throws: WorktreeService.GitError.self) {
            try WorktreeService.run(["status", "--porcelain"], in: path)
        }

        // fail-closed: 判定不能を「クリーン」に倒さず、安全側の .dirty として扱うこと。
        #expect(WorktreeService.removalRisk(worktreePath: path, repoRoot: repo, inUse: false) == .dirty)
    }

    @Test func currentBranchReturnsInitialBranch() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        #expect(WorktreeService.currentBranch(repoRoot: repo) == "main")
    }

    @Test func currentBranchNilForNonGitDir() throws {
        let dir = NSTemporaryDirectory() + "wt-test-nogit-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(WorktreeService.currentBranch(repoRoot: dir) == nil)
    }

    @Test func branchesListsLocalBranchesForGitDir() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        #expect(WorktreeService.branches(repoRoot: repo) == ["main"])
    }

    @Test func branchesEmptyForNonGitDir() throws {
        let dir = NSTemporaryDirectory() + "wt-test-nogit-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(WorktreeService.branches(repoRoot: dir) == [])
    }

    @Test func duplicateBranchRejected() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        _ = try WorktreeService.create(repoRoot: repo, branch: "dup", baseRef: "main", baseDir: ".fleet-worktrees")
        #expect(throws: WorktreeService.GitError.self) {
            _ = try WorktreeService.create(repoRoot: repo, branch: "dup", baseRef: "main", baseDir: ".fleet-worktrees")
        }
    }

    /// SAFETY: 未 push のコミットがある worktree は "never destroy work" の要石。
    /// upstream が設定済みでローカルに ahead なコミットがある状態を作り、removalRisk が
    /// .unpushed を返すこと・removeSafely が撤去せず throw することを確認する。
    @Test func unpushedBlocksRemoval() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let bareDir = NSTemporaryDirectory() + "wt-test-bare-" + UUID().uuidString + ".git"
        defer { try? FileManager.default.removeItem(atPath: bareDir) }
        _ = try WorktreeService.run(["init", "--bare", bareDir], in: repo)
        _ = try WorktreeService.run(["remote", "add", "origin", bareDir], in: repo)
        _ = try WorktreeService.run(["push", "origin", "main"], in: repo)

        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/unpushed", baseRef: "main", baseDir: ".fleet-worktrees")
        // 新ブランチの upstream を張る(この時点ではまだ ahead=0)。
        _ = try WorktreeService.run(["push", "-u", "origin", "feat/unpushed"], in: path)
        // upstream には無いローカルコミットを積む。
        FileManager.default.createFile(atPath: path + "/new.txt", contents: Data("x".utf8))
        _ = try WorktreeService.run(["add", "."], in: path)
        _ = try WorktreeService.run(["commit", "-m", "local only"], in: path)

        #expect(WorktreeService.removalRisk(worktreePath: path, repoRoot: repo, inUse: false) == .unpushed)
        #expect(throws: WorktreeService.GitError.self) {
            try WorktreeService.removeSafely(worktreePath: path, repoRoot: repo, inUse: false)
        }
        #expect(FileManager.default.fileExists(atPath: path)) // 残っている
    }

    /// SAFETY: 稼働中のカード(inUse)の worktree は、クリーンであっても撤去してはならない。
    @Test func inUseBlocksRemoval() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/inuse", baseRef: "main", baseDir: ".fleet-worktrees")
        #expect(WorktreeService.removalRisk(worktreePath: path, repoRoot: repo, inUse: true) == .inUse)
        #expect(throws: WorktreeService.GitError.self) {
            try WorktreeService.removeSafely(worktreePath: path, repoRoot: repo, inUse: true)
        }
        #expect(FileManager.default.fileExists(atPath: path)) // 残っている
    }

    /// SAFETY: 配置先ディレクトリが既に存在する場合、`WorktreeService.create` は
    /// (ブランチがまだ存在しなくても)"配置先が既に存在します" 側で拒否しなければならない。
    /// これまで未テストだった分岐(既存の duplicateBranchRejected はブランチ重複側のみ検証)。
    @Test func pathCollisionRejected() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let branch = "feat/collide"
        let path = WorktreeService.worktreePath(repoRoot: repo, branch: branch, baseDir: ".fleet-worktrees")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        #expect(throws: WorktreeService.GitError.self) {
            _ = try WorktreeService.create(repoRoot: repo, branch: branch, baseRef: "main", baseDir: ".fleet-worktrees")
        }
    }

    // MARK: - resolveFreshBase (worktree のベース最新化)

    /// THE KEY TEST: origin (bare) を1つ用意し、2つの独立クローンを持つ。
    /// clone1 で C1 を作って origin に push → clone2 が origin から C2 を作って push
    /// (clone1 のローカル main は更新しない = clone1 視点では origin の方が進んでいる、
    /// ユーザーのローカル main が stale になる典型的な状況の再現)。
    /// clone1 で `resolveFreshBase(fetch: true)` してから `create` した worktree の HEAD が
    /// C2(origin の最新)であること、C1(clone1 のローカル stale HEAD)ではないことを確認する。
    @Test func worktreeBasesOnFreshRemoteTip() throws {
        let root = NSTemporaryDirectory() + "wt-fresh-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let bareDir = root + "/origin.git"
        _ = try WorktreeService.run(["init", "--bare", "-b", "main", bareDir], in: root)

        // clone1: C1 を作って push。
        let clone1 = root + "/clone1"
        _ = try WorktreeService.run(["clone", bareDir, clone1], in: root)
        _ = try WorktreeService.run(["config", "user.email", "t@t"], in: clone1)
        _ = try WorktreeService.run(["config", "user.name", "t"], in: clone1)
        FileManager.default.createFile(atPath: clone1 + "/f1.txt", contents: Data("c1".utf8))
        _ = try WorktreeService.run(["add", "."], in: clone1)
        _ = try WorktreeService.run(["commit", "-m", "C1"], in: clone1)
        _ = try WorktreeService.run(["push", "origin", "main"], in: clone1)
        let c1 = try WorktreeService.run(["rev-parse", "HEAD"], in: clone1)

        // clone2: C1 を fetch した上に、clone1 が知らない C2 を作って push。
        let clone2 = root + "/clone2"
        _ = try WorktreeService.run(["clone", bareDir, clone2], in: root)
        _ = try WorktreeService.run(["config", "user.email", "t@t"], in: clone2)
        _ = try WorktreeService.run(["config", "user.name", "t"], in: clone2)
        FileManager.default.createFile(atPath: clone2 + "/f2.txt", contents: Data("c2".utf8))
        _ = try WorktreeService.run(["add", "."], in: clone2)
        _ = try WorktreeService.run(["commit", "-m", "C2"], in: clone2)
        _ = try WorktreeService.run(["push", "origin", "main"], in: clone2)
        let c2 = try WorktreeService.run(["rev-parse", "HEAD"], in: clone2)
        #expect(c1 != c2)

        // clone1 視点では main はまだ C1(stale)。
        #expect(try WorktreeService.run(["rev-parse", "main"], in: clone1) == c1)

        let resolved = WorktreeService.resolveFreshBase(repoRoot: clone1, base: "main", fetch: true)
        #expect(resolved.usedRemote == true)
        #expect(resolved.note == nil)
        #expect(resolved.ref == "origin/main")

        let path = try WorktreeService.create(repoRoot: clone1, branch: "feat/fresh", baseRef: resolved.ref, baseDir: ".fleet-worktrees")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let head = try WorktreeService.run(["rev-parse", "HEAD"], in: path)
        #expect(head == c2)    // origin の最新(C2)から作られている
        #expect(head != c1)    // clone1 のローカル stale main(C1)からではない

        // clone1 のローカル main 自体は変更されていない(pull/ff していない)ことを確認する。
        #expect(try WorktreeService.run(["rev-parse", "main"], in: clone1) == c1)
    }

    @Test func resolveFreshBaseFallsBackWhenNoRemote() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let resolved = WorktreeService.resolveFreshBase(repoRoot: repo, base: "main", fetch: true)
        #expect(resolved.ref == "main")
        #expect(resolved.usedRemote == false)
        #expect(resolved.note != nil)
    }

    @Test func resolveFreshBaseFallsBackWhenBranchNotOnRemote() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let bareDir = NSTemporaryDirectory() + "wt-test-bare2-" + UUID().uuidString + ".git"
        defer { try? FileManager.default.removeItem(atPath: bareDir) }
        _ = try WorktreeService.run(["init", "--bare", bareDir], in: repo)
        _ = try WorktreeService.run(["remote", "add", "origin", bareDir], in: repo)
        _ = try WorktreeService.run(["push", "origin", "main"], in: repo)

        // "main" だけを origin に push した状態で、ローカルのみのブランチを作って解決する。
        _ = try WorktreeService.run(["branch", "local-only"], in: repo)
        let resolved = WorktreeService.resolveFreshBase(repoRoot: repo, base: "local-only", fetch: true)
        #expect(resolved.ref == "local-only")
        #expect(resolved.usedRemote == false)
        #expect(resolved.note != nil)
    }

    /// リモートが到達不能(存在しないローカルパス)でも、fetch がハングせず即座に失敗し、
    /// フォールバックした ResolvedBase を返すこと。ネットワークを使わないので高速・オフライン安全。
    @Test func fetchDoesNotHangOnUnreachableRemote() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        _ = try WorktreeService.run(["remote", "add", "origin", "/nonexistent/x.git"], in: repo)

        let start = Date()
        let resolved = WorktreeService.resolveFreshBase(repoRoot: repo, base: "main", fetch: true)
        let elapsed = Date().timeIntervalSince(start)

        #expect(resolved.ref == "main")
        #expect(resolved.usedRemote == false)
        #expect(resolved.note != nil)
        #expect(elapsed < 10)   // ハングしていないことの目安(通常は数百ms未満で失敗するはず)
    }
}
