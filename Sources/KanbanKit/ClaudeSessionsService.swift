import Foundation

/// Claude Code の過去セッション1件。
public struct ClaudeSession: Identifiable, Hashable, Sendable {
    public let id: String        // session_id (= jsonl のファイル名)
    public let title: String
    public let modified: Date
    public let path: String      // jsonl のフルパス(プレビュー遅延読み込み用)

    public init(id: String, title: String, modified: Date, path: String) {
        self.id = id; self.title = title; self.modified = modified; self.path = path
    }
}

/// プレビュー用の1メッセージ。
public struct PreviewMessage: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let role: String      // "user" / "assistant"
    public let text: String

    public init(id: UUID = UUID(), role: String, text: String) {
        self.id = id; self.role = role; self.text = text
    }
}

/// `claude --resume <uuid>` と `--session-id <uuid>` のどちらで起動すべきかを表す。
public enum ClaudeLaunchMode: Equatable, Sendable {
    case resume(String)
    case createNew(String)
}

/// `~/.claude/projects/<cwd由来>/<session-id>.jsonl` から、指定 cwd のセッション一覧を取り出す。
/// (ディレクトリ名は cwd の "/" と "." を "-" に置換したもの。トークン集計と同じ領域)
public enum ClaudeSessionsService {
    public static func projectDirName(for cwd: String) -> String {
        let expanded = (cwd as NSString).expandingTildeInPath
        return expanded
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// `CLAUDE_HOME` 環境変数が設定されていればそれを使う(主にテストの隔離用: 実マシンの
    /// `~/.claude` を汚さずに済む)。未設定なら従来どおり `~/.claude`。
    /// `ChannelStore.fleetRoot()` の `FLEET_ROOT` と同じ流儀(`ProcessInfo.environment` を
    /// キャッシュせず毎回引く: テストプロセスが起動直後に一度だけ設定する前提のため)。
    public static func claudeHome() -> String {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_HOME"], !override.isEmpty {
            return override
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }

    /// `~/.claude/projects` あるいは(プロファイル指定時)`<configDir>/projects` を返す。
    /// カードに `ClaudeProfile` が割り当てられている場合、そのセッション履歴は
    /// デフォルトの `~/.claude` ではなく `configDir` の下に生成される(`CLAUDE_CONFIG_DIR` 起動時)。
    /// 解決を誤ると「実在するのに見つからない」→ `--session-id` を新規発行して
    /// "already in use" になる不具合を再現するため、起動時の env と必ず同じ基準で解決する。
    /// `configDir` が明示されていれば `CLAUDE_HOME` より優先する(呼び出し側の指定が最優先)。
    private static func projectsBase(configDir: String?) -> String {
        if let configDir, !configDir.isEmpty {
            return (configDir as NSString).expandingTildeInPath + "/projects"
        }
        return (claudeHome() as NSString).appendingPathComponent("projects")
    }

    /// `~/.claude/projects/`(または `configDir` 配下)の「どの project ディレクトリでもいいから」
    /// このセッション id の jsonl があるか。`claude --resume <uuid>` は cwd に関係なく id だけで
    /// 解決できるため、worktree カード(cwd がその都度変わる)の自動復帰判定はこちらを使う。
    /// (元 repo の cwd で作られたセッションを、worktree の cwd から見て「無い」と誤判定しないため。)
    public static func sessionExistsAnywhere(id: String, configDir: String? = nil) -> Bool {
        let base = projectsBase(configDir: configDir)
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: base) else { return false }
        for projectDir in projectDirs {
            let dir = (base as NSString).appendingPathComponent(projectDir)
            let path = (dir as NSString).appendingPathComponent("\(id).jsonl")
            if fm.fileExists(atPath: path) { return true }
        }
        return false
    }

    public static func list(forCwd cwd: String, configDir: String? = nil, limit: Int = 40) -> [ClaudeSession] {
        let base = projectsBase(configDir: configDir)
        let dir = (base as NSString).appendingPathComponent(projectDirName(for: cwd))
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        var out: [ClaudeSession] = []
        for file in files where file.hasSuffix(".jsonl") {
            let path = (dir as NSString).appendingPathComponent(file)
            let sid = (file as NSString).deletingPathExtension
            // session id は UUID 相当のみ採用(細工ファイル名を端末コマンドに混ぜない)
            guard sid.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { continue }
            let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
            out.append(ClaudeSession(id: sid,
                                     title: firstPrompt(path) ?? "(プロンプトなし)",
                                     modified: modified,
                                     path: path))
        }
        return Array(out.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// セッション末尾付近を読み、直近の会話(user/assistant のテキスト)を取り出す。
    public static func preview(path: String, maxMessages: Int = 12) -> [PreviewMessage] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 256 * 1024
        let start = size > tail ? size - tail : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard var text = String(data: data, encoding: .utf8) else { return [] }
        // 途中から読んだ場合、最初の不完全な行は捨てる
        if start > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }

        var msgs: [PreviewMessage] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = o["type"] as? String, type == "user" || type == "assistant",
                  let raw = messageText(o["message"]) else { continue }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("Caveat:") { continue }
            msgs.append(PreviewMessage(role: type, text: String(t.prefix(600))))
        }
        return Array(msgs.suffix(maxMessages))
    }

    /// 先頭付近を読み、最初の「実プロンプト」(メタ/コマンド/ツール結果でない user 発言)をタイトルに。
    private static func firstPrompt(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["type"] as? String) == "user",
                  let raw = messageText(o["message"]) else { continue }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("Caveat:") { continue }
            let oneLine = t.replacingOccurrences(of: "\n", with: " ")
            return String(oneLine.prefix(100))
        }
        return nil
    }

    private static func messageText(_ message: Any?) -> String? {
        guard let m = message as? [String: Any] else { return nil }
        if let s = m["content"] as? String { return s }
        if let arr = m["content"] as? [[String: Any]] {
            let texts = arr.compactMap { part -> String? in
                (part["type"] as? String) == "text" ? part["text"] as? String : nil
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }

    // MARK: - resume / new 判定(純関数)

    /// `claude` をどの id で・`--resume` と `--session-id` のどちらで起動するかを決める。
    /// 過去2回のリグレッション(worktree の cwd 変化、プロファイルの CLAUDE_CONFIG_DIR 変化)は
    /// どちらもこの決定ロジック自体ではなく「存在チェックの基準(root)がずれる」ことが原因だった。
    /// そのためここでは存在チェックを `sessionExists` クロージャとして外から渡してもらい、
    /// 本関数自体はファイルシステムに一切触れない(=テストがファイルを用意しなくても検証できる)。
    ///
    /// id の優先順位: 明示的な resume 指定(履歴ピッカーでの選択)> カードにピン留め済みの id
    /// > 新規生成した id。選ばれた id が(渡された基準で)既に存在すれば `.resume`、
    /// 存在しなければ `.createNew`。
    public static func resolveLaunchMode(
        explicitResumeID: String?,
        pinnedSessionID: String?,
        newSessionID: String,
        sessionExists: (String) -> Bool
    ) -> ClaudeLaunchMode {
        let sid = explicitResumeID ?? pinnedSessionID ?? newSessionID
        return sessionExists(sid) ? .resume(sid) : .createNew(sid)
    }
}
