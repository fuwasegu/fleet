import Foundation
import SwiftData

public enum BoardError: Error, Equatable {
    case emptyName
    case columnNotEmpty
}

/// ボード操作 API。`kanban_ui.fsl` のアクションに 1:1 対応し、不変条件をここで担保する。
@MainActor
public struct BoardStore {
    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// 列を order 昇順で取得
    public func columns() throws -> [BoardColumn] {
        let descriptor = FetchDescriptor<BoardColumn>(sortBy: [SortDescriptor(\.order)])
        return try context.fetch(descriptor)
    }

    // MARK: - 列 (状態)

    @discardableResult
    public func addColumn(name: String) throws -> BoardColumn {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardError.emptyName }
        let next = (try columns().map(\.order).max() ?? -1) + 1
        let column = BoardColumn(name: trimmed, order: next)
        context.insert(column)
        try context.save()
        return column
    }

    public func renameColumn(_ column: BoardColumn, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardError.emptyName }
        column.name = trimmed
        try context.save()
    }

    public func setColumnColor(_ column: BoardColumn, hex: String?) throws {
        column.colorHex = hex
        try context.save()
    }

    /// fsl: remove_column — 空でない列は削除不可（孤児カード防止 / CardInExistingColumn）
    public func removeColumn(_ column: BoardColumn) throws {
        guard column.cards.isEmpty else { throw BoardError.columnNotEmpty }
        context.delete(column)
        try context.save()
        normalizeColumnOrders()
        try context.save()
    }

    /// 列の並べ替え。order を 0..n-1 に振り直す。
    public func moveColumn(_ column: BoardColumn, to index: Int) throws {
        var target = try columns().filter { $0.id != column.id }
        let clamped = max(0, min(index, target.count))
        target.insert(column, at: clamped)
        for (i, c) in target.enumerated() { c.order = i }
        try context.save()
    }

    // MARK: - カード

    @discardableResult
    public func addCard(title: String,
                        to column: BoardColumn,
                        workingDirPath: String? = nil,
                        dangerSkip: Bool = false,
                        autoStartAgent: Bool = false) throws -> Card {
        let next = (column.cards.map(\.order).max() ?? -1) + 1
        let card = Card(title: title,
                        order: next,
                        column: column,
                        workingDirPath: workingDirPath,
                        dangerSkip: dangerSkip,
                        autoStartAgent: autoStartAgent)
        context.insert(card)
        try context.save()
        return card
    }

    public func renameCard(_ card: Card, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardError.emptyName }
        card.title = trimmed
        try context.save()
    }

    public func setCardDirectory(_ card: Card, path: String?) throws {
        card.workingDirPath = path
        try context.save()
    }

    public func setCardPR(_ card: Card, url: String?) throws {
        card.prURL = url
        try context.save()
    }

    public func setCardGitInfo(_ card: Card, branch: String?, prURL: String?) throws {
        card.branch = branch
        card.prURL = prURL
        try context.save()
    }

    /// アプリ起動時に呼ぶ。端末セッションはプロセスと共に消えるため、全カードを
    /// 「CC 未起動」状態(unknown / 既読 / 問いなし)にリセットして、表示と実体の齟齬を防ぐ。
    public func resetAgentStates() throws {
        let cards = try context.fetch(FetchDescriptor<Card>())
        var changed = false
        for card in cards {
            if card.agentState != .unknown { card.agentState = .unknown; changed = true }
            if !card.seen { card.seen = true; changed = true }
            if card.blockedPrompt != nil { card.blockedPrompt = nil; changed = true }
        }
        if changed { try context.save() }
    }

    public func card(withID id: UUID) -> Card? {
        let descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    public func column(withID id: UUID) -> BoardColumn? {
        let descriptor = FetchDescriptor<BoardColumn>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    public func deleteCard(_ card: Card) throws {
        let column = card.column
        context.delete(card)
        try context.save()
        if let column {
            normalizeCardOrders(in: column)
            try context.save()
        }
    }

    /// fsl: move_card — 列間移動 / 列内並び替え。移動後もカードは必ず列に属す。
    public func moveCard(_ card: Card, to column: BoardColumn, at index: Int) throws {
        let source = card.column
        card.column = column
        var target = column.cards
            .filter { $0.id != card.id }
            .sorted { $0.order < $1.order }
        let clamped = max(0, min(index, target.count))
        target.insert(card, at: clamped)
        for (i, c) in target.enumerated() { c.order = i }
        if let source, source.persistentModelID != column.persistentModelID {
            normalizeCardOrders(in: source)
        }
        try context.save()
    }

    // MARK: - Channel (A2A 共有メモリ)

    private static let channelColors = ["7FD962", "6FB0FF", "FF9F0A", "BF5AF2", "FF375F", "32D74B", "FFD60A"]

    public func channels() throws -> [Channel] {
        try context.fetch(FetchDescriptor<Channel>())
    }

    public func channel(withID id: UUID) -> Channel? {
        let d = FetchDescriptor<Channel>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(d).first
    }

    /// 2枚のカードを同一チャンネル(共有メモリ)へ。無ければ新規、片方所属なら合流、両方別なら合流。
    @discardableResult
    public func connectCards(_ a: Card, _ b: Card) throws -> Channel? {
        guard a.id != b.id else { return a.channel }
        if let ch = a.channel, ch.id == b.channel?.id { return ch }   // 既に同一

        let channel: Channel
        switch (a.channel, b.channel) {
        case (nil, nil):
            let color = Self.channelColors[(try channels().count) % Self.channelColors.count]
            let ch = Channel(name: defaultChannelName(a, b), colorHex: color)
            context.insert(ch)
            a.channel = ch; b.channel = ch
            channel = ch
        case (let ca?, nil):
            b.channel = ca; channel = ca
        case (nil, let cb?):
            a.channel = cb; channel = cb
        case (let ca?, let cb?):
            // cb を ca へ合流(メモリも移す)
            ChannelStore.mergeMemory(from: cb.id, into: ca.id)
            for c in cb.cards { c.channel = ca }
            ChannelStore.removeDir(for: cb.id)
            context.delete(cb)
            channel = ca
        }
        try context.save()
        ChannelStore.writePeers(channel.cards.map(\.title), for: channel.id)
        return channel
    }

    /// カードをチャンネルから外す。残り1枚以下になったチャンネルは解散する。
    public func disconnectCard(_ card: Card) throws {
        guard let ch = card.channel else { return }
        card.channel = nil
        try context.save()
        if ch.cards.count < 2 {
            for c in ch.cards { c.channel = nil }
            ChannelStore.removeDir(for: ch.id)
            context.delete(ch)
            try context.save()
        } else {
            ChannelStore.writePeers(ch.cards.map(\.title), for: ch.id)
        }
    }

    private func defaultChannelName(_ a: Card, _ b: Card) -> String {
        if let p = a.workingDirPath, !p.isEmpty {
            let base = (p as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        return a.title.isEmpty ? "channel" : String(a.title.prefix(20))
    }

    // MARK: - order 正規化 (0..n-1)

    private func normalizeColumnOrders() {
        guard let cols = try? columns() else { return }
        for (i, c) in cols.enumerated() { c.order = i }
    }

    private func normalizeCardOrders(in column: BoardColumn) {
        let sorted = column.cards.sorted { $0.order < $1.order }
        for (i, c) in sorted.enumerated() { c.order = i }
    }
}
