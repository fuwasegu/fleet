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
