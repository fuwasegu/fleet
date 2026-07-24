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
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/x", base: .current, baseDir: ".fleet-worktrees")
        #expect(FileManager.default.fileExists(atPath: path))
        // clean なので撤去できる
        #expect(WorktreeService.removalRisk(worktreePath: path, repoRoot: repo, inUse: false) == .clean)
        try WorktreeService.removeSafely(worktreePath: path, repoRoot: repo, inUse: false)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func dirtyBlocksRemoval() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/y", base: .current, baseDir: ".fleet-worktrees")
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
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/lockcheck", base: .current, baseDir: ".fleet-worktrees")

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

    @Test func duplicateBranchRejected() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        _ = try WorktreeService.create(repoRoot: repo, branch: "dup", base: .current, baseDir: ".fleet-worktrees")
        #expect(throws: WorktreeService.GitError.self) {
            _ = try WorktreeService.create(repoRoot: repo, branch: "dup", base: .current, baseDir: ".fleet-worktrees")
        }
    }
}
