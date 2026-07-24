import Testing
import Foundation
import SwiftData
@testable import KanbanKit

/// fleet_worktree_create の intent→適用パイプライン(BoardStore.applyWorktreeIntents)のテスト。
/// bridge は書けないので、ここでは ChannelStore.appendWorktreeIntent で直接 intent を書き込み、
/// 実際の git を使う一時リポジトリに対して適用が正しく動くこと・冪等であることを確認する。
@MainActor
struct WorktreeIntentApplyTests {

    private func makeStore() throws -> BoardStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BoardColumn.self, Card.self, Channel.self, configurations: config)
        return BoardStore(context: ModelContext(container))
    }

    private func tmpRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "wt-intent-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = try WorktreeService.run(["init", "-b", "main"], in: dir)
        _ = try WorktreeService.run(["config", "user.email", "t@t"], in: dir)
        _ = try WorktreeService.run(["config", "user.name", "t"], in: dir)
        FileManager.default.createFile(atPath: dir + "/README", contents: Data("hi".utf8))
        _ = try WorktreeService.run(["add", "."], in: dir)
        _ = try WorktreeService.run(["commit", "-m", "init"], in: dir)
        return dir
    }

    @Test func applyWorktreeIntentCreatesAndBinds() throws {
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
            if let wt = a.worktreePath { try? FileManager.default.removeItem(atPath: (wt as NSString).deletingLastPathComponent) }
            try? FileManager.default.removeItem(atPath: repo)
        }

        let intent = WorktreeIntent(fromCardID: a.id.uuidString, branch: "feat/from-agent", base: "current")
        ChannelStore.appendWorktreeIntent(intent, to: ch.id)
        store.applyWorktreeIntents(for: ch.id)

        // カードが Fleet 管理 worktree へ再バインドされている
        #expect(a.isFleetOwnedWorktree == true)
        #expect(a.repoRoot != nil)
        #expect(a.branch == "feat/from-agent")
        let path = try #require(a.worktreePath)
        #expect(FileManager.default.fileExists(atPath: path))

        // 結果ファイルが成功として書かれている
        let result = try #require(ChannelStore.worktreeResult(id: intent.id, for: ch.id))
        #expect(result.ok == true)
        #expect(result.path == path)

        // 二度目の適用は再作成しない(既存 branch/dir に対して create を再実行するとエラーになるため、
        // 冪等性が破れると worktreePath が変わったり binding が壊れたりする)。
        store.applyWorktreeIntents(for: ch.id)
        #expect(a.worktreePath == path)
        #expect(a.isFleetOwnedWorktree == true)
    }

    @Test func applyWorktreeIntentFailsWhenCardAlreadyHasWorktree() throws {
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
            try? FileManager.default.removeItem(atPath: repo)
        }
        try store.setWorktree(a, repoRoot: repo, worktreePath: repo + "/already-bound", branch: "existing", fleetOwned: true)

        let intent = WorktreeIntent(fromCardID: a.id.uuidString, branch: "feat/should-not-run", base: "current")
        ChannelStore.appendWorktreeIntent(intent, to: ch.id)
        store.applyWorktreeIntents(for: ch.id)

        let result = try #require(ChannelStore.worktreeResult(id: intent.id, for: ch.id))
        #expect(result.ok == false)
        // 既存のバインディングは変更されない
        #expect(a.branch == "existing")
        #expect(a.worktreePath == repo + "/already-bound")
    }

    @Test func applyWorktreeIntentFailsWhenCardNotFound() throws {
        let store = try makeStore()
        let todo = try store.addColumn(name: "Todo")
        let a = try store.addCard(title: "a", to: todo)
        let b = try store.addCard(title: "b", to: todo)
        let ch = try #require(try store.connectCards(a, b))
        defer {
            ChannelStore.removeBinding(cardID: a.id)
            ChannelStore.removeBinding(cardID: b.id)
            ChannelStore.removeDir(for: ch.id)
        }

        let intent = WorktreeIntent(fromCardID: UUID().uuidString, branch: "feat/orphan", base: "current")
        ChannelStore.appendWorktreeIntent(intent, to: ch.id)
        store.applyWorktreeIntents(for: ch.id)

        let result = try #require(ChannelStore.worktreeResult(id: intent.id, for: ch.id))
        #expect(result.ok == false)
    }
}
