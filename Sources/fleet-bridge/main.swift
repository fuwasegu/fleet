import Foundation

// fleet-bridge: Fleet の A2A 共有メモリを Claude Code に提供する stdio MCP サーバ。
// JSON-RPC 2.0(改行区切り)。起動: fleet-bridge --card <cardUUID> [--root <dir>]
//
// チャンネルは起動時に固定しない。毎操作で ~/.fleet/cards/<cardID>/binding.json を読み、
// 現在の所属チャンネル(channels/<uuid>/)を解決する。これにより盤面での接続/解除/合流/改名が
// 稼働中の Agent にも即反映される(dir を焼き込む旧方式のデータ分断バグを回避)。

func argValue(_ name: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return ""
}
let cardID = argValue("--card")
let rootOverride = argValue("--root")
// 後方互換: 旧 --channel <dir> 指定も一応受ける(その場合は固定チャンネルとして扱う)
let fixedChannelDir = argValue("--channel")

let fleetRoot: URL = rootOverride.isEmpty
    ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fleet")
    : URL(fileURLWithPath: rootOverride)

// MARK: - パス解決(毎操作で最新の binding を読む)

struct Binding: Decodable { let channel: String?; let name: String? }

func readBinding() -> Binding? {
    guard !cardID.isEmpty else { return nil }
    let url = fleetRoot.appendingPathComponent("cards/\(cardID)/binding.json")
    guard let d = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Binding.self, from: d)
}

/// 現在の所属チャンネルのディレクトリ。所属なしなら nil。
func currentChannelDir() -> URL? {
    if !fixedChannelDir.isEmpty { return URL(fileURLWithPath: fixedChannelDir) }
    guard let ch = readBinding()?.channel, !ch.isEmpty else { return nil }
    return fleetRoot.appendingPathComponent("channels/\(ch)", isDirectory: true)
}

/// 書き込み時の author 表示名(改名に追従)。
func authorName() -> String {
    readBinding()?.name ?? ProcessInfo.processInfo.environment["FLEET_CARD"] ?? "agent"
}

let maxRememberBytes = 16 * 1024   // fleet_remember の上限(交錯・肥大防止)

// MARK: - I/O

func emit(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
func sendResult(_ id: Any, _ res: [String: Any]) { emit(["jsonrpc": "2.0", "id": id, "result": res]) }
func sendError(_ id: Any, _ code: Int, _ msg: String) {
    emit(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": msg]])
}
func textContent(_ text: String, isError: Bool = false) -> [String: Any] {
    var r: [String: Any] = ["content": [["type": "text", "text": text]]]
    if isError { r["isError"] = true }
    return r
}

/// チャンネル dir 単位の排他ロック下で body を実行(Fleet 本体の全書換と直列化)。
func withChannelLock<T>(_ channelDir: URL, _ body: () -> T) -> T {
    try? FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
    let lockURL = channelDir.appendingPathComponent(".lock")
    let fd = lockURL.path.withCString { open($0, O_WRONLY | O_CREAT, 0o644) }
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return body()
}

// MARK: - Memory store (memory.jsonl と同形式)

func readEntries(_ channelDir: URL) -> [[String: Any]] {
    let memoryURL = channelDir.appendingPathComponent("memory.jsonl")
    guard let text = try? String(contentsOf: memoryURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o
    }
}

func appendEntry(_ channelDir: URL, _ text: String) {
    let memoryURL = channelDir.appendingPathComponent("memory.jsonl")
    let iso = ISO8601DateFormatter().string(from: Date())
    let entry: [String: Any] = [
        "id": UUID().uuidString,
        "author": authorName(),
        "authorID": cardID,
        "text": text,
        "createdAt": iso
    ]
    guard let d = try? JSONSerialization.data(withJSONObject: entry),
          let s = String(data: d, encoding: .utf8) else { return }
    let line = Data((s + "\n").utf8)
    withChannelLock(channelDir) {
        // ロック下 + O_APPEND: 大きな書込が複数 write に分割されても他書込と交錯しない
        let fd = memoryURL.path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard fd >= 0 else { return }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try? h.write(contentsOf: line)
        try? h.close()
    }
}

/// peers.json は {id,name,status,task,blocked,branch,pr} の配列。
func readPeers(_ channelDir: URL) -> [[String: Any]] {
    let peersURL = channelDir.appendingPathComponent("peers.json")
    guard let d = try? Data(contentsOf: peersURL),
          let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
    return arr
}

// MARK: - Tools

let toolDefs: [[String: Any]] = [
    [
        "name": "fleet_recall",
        "description": "Read the shared context/memory for this channel — notes other agents (and you) have recorded. Call this before starting work, and again whenever you resume, to avoid duplicating effort or conflicting decisions.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Optional substring filter."],
                "limit": ["type": "integer", "description": "Max entries to return (default 20)."]
            ]
        ]
    ],
    [
        "name": "fleet_remember",
        "description": "Record a note into the shared channel memory so other agents can see it. Use for decisions, findings, conventions, and hand-off info.",
        "inputSchema": [
            "type": "object",
            "properties": ["text": ["type": "string", "description": "The note to share (max 16 KB)."]],
            "required": ["text"]
        ]
    ],
    [
        "name": "fleet_peers",
        "description": "List the other agents (cards) sharing this channel, with their live status (working / blocked / idle / done), current branch and PR, and — when blocked — the question they are stuck on. Use it to decide whether to wait for, or hand off to, a peer.",
        "inputSchema": ["type": "object", "properties": [:]]
    ]
]

func handleToolCall(_ id: Any, _ params: [String: Any]?) {
    let name = params?["name"] as? String ?? ""
    let arguments = params?["arguments"] as? [String: Any] ?? [:]

    guard let channelDir = currentChannelDir() else {
        sendResult(id, textContent("You are not currently in a shared channel. Connect this card to another on the Fleet board to share context.", isError: true))
        return
    }

    switch name {
    case "fleet_recall":
        var entries = readEntries(channelDir)
        if let q = (arguments["query"] as? String)?.lowercased(), !q.isEmpty {
            entries = entries.filter { (($0["text"] as? String) ?? "").lowercased().contains(q) }
        }
        let limit = (arguments["limit"] as? Int) ?? 20
        let recent = Array(entries.suffix(limit)).reversed()   // 新しい順
        if recent.isEmpty {
            sendResult(id, textContent("(shared memory is empty)"))
            return
        }
        let lines = recent.map { e -> String in
            let a = (e["author"] as? String) ?? "?"
            let t = (e["text"] as? String) ?? ""
            let ts = (e["createdAt"] as? String) ?? ""
            return "- [\(a) · \(ts)] \(t)"
        }
        sendResult(id, textContent("Shared memory for this channel:\n" + lines.joined(separator: "\n")))

    case "fleet_remember":
        guard let text = arguments["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendResult(id, textContent("text is required", isError: true))
            return
        }
        guard text.utf8.count <= maxRememberBytes else {
            sendResult(id, textContent("Note too large (\(text.utf8.count) bytes; max \(maxRememberBytes)). Summarize or split it.", isError: true))
            return
        }
        appendEntry(channelDir, text)
        sendResult(id, textContent("Saved to shared memory."))

    case "fleet_peers":
        let peers = readPeers(channelDir).filter { ($0["id"] as? String) != cardID }
        if peers.isEmpty {
            sendResult(id, textContent("No other agents in this channel yet."))
            return
        }
        let lines = peers.map { p -> String in
            let n = (p["name"] as? String) ?? "?"
            let status = (p["status"] as? String) ?? "unknown"
            var extra: [String] = []
            if let task = p["task"] as? String, !task.isEmpty { extra.append("task: \(task)") }
            if status == "blocked", let b = p["blocked"] as? String, !b.isEmpty { extra.append("blocked on: \(b)") }
            if let br = p["branch"] as? String, !br.isEmpty { extra.append("branch: \(br)") }
            if let pr = p["pr"] as? String, !pr.isEmpty { extra.append("PR: \(pr)") }
            let suffix = extra.isEmpty ? "" : " (" + extra.joined(separator: "; ") + ")"
            return "- \(n) [\(status)]\(suffix)"
        }
        sendResult(id, textContent("Agents sharing this channel:\n" + lines.joined(separator: "\n")))

    default:
        sendResult(id, textContent("Unknown tool: \(name)", isError: true))
    }
}

// MARK: - JSON-RPC loop

let supportedProtocols: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let d = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        // 不正 JSON はパースエラーを返す(id 不明なので null)。クライアントの待ちハングを避ける。
        sendError(NSNull(), -32700, "Parse error")
        continue
    }
    let method = msg["method"] as? String
    let id = msg["id"]
    switch method {
    case "initialize":
        guard let id else { break }
        let clientProto = (msg["params"] as? [String: Any])?["protocolVersion"] as? String
        // クライアント要求が実装済みなら合わせ、未知なら安全側の 2024-11-05 に下げる。
        let proto = (clientProto.map { supportedProtocols.contains($0) } ?? false) ? clientProto! : "2024-11-05"
        sendResult(id, [
            "protocolVersion": proto,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "fleet-bridge", "version": "1.1.0"]
        ])
    case "notifications/initialized", "notifications/cancelled":
        break   // 通知には応答しない
    case "ping":
        if let id { sendResult(id, [:]) }
    case "tools/list":
        if let id { sendResult(id, ["tools": toolDefs]) }
    case "tools/call":
        if let id { handleToolCall(id, msg["params"] as? [String: Any]) }
    default:
        if let id { sendError(id, -32601, "Method not found: \(method ?? "")") }
    }
}
