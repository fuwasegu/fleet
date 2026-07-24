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
                        autoStartAgent: Bool = false,
                        agentKind: AgentKind = .claude) throws -> Card {
        let next = (column.cards.map(\.order).max() ?? -1) + 1
        let card = Card(title: title,
                        order: next,
                        column: column,
                        workingDirPath: workingDirPath,
                        dangerSkip: dangerSkip,
                        autoStartAgent: autoStartAgent,
                        agentKind: agentKind)
        context.insert(card)
        try context.save()
        return card
    }

    public func renameCard(_ card: Card, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BoardError.emptyName }
        card.title = trimmed
        try context.save()
        // A2A: 表示名は peers/binding に出るので追従させる(識別子は id なので改名は安全)
        if let ch = card.channel { syncChannel(ch) }
        else { ChannelStore.writeBinding(cardID: card.id, channel: nil, name: card.title) }
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

    /// カードを Fleet 管理 worktree にバインドする(git 操作は行わない。バインディングのみ)。
    public func setWorktree(_ card: Card, repoRoot: String, worktreePath: String, branch: String, fleetOwned: Bool) throws {
        card.repoRoot = repoRoot
        card.worktreePath = worktreePath
        card.branch = branch
        card.isFleetOwnedWorktree = fleetOwned
        try context.save()
    }

    /// worktree バインディングのみ解除する(ディスク上の worktree には触れない)。
    public func clearWorktree(_ card: Card) throws {
        card.worktreePath = nil
        card.repoRoot = nil
        card.isFleetOwnedWorktree = false
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
        // A2A: ディスク上の peers/binding も現在の(=未起動)状態へ同期し、
        // 前回セッションの古い status がファイルに残らないようにする。
        for ch in (try? channels()) ?? [] { syncChannel(ch) }
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
        let cardID = card.id
        try disconnectCard(card)   // A2A: チャンネルから離脱(1枚チャンネルの残留防止)
        ChannelStore.removeBinding(cardID: cardID)   // カード用ディレクトリごと掃除
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
            // cb を ca へ合流。順序が重要(FSL a2a_channel_race_fixed 準拠):
            //  (1)所属を ca へ → (2)binding を ca へ(syncChannel)→ (3)src ロック下で
            //     メモリ移動+dir 削除。稼働中 bridge は書込直前に binding を読み直すので、
            //     binding が ca に変わった後なら消えた cb へ書いて失うことがない(TOCTOU 回避)。
            let cbID = cb.id
            let moved = cb.cards
            for c in moved { c.channel = ca; ChannelStore.removeMCPConfig(cardID: c.id, channelID: cbID) }
            channel = ca
            context.delete(cb)
            try context.save()
            syncChannel(ca)                                      // (2) binding→ca(削除より前)
            ChannelStore.relocateAndRemove(from: cbID, into: ca.id)  // (3) src ロック下で移動+削除
            return channel
        }
        try context.save()
        syncChannel(channel)
        return channel
    }

    /// カードをチャンネルから外す。残り1枚以下になったチャンネルは解散する。
    public func disconnectCard(_ card: Card) throws {
        guard let ch = card.channel else { return }
        let leavingID = card.id
        let chID = ch.id
        card.channel = nil
        try context.save()
        // 離脱カードは binding を無所属に(稼働中 bridge は次操作で「未所属」を検知して書込を止める)。
        ChannelStore.writeBinding(cardID: leavingID, channel: nil, name: card.title)
        ChannelStore.removeMCPConfig(cardID: leavingID, channelID: chID)
        if ch.cards.count < 2 {
            for c in ch.cards {
                ChannelStore.writeBinding(cardID: c.id, channel: nil, name: c.title)  // binding→無所属(削除より前)
                ChannelStore.removeMCPConfig(cardID: c.id, channelID: chID)
                c.channel = nil
            }
            context.delete(ch)
            try context.save()
            ChannelStore.removeDirLocked(for: chID)   // src ロック下で削除(稼働中 bridge と直列化)
        } else {
            syncChannel(ch)
        }
    }

    /// チャンネルの現在メンバーで peers.json と各カードの binding.json を同期する。
    /// A2A の「所属は可変・bridge は間接解決」を成立させる唯一の書き込み口。
    /// 状態変化時にも呼ばれ、fleet_peers を live-aware に保つ。
    public func syncChannel(_ channel: Channel) {
        let peers = channel.cards.map { Self.peerInfo(for: $0, channelID: channel.id) }
        ChannelStore.writePeers(peers, for: channel.id)
        for c in channel.cards {
            ChannelStore.writeBinding(cardID: c.id, channel: channel.id, name: c.title)
        }
    }

    /// Agent の盤面操作 intent(board-intents.jsonl)を適用する。
    /// create_card / move_card のみ(破壊操作なし)。move はチャンネル所属カードに限定。
    /// 適用済み id は記録し、成否に関わらず再適用しない(リトライ暴走防止)。
    public func applyBoardIntents(for channelID: UUID) {
        let intents = ChannelStore.boardIntents(for: channelID)
        guard !intents.isEmpty else { return }
        var applied = ChannelStore.appliedIntentIDs(for: channelID)
        var didApply = false
        for intent in intents where !applied.contains(intent.id) {
            applied.insert(intent.id); didApply = true
            guard let ch = channel(withID: channelID) else { continue }
            let cols = (try? columns()) ?? []
            switch intent.kind {
            case "create_card":
                guard let title = intent.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { break }
                guard let col = cols.first(where: { $0.name == intent.column }) ?? cols.first else { break }
                let dir = (intent.dir?.isEmpty == false) ? intent.dir : nil
                if let card = try? addCard(title: title, to: col, workingDirPath: dir) {
                    // 作成元と同じチャンネルへ参加させて文脈を共有(委譲の要)。
                    let anchor = ch.cards.first { $0.id.uuidString == intent.fromID } ?? ch.cards.first
                    if let anchor { try? connectCards(card, anchor) }
                }
            case "move_card":
                guard let ref = intent.card, let colName = intent.column,
                      let col = cols.first(where: { $0.name == colName }) else { break }
                if let target = ch.cards.first(where: { $0.id.uuidString == ref || $0.title == ref }) {
                    try? moveCard(target, to: col, at: col.cards.count)
                }
            default: break
            }
        }
        if didApply { ChannelStore.writeAppliedIntentIDs(applied, for: channelID) }
    }

    /// board.json スナップショット(fleet_board 用)を書く。差分時のみ書き込む。
    public func writeBoardSnapshot(for channelID: UUID) {
        guard let ch = channel(withID: channelID) else { return }
        let cols = ((try? columns()) ?? []).map { BoardSnapshot.Col(name: $0.name) }
        let sorted = ch.cards.sorted { a, b in
            let ca = a.column?.order ?? 0, cb = b.column?.order ?? 0
            return ca != cb ? ca < cb : a.order < b.order
        }
        let cards = sorted.map { c in
            BoardSnapshot.CardRef(id: c.id.uuidString, title: c.title,
                                  column: c.column?.name ?? "",
                                  status: c.isDone ? "done" : c.agentState.rawValue)
        }
        ChannelStore.writeBoardSnapshot(BoardSnapshot(columns: cols, cards: cards), for: channelID)
    }

    private static func peerInfo(for card: Card, channelID: UUID) -> PeerInfo {
        let status = card.isDone ? "done" : card.agentState.rawValue
        return PeerInfo(id: card.id.uuidString,
                        name: card.title,
                        status: status,
                        task: ChannelStore.readStatus(cardID: card.id, channelID: channelID),
                        blocked: card.blockedPrompt,
                        branch: card.branch,
                        pr: card.prURL)
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
