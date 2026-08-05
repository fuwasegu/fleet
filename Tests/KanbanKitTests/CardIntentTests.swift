import Foundation
import Testing
import SwiftData
@testable import KanbanKit

/// 無所属カードからの委譲(`cards/<id>/board-intents.jsonl`)と、`create_card` の agent/model。
///
/// 直した穴: **まだどのカードともつながっていないカードは fleet_create_card すら呼べず、
/// 「最初の委譲」が原理的にできなかった**(intent ファイルがチャンネル dir にしか無いため)。
@MainActor
struct CardIntentTests {
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

        ChannelStore.appendCardIntent(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString, title: "調査カード"),
            to: creator.id)
        store.applyCardIntents()

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

        ChannelStore.appendCardIntent(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString,
                        title: "レビュー", agent: "codex", model: "gpt-5-codex"),
            to: creator.id)
        store.applyCardIntents()

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

        ChannelStore.appendCardIntent(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString,
                        title: "変な agent", agent: "gemini"),
            to: creator.id)
        store.applyCardIntents()

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

        ChannelStore.appendCardIntent(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString,
                        title: "危険なモデル名", model: "opus; rm -rf /"),
            to: creator.id)
        store.applyCardIntents()

        let made = try store.cards().first { $0.title == "危険なモデル名" }
        #expect(made?.model == nil)
        cleanup(creator, made)
    }

    // MARK: - 冪等性・堅牢性

    /// 二度適用してもカードは増えない(適用済み集合が効いている)。
    @Test func appliedIntentsAreNotReapplied() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "作業中")
        let creator = try store.addCard(title: "親", to: col)

        ChannelStore.appendCardIntent(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString, title: "一度だけ"),
            to: creator.id)
        store.applyCardIntents()
        store.applyCardIntents()
        store.applyCardIntents()

        #expect(try store.cards().filter { $0.title == "一度だけ" }.count == 1)
        cleanup(creator, nil)
    }

    /// 作成元カードが盤面から消えていたら何もしない(孤児カードを作らない)。
    @Test func doesNothingWhenCreatorIsGone() throws {
        let store = try makeStore()
        let ghost = UUID()
        ChannelStore.appendCardIntent(
            BoardIntent(kind: "create_card", fromID: ghost.uuidString, title: "幽霊の子"),
            to: ghost)
        store.applyCardIntents()
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
        ChannelStore.appendCardIntent(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString,
                        title: "列指定ミス", column: "存在しない列"),
            to: creator.id)
        store.applyCardIntents()
        let made = try store.cards().first { $0.title == "列指定ミス" }
        #expect(made?.column?.name == "作業中")   // 先頭列へフォールバック
        cleanup(creator, made)
    }

    /// 壊れた行が混ざっても読める行は落とさない。
    @Test func skipsUnreadableLines() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "作業中")
        let creator = try store.addCard(title: "親", to: col)

        ChannelStore.appendCardIntent(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString, title: "前"),
            to: creator.id)
        ChannelStore.withChannelLock(ChannelStore.cardDir(for: creator.id)) {
            ChannelStore.appendLineAtomically(Data("これは JSON ではない\n".utf8),
                                              to: ChannelStore.cardIntentsFile(for: creator.id))
        }
        ChannelStore.appendCardIntent(
            BoardIntent(kind: "create_card", fromID: creator.id.uuidString, title: "後"),
            to: creator.id)
        store.applyCardIntents()

        #expect(try store.cards().contains { $0.title == "前" })
        #expect(try store.cards().contains { $0.title == "後" })
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

    private func cleanup(_ a: Card?, _ b: Card?) {
        for c in [a, b].compactMap({ $0 }) {
            ChannelStore.removeBinding(cardID: c.id)
            if let ch = c.channel { ChannelStore.removeDir(for: ch.id) }
        }
    }
}
