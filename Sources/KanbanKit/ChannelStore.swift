import Foundation

/// チャンネル共有メモリの1エントリ。fleet-bridge と同じ JSON 形式。
/// author は表示名、authorID は安定な識別子(カード UUID)。改名しても authorID は不変。
/// kind/refs は構造化メモリ用(後方互換: 旧エントリは nil → note 扱い)。
public struct ChannelEntry: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let author: String
    public let authorID: String?   // 後方互換: 旧エントリには無い
    public let text: String
    public let createdAt: Date
    public let kind: String?       // decision | blocker | artifact | question | note
    public let refs: [String]?     // 関連するファイルパス / PR / カード id など

    public init(id: String = UUID().uuidString, author: String, authorID: String? = nil,
                text: String, createdAt: Date = Date(), kind: String? = nil, refs: [String]? = nil) {
        self.id = id; self.author = author; self.authorID = authorID
        self.text = text; self.createdAt = createdAt; self.kind = kind; self.refs = refs
    }

    /// 有効な kind(nil や不明値は note に丸める)。
    public var effectiveKind: String {
        let allowed: Set<String> = ["decision", "blocker", "artifact", "question", "note"]
        guard let k = kind?.lowercased(), allowed.contains(k) else { return "note" }
        return k
    }
}

/// peers.json の1メンバー。fleet_peers が返す live-aware な情報。
/// 識別子は id(カード UUID)。status/task/blocked/branch/pr は Fleet 本体が随時更新する。
public struct PeerInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var status: String?    // working | blocked | idle | done | unknown
    public var task: String?      // fleet_status で自己申告した現在の作業
    public var blocked: String?   // blocked 時の実際の問い
    public var branch: String?
    public var pr: String?

    public init(id: String, name: String, status: String? = nil, task: String? = nil,
                blocked: String? = nil, branch: String? = nil, pr: String? = nil) {
        self.id = id; self.name = name; self.status = status; self.task = task
        self.blocked = blocked; self.branch = branch; self.pr = pr
    }
}

/// 有向メッセージ(fleet_message / fleet_handoff)。outbox.jsonl に追記され、
/// Fleet 本体の常駐 watcher が宛先カードの live セッションへ配信する。
public struct OutboxMessage: Codable, Identifiable, Sendable {
    public let id: String
    public let fromID: String
    public let from: String        // 送信者の表示名
    public let to: String          // 宛先の表示名(LLM が指定)
    public let toID: String?       // 解決済みの宛先カード UUID(あれば)
    public let kind: String        // "message" | "handoff"
    public let text: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, fromID: String, from: String,
                to: String, toID: String? = nil, kind: String = "message",
                text: String, createdAt: Date = Date()) {
        self.id = id; self.fromID = fromID; self.from = from; self.to = to
        self.toID = toID; self.kind = kind; self.text = text; self.createdAt = createdAt
    }
}

/// Agent が盤面を操作する意図(board-intents.jsonl)。Fleet 本体の watcher が
/// BoardStore で適用する(bridge は SwiftData に触れないためファイル IPC)。
public struct BoardIntent: Codable, Identifiable, Sendable {
    public let id: String
    public let kind: String        // "create_card" | "move_card"
    public let fromID: String      // 発行元カード id
    public let title: String?      // create_card: 新カード名
    public let card: String?       // move_card: 対象カード(id or title)
    public let column: String?     // 対象列名
    public let dir: String?        // create_card: 作業ディレクトリ
    public let createdAt: Date

    public init(id: String = UUID().uuidString, kind: String, fromID: String,
                title: String? = nil, card: String? = nil, column: String? = nil,
                dir: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.fromID = fromID; self.title = title
        self.card = card; self.column = column; self.dir = dir; self.createdAt = createdAt
    }
}

/// 盤面スナップショット(board.json)。fleet_board が読む。Agent が盤面を観測できるように。
public struct BoardSnapshot: Codable, Sendable, Equatable {
    public struct Col: Codable, Sendable, Equatable {
        public var name: String
        public init(name: String) { self.name = name }
    }
    public struct CardRef: Codable, Sendable, Equatable {
        public var id: String; public var title: String; public var column: String; public var status: String
        // Fleet 管理 worktree バインディング(旧 board.json には無いフィールド。decode 時は欠落を許容)。
        public var repoRoot: String?
        public var worktreePath: String?
        public var branch: String?
        public var isFleetOwnedWorktree: Bool

        public init(id: String, title: String, column: String, status: String,
                    repoRoot: String? = nil, worktreePath: String? = nil, branch: String? = nil,
                    isFleetOwnedWorktree: Bool = false) {
            self.id = id; self.title = title; self.column = column; self.status = status
            self.repoRoot = repoRoot; self.worktreePath = worktreePath; self.branch = branch
            self.isFleetOwnedWorktree = isFleetOwnedWorktree
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, column, status, repoRoot, worktreePath, branch, isFleetOwnedWorktree
        }

        // 手書き init(from:): isFleetOwnedWorktree のような非 Optional 追加フィールドは
        // 合成 Decodable だとキー欠落で全体デコード失敗になるため、旧 board.json との
        // 後方互換のため decodeIfPresent + デフォルト値で吸収する。
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            column = try c.decode(String.self, forKey: .column)
            status = try c.decode(String.self, forKey: .status)
            repoRoot = try c.decodeIfPresent(String.self, forKey: .repoRoot)
            worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
            branch = try c.decodeIfPresent(String.self, forKey: .branch)
            isFleetOwnedWorktree = try c.decodeIfPresent(Bool.self, forKey: .isFleetOwnedWorktree) ?? false
        }
    }
    public var columns: [Col]
    public var cards: [CardRef]     // このチャンネルに属すカードのみ
    public init(columns: [Col], cards: [CardRef]) { self.columns = columns; self.cards = cards }
}

/// カードとチャンネルの束縛。fleet-bridge は起動時にチャンネルdirを焼き込まず、
/// この binding を毎操作で読んで現在のチャンネルを解決する(所属変更に追従するため)。
public struct CardBinding: Codable, Sendable {
    public var channel: String?   // 所属チャンネルの UUID 文字列(nil = どこにも属さない)
    public var name: String       // 表示名(カードタイトル)

    public init(channel: String? = nil, name: String) {
        self.channel = channel; self.name = name
    }
}

/// `~/.fleet/` 配下のファイル I/O。
/// - channels/<channelID>/memory.jsonl … 共有メモリ(1行1エントリ)
/// - channels/<channelID>/peers.json   … メンバー一覧(fleet_peers 用)
/// - cards/<cardID>/binding.json        … カード→現在のチャンネル束縛(fleet-bridge が参照)
/// Fleet 本体(UI)と fleet-bridge(Agent) が同じ実体を読み書きする。
/// 全書き換え(deleteEntry/merge)と追記(remember)はチャンネル毎の .lock で直列化する。
public enum ChannelStore {
    // MARK: - パス

    public static func fleetRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".fleet", directoryHint: .isDirectory)
    }
    public static func baseDir() -> URL {
        fleetRoot().appending(path: "channels", directoryHint: .isDirectory)
    }
    public static func dir(for id: UUID) -> URL {
        baseDir().appending(path: id.uuidString, directoryHint: .isDirectory)
    }
    public static func memoryFile(for id: UUID) -> URL {
        dir(for: id).appending(path: "memory.jsonl")
    }
    public static func cardsDir() -> URL {
        fleetRoot().appending(path: "cards", directoryHint: .isDirectory)
    }
    public static func cardDir(for cardID: UUID) -> URL {
        cardsDir().appending(path: cardID.uuidString, directoryHint: .isDirectory)
    }
    public static func bindingFile(for cardID: UUID) -> URL {
        cardDir(for: cardID).appending(path: "binding.json")
    }

    private static func ensureDir(_ id: UUID) {
        try? FileManager.default.createDirectory(at: dir(for: id), withIntermediateDirectories: true)
    }
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    // MARK: - クロスプロセスロック

    /// チャンネルディレクトリ単位の排他ロック下で body を実行する。
    /// Fleet 本体の全書き換えと、各カードの fleet-bridge の O_APPEND 追記が
    /// 同じ .lock ファイルを介して直列化されるため、rename over と追記が競合しない。
    @discardableResult
    static func withChannelLock<T>(_ channelDir: URL, _ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
        let lockURL = channelDir.appendingPathComponent(".lock")
        let fd = lockURL.path.withCString { open($0, O_WRONLY | O_CREAT, 0o644) }
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return try body()
    }

    // MARK: - 読み取り

    /// memory.jsonl の生の行(空行を除く)。デコード可否に関わらず全行を返す。
    static func rawLines(for id: UUID) -> [String] {
        guard let text = try? String(contentsOf: memoryFile(for: id), encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    public static func entries(for id: UUID) -> [ChannelEntry] {
        let dec = decoder()
        return rawLines(for: id).compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? dec.decode(ChannelEntry.self, from: d)
        }
    }

    // MARK: - 追記(remember)

    public static func append(_ text: String, author: String, authorID: String? = nil,
                              kind: String? = nil, refs: [String]? = nil, to id: UUID) {
        ensureDir(id)
        let entry = ChannelEntry(author: author, authorID: authorID, text: text, kind: kind, refs: refs)
        guard let data = try? encoder().encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        withChannelLock(dir(for: id)) {
            appendLineAtomically(Data(line.utf8), to: memoryFile(for: id))
        }
    }

    /// O_APPEND で追記する。呼び出し側で withChannelLock を取ること
    /// (大きな書込が複数 write に分割されても、ロック下なら他書込と交錯しない)。
    static func appendLineAtomically(_ data: Data, to url: URL) {
        let fd = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard fd >= 0 else { return }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try? h.write(contentsOf: data)
        try? h.close()
    }

    // MARK: - 全書き換え(delete / merge)

    public static func deleteEntry(_ entryID: String, from id: UUID) {
        let dec = decoder()
        withChannelLock(dir(for: id)) {
            // 生の行を保持したまま、対象エントリの行だけ除去する。
            // デコード不能な行は「消したい対象ではない」ので温存する(MEDIUM-3)。
            let kept = rawLines(for: id).filter { line in
                guard let d = line.data(using: .utf8),
                      let e = try? dec.decode(ChannelEntry.self, from: d) else { return true }
                return e.id != entryID
            }
            writeRawLocked(kept, to: id)
        }
    }

    /// src の全行を dst 末尾へ移す(チャンネル合流時)。ロック下で追記するので
    /// デコード不能行も含めて温存され、dst への並行追記とも競合しない。
    public static func mergeMemory(from src: UUID, into dst: UUID) {
        let srcLines = rawLines(for: src)
        guard !srcLines.isEmpty else { return }
        ensureDir(dst)
        let body = srcLines.joined(separator: "\n") + "\n"
        withChannelLock(dir(for: dst)) {
            appendLineAtomically(Data(body.utf8), to: memoryFile(for: dst))
        }
    }

    /// 生の行を memory.jsonl へ原子的に書き出す。必ず withChannelLock 下で呼ぶこと。
    private static func writeRawLocked(_ lines: [String], to id: UUID) {
        ensureDir(id)
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? body.write(to: memoryFile(for: id), atomically: true, encoding: .utf8)
    }

    // MARK: - peers.json

    /// メンバー情報を peers.json に書き出す(fleet-bridge の fleet_peers 用)。原子書込。
    /// 内容が変わらないときは書かない(常駐 watcher の自己トリガーによる無限ループ防止)。
    /// 実際に書き込んだら true、内容不変でスキップしたら false を返す。
    @discardableResult
    public static func writePeers(_ peers: [PeerInfo], for id: UUID) -> Bool {
        ensureDir(id)
        guard let d = try? JSONEncoder().encode(peers) else { return false }
        let url = dir(for: id).appending(path: "peers.json")
        // 生バイトではなくデコードした内容で比較する。JSONEncoder のキー順が
        // OS/Xcode で微妙に変わっても、意味が同じなら書かない(watcher の自己トリガー防止)。
        if let existing = try? Data(contentsOf: url),
           let old = try? JSONDecoder().decode([PeerInfo].self, from: existing),
           old == peers { return false }
        try? d.write(to: url, options: .atomic)
        return true
    }

    // MARK: - Outbox(有向メッセージ)

    public static func outboxFile(for id: UUID) -> URL {
        dir(for: id).appending(path: "outbox.jsonl")
    }

    public static func appendOutbox(_ msg: OutboxMessage, to id: UUID) {
        ensureDir(id)
        guard let data = try? encoder().encode(msg),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        withChannelLock(dir(for: id)) {
            appendLineAtomically(Data(line.utf8), to: outboxFile(for: id))
        }
    }

    public static func outbox(for id: UUID) -> [OutboxMessage] {
        guard let text = try? String(contentsOf: outboxFile(for: id), encoding: .utf8) else { return [] }
        let dec = decoder()
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? dec.decode(OutboxMessage.self, from: d)
        }
    }

    // MARK: - 配信カーソル(宛先カード毎に配信済みメッセージ id)

    private static func deliveredFile(cardID: UUID, channelID: UUID) -> URL {
        dir(for: channelID).appending(path: "delivered-\(cardID.uuidString).json")
    }
    public static func deliveredIDs(cardID: UUID, channelID: UUID) -> Set<String> {
        guard let d = try? Data(contentsOf: deliveredFile(cardID: cardID, channelID: channelID)),
              let arr = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(arr)
    }
    public static func writeDelivered(_ ids: Set<String>, cardID: UUID, channelID: UUID) {
        ensureDir(channelID)
        if let d = try? JSONEncoder().encode(Array(ids)) {
            try? d.write(to: deliveredFile(cardID: cardID, channelID: channelID), options: .atomic)
        }
    }

    // MARK: - 盤面操作 intent(Agent → Fleet)

    public static func boardIntents(for id: UUID) -> [BoardIntent] {
        let url = dir(for: id).appending(path: "board-intents.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = decoder()
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? dec.decode(BoardIntent.self, from: d)
        }
    }
    public static func appliedIntentIDs(for id: UUID) -> Set<String> {
        let url = dir(for: id).appending(path: "board-applied.json")
        guard let d = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(arr)
    }
    public static func writeAppliedIntentIDs(_ ids: Set<String>, for id: UUID) {
        ensureDir(id)
        if let d = try? JSONEncoder().encode(Array(ids)) {
            try? d.write(to: dir(for: id).appending(path: "board-applied.json"), options: .atomic)
        }
    }
    /// board.json を書く。内容不変なら書かない(watcher の自己トリガー防止)。
    @discardableResult
    public static func writeBoardSnapshot(_ snapshot: BoardSnapshot, for id: UUID) -> Bool {
        ensureDir(id)
        guard let d = try? JSONEncoder().encode(snapshot) else { return false }
        let url = dir(for: id).appending(path: "board.json")
        if let existing = try? Data(contentsOf: url),
           let old = try? JSONDecoder().decode(BoardSnapshot.self, from: existing),
           old == snapshot { return false }
        try? d.write(to: url, options: .atomic)
        return true
    }

    // MARK: - Agent 自己申告ステータス(fleet_status)

    public static func statusFile(cardID: UUID, channelID: UUID) -> URL {
        dir(for: channelID).appending(path: "status-\(cardID.uuidString).json")
    }
    /// status-<cardID>.json の task 文字列(Agent が fleet_status で申告した現在の作業)。
    public static func readStatus(cardID: UUID, channelID: UUID) -> String? {
        guard let d = try? Data(contentsOf: statusFile(cardID: cardID, channelID: channelID)),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj["task"] as? String
    }

    // MARK: - カード束縛(binding.json)

    public static func writeBinding(cardID: UUID, channel: UUID?, name: String) {
        let dir = cardDir(for: cardID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binding = CardBinding(channel: channel?.uuidString, name: name)
        if let d = try? JSONEncoder().encode(binding) {
            try? d.write(to: bindingFile(for: cardID), options: .atomic)
        }
    }

    public static func readBinding(cardID: UUID) -> CardBinding? {
        guard let d = try? Data(contentsOf: bindingFile(for: cardID)) else { return nil }
        return try? JSONDecoder().decode(CardBinding.self, from: d)
    }

    public static func removeBinding(cardID: UUID) {
        try? FileManager.default.removeItem(at: cardDir(for: cardID))
    }

    // MARK: - 後片付け

    public static func removeDir(for id: UUID) {
        try? FileManager.default.removeItem(at: dir(for: id))
    }

    /// src のメモリを dst へ移してから src dir を削除する。src チャンネルのロック下で行い、
    /// 稼働中 bridge の追記(src ロックを取り書込直前に binding を再確認する)と直列化する。
    /// 呼び出し側は先に binding を dst へ更新しておくこと(bridge が再確認で dst を見て書けるように)。
    /// FSL: a2a_channel_race_fixed.fsl で NoLostWrite を証明済み。
    public static func relocateAndRemove(from src: UUID, into dst: UUID) {
        withChannelLock(dir(for: src)) {
            mergeMemory(from: src, into: dst)     // mergeMemory は内側で dst ロックを取る(src→dst 順で一貫)
            try? FileManager.default.removeItem(at: dir(for: src))
        }
    }

    /// チャンネル dir をロック下で削除する(解散時)。呼び出し側は先に binding を無所属へ。
    public static func removeDirLocked(for id: UUID) {
        withChannelLock(dir(for: id)) {
            try? FileManager.default.removeItem(at: dir(for: id))
        }
    }

    /// カードの MCP 設定ファイル(mcp-<cardID>.json)を削除する(離脱時のゴミ掃除, LOW-2)。
    public static func removeMCPConfig(cardID: UUID, channelID: UUID) {
        let url = dir(for: channelID).appendingPathComponent("mcp-\(cardID.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }
}
