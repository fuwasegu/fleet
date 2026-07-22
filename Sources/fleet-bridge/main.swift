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

func appendEntry(_ channelDir: URL, _ text: String, kind: String?, refs: [String]?) {
    let memoryURL = channelDir.appendingPathComponent("memory.jsonl")
    let iso = ISO8601DateFormatter().string(from: Date())
    var entry: [String: Any] = [
        "id": UUID().uuidString,
        "author": authorName(),
        "authorID": cardID,
        "text": text,
        "createdAt": iso
    ]
    if let kind, !kind.isEmpty { entry["kind"] = kind }
    if let refs, !refs.isEmpty { entry["refs"] = refs }
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

/// recall の未読カーソル(このカードが最後に見たエントリ id)。
func readRecallCursor(_ channelDir: URL) -> String? {
    let url = channelDir.appendingPathComponent("recall-cursor-\(cardID).json")
    guard let d = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return obj["lastSeen"] as? String
}
func writeRecallCursor(_ channelDir: URL, lastSeen: String) {
    let url = channelDir.appendingPathComponent("recall-cursor-\(cardID).json")
    if let d = try? JSONSerialization.data(withJSONObject: ["lastSeen": lastSeen]) {
        try? d.write(to: url, options: .atomic)
    }
}

/// peers.json は {id,name,status,task,blocked,branch,pr} の配列。
func readPeers(_ channelDir: URL) -> [[String: Any]] {
    let peersURL = channelDir.appendingPathComponent("peers.json")
    guard let d = try? Data(contentsOf: peersURL),
          let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
    return arr
}

/// 宛先の表示名から自分以外のカード id を解決する(見つからなければ nil)。
func resolvePeerID(_ name: String, in channelDir: URL) -> String? {
    let target = name.lowercased()
    for p in readPeers(channelDir) where (p["id"] as? String) != cardID {
        if ((p["name"] as? String) ?? "").lowercased() == target { return p["id"] as? String }
    }
    return nil
}

/// 有向メッセージを outbox.jsonl へ追記する(Fleet 本体の watcher が配信)。
func appendOutbox(_ channelDir: URL, to: String, kind: String, text: String) {
    let outboxURL = channelDir.appendingPathComponent("outbox.jsonl")
    let iso = ISO8601DateFormatter().string(from: Date())
    var entry: [String: Any] = [
        "id": UUID().uuidString, "fromID": cardID, "from": authorName(),
        "to": to, "kind": kind, "text": text, "createdAt": iso
    ]
    if let toID = resolvePeerID(to, in: channelDir) { entry["toID"] = toID }
    guard let d = try? JSONSerialization.data(withJSONObject: entry),
          let s = String(data: d, encoding: .utf8) else { return }
    let line = Data((s + "\n").utf8)
    withChannelLock(channelDir) {
        let fd = outboxURL.path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard fd >= 0 else { return }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try? h.write(contentsOf: line)
        try? h.close()
    }
}

/// 現在の作業を status-<cardID>.json に書き、fleet_peers に反映させる。
func writeStatus(_ channelDir: URL, task: String) {
    let url = channelDir.appendingPathComponent("status-\(cardID).json")
    let obj: [String: Any] = ["task": task, "ts": ISO8601DateFormatter().string(from: Date())]
    if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: url, options: .atomic) }
}

// MARK: - 盤面操作 intent(board-intents.jsonl)+ スナップショット(board.json)

func appendBoardIntent(_ channelDir: URL, _ entry: [String: Any]) {
    let url = channelDir.appendingPathComponent("board-intents.jsonl")
    var e = entry
    e["id"] = UUID().uuidString
    e["fromID"] = cardID
    e["createdAt"] = ISO8601DateFormatter().string(from: Date())
    guard let d = try? JSONSerialization.data(withJSONObject: e),
          let s = String(data: d, encoding: .utf8) else { return }
    let line = Data((s + "\n").utf8)
    withChannelLock(channelDir) {
        let fd = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard fd >= 0 else { return }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try? h.write(contentsOf: line)
        try? h.close()
    }
}

func readBoardSnapshot(_ channelDir: URL) -> [String: Any]? {
    let url = channelDir.appendingPathComponent("board.json")
    guard let d = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return obj
}

// MARK: - Advisory ロック(locks.json: resource -> {holderID,holderName,ts})

func readLocks(_ channelDir: URL) -> [String: [String: Any]] {
    let url = channelDir.appendingPathComponent("locks.json")
    guard let d = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] else { return [:] }
    return obj
}
func writeLocks(_ channelDir: URL, _ locks: [String: [String: Any]]) {
    let url = channelDir.appendingPathComponent("locks.json")
    if let d = try? JSONSerialization.data(withJSONObject: locks) { try? d.write(to: url, options: .atomic) }
}

// MARK: - Tools

let toolDefs: [[String: Any]] = [
    [
        "name": "fleet_recall",
        "description": "Read the shared context/memory for this channel — notes other agents (and you) have recorded. Call this before starting work, and again whenever you resume. Use unread:true to get only what changed since your last recall, and kind to focus (e.g. kind:\"blocker\" for open blockers, kind:\"decision\" for decisions).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Optional substring filter."],
                "kind": ["type": "string", "description": "Optional: only entries of this kind (decision|blocker|artifact|question|note)."],
                "unread": ["type": "boolean", "description": "If true, return only entries recorded since your last recall."],
                "limit": ["type": "integer", "description": "Max entries to return (default 20)."]
            ]
        ]
    ],
    [
        "name": "fleet_remember",
        "description": "Record a note into the shared channel memory so other agents can see it. Tag it with kind so peers can filter: decision (a choice made), blocker (something stuck), artifact (a file/PR/output produced), question (needs an answer), note (default). Attach refs (file paths, PR URLs, card ids) it relates to.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "The note to share (max 16 KB)."],
                "kind": ["type": "string", "description": "decision | blocker | artifact | question | note (default note)."],
                "refs": ["type": "array", "items": ["type": "string"], "description": "Related file paths / PR URLs / card ids."]
            ],
            "required": ["text"]
        ]
    ],
    [
        "name": "fleet_peers",
        "description": "List the other agents (cards) sharing this channel, with their live status (working / blocked / idle / done), current branch and PR, and — when blocked — the question they are stuck on. Use it to decide whether to wait for, or hand off to, a peer.",
        "inputSchema": ["type": "object", "properties": [:]]
    ],
    [
        "name": "fleet_message",
        "description": "Send a direct message to a specific peer agent. Unlike fleet_remember (a passive shared note), this is PUSHED into the recipient's session so they see it even mid-task — use it for events that affect them: 'I changed the schema, re-pull', 'the API is ready, you can start the client', a question you need answered.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "to": ["type": "string", "description": "The peer's name (as shown by fleet_peers)."],
                "text": ["type": "string", "description": "The message (max 16 KB)."]
            ],
            "required": ["to", "text"]
        ]
    ],
    [
        "name": "fleet_handoff",
        "description": "Hand off work to a peer agent: pushes a framed handoff message to them. Use when you have finished a part and another agent should take over. Include what you did and what remains.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "to": ["type": "string", "description": "The peer's name to hand off to."],
                "text": ["type": "string", "description": "What you did and what they should do next (max 16 KB)."]
            ],
            "required": ["to", "text"]
        ]
    ],
    [
        "name": "fleet_status",
        "description": "Publish a one-line description of what you are currently working on. Peers see it via fleet_peers. Update it when you switch tasks so others can coordinate.",
        "inputSchema": [
            "type": "object",
            "properties": ["text": ["type": "string", "description": "Short current-activity line."]],
            "required": ["text"]
        ]
    ],
    [
        "name": "fleet_claim",
        "description": "Take an advisory lock on a resource (usually a file path) before editing it, so peer agents sharing this repo don't clobber each other. Fails if another agent already holds it — check fleet_locks / the error and coordinate. Release it with fleet_release when done. Advisory only: it coordinates, it does not enforce at the filesystem.",
        "inputSchema": [
            "type": "object",
            "properties": ["resource": ["type": "string", "description": "What you're claiming, e.g. a file path."]],
            "required": ["resource"]
        ]
    ],
    [
        "name": "fleet_release",
        "description": "Release an advisory lock you took with fleet_claim.",
        "inputSchema": [
            "type": "object",
            "properties": ["resource": ["type": "string", "description": "The resource to release."]],
            "required": ["resource"]
        ]
    ],
    [
        "name": "fleet_locks",
        "description": "List the advisory locks currently held in this channel and who holds each. Check before claiming or before editing a shared file.",
        "inputSchema": ["type": "object", "properties": [:]]
    ],
    [
        "name": "fleet_board",
        "description": "See the Fleet kanban board: the columns and the cards in your channel with their live status. Use it to understand the work layout before creating or moving cards.",
        "inputSchema": ["type": "object", "properties": [:]]
    ],
    [
        "name": "fleet_create_card",
        "description": "Create a new card (a subtask) on the Fleet board. The new card automatically joins your channel, so it shares this context and a peer (or you) can pick it up. Use it to decompose work and delegate. Optionally place it in a named column and give it a working directory.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "The card/subtask title."],
                "column": ["type": "string", "description": "Optional column name (defaults to the first column)."],
                "dir": ["type": "string", "description": "Optional working directory for the card's terminal."]
            ],
            "required": ["title"]
        ]
    ],
    [
        "name": "fleet_move_card",
        "description": "Move a card in your channel to another column (e.g. to 'Done' or 'Review'). Identify the card by its title or id (see fleet_board).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "card": ["type": "string", "description": "Target card's title or id."],
                "column": ["type": "string", "description": "Destination column name."]
            ],
            "required": ["card", "column"]
        ]
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
        // 未読のみ: 最後に見たエントリより後だけを返し、カーソルを最新へ進める。
        let unreadOnly = (arguments["unread"] as? Bool) ?? false
        if unreadOnly, let cursor = readRecallCursor(channelDir),
           let idx = entries.firstIndex(where: { ($0["id"] as? String) == cursor }) {
            entries = Array(entries.suffix(from: idx + 1))
        }
        if let q = (arguments["query"] as? String)?.lowercased(), !q.isEmpty {
            entries = entries.filter { (($0["text"] as? String) ?? "").lowercased().contains(q) }
        }
        if let kindFilter = (arguments["kind"] as? String)?.lowercased(), !kindFilter.isEmpty {
            entries = entries.filter { (($0["kind"] as? String)?.lowercased() ?? "note") == kindFilter }
        }
        // カーソルは(フィルタ前の)ファイル全体の最新へ進める = 「前回見て以降」の意味
        if let newest = readEntries(channelDir).last?["id"] as? String { writeRecallCursor(channelDir, lastSeen: newest) }
        let limit = (arguments["limit"] as? Int) ?? 20
        let recent = Array(entries.suffix(limit)).reversed()   // 新しい順
        if recent.isEmpty {
            sendResult(id, textContent(unreadOnly ? "(no new shared memory since last recall)" : "(shared memory is empty)"))
            return
        }
        let lines = recent.map { e -> String in
            let a = (e["author"] as? String) ?? "?"
            let t = (e["text"] as? String) ?? ""
            let ts = (e["createdAt"] as? String) ?? ""
            let k = (e["kind"] as? String).map { " (\($0))" } ?? ""
            let r = (e["refs"] as? [String]).flatMap { $0.isEmpty ? nil : " {refs: \($0.joined(separator: ", "))}" } ?? ""
            return "- [\(a) · \(ts)]\(k) \(t)\(r)"
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
        let kind = (arguments["kind"] as? String)?.lowercased()
        let refs = arguments["refs"] as? [String]
        appendEntry(channelDir, text, kind: kind, refs: refs)
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

    case "fleet_message", "fleet_handoff":
        guard let to = (arguments["to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else {
            sendResult(id, textContent("to (peer name) is required", isError: true)); return
        }
        guard let text = arguments["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendResult(id, textContent("text is required", isError: true)); return
        }
        guard text.utf8.count <= maxRememberBytes else {
            sendResult(id, textContent("Message too large (\(text.utf8.count) bytes; max \(maxRememberBytes)).", isError: true)); return
        }
        let kind = name == "fleet_handoff" ? "handoff" : "message"
        appendOutbox(channelDir, to: to, kind: kind, text: text)
        let known = resolvePeerID(to, in: channelDir) != nil
        let note = known ? "" : " (note: no peer named \"\(to)\" is currently in this channel; it will be delivered if they join)"
        sendResult(id, textContent("Sent to \(to). It will be pushed into their session when they are ready.\(note)"))

    case "fleet_status":
        guard let text = arguments["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendResult(id, textContent("text is required", isError: true)); return
        }
        writeStatus(channelDir, task: String(text.prefix(200)))
        sendResult(id, textContent("Status updated."))

    case "fleet_claim":
        guard let resource = (arguments["resource"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !resource.isEmpty else {
            sendResult(id, textContent("resource is required", isError: true)); return
        }
        var conflict: String?
        withChannelLock(channelDir) {
            var locks = readLocks(channelDir)
            if let held = locks[resource], (held["holderID"] as? String) != cardID {
                conflict = (held["holderName"] as? String) ?? "another agent"
                return
            }
            locks[resource] = ["holderID": cardID, "holderName": authorName(), "ts": ISO8601DateFormatter().string(from: Date())]
            writeLocks(channelDir, locks)
        }
        if let who = conflict {
            sendResult(id, textContent("Cannot claim \"\(resource)\": already held by \(who). Coordinate (fleet_message) or wait.", isError: true))
        } else {
            sendResult(id, textContent("Claimed \"\(resource)\". Release it with fleet_release when done."))
        }

    case "fleet_release":
        guard let resource = (arguments["resource"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !resource.isEmpty else {
            sendResult(id, textContent("resource is required", isError: true)); return
        }
        withChannelLock(channelDir) {
            var locks = readLocks(channelDir)
            if (locks[resource]?["holderID"] as? String) == cardID {
                locks.removeValue(forKey: resource)
                writeLocks(channelDir, locks)
            }
        }
        sendResult(id, textContent("Released \"\(resource)\"."))

    case "fleet_locks":
        let locks = readLocks(channelDir)
        if locks.isEmpty { sendResult(id, textContent("No advisory locks are held in this channel.")); return }
        let lines = locks.map { (res, info) -> String in
            let who = (info["holderName"] as? String) ?? "?"
            let mine = (info["holderID"] as? String) == cardID ? " (you)" : ""
            return "- \(res) → \(who)\(mine)"
        }.sorted()
        sendResult(id, textContent("Advisory locks in this channel:\n" + lines.joined(separator: "\n")))

    case "fleet_board":
        guard let snap = readBoardSnapshot(channelDir) else {
            sendResult(id, textContent("(board snapshot not available yet)")); return
        }
        let colNames = (snap["columns"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let cards = (snap["cards"] as? [[String: Any]]) ?? []
        var out = "Board columns: " + (colNames.isEmpty ? "(none)" : colNames.joined(separator: " | "))
        if cards.isEmpty {
            out += "\nNo cards in this channel yet."
        } else {
            out += "\nCards in this channel:\n" + cards.map { c -> String in
                let t = (c["title"] as? String) ?? "?"
                let col = (c["column"] as? String) ?? "?"
                let st = (c["status"] as? String) ?? "?"
                return "- \(t) [\(col)] (\(st))"
            }.joined(separator: "\n")
        }
        sendResult(id, textContent(out))

    case "fleet_create_card":
        guard let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            sendResult(id, textContent("title is required", isError: true)); return
        }
        var intent: [String: Any] = ["kind": "create_card", "title": title]
        if let col = arguments["column"] as? String, !col.isEmpty { intent["column"] = col }
        if let dir = arguments["dir"] as? String, !dir.isEmpty { intent["dir"] = dir }
        appendBoardIntent(channelDir, intent)
        sendResult(id, textContent("Requested new card \"\(title)\". It will appear on the board and join this channel shortly (check fleet_board)."))

    case "fleet_move_card":
        guard let card = (arguments["card"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !card.isEmpty,
              let column = (arguments["column"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !column.isEmpty else {
            sendResult(id, textContent("card and column are required", isError: true)); return
        }
        appendBoardIntent(channelDir, ["kind": "move_card", "card": card, "column": column])
        sendResult(id, textContent("Requested move of \"\(card)\" to \"\(column)\" (check fleet_board)."))

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
