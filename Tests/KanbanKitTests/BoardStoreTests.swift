import Foundation
import Testing
import SwiftData
@testable import KanbanKit

@MainActor
struct BoardStoreTests {

    private func makeStore() throws -> BoardStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BoardColumn.self, Card.self, Channel.self, ClaudeProfile.self, configurations: config)
        return BoardStore(context: ModelContext(container))
    }

    // MARK: - 列

    @Test func addColumnAssignsIncreasingOrder() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "作業中")
        let b = try store.addColumn(name: "レビュー待ち")
        #expect(a.order == 0)
        #expect(b.order == 1)
        #expect(try store.columns().count == 2)
    }

    @Test func addColumnRejectsEmptyName() throws {
        let store = try makeStore()
        #expect(throws: BoardError.emptyName) { try store.addColumn(name: "   ") }
    }

    @Test func renameColumnRejectsEmptyName() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        #expect(throws: BoardError.emptyName) { try store.renameColumn(a, to: "") }
        #expect(a.name == "A")
    }

    @Test func removeEmptyColumnSucceeds() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        try store.removeColumn(a)
        #expect(try store.columns().isEmpty)
    }

    // fsl: CardInExistingColumn / 孤児カード防止
    @Test func removeNonEmptyColumnFails() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        _ = try store.addCard(title: "card", to: a)
        #expect(throws: BoardError.columnNotEmpty) { try store.removeColumn(a) }
        #expect(try store.columns().count == 1)
    }

    @Test func removeColumnNormalizesRemainingOrders() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        _ = try store.addColumn(name: "B")
        let c = try store.addColumn(name: "C")
        try store.removeColumn(a)
        let cols = try store.columns()
        #expect(cols.map(\.order) == [0, 1])
        #expect(cols.last?.id == c.id)
    }

    @Test func moveColumnReorders() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let b = try store.addColumn(name: "B")
        let c = try store.addColumn(name: "C")
        // A(0) B(1) C(2) → C を先頭へ
        try store.moveColumn(c, to: 0)
        var names = try store.columns().map(\.name)
        #expect(names == ["C", "A", "B"])
        #expect(try store.columns().map(\.order) == [0, 1, 2])
        // A を末尾へ
        try store.moveColumn(a, to: 2)
        names = try store.columns().map(\.name)
        #expect(names == ["C", "B", "A"])
        _ = b
    }

    @Test func setColumnColorPersists() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        try store.setColumnColor(a, hex: "FF453A")
        #expect(a.colorHex == "FF453A")
        try store.setColumnColor(a, hex: nil)
        #expect(a.colorHex == nil)
    }

    // MARK: - カード

    @Test func addCardAssignsIncreasingOrder() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c0 = try store.addCard(title: "0", to: a)
        let c1 = try store.addCard(title: "1", to: a)
        #expect(c0.order == 0)
        #expect(c1.order == 1)
        #expect(c0.column?.id == a.id)
    }

    @Test func addCardStoresCreationOptions() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c = try store.addCard(
            title: "task", to: a,
            workingDirPath: "/tmp/proj", dangerSkip: true, autoStartAgent: true
        )
        #expect(c.workingDirPath == "/tmp/proj")
        #expect(c.dangerSkip == true)
        #expect(c.autoStartAgent == true)
    }

    @Test func newCardDefaultsToUnknownAndSeen() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c = try store.addCard(title: "c", to: a)
        #expect(c.agentState == .unknown)
        #expect(c.isDone == false)
        #expect(c.dangerSkip == false)
    }

    // fsl: move_card — 移動後もカードは必ず列に属す
    @Test func moveCardBetweenColumns() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let b = try store.addColumn(name: "B")
        let c = try store.addCard(title: "c", to: a)
        try store.moveCard(c, to: b, at: 0)
        #expect(c.column?.id == b.id)
        #expect(a.cards.isEmpty)
        #expect(b.cards.count == 1)
    }

    @Test func moveCardReordersWithinColumn() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        _ = try store.addCard(title: "0", to: a)
        _ = try store.addCard(title: "1", to: a)
        let c2 = try store.addCard(title: "2", to: a)
        try store.moveCard(c2, to: a, at: 0)
        let titles = a.cards.sorted { $0.order < $1.order }.map(\.title)
        #expect(titles == ["2", "0", "1"])
    }

    @Test func renameCardUpdatesTitle() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c = try store.addCard(title: "old", to: a)
        try store.renameCard(c, to: "new")
        #expect(c.title == "new")
    }

    @Test func renameCardRejectsEmpty() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c = try store.addCard(title: "keep", to: a)
        #expect(throws: BoardError.emptyName) { try store.renameCard(c, to: "  ") }
        #expect(c.title == "keep")
    }

    @Test func cardWithIDResolves() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c = try store.addCard(title: "x", to: a)
        #expect(store.card(withID: c.id)?.id == c.id)
        #expect(store.card(withID: UUID()) == nil)
    }

    @Test func columnWithIDResolves() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        #expect(store.column(withID: a.id)?.id == a.id)
        #expect(store.column(withID: UUID()) == nil)
    }

    // 先頭カードを最下部へ（上→下の並べ替えが store 層で成立すること）
    @Test func moveCardTopToBottom() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c0 = try store.addCard(title: "0", to: a)
        _ = try store.addCard(title: "1", to: a)
        _ = try store.addCard(title: "2", to: a)
        let end = a.cards.filter { $0.id != c0.id }.count   // = 2
        try store.moveCard(c0, to: a, at: end)
        let titles = a.cards.sorted { $0.order < $1.order }.map(\.title)
        #expect(titles == ["1", "2", "0"])
    }

    // アプリ起動時: 端末は消えているので全カードを CC 未起動状態へ戻す
    @Test func resetAgentStatesClearsRuntimeState() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let working = try store.addCard(title: "w", to: a)
        working.agentState = .working
        let blocked = try store.addCard(title: "b", to: a)
        blocked.agentState = .blocked
        blocked.seen = false
        blocked.blockedPrompt = "Do you want to proceed?"

        try store.resetAgentStates()

        for card in a.cards {
            #expect(card.agentState == .unknown)
            #expect(card.seen == true)
            #expect(card.blockedPrompt == nil)
            #expect(card.isDone == false)
        }
    }

    // MARK: - Channel (A2A)

    @Test func connectCreatesSharedChannel() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "A")
        let a = try store.addCard(title: "a", to: col)
        let b = try store.addCard(title: "b", to: col)
        let ch = try store.connectCards(a, b)
        #expect(ch != nil)
        #expect(a.channel?.id == ch?.id)
        #expect(b.channel?.id == ch?.id)
        #expect(ch?.cards.count == 2)
    }

    @Test func connectThirdJoinsExistingChannel() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "A")
        let a = try store.addCard(title: "a", to: col)
        let b = try store.addCard(title: "b", to: col)
        let c = try store.addCard(title: "c", to: col)
        let ch = try store.connectCards(a, b)
        _ = try store.connectCards(b, c)   // c を既存チャンネルへ
        #expect(c.channel?.id == ch?.id)
        #expect(ch?.cards.count == 3)
        #expect(try store.channels().count == 1)
    }

    @Test func connectTwoChannelsMerges() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "A")
        let a = try store.addCard(title: "a", to: col)
        let b = try store.addCard(title: "b", to: col)
        let c = try store.addCard(title: "c", to: col)
        let d = try store.addCard(title: "d", to: col)
        _ = try store.connectCards(a, b)   // ch1
        _ = try store.connectCards(c, d)   // ch2
        #expect(try store.channels().count == 2)
        _ = try store.connectCards(b, c)   // 合流
        #expect(try store.channels().count == 1)
        #expect(a.channel?.id == d.channel?.id)
        #expect(a.channel?.cards.count == 4)
    }

    @Test func deleteCardDissolvesOrphanChannel() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "A")
        let a = try store.addCard(title: "a", to: col)
        let b = try store.addCard(title: "b", to: col)
        _ = try store.connectCards(a, b)
        try store.deleteCard(a)   // 残り1枚 → チャンネル解散
        #expect(b.channel == nil)
        #expect(try store.channels().isEmpty)
    }

    @Test func deleteCardKeepsChannelWithTwoRemaining() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "A")
        let a = try store.addCard(title: "a", to: col)
        let b = try store.addCard(title: "b", to: col)
        let c = try store.addCard(title: "c", to: col)
        let ch = try store.connectCards(a, b)
        _ = try store.connectCards(b, c)
        try store.deleteCard(a)   // 2枚残る → チャンネル存続
        #expect(try store.channels().count == 1)
        #expect(b.channel?.id == ch?.id)
        #expect(c.channel?.id == ch?.id)
        #expect(ch?.cards.count == 2)
    }

    @Test func disconnectDissolvesWhenBelowTwo() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "A")
        let a = try store.addCard(title: "a", to: col)
        let b = try store.addCard(title: "b", to: col)
        _ = try store.connectCards(a, b)
        try store.disconnectCard(a)   // 残り1枚 → 解散
        #expect(a.channel == nil)
        #expect(b.channel == nil)
        #expect(try store.channels().isEmpty)
    }

    @Test func deleteCardNormalizesOrders() throws {
        let store = try makeStore()
        let a = try store.addColumn(name: "A")
        let c0 = try store.addCard(title: "0", to: a)
        _ = try store.addCard(title: "1", to: a)
        try store.deleteCard(c0)
        #expect(a.cards.count == 1)
        #expect(a.cards.first?.order == 0)
        #expect(a.cards.first?.title == "1")
    }

    // MARK: - A2A ファイル層 (binding / 破損行温存 / merge)

    /// 接続で各カードの binding.json が現在チャンネルを指し、peers.json に両者が入る。
    @Test func connectWritesBindingAndPeers() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "A")
        let a = try store.addCard(title: "a", to: col)
        let b = try store.addCard(title: "b", to: col)
        let ch = try #require(try store.connectCards(a, b))
        defer { cleanup(cards: [a.id, b.id], channels: [ch.id]) }

        #expect(ChannelStore.readBinding(cardID: a.id)?.channel == ch.id.uuidString)
        #expect(ChannelStore.readBinding(cardID: b.id)?.channel == ch.id.uuidString)
        let peers = try #require(readPeers(ch.id))
        #expect(Set(peers.map(\.id)) == Set([a.id.uuidString, b.id.uuidString]))
    }

    /// 解除(解散)で離脱カードの binding が無所属になる。
    @Test func disconnectClearsBinding() throws {
        let store = try makeStore()
        let col = try store.addColumn(name: "A")
        let a = try store.addCard(title: "a", to: col)
        let b = try store.addCard(title: "b", to: col)
        let ch = try #require(try store.connectCards(a, b))
        defer { cleanup(cards: [a.id, b.id], channels: [ch.id]) }
        try store.disconnectCard(a)
        #expect(ChannelStore.readBinding(cardID: a.id)?.channel == nil)
        #expect(ChannelStore.readBinding(cardID: b.id)?.channel == nil)
    }

    /// deleteEntry はデコード不能な行を巻き添えで消さない(MEDIUM-3)。
    @Test func deleteEntryPreservesCorruptLines() throws {
        let chID = UUID()
        defer { ChannelStore.removeDir(for: chID) }
        // 正常エントリ1件 + 壊れた行1件を用意
        ChannelStore.append("valid note", author: "a", authorID: "aid", to: chID)
        let valid = try #require(ChannelStore.entries(for: chID).first)
        let mem = ChannelStore.memoryFile(for: chID)
        let raw = (try? String(contentsOf: mem, encoding: .utf8)) ?? ""
        try (raw + "{not valid json}\n").write(to: mem, atomically: true, encoding: .utf8)

        ChannelStore.deleteEntry(valid.id, from: chID)   // 正常エントリだけ消す
        let after = ChannelStore.rawLines(for: chID)
        #expect(after.count == 1)                         // 壊れた行は残る
        #expect(after.first?.contains("not valid json") == true)
        #expect(ChannelStore.entries(for: chID).isEmpty)  // 正常エントリは消えた
    }

    /// merge は両チャンネルの全エントリを温存する(追記ベース)。
    @Test func mergeMemoryKeepsAllEntries() throws {
        let src = UUID(); let dst = UUID()
        defer { ChannelStore.removeDir(for: src); ChannelStore.removeDir(for: dst) }
        ChannelStore.append("from-dst", author: "d", to: dst)
        ChannelStore.append("from-src-1", author: "s", to: src)
        ChannelStore.append("from-src-2", author: "s", to: src)
        ChannelStore.mergeMemory(from: src, into: dst)
        let texts = ChannelStore.entries(for: dst).map(\.text)
        #expect(texts.count == 3)
        #expect(Set(texts) == Set(["from-dst", "from-src-1", "from-src-2"]))
    }

    /// outbox の追記・読み出しと配信カーソルが往復する。
    @Test func outboxAndDeliveryCursorRoundTrip() throws {
        let chID = UUID(); let toID = UUID()
        defer { ChannelStore.removeDir(for: chID) }
        let m = OutboxMessage(fromID: "a", from: "cardA", to: "cardB", toID: toID.uuidString,
                              kind: "handoff", text: "take over")
        ChannelStore.appendOutbox(m, to: chID)
        let read = ChannelStore.outbox(for: chID)
        #expect(read.count == 1)
        #expect(read.first?.kind == "handoff")
        #expect(read.first?.toID == toID.uuidString)

        #expect(ChannelStore.deliveredIDs(cardID: toID, channelID: chID).isEmpty)
        ChannelStore.writeDelivered([m.id], cardID: toID, channelID: chID)
        #expect(ChannelStore.deliveredIDs(cardID: toID, channelID: chID) == [m.id])
    }

    /// peers.json は内容が同じなら書き直さない(watcher の自己トリガー防止)。
    /// 返り値(書いたか)で判定する(mtime 精度に依存しない決定的テスト)。
    @Test func writePeersSkipsWhenUnchanged() throws {
        let chID = UUID()
        defer { ChannelStore.removeDir(for: chID) }
        let peers = [PeerInfo(id: "1", name: "a", status: "idle")]
        #expect(ChannelStore.writePeers(peers, for: chID) == true)    // 初回は書く
        #expect(ChannelStore.writePeers(peers, for: chID) == false)   // 同内容 → スキップ
        let changed = [PeerInfo(id: "1", name: "a", status: "working")]
        #expect(ChannelStore.writePeers(changed, for: chID) == true)  // 変化 → 書く
    }

    /// 構造化メモリ: kind/refs が往復する。
    @Test func structuredMemoryRoundTrip() throws {
        let chID = UUID()
        defer { ChannelStore.removeDir(for: chID) }
        ChannelStore.append("chose SwiftData", author: "a", authorID: "aid",
                            kind: "decision", refs: ["Models.swift"], to: chID)
        let e = try #require(ChannelStore.entries(for: chID).first)
        #expect(e.effectiveKind == "decision")
        #expect(e.refs == ["Models.swift"])
        // 不明 kind は note に丸める
        ChannelStore.append("misc", author: "a", kind: "weird", to: chID)
        #expect(ChannelStore.entries(for: chID).last?.effectiveKind == "note")
    }

    /// board intent(create_card)を適用すると、カードが作られチャンネルへ参加する。
    @Test func applyCreateCardIntentJoinsChannel() throws {
        let store = try makeStore()
        let todo = try store.addColumn(name: "Todo")
        _ = try store.addColumn(name: "Done")
        let a = try store.addCard(title: "a", to: todo)
        let b = try store.addCard(title: "b", to: todo)
        let ch = try #require(try store.connectCards(a, b))
        defer { cleanup(cards: [a.id, b.id], channels: [ch.id]) }

        let intent = BoardIntent(kind: "create_card", fromID: a.id.uuidString, title: "spawned", column: "Todo")
        writeIntent(intent, to: ch.id)
        store.applyBoardIntents(for: ch.id)

        let created = try #require(todo.cards.first { $0.title == "spawned" })
        #expect(created.channel?.id == ch.id)          // 同じチャンネルへ参加
        #expect(ch.cards.count == 3)
        // 二度目の適用は冪等(重複作成しない)
        store.applyBoardIntents(for: ch.id)
        #expect(todo.cards.filter { $0.title == "spawned" }.count == 1)
    }

    /// board intent(move_card)はチャンネル所属カードを別列へ移す。
    @Test func applyMoveCardIntent() throws {
        let store = try makeStore()
        let todo = try store.addColumn(name: "Todo")
        let done = try store.addColumn(name: "Done")
        let a = try store.addCard(title: "a", to: todo)
        let b = try store.addCard(title: "b", to: todo)
        let ch = try #require(try store.connectCards(a, b))
        defer { cleanup(cards: [a.id, b.id], channels: [ch.id]) }

        writeIntent(BoardIntent(kind: "move_card", fromID: a.id.uuidString, card: "b", column: "Done"), to: ch.id)
        store.applyBoardIntents(for: ch.id)
        #expect(b.column?.name == "Done")
    }

    /// board.json スナップショットが列とチャンネルカードを反映する。
    @Test func boardSnapshotReflectsChannel() throws {
        let store = try makeStore()
        let todo = try store.addColumn(name: "Todo")
        let a = try store.addCard(title: "a", to: todo)
        let b = try store.addCard(title: "b", to: todo)
        let ch = try #require(try store.connectCards(a, b))
        defer { cleanup(cards: [a.id, b.id], channels: [ch.id]) }
        store.writeBoardSnapshot(for: ch.id)
        let url = ChannelStore.dir(for: ch.id).appending(path: "board.json")
        let snap = try JSONDecoder().decode(BoardSnapshot.self, from: Data(contentsOf: url))
        #expect(snap.columns.map(\.name).contains("Todo"))
        #expect(Set(snap.cards.map(\.title)) == Set(["a", "b"]))
    }

    /// worktree バインディング(setWorktree)が board.json スナップショットへ反映されることを確認する。
    @Test func boardSnapshotReflectsWorktreeBinding() throws {
        let store = try makeStore()
        let todo = try store.addColumn(name: "Todo")
        let a = try store.addCard(title: "a", to: todo)
        let b = try store.addCard(title: "b", to: todo)
        let ch = try #require(try store.connectCards(a, b))
        defer { cleanup(cards: [a.id, b.id], channels: [ch.id]) }
        try store.setWorktree(a, repoRoot: "/repo", worktreePath: "/repo/.worktrees/a", branch: "feat/a", fleetOwned: true)
        store.writeBoardSnapshot(for: ch.id)
        let url = ChannelStore.dir(for: ch.id).appending(path: "board.json")
        let snap = try JSONDecoder().decode(BoardSnapshot.self, from: Data(contentsOf: url))
        let cardA = try #require(snap.cards.first { $0.title == "a" })
        #expect(cardA.repoRoot == "/repo")
        #expect(cardA.worktreePath == "/repo/.worktrees/a")
        #expect(cardA.branch == "feat/a")
        #expect(cardA.isFleetOwnedWorktree == true)
        let cardB = try #require(snap.cards.first { $0.title == "b" })
        #expect(cardB.worktreePath == nil)
        #expect(cardB.isFleetOwnedWorktree == false)
    }

    // MARK: helpers

    private func writeIntent(_ intent: BoardIntent, to channelID: UUID) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let line = (try? enc.encode(intent)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let url = ChannelStore.dir(for: channelID).appending(path: "board-intents.jsonl")
        try? FileManager.default.createDirectory(at: ChannelStore.dir(for: channelID), withIntermediateDirectories: true)
        try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func readPeers(_ id: UUID) -> [PeerInfo]? {
        let url = ChannelStore.dir(for: id).appending(path: "peers.json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([PeerInfo].self, from: d)
    }

    private func cleanup(cards: [UUID], channels: [UUID]) {
        for c in cards { ChannelStore.removeBinding(cardID: c) }
        for c in channels { ChannelStore.removeDir(for: c) }
    }
}
