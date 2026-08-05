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
                        agentKind: AgentKind = .claude,
                        model: String? = nil) throws -> Card {
        let next = (column.cards.map(\.order).max() ?? -1) + 1
        let card = Card(title: title,
                        order: next,
                        column: column,
                        workingDirPath: workingDirPath,
                        dangerSkip: dangerSkip,
                        autoStartAgent: autoStartAgent,
                        agentKind: agentKind)
        // 不正な値が来ても起動コマンドを汚染しないよう、保存前に必ず正規化する。
        card.model = AgentLaunch.normalizedModel(model)
        context.insert(card)
        try context.save()
        return card
    }

    /// カードのモデル指定を差し替える。空/不正な値は nil(= CLI の既定モデル)に落とす。
    /// 反映されるのは次にそのカードのターミナルを起動したときから(走っているセッションは
    /// 起動時のモデルのまま。途中で変えたければ端末で `/model` を使う)。
    public func setCardModel(_ card: Card, model: String?) throws {
        card.model = AgentLaunch.normalizedModel(model)
        try context.save()
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
    /// 「CC 未起動」状態(unknown / 問いなし)にリセットして、表示と実体の齟齬を防ぐ。
    /// `seen`(未読/既読)には触れない — 「Agent がよそ見中に完了した」という事実は
    /// 端末セッションと違ってプロセスの生死に紐付かないため、再起動後も持ち越して良い
    /// (`Card.isDone` は `.unknown` になっても `!seen` を見て Done/未読を維持する)。
    public func resetAgentStates() throws {
        let cards = try context.fetch(FetchDescriptor<Card>())
        var changed = false
        for card in cards {
            if card.agentState != .unknown { card.agentState = .unknown; changed = true }
            if card.blockedPrompt != nil { card.blockedPrompt = nil; changed = true }
        }
        if changed { try context.save() }
        // A2A: ディスク上の peers/binding も現在の(=未起動)状態へ同期し、
        // 前回セッションの古い status がファイルに残らないようにする。
        for ch in (try? channels()) ?? [] { syncChannel(ch) }
    }

    /// 盤面の全カード。列を跨いで探すときに使う。
    public func cards() throws -> [Card] {
        try context.fetch(FetchDescriptor<Card>())
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

    /// binding.json の自己改竄への緩和策(C1)。fleet-bridge はカード自身の binding.json を
    /// 唯一の「今どのチャンネルか」の入力源として信用するが、その agent 自身がシェル権限で
    /// 同じファイルを別チャンネルの(有効な形の)UUID へ書き換えれば、bridge はそのチャンネルの
    /// 共有メモリ/ロック/outbox を、アプリが一度もメンバーにしていない状態のまま操作してしまう。
    /// アプリ(SwiftData)だけが本当の所属を知っているので、`~/.fleet/cards/*/binding.json` を
    /// 総当りして各ファイルの内容を実際の所属で強制的に書き直す。件数は小さい(カード数)ため
    /// 安価。破壊的な token 方式などの完全な対策は out of scope — シェル権限を持つ agent は
    /// 他チャンネルのファイルを直接触れるので、ファイル衛生だけでは閉じきれない(bounded mitigation)。
    /// 解析できないエントリ(UUID でないディレクトリ名・デコード不能な binding.json)は黙って無視する。
    public func reconcileBindings() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: ChannelStore.cardsDir(), includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            guard let cardID = UUID(uuidString: entry.lastPathComponent) else { continue }
            guard let binding = ChannelStore.readBinding(cardID: cardID) else { continue }
            guard let card = card(withID: cardID) else {
                // カード自体がもう存在しない(削除済み) → binding ディレクトリごと片付ける
                // (deleteCard と同じ後片付け)。
                ChannelStore.removeBinding(cardID: cardID)
                continue
            }
            let realChannelID = card.channel?.id.uuidString
            if binding.channel != realChannelID {
                // disconnect と同じ書き込み経路(writeBinding)で真実へ上書きする。
                ChannelStore.writeBinding(cardID: cardID, channel: card.channel?.id, name: card.title)
            }
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
                // 作成元と同じチャンネルへ参加させて文脈を共有(委譲の要)。
                let anchor = ch.cards.first { $0.id.uuidString == intent.fromID } ?? ch.cards.first
                _ = createCard(from: intent, columns: cols, connectTo: anchor)
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

    /// `create_card` intent からカードを1枚作る。チャンネル経由とカード経由の**唯一の実装**。
    /// 片方だけ挙動が変わると「無所属から作ったカードだけ agent が効かない」といった
    /// ズレを生むので、必ずここを通す。
    @discardableResult
    func createCard(from intent: BoardIntent, columns cols: [BoardColumn],
                    connectTo anchor: Card?) -> Card? {
        guard let title = intent.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        guard let col = cols.first(where: { $0.name == intent.column }) ?? cols.first else { return nil }
        let dir = (intent.dir?.isEmpty == false) ? intent.dir : nil
        // agent は Agent が渡す任意の文字列。未知の値は既定(claude)に落とす。
        let kind = AgentKind(rawValue: (intent.agent ?? "").lowercased()) ?? .claude
        guard let card = try? addCard(title: title, to: col, workingDirPath: dir,
                                     agentKind: kind, model: intent.model) else { return nil }
        if let anchor, anchor.id != card.id { try? connectCards(card, anchor) }
        return card
    }

    /// カード単位の `board-intents.jsonl` を適用する(まだどのカードともつながっていない
    /// カードからの委譲)。適用時に作成元と結線するので、ここでチャンネルが生まれる。
    ///
    /// チャンネル所属カードもこのキューに書きうる(bridge は無所属のときだけ使うが、
    /// 取りこぼしを避けるため所属の有無で分岐しない)。`connectCards` は既に同一チャンネルなら
    /// 何もしないので二重参加にはならない。
    public func applyCardIntents() {
        for cardID in ChannelStore.knownCardIDs() {
            let intents = ChannelStore.cardIntents(for: cardID)
            guard !intents.isEmpty else { continue }
            var applied = ChannelStore.appliedCardIntentIDs(for: cardID)
            var didApply = false
            let cols = (try? columns()) ?? []
            for intent in intents where !applied.contains(intent.id) {
                applied.insert(intent.id); didApply = true
                guard intent.kind == "create_card" else { continue }
                // 作成元カードが盤面から消えていたら何もしない(孤児カードを作らない)。
                guard let creator = card(withID: cardID) else { continue }
                createCard(from: intent, columns: cols, connectTo: creator)
            }
            if didApply { ChannelStore.writeAppliedCardIntentIDs(applied, for: cardID) }
        }
    }

    /// Agent の worktree 作成 intent(worktree-intents.jsonl)を適用する(同期版)。
    /// 検証済みの WorktreeService.create を単一の git 実行経路として使い、成功したら
    /// カードを Fleet 管理 worktree へ再バインドする(setWorktree)。適用済み id は
    /// board intent と同じ「applied 集合」パターンで記録し、成否に関わらず再適用しない
    /// (二重 create による重複エラー/二重バインドを防ぐ)。
    ///
    /// git 呼び出しを含むため MainActor 上で数秒ブロックしうる。UI から常駐監視で呼ぶ経路
    /// (A2AChannelHub)は必ず `applyWorktreeIntentsAsync` を使うこと。この同期版はテスト、
    /// および MainActor をブロックしても問題ない呼び出し元専用に残す。
    public func applyWorktreeIntents(for channelID: UUID) {
        let intents = ChannelStore.worktreeIntents(for: channelID)
        guard !intents.isEmpty else { return }
        var applied = ChannelStore.appliedWorktreeIntentIDs(for: channelID)
        for intent in intents where !applied.contains(intent.id) {
            let result: WorktreeResult
            switch validateWorktreeIntent(intent, channelID: channelID) {
            case .failure(let r):
                result = r
            case .ok(let fromUUID, let cwd, let existingRepoRoot):
                let gitOutcome = Self.performWorktreeGit(
                    cwd: cwd, existingRepoRoot: existingRepoRoot,
                    branch: intent.branch, base: Self.base(for: intent)
                )
                result = finishWorktreeIntent(intent, fromUUID: fromUUID, gitOutcome: gitOutcome)
            }
            ChannelStore.writeWorktreeResult(result, for: channelID)
            applied.insert(intent.id)
            ChannelStore.writeAppliedWorktreeIntentIDs(applied, for: channelID)
        }
    }

    /// Agent の worktree 作成 intent を非同期に適用する(git 呼び出しを MainActor 外の
    /// `Task.detached` で実行し、UI フリーズを避ける)。手順は per-intent で:
    /// (1) MainActor 上で intent を検証し、必要な値(cwd/repoRoot 等、すべて値型)を取り出す。
    /// (2) git 呼び出しは `Task.detached` へ(SwiftData オブジェクトは一切キャプチャしない)。
    /// (3) await から戻ったら MainActor でカードを再取得し直し(await 中に削除される可能性が
    ///     あるため)、setWorktree で SwiftData へバインドし、結果ファイルを書く。
    /// 適用済み id の記録は同期版と同じ「applied 集合」パターンで、成否に関わらず1度だけ適用する。
    public func applyWorktreeIntentsAsync(for channelID: UUID) async {
        let intents = ChannelStore.worktreeIntents(for: channelID)
        guard !intents.isEmpty else { return }
        var applied = ChannelStore.appliedWorktreeIntentIDs(for: channelID)
        for intent in intents where !applied.contains(intent.id) {
            let result: WorktreeResult
            switch validateWorktreeIntent(intent, channelID: channelID) {
            case .failure(let r):
                result = r
            case .ok(let fromUUID, let cwd, let existingRepoRoot):
                let branch = intent.branch
                let base = Self.base(for: intent)
                // git 呼び出しのみを MainActor 外へ退避する。渡すのは String/enum の値型のみ。
                let gitOutcome = await Task.detached(priority: .userInitiated) {
                    Self.performWorktreeGit(cwd: cwd, existingRepoRoot: existingRepoRoot, branch: branch, base: base)
                }.value
                result = finishWorktreeIntent(intent, fromUUID: fromUUID, gitOutcome: gitOutcome)
            }
            ChannelStore.writeWorktreeResult(result, for: channelID)
            applied.insert(intent.id)
            ChannelStore.writeAppliedWorktreeIntentIDs(applied, for: channelID)
        }
    }

    private static func base(for intent: WorktreeIntent) -> WorktreeBase {
        intent.base == "default" ? .defaultBranch : .current
    }

    private enum WorktreeIntentValidation {
        /// `fromUUID` = 検証済みの発行元カード id、`cwd` = そのカードの実効 cwd、
        /// `existingRepoRoot` = カードに既に紐づいている repoRoot(あれば再利用する)。
        case ok(fromUUID: UUID, cwd: String, existingRepoRoot: String?)
        case failure(WorktreeResult)
    }

    /// `intent.fromCardID` は必ず `channelID` に所属するカードでなければならない
    /// (board intent の move/create と同じく `ch.cards` でスコープする)。所属チェックを
    /// 外すと、あるチャンネルで偽装した intent が無関係カードの worktree を作成/再バインド
    /// できてしまう。SwiftData の読み取りのみで、git には触れない(MainActor 上で完結)。
    private func validateWorktreeIntent(_ intent: WorktreeIntent, channelID: UUID) -> WorktreeIntentValidation {
        guard let ch = channel(withID: channelID) else {
            return .failure(WorktreeResult(id: intent.id, ok: false, error: "channel not found"))
        }
        guard let fromUUID = UUID(uuidString: intent.fromCardID), let card = card(withID: fromUUID) else {
            return .failure(WorktreeResult(id: intent.id, ok: false, error: "card not found"))
        }
        guard ch.cards.contains(where: { $0.id == fromUUID }) else {
            return .failure(WorktreeResult(id: intent.id, ok: false, error: "card is not a member of this channel"))
        }
        if card.isFleetOwnedWorktree, card.worktreePath != nil {
            return .failure(WorktreeResult(id: intent.id, ok: false, error: "this card already has a Fleet-managed worktree"))
        }
        guard let cwd = card.effectiveCwd else {
            return .failure(WorktreeResult(id: intent.id, ok: false, error: "card has no working directory; not a git repository"))
        }
        return .ok(fromUUID: fromUUID, cwd: cwd, existingRepoRoot: card.repoRoot)
    }

    /// nonisolated: 純粋な git 操作のみ(repoRoot 解決 + ベース最新化 + worktree create)。
    /// SwiftData には一切触れないので、MainActor の内外どちらから呼んでも(sync 版はそのまま、
    /// async 版は `Task.detached` の中から)安全。引数・戻り値はすべて値型 (String/enum/Result)。
    ///
    /// Agent 経由(MCP `fleet_worktree_create`)の intent も UI からの作成と同じ「ローカル
    /// base ブランチが陳腐化している」問題を踏むため、`resolveFreshBase` で origin から
    /// フェッチしたリモート追跡ブランチを優先する(fetch: true)。フォールバックした場合の
    /// note は呼び出し元(finishWorktreeIntent)に伝え、WorktreeResult 経由で Agent に返す。
    private nonisolated static func performWorktreeGit(
        cwd: String, existingRepoRoot: String?, branch: String, base: WorktreeBase
    ) -> Result<(repoRoot: String, path: String, note: String?), WorktreeService.GitError> {
        do {
            let repoRoot: String
            if let r = existingRepoRoot {
                repoRoot = r
            } else if let r = try? WorktreeService.run(["rev-parse", "--show-toplevel"], in: cwd), !r.isEmpty {
                repoRoot = r
            } else {
                return .failure(WorktreeService.GitError(message: "not a git repository: \(cwd)"))
            }
            let localBase = WorktreeService.resolveBase(base, repoRoot: repoRoot)
            let resolved = WorktreeService.resolveFreshBase(repoRoot: repoRoot, base: localBase, fetch: true)
            let path = try WorktreeService.create(repoRoot: repoRoot, branch: branch, baseRef: resolved.ref, baseDir: WorktreeService.defaultWorktreeBaseDir)
            return .success((repoRoot, path, resolved.note))
        } catch let e as WorktreeService.GitError {
            return .failure(e)
        } catch {
            return .failure(WorktreeService.GitError(message: "\(error)"))
        }
    }

    /// git 結果を受けてカードを再バインドする仕上げ処理。同期版・async 版どちらからも呼ぶ。
    /// カードは id で再取得する(同期版では検証直後なので実質同一だが、async 版では `await` の
    /// 間にカードが削除/変更されている可能性があるため、事前に保持した `Card` 参照は使わず
    /// 必ずここで取り直す)。
    private func finishWorktreeIntent(
        _ intent: WorktreeIntent, fromUUID: UUID,
        gitOutcome: Result<(repoRoot: String, path: String, note: String?), WorktreeService.GitError>
    ) -> WorktreeResult {
        switch gitOutcome {
        case .failure(let e):
            return WorktreeResult(id: intent.id, ok: false, error: e.message)
        case .success(let (repoRoot, path, note)):
            guard let card = card(withID: fromUUID) else {
                // await 中にカードが削除された。worktree はディスク上に作られてしまっているが、
                // バインド先が無いので安全側に倒してエラーとして報告する(孤児 worktree はユーザーが
                // 「ターミナルを開いて手動で処理」等で発見できるよう、パスをメッセージに残す)。
                return WorktreeResult(id: intent.id, ok: false, error: "card was removed while creating worktree: \(path)", note: note)
            }
            if card.isFleetOwnedWorktree, card.worktreePath != nil {
                // await 中に別経路で既にバインドされた(理論上は per-channel in-flight ガードで
                // 起こらないはずだが、fail-closed で二重バインドを防ぐ)。
                return WorktreeResult(id: intent.id, ok: false, error: "this card already has a Fleet-managed worktree")
            }
            do {
                try setWorktree(card, repoRoot: repoRoot, worktreePath: path,
                                branch: WorktreeService.sanitizeBranch(intent.branch), fleetOwned: true)
                // note != nil はベース最新化がフォールバックした(陳腐化しうるローカルブランチから
                // 作成した)ことを意味する。ok な結果に紛れて消えないよう note をそのまま乗せて
                // Agent に伝える(fleet-bridge 側が成功メッセージに付記する)。
                return WorktreeResult(id: intent.id, ok: true, path: path, note: note)
            } catch {
                return WorktreeResult(id: intent.id, ok: false, error: "\(error)")
            }
        }
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
                                  status: c.isDone ? "done" : c.agentState.rawValue,
                                  repoRoot: c.repoRoot, worktreePath: c.worktreePath,
                                  branch: c.branch, isFleetOwnedWorktree: c.isFleetOwnedWorktree)
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

    // MARK: - Claude プロファイル (config dir 切替)

    /// プロファイルを order 昇順 → label 昇順で取得
    public func profiles() throws -> [ClaudeProfile] {
        let descriptor = FetchDescriptor<ClaudeProfile>(
            sortBy: [SortDescriptor(\.order), SortDescriptor(\.label)]
        )
        return try context.fetch(descriptor)
    }

    @discardableResult
    public func addProfile(label: String, configDirPath: String) throws -> ClaudeProfile {
        let next = (try profiles().map(\.order).max() ?? -1) + 1
        let profile = ClaudeProfile(label: label, configDirPath: configDirPath, order: next)
        context.insert(profile)
        try context.save()
        return profile
    }

    public func updateProfile(_ p: ClaudeProfile, label: String, configDirPath: String) throws {
        p.label = label
        p.configDirPath = configDirPath
        try context.save()
    }

    /// プロファイルを削除する。割り当て済みカードは nullify される(カード自体は残る)。
    public func deleteProfile(_ p: ClaudeProfile) throws {
        context.delete(p)
        try context.save()
    }

    public func setCardProfile(_ card: Card, profile: ClaudeProfile?) throws {
        card.claudeProfile = profile
        try context.save()
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
