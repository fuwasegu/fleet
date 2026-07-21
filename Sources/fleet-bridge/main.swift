import Foundation

// fleet-bridge: Fleet の A2A 共有メモリを Claude Code に提供する stdio MCP サーバ。
// JSON-RPC 2.0(改行区切り)。起動: fleet-bridge --channel <dir>  env: FLEET_CARD=<カード名>
// チャンネルの memory.jsonl / peers.json を読み書きする(Fleet 本体と同じ実体)。

let args = CommandLine.arguments
var channelDir = ""
if let i = args.firstIndex(of: "--channel"), i + 1 < args.count { channelDir = args[i + 1] }
let cardAuthor = ProcessInfo.processInfo.environment["FLEET_CARD"] ?? "agent"

let dirURL = URL(fileURLWithPath: channelDir)
let memoryURL = dirURL.appendingPathComponent("memory.jsonl")
let peersURL = dirURL.appendingPathComponent("peers.json")

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

// MARK: - Memory store (memory.jsonl と同形式)

func readEntries() -> [[String: Any]] {
    guard let text = try? String(contentsOf: memoryURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o
    }
}
func appendEntry(_ text: String) {
    let iso = ISO8601DateFormatter().string(from: Date())
    let entry: [String: Any] = ["id": UUID().uuidString, "author": cardAuthor, "text": text, "createdAt": iso]
    guard let d = try? JSONSerialization.data(withJSONObject: entry),
          let s = String(data: d, encoding: .utf8) else { return }
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    let line = Data((s + "\n").utf8)
    if let h = try? FileHandle(forWritingTo: memoryURL) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line)
    } else {
        try? line.write(to: memoryURL)
    }
}
func readPeers() -> [String] {
    guard let d = try? Data(contentsOf: peersURL),
          let arr = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
    return arr
}

// MARK: - Tools

let toolDefs: [[String: Any]] = [
    [
        "name": "fleet_recall",
        "description": "Read the shared context/memory for this channel — notes other agents (and you) have recorded. Call this before starting work to avoid duplicating effort or conflicting decisions.",
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
            "properties": ["text": ["type": "string", "description": "The note to share."]],
            "required": ["text"]
        ]
    ],
    [
        "name": "fleet_peers",
        "description": "List the other agents (cards) that share this context channel with you.",
        "inputSchema": ["type": "object", "properties": [:]]
    ]
]

func handleToolCall(_ id: Any, _ params: [String: Any]?) {
    let name = params?["name"] as? String ?? ""
    let arguments = params?["arguments"] as? [String: Any] ?? [:]
    switch name {
    case "fleet_recall":
        var entries = readEntries()
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
        guard let text = arguments["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendResult(id, textContent("text is required", isError: true))
            return
        }
        appendEntry(text)
        sendResult(id, textContent("Saved to shared memory."))
    case "fleet_peers":
        let peers = readPeers().filter { $0 != cardAuthor }
        let text = peers.isEmpty ? "No other agents in this channel yet."
                                 : "Agents sharing this channel: " + peers.joined(separator: ", ")
        sendResult(id, textContent(text))
    default:
        sendResult(id, textContent("Unknown tool: \(name)", isError: true))
    }
}

// MARK: - JSON-RPC loop

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let d = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
    let method = msg["method"] as? String
    let id = msg["id"]
    switch method {
    case "initialize":
        guard let id else { break }
        let clientProto = (msg["params"] as? [String: Any])?["protocolVersion"] as? String
        sendResult(id, [
            "protocolVersion": clientProto ?? "2024-11-05",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "fleet-bridge", "version": "1.0.0"]
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
