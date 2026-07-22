import Foundation

/// `gh` CLI を使って、指定ディレクトリの現在ブランチに紐づく PR の URL を取得する。
/// gh 未導入/未ログイン/PRなし の場合は nil。ブロッキングなので必ず main 以外から呼ぶこと。
enum GitHubService {
    /// 現在の git ブランチ名（detached HEAD 等は nil）。
    static func branch(cwd: String) -> String? {
        let expanded = (cwd as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "cd \(shellQuote(expanded)) && git rev-parse --abbrev-ref HEAD 2>/dev/null"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty, text != "HEAD" else { return nil }
        return text
    }

    /// 指定ブランチに紐づく PR の URL。
    /// worktree では `gh pr view`(引数なし)の暗黙のブランチ検出がずれて別 PR を拾うことがあるため、
    /// ブランチが分かるときは `gh pr list --head <branch>` で「この head を持つ PR」を決定的に引く。
    /// (gh の暗黙のブランチ推定に依存しないので worktree でも安定する。)branch 不明時のみ暗黙検出。
    static func prURL(cwd: String, branch: String? = nil) -> String? {
        let expanded = (cwd as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }

        let query: String
        if let branch, !branch.isEmpty {
            // open を優先、無ければ最新の PR。head を明示するので worktree でもずれない。
            query = "gh pr list --head \(shellQuote(branch)) --state all --json url,state "
                  + "--jq '([.[] | select(.state==\"OPEN\")] + .)[0].url'"
        } else {
            query = "gh pr view --json url -q .url"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // ログインシェル経由で PATH を通す(homebrew の gh 等)。PR URL を1行出力。
        process.arguments = ["-lc", "cd \(shellQuote(expanded)) && \(query) 2>/dev/null"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, text.hasPrefix("http") else { return nil }
        return text
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
