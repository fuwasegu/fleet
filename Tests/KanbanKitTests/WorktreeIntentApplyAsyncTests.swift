import Testing
import Foundation
import SwiftData
@testable import KanbanKit

/// `BoardStore.applyWorktreeIntentsAsync` (git 呼び出しを `Task.detached` へ逃がす非同期版)の
/// テスト。`WorktreeIntentApplyTests` と同じシナリオを async 経路でも確認し、
/// (1) 同期版と同じ結果(バインド/結果ファイル)になること、(2) 同期版と同じく冪等であること
/// (2回目の適用は再作成しない)を担保する。UI 側(A2AChannelHub)の per-channel in-flight
/// ガードは KanbanTerm 側の実装なのでここでは対象外。
@MainActor
struct WorktreeIntentApplyAsyncTests {

    /// ChannelStore 経由でファイルを書くテストを含むため、実マシンの ~/.fleet を汚さないよう
    /// 最初のテスト本体が動く前に隔離用 FLEET_ROOT を確実に設定しておく。
    init() { TestFleetRoot.bootstrap() }

    private func makeStore() throws -> BoardStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BoardColumn.self, Card.self, Channel.self, ClaudeProfile.self, configurations: config)
        return BoardStore(context: ModelContext(container))
    }

    /// `performWorktreeIntent`(同期版) と同じく baseDir に相対パス "../.fleet-worktrees" を
    /// 固定で使うため、repo をテストごとに一意な親ディレクトリ配下に作る。
    private func tmpRepo() throws -> String {
        let root = NSTemporaryDirectory() + "wt-intent-async-test-" + UUID().uuidString
        let dir = root + "/repo"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = try WorktreeService.run(["init", "-b", "main"], in: dir)
        _ = try WorktreeService.run(["config", "user.email", "t@t"], in: dir)
        _ = try WorktreeService.run(["config", "user.name", "t"], in: dir)
        FileManager.default.createFile(atPath: dir + "/README", contents: Data("hi".utf8))
        _ = try WorktreeService.run(["add", "."], in: dir)
        _ = try WorktreeService.run(["commit", "-m", "init"], in: dir)
        return dir
    }

    private func removeTestRoot(forRepo repo: String) {
        let root = (repo as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test func applyWorktreeIntentsAsyncCreatesAndBinds() async throws {
        let store = try makeStore()
        let todo = try store.addColumn(name: "Todo")
        let repo = try tmpRepo()
        let a = try store.addCard(title: "a", to: todo, workingDirPath: repo)
        let b = try store.addCard(title: "b", to: todo)
        let ch = try #require(try store.connectCards(a, b))
        defer {
            ChannelStore.removeBinding(cardID: a.id)
            ChannelStore.removeBinding(cardID: b.id)
            ChannelStore.removeDir(for: ch.id)
            removeTestRoot(forRepo: repo)
        }

        let intent = WorktreeIntent(fromCardID: a.id.uuidString, branch: "feat/from-agent-async", base: "current")
        ChannelStore.appendWorktreeIntent(intent, to: ch.id)
        await store.applyWorktreeIntentsAsync(for: ch.id)

        // カードが Fleet 管理 worktree へ再バインドされている(同期版と同じ結果)。
        #expect(a.isFleetOwnedWorktree == true)
        #expect(a.repoRoot != nil)
        #expect(a.branch == "feat/from-agent-async")
        let path = try #require(a.worktreePath)
        #expect(FileManager.default.fileExists(atPath: path))

        // 結果ファイルが成功として書かれている
        let result = try #require(ChannelStore.worktreeResult(id: intent.id, for: ch.id))
        #expect(result.ok == true)
        #expect(result.path == path)

        // 二度目の適用は再作成しない(冪等性は async 経路でも維持される)。
        await store.applyWorktreeIntentsAsync(for: ch.id)
        #expect(a.worktreePath == path)
        #expect(a.isFleetOwnedWorktree == true)
    }

    @Test func applyWorktreeIntentsAsyncFailsWhenCardAlreadyHasWorktree() async throws {
        let store = try makeStore()
        let todo = try store.addColumn(name: "Todo")
        let repo = try tmpRepo()
        let a = try store.addCard(title: "a", to: todo, workingDirPath: repo)
        let b = try store.addCard(title: "b", to: todo)
        let ch = try #require(try store.connectCards(a, b))
        defer {
            ChannelStore.removeBinding(cardID: a.id)
            ChannelStore.removeBinding(cardID: b.id)
            ChannelStore.removeDir(for: ch.id)
            removeTestRoot(forRepo: repo)
        }
        try store.setWorktree(a, repoRoot: repo, worktreePath: repo + "/already-bound", branch: "existing", fleetOwned: true)

        let intent = WorktreeIntent(fromCardID: a.id.uuidString, branch: "feat/should-not-run-async", base: "current")
        ChannelStore.appendWorktreeIntent(intent, to: ch.id)
        await store.applyWorktreeIntentsAsync(for: ch.id)

        let result = try #require(ChannelStore.worktreeResult(id: intent.id, for: ch.id))
        #expect(result.ok == false)
        // 既存のバインディングは変更されない
        #expect(a.branch == "existing")
        #expect(a.worktreePath == repo + "/already-bound")
    }

    /// SECURITY: 同期版と同じく、チャンネル外のカードを指す intent は async 経路でもバインドされない。
    @Test func applyWorktreeIntentsAsyncFailsWhenCardNotMemberOfChannel() async throws {
        let store = try makeStore()
        let todo = try store.addColumn(name: "Todo")
        let repo = try tmpRepo()
        let a = try store.addCard(title: "a", to: todo, workingDirPath: repo)
        let b = try store.addCard(title: "b", to: todo, workingDirPath: repo)  // channel に所属させない
        let other = try store.addCard(title: "other", to: todo)
        let ch = try #require(try store.connectCards(a, other))
        defer {
            ChannelStore.removeBinding(cardID: a.id)
            ChannelStore.removeBinding(cardID: b.id)
            ChannelStore.removeBinding(cardID: other.id)
            ChannelStore.removeDir(for: ch.id)
            removeTestRoot(forRepo: repo)
        }

        #expect(ch.cards.contains { $0.id == b.id } == false)

        let intent = WorktreeIntent(fromCardID: b.id.uuidString, branch: "feat/should-not-bind-async", base: "current")
        ChannelStore.appendWorktreeIntent(intent, to: ch.id)
        await store.applyWorktreeIntentsAsync(for: ch.id)

        #expect(b.isFleetOwnedWorktree == false)
        #expect(b.worktreePath == nil)

        let result = try #require(ChannelStore.worktreeResult(id: intent.id, for: ch.id))
        #expect(result.ok == false)

        let applied = ChannelStore.appliedWorktreeIntentIDs(for: ch.id)
        #expect(applied.contains(intent.id))
    }
}
