import Testing
import Foundation
import SwiftData
@testable import KanbanKit

/// fleet_worktree_create の intent→適用パイプライン(BoardStore.applyWorktreeIntents)のテスト。
/// bridge は書けないので、ここでは ChannelStore.appendWorktreeIntent で直接 intent を書き込み、
/// 実際の git を使う一時リポジトリに対して適用が正しく動くこと・冪等であることを確認する。
@MainActor
struct WorktreeIntentApplyTests {

    /// ChannelStore 経由でファイルを書くテストを含むため、実マシンの ~/.fleet を汚さないよう
    /// 最初のテスト本体が動く前に隔離用 FLEET_ROOT を確実に設定しておく。
    init() { TestFleetRoot.bootstrap() }

    private func makeStore() throws -> BoardStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BoardColumn.self, Card.self, Channel.self, ClaudeProfile.self, configurations: config)
        return BoardStore(context: ModelContext(container))
    }

    /// `performWorktreeIntent` は baseDir に相対パス "../.fleet-worktrees" を固定で使う
    /// (BoardStore.swift)。つまり worktree の実体は repo の「親ディレクトリ」配下に置かれる。
    /// そのため repo をテストごとに一意な親ルート配下の子ディレクトリとして作ることで、
    /// worktree の置き場所ごとテスト間で衝突しないようにする。
    private func tmpRepo() throws -> String {
        let root = NSTemporaryDirectory() + "wt-intent-test-" + UUID().uuidString
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

    /// テストが作った一意な親ルート(tmpRepo が返す repo の親)を丸ごと削除する。
    /// worktree ("../.fleet-worktrees") は repo の親配下に作られるため、これで
    /// repo 本体・worktree・ブランチ情報がまとめて消える。
    private func removeTestRoot(forRepo repo: String) {
        let root = (repo as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: root)
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
            removeTestRoot(forRepo: repo)
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
            removeTestRoot(forRepo: repo)
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

    /// SECURITY: `fromCardID` はチャンネルの実メンバーでなければならない。チャンネル外の
    /// カード(B)を指す intent をチャンネル(A のみ所属)に書き込んでも、B に worktree が
    /// バインドされてはならない(cross-channel targeting と同種の bypass)。
    @Test func applyWorktreeIntentFailsWhenCardNotMemberOfChannel() throws {
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

        // b はチャンネルに参加していない(a と other のみが所属)
        #expect(ch.cards.contains { $0.id == b.id } == false)

        let intent = WorktreeIntent(fromCardID: b.id.uuidString, branch: "feat/should-not-bind", base: "current")
        ChannelStore.appendWorktreeIntent(intent, to: ch.id)
        store.applyWorktreeIntents(for: ch.id)

        // b には worktree がバインドされていない
        #expect(b.isFleetOwnedWorktree == false)
        #expect(b.worktreePath == nil)

        // 失敗結果が書かれている
        let result = try #require(ChannelStore.worktreeResult(id: intent.id, for: ch.id))
        #expect(result.ok == false)

        // intent は適用済みとして記録され、再試行され続けない
        let applied = ChannelStore.appliedWorktreeIntentIDs(for: ch.id)
        #expect(applied.contains(intent.id))
    }

    /// SAFETY: カードの cwd が git リポジトリでない(素のディレクトリ)場合、worktree 作成は
    /// 失敗結果として記録されるだけで、worktree はバインドされず、intent は(リトライされないよう)
    /// 適用済みとして記録される。これまで未テストだった "not a git repository" 経路。
    @Test func worktreeIntentFailsWhenNotAGitRepo() throws {
        let store = try makeStore()
        let todo = try store.addColumn(name: "Todo")
        let plainDir = NSTemporaryDirectory() + "wt-intent-nogit-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: plainDir, withIntermediateDirectories: true)
        let a = try store.addCard(title: "a", to: todo, workingDirPath: plainDir)
        let b = try store.addCard(title: "b", to: todo)
        let ch = try #require(try store.connectCards(a, b))
        defer {
            ChannelStore.removeBinding(cardID: a.id)
            ChannelStore.removeBinding(cardID: b.id)
            ChannelStore.removeDir(for: ch.id)
            try? FileManager.default.removeItem(atPath: plainDir)
        }

        let intent = WorktreeIntent(fromCardID: a.id.uuidString, branch: "feat/nogit", base: "current")
        ChannelStore.appendWorktreeIntent(intent, to: ch.id)
        store.applyWorktreeIntents(for: ch.id)

        let result = try #require(ChannelStore.worktreeResult(id: intent.id, for: ch.id))
        #expect(result.ok == false)
        #expect(a.isFleetOwnedWorktree == false)
        #expect(a.worktreePath == nil)

        let applied = ChannelStore.appliedWorktreeIntentIDs(for: ch.id)
        #expect(applied.contains(intent.id))
    }
}
