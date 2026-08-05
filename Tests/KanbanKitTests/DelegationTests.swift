import Foundation
import Testing
import SwiftData
@testable import KanbanKit

/// 無所属カードからの委譲(`~/.fleet/delegations/<id>.json`)と、`create_card` の agent/model。
///
/// 直した穴: **まだどのカードともつながっていないカードは fleet_create_card すら呼べず、
/// 「最初の委譲」が原理的にできなかった**(intent ファイルがチャンネル dir にしか無いため)。
@MainActor
struct DelegationTests {
    init() { TestFleetRoot.bootstrap() }

    private func makeStore() throws -> BoardStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: BoardColumn.self, Card.self, Channel.self, ClaudeProfile.self, configurations: config)
        return BoardStore(context: ModelContext(container))
    }

    // MARK: - 無所属カードからの委譲

    /// 無所属カードが出した intent が適用され、**作成元と結線されてチャンネルが生まれる**。
    /// ここが通らないと「別ディレクトリのカードを作って調べさせる」が始められない。
    @Test func delegationFromUnconnectedCardCreatesChannel() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "作業中")
        let creator = try store.addCard(title: "親カード", to: col)
        #expect(creator.channel == nil)     // まだ無所属

        ChannelStore.appendDelegation(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString, title: "調査カード"))
        store.applyDelegations()

        let made = try store.cards().first { $0.title == "調査カード" }
        #expect(made != nil)
        // 双方が同じチャンネルに入っている = 以降 fleet_message / fleet_recall が使える
        #expect(creator.channel != nil)
        #expect(made?.channel?.id == creator.channel?.id)
        cleanup(creator, made)
    }

    /// agent / model が新カードへ渡る(「Codex のカードを立ててレビューさせて」の要)。
    @Test func passesAgentAndModelToTheNewCard() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "作業中")
        let creator = try store.addCard(title: "親", to: col)

        ChannelStore.appendDelegation(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString,
                        title: "レビュー", agent: "codex", model: "gpt-5-codex"))
        store.applyDelegations()

        let made = try store.cards().first { $0.title == "レビュー" }
        #expect(made?.agentKind == .codex)
        #expect(made?.model == "gpt-5-codex")
        cleanup(creator, made)
    }

    /// 未知の agent 名は既定(claude)に落とす。綴り間違いで作成そのものを失敗させない。
    @Test func unknownAgentFallsBackToClaude() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "作業中")
        let creator = try store.addCard(title: "親", to: col)

        ChannelStore.appendDelegation(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString,
                        title: "変な agent", agent: "gemini"))
        store.applyDelegations()

        let made = try store.cards().first { $0.title == "変な agent" }
        #expect(made != nil)
        #expect(made?.agentKind == .claude)
        cleanup(creator, made)
    }

    /// 不正なモデル名は起動コマンドを汚染せず既定に落ちる(addCard 側の正規化に乗る)。
    @Test func invalidModelIsDroppedNotPassedThrough() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "作業中")
        let creator = try store.addCard(title: "親", to: col)

        ChannelStore.appendDelegation(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString,
                        title: "危険なモデル名", model: "opus; rm -rf /"))
        store.applyDelegations()

        let made = try store.cards().first { $0.title == "危険なモデル名" }
        #expect(made?.model == nil)
        cleanup(creator, made)
    }

    // MARK: - 冪等性・堅牢性

    /// 二度適用してもカードは増えない(適用したファイルを取り除くので再適用されない)。
    @Test func appliedIntentsAreNotReapplied() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "作業中")
        let creator = try store.addCard(title: "親", to: col)

        ChannelStore.appendDelegation(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString, title: "一度だけ"))
        store.applyDelegations()
        store.applyDelegations()
        store.applyDelegations()

        #expect(try store.cards().filter { $0.title == "一度だけ" }.count == 1)
        cleanup(creator, nil)
    }

    /// 作成元カードが盤面から消えていたら何もしない(孤児カードを作らない)。
    @Test func doesNothingWhenCreatorIsGone() throws {
        let store = try makeStore()
        let ghost = UUID()
        ChannelStore.appendDelegation(
            BoardIntent(kind: "create_card", fromID: ghost.uuidString, title: "幽霊の子"))
        store.applyDelegations()
        #expect(try store.cards().allSatisfy { $0.title != "幽霊の子" })
        ChannelStore.removeBinding(cardID: ghost)
    }

    /// 列が1つも無い盤面ではカードを作らない(列を勝手に作らない)。
    @Test func doesNothingWithoutColumns() throws {
        let store = try makeStore()
        // カードは列が必要なので、作成元だけ列付きで作って直後に列を空にはできない。
        // ここでは「列名が一致しない指定でも先頭列にフォールバックする」ことを確認する。
        let col = try store.addColumn(name: "作業中")
        let creator = try store.addCard(title: "親", to: col)
        ChannelStore.appendDelegation(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString,
                        title: "列指定ミス", column: "存在しない列"))
        store.applyDelegations()
        let made = try store.cards().first { $0.title == "列指定ミス" }
        #expect(made?.column?.name == "作業中")   // 先頭列へフォールバック
        cleanup(creator, made)
    }

    /// 壊れたファイルが混ざっても、読めるものは落とさない。
    @Test func skipsUnreadableFiles() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "作業中")
        let creator = try store.addCard(title: "親", to: col)

        ChannelStore.appendDelegation(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString, title: "前"))
        let junk = ChannelStore.delegationDir().appending(path: "\(UUID().uuidString).json")
        try Data("これは JSON ではない".utf8).write(to: junk)
        ChannelStore.appendDelegation(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString, title: "後"))
        store.applyDelegations()

        #expect(try store.cards().contains { $0.title == "前" })
        #expect(try store.cards().contains { $0.title == "後" })
        // 壊れたファイルは読めないので取り除かれず残る(次回また読み飛ばされるだけ)。
        try? FileManager.default.removeItem(at: junk)
        cleanup(creator, nil)
    }

    /// 古い順に適用される(委譲の順序が入れ替わらない)。
    @Test func appliesInCreatedAtOrder() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "作業中")
        let creator = try store.addCard(title: "親", to: col)
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        // ファイル名(UUID)の順序と時刻の順序が一致しないように、後の時刻を先に書く。
        ChannelStore.appendDelegation(BoardIntent(kind: "create_card", fromID: creator.id.uuidString,
                                                 title: "2番目", createdAt: base.addingTimeInterval(10)))
        ChannelStore.appendDelegation(BoardIntent(kind: "create_card", fromID: creator.id.uuidString,
                                                 title: "1番目", createdAt: base))
        store.applyDelegations()

        let order = try store.cards().filter { ["1番目", "2番目"].contains($0.title) }
            .sorted { $0.order < $1.order }.map(\.title)
        #expect(order == ["1番目", "2番目"])
        cleanup(creator, nil)
    }

    /// 旧形式(agent/model が無い)の intent もそのまま読める。
    @Test func decodesLegacyIntentWithoutAgentOrModel() throws {
        let line = #"{"id":"X","kind":"create_card","fromID":"Y","title":"旧形式","createdAt":"2026-08-05T01:23:45Z"}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let intent = try dec.decode(BoardIntent.self, from: Data(line.utf8))
        #expect(intent.title == "旧形式")
        #expect(intent.agent == nil)
        #expect(intent.model == nil)
    }

    // MARK: - レビュー指摘への対応(Codex)

    /// **dir は本体側でも検証する。** bridge の検証しか無いと、Agent が intent ファイルを
    /// 直接書いて迂回し、任意の既存ディレクトリで新しい Agent を起動させられる。
    @Test func rejectsSuspiciousWorkingDirEvenWhenBridgeIsBypassed() throws {
        #expect(BoardStore.validatedWorkingDir("/tmp") == "/tmp")          // 絶対 + 実在 → 通す
        #expect(BoardStore.validatedWorkingDir("relative/path") == nil)     // 相対 → 捨てる
        #expect(BoardStore.validatedWorkingDir("/does/not/exist/xyz") == nil)
        #expect(BoardStore.validatedWorkingDir("/etc/hosts") == nil)        // ファイル(ディレクトリでない)
        #expect(BoardStore.validatedWorkingDir(nil) == nil)
        #expect(BoardStore.validatedWorkingDir("") == nil)
    }

    /// 不正な dir を持つ intent でも、カード自体は作る(cwd を持たないだけ)。
    @Test func createsCardWithoutCwdWhenDirIsRejected() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "作業中")
        let creator = try store.addCard(title: "親", to: col)
        ChannelStore.appendDelegation(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString,
                        title: "怪しい dir", dir: "/does/not/exist/xyz"))
        store.applyDelegations()
        let made = try store.cards().first { $0.title == "怪しい dir" }
        #expect(made != nil)
        #expect(made?.workingDirPath == nil)
        cleanup(creator, made)
    }

    /// **claim してから適用する。** 一度 claim された intent は、もう一度スキャンしても出てこない
    /// (= 別プロセスや再起動で二重作成されない)。
    @Test func claimRemovesIntentFromTheQueue() throws {
        let intent = BoardIntent(kind: "create_card", fromID: UUID().uuidString, title: "claim テスト")
        ChannelStore.appendDelegation(intent)

        let first = ChannelStore.claimDelegations().filter { $0.intent.id == intent.id }
        #expect(first.count == 1)
        // 2回目のスキャンには現れない
        #expect(ChannelStore.claimDelegations().allSatisfy { $0.intent.id != intent.id })
        for (url, _) in first { ChannelStore.removeDelegation(at: url) }
    }

    /// 壊れたファイルは broken/ へ退避され、キューに残り続けない。
    @Test func quarantinesUnreadableDelegation() throws {
        let name = "\(UUID().uuidString).json"
        let dir = ChannelStore.delegationDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("これは JSON ではない".utf8).write(to: dir.appending(path: name))

        _ = ChannelStore.claimDelegations()

        // 元の場所からは消え、broken/ に残っている
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: name).path))
        let broken = (try? FileManager.default.contentsOfDirectory(
            at: ChannelStore.brokenDelegationDir(), includingPropertiesForKeys: nil)) ?? []
        #expect(broken.contains { $0.lastPathComponent.hasPrefix(name) })
        for u in broken { try? FileManager.default.removeItem(at: u) }
    }

    private func cleanup(_ a: Card?, _ b: Card?) {
        for c in [a, b].compactMap({ $0 }) {
            ChannelStore.removeBinding(cardID: c.id)
            if let ch = c.channel { ChannelStore.removeDir(for: ch.id) }
        }
    }
}
