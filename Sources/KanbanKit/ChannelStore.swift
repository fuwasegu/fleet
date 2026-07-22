import Foundation

/// チャンネル共有メモリの1エントリ。fleet-bridge と同じ JSON 形式。
/// author は表示名、authorID は安定な識別子(カード UUID)。改名しても authorID は不変。
public struct ChannelEntry: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let author: String
    public let authorID: String?   // 後方互換: 旧エントリには無い
    public let text: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, author: String, authorID: String? = nil, text: String, createdAt: Date = Date()) {
        self.id = id; self.author = author; self.authorID = authorID; self.text = text; self.createdAt = createdAt
    }
}

/// peers.json の1メンバー。fleet_peers が返す live-aware な情報。
/// 識別子は id(カード UUID)。status/task/blocked/branch/pr は Fleet 本体が随時更新する。
public struct PeerInfo: Codable, Sendable {
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

    public static func append(_ text: String, author: String, authorID: String? = nil, to id: UUID) {
        ensureDir(id)
        let entry = ChannelEntry(author: author, authorID: authorID, text: text)
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
    public static func writePeers(_ peers: [PeerInfo], for id: UUID) {
        ensureDir(id)
        guard let d = try? JSONEncoder().encode(peers) else { return }
        let url = dir(for: id).appending(path: "peers.json")
        if let existing = try? Data(contentsOf: url), existing == d { return }
        try? d.write(to: url, options: .atomic)
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

    /// カードの MCP 設定ファイル(mcp-<cardID>.json)を削除する(離脱時のゴミ掃除, LOW-2)。
    public static func removeMCPConfig(cardID: UUID, channelID: UUID) {
        let url = dir(for: channelID).appendingPathComponent("mcp-\(cardID.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }
}
