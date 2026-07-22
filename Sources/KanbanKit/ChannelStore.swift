import Foundation

/// チャンネル共有メモリの1エントリ。fleet-bridge と同じ JSON 形式。
public struct ChannelEntry: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let author: String
    public let text: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, author: String, text: String, createdAt: Date = Date()) {
        self.id = id; self.author = author; self.text = text; self.createdAt = createdAt
    }
}

/// `~/.fleet/channels/<channelID>/` 配下のファイル I/O。
/// memory.jsonl(共有メモリ, 1行1エントリ) と peers.json(メンバーのカード名) を扱う。
/// Fleet 本体(UI)と fleet-bridge(Agent) が同じ実体を読み書きする。
public enum ChannelStore {
    public static func baseDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".fleet/channels", directoryHint: .isDirectory)
    }
    public static func dir(for id: UUID) -> URL {
        baseDir().appending(path: id.uuidString, directoryHint: .isDirectory)
    }
    public static func memoryFile(for id: UUID) -> URL {
        dir(for: id).appending(path: "memory.jsonl")
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

    public static func entries(for id: UUID) -> [ChannelEntry] {
        guard let text = try? String(contentsOf: memoryFile(for: id), encoding: .utf8) else { return [] }
        let dec = decoder()
        return text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? dec.decode(ChannelEntry.self, from: d)
        }
    }

    public static func append(_ text: String, author: String, to id: UUID) {
        ensureDir(id)
        let entry = ChannelEntry(author: author, text: text)
        guard let data = try? encoder().encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        appendLineAtomically(Data(line.utf8), to: memoryFile(for: id))
    }

    /// O_APPEND で追記する。seekToEnd+write と違い、複数プロセス(Fleet 本体と各カードの
    /// fleet-bridge)が同時に書いてもオフセットがアトミックに進み、行が壊れない。
    static func appendLineAtomically(_ data: Data, to url: URL) {
        let fd = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard fd >= 0 else { return }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try? h.write(contentsOf: data)
        try? h.close()
    }

    public static func deleteEntry(_ entryID: String, from id: UUID) {
        let remaining = entries(for: id).filter { $0.id != entryID }
        writeAll(remaining, to: id)
    }

    private static func writeAll(_ entries: [ChannelEntry], to id: UUID) {
        ensureDir(id)
        let enc = encoder()
        let lines = entries.compactMap { try? enc.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? body.write(to: memoryFile(for: id), atomically: true, encoding: .utf8)
    }

    /// メンバーのカード名を peers.json に書き出す(fleet-bridge の fleet_peers 用)。
    public static func writePeers(_ names: [String], for id: UUID) {
        ensureDir(id)
        if let d = try? JSONEncoder().encode(names) {
            try? d.write(to: dir(for: id).appending(path: "peers.json"))
        }
    }

    /// src の全エントリを dst 末尾へ移す(チャンネル合流時)。
    public static func mergeMemory(from src: UUID, into dst: UUID) {
        let merged = entries(for: dst) + entries(for: src)
        writeAll(merged, to: dst)
    }

    public static func removeDir(for id: UUID) {
        try? FileManager.default.removeItem(at: dir(for: id))
    }
}
