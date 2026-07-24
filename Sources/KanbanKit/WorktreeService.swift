import Foundation

public enum WorktreeBase: Hashable { case current, defaultBranch }

public struct WorktreeService {
    public static func sanitizeBranch(_ raw: String) -> String {
        var s = raw.map { c -> Character in
            c.isLetter || c.isNumber || "._/-".contains(c) ? c : "-"
        }.reduce(into: "") { acc, c in
            // 連続する区切り記号(- または /)は種類を問わずまとめて畳む
            if (c == "-" || c == "/"), let last = acc.last, (last == "-" || last == "/") { return }
            acc.append(c)
        }
        while let f = s.first, f == "-" || f == "/" { s.removeFirst() }
        while let l = s.last, l == "-" || l == "/" { s.removeLast() }
        return s.isEmpty ? "work" : s
    }

    public static func worktreePath(repoRoot: String, branch: String, baseDir: String) -> String {
        let base = URL(fileURLWithPath: repoRoot).appendingPathComponent(baseDir).standardizedFileURL
        return base.appendingPathComponent(sanitizeBranch(branch)).standardizedFileURL.path
    }

    public enum RemovalRisk { case clean, dirty, unpushed, inUse }

    public static func classifyRemoval(porcelain: String, aheadCount: Int, mergedIntoDefault: Bool, inUse: Bool) -> RemovalRisk {
        if inUse { return .inUse }
        if !porcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .dirty }
        if aheadCount > 0 || !mergedIntoDefault { return .unpushed }
        return .clean
    }
}

extension WorktreeService {
    public struct GitError: Error {
        public let message: String
    }

    /// `git -C <dir> <args...>` を実行し、非0終了で `GitError` を投げる。stdout は trim して返す。
    @discardableResult
    public static func run(_ args: [String], in dir: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir] + args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()

        // stdout/stderr を並行して読み切ってから waitUntilExit する。
        // 大量出力(例: status --porcelain が数千件の untracked を返す)でパイプの
        // OS バッファ(~64KB)が埋まると、先に waitUntilExit してしまうとプロセス側が
        // write でブロックし続けてデッドロックする。読み取りを先に(同時に)進めることで防ぐ。
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        p.waitUntilExit()

        let o = String(data: outData, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            let e = String(data: errData, encoding: .utf8) ?? ""
            throw GitError(message: e.isEmpty ? o : e)
        }
        return o.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// リモート origin の HEAD から既定ブランチ名を推定。取れなければ現在の HEAD、最終 fallback は "main"。
    public static func defaultBranch(repoRoot: String) -> String {
        if let r = try? run(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], in: repoRoot),
           let name = r.split(separator: "/").last {
            return String(name)
        }
        if let cur = try? run(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot), !cur.isEmpty {
            return cur
        }
        return "main"
    }

    /// リポジトリの現在のブランチ名。detached HEAD やそもそも git リポジトリでない場合は nil。
    public static func currentBranch(repoRoot: String) -> String? {
        guard let b = try? run(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot), !b.isEmpty, b != "HEAD" else { return nil }
        return b
    }

    /// `refs/heads/<branch>` が存在するかどうか。存在しなければ `run` が非0終了で throw するのでそれを catch して false。
    public static func branchExists(repoRoot: String, branch: String) -> Bool {
        guard let out = try? run(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], in: repoRoot) else {
            return false
        }
        return !out.isEmpty
    }

    /// ローカルブランチの短縮名一覧。git リポジトリでない場合は `[]`。
    public static func branches(repoRoot: String) -> [String] {
        (try? run(["branch", "--format=%(refname:short)"], in: repoRoot))?
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
    }

    /// `WorktreeBase` (current|default) を具体的な ref 文字列へ解決する。
    /// MCP intent 経路 (`base` フィールドが "current"/"default" の2値のみ) で使用する。
    public static func resolveBase(_ base: WorktreeBase, repoRoot: String) -> String {
        switch base {
        case .current:
            return currentBranch(repoRoot: repoRoot) ?? ((try? run(["rev-parse", "HEAD"], in: repoRoot)) ?? "HEAD")
        case .defaultBranch:
            return defaultBranch(repoRoot: repoRoot)
        }
    }

    public static func create(repoRoot: String, branch: String, baseRef: String, baseDir: String) throws -> String {
        let b = sanitizeBranch(branch)
        if branchExists(repoRoot: repoRoot, branch: b) {
            throw GitError(message: "branch '\(b)' は既に存在します。別名にしてください。")
        }
        let path = worktreePath(repoRoot: repoRoot, branch: b, baseDir: baseDir)
        if FileManager.default.fileExists(atPath: path) {
            throw GitError(message: "配置先が既に存在します: \(path)")
        }
        try run(["worktree", "add", "-b", b, path, baseRef], in: repoRoot)
        return path
    }

    public static func removalRisk(worktreePath: String, repoRoot: String, inUse: Bool) -> RemovalRisk {
        // fail-closed: git status が失敗する(例: そのカードの実行中エージェントが同じ
        // worktree で git を操作していて index.lock が競合している)場合、クリーンかどうか
        // 判定できないので "" (クリーン扱い) にフォールバックしてはいけない。安全側に倒して dirty とみなす。
        // ただし inUse による使用中判定はそれよりも優先度が高いので維持する。
        guard let porcelain = try? run(["status", "--porcelain"], in: worktreePath) else {
            return inUse ? .inUse : .dirty
        }
        let hasUpstream = (try? run(["rev-parse", "--abbrev-ref", "@{u}"], in: worktreePath)) != nil
        let def = defaultBranch(repoRoot: repoRoot)
        // merge-base --is-ancestor は終了コードのみで判定する: 成功(exit 0)= HEAD が def の祖先。
        // 非0終了(祖先でない)は run が throw するだけで、クラッシュにはならない。
        let merged = (try? run(["merge-base", "--is-ancestor", "HEAD", def], in: worktreePath)) != nil
        let mergedIntoDefault: Bool
        let aheadCount: Int
        if hasUpstream {
            // fail-closed: rev-list --count が失敗する/パースできない場合、ahead=0 (push 済み扱い)に
            // フォールバックしてはいけない。安全側に倒して unpushed とみなす。
            guard let aheadStr = try? run(["rev-list", "--count", "@{u}..HEAD"], in: worktreePath),
                  let ahead = Int(aheadStr) else {
                return inUse ? .inUse : .unpushed
            }
            aheadCount = ahead
            mergedIntoDefault = true
        } else {
            aheadCount = 0
            mergedIntoDefault = merged
        }
        return classifyRemoval(porcelain: porcelain, aheadCount: aheadCount, mergedIntoDefault: mergedIntoDefault, inUse: inUse)
    }

    public static func removeSafely(worktreePath: String, repoRoot: String, inUse: Bool) throws {
        let risk = removalRisk(worktreePath: worktreePath, repoRoot: repoRoot, inUse: inUse)
        guard risk == .clean else {
            throw GitError(message: "撤去できません(\(risk))。--force は使いません。")
        }
        try run(["worktree", "remove", worktreePath], in: repoRoot)
        _ = try? run(["worktree", "prune"], in: repoRoot)
    }
}
