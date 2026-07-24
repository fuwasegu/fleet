import Foundation

public enum WorktreeBase { case current, defaultBranch }

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
        p.waitUntilExit()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let o = String(data: outData, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
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

    /// `refs/heads/<branch>` が存在するかどうか。存在しなければ `run` が非0終了で throw するのでそれを catch して false。
    public static func branchExists(repoRoot: String, branch: String) -> Bool {
        guard let out = try? run(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], in: repoRoot) else {
            return false
        }
        return !out.isEmpty
    }

    public static func create(repoRoot: String, branch: String, base: WorktreeBase, baseDir: String) throws -> String {
        let b = sanitizeBranch(branch)
        if branchExists(repoRoot: repoRoot, branch: b) {
            throw GitError(message: "branch '\(b)' は既に存在します。別名にしてください。")
        }
        let path = worktreePath(repoRoot: repoRoot, branch: b, baseDir: baseDir)
        if FileManager.default.fileExists(atPath: path) {
            throw GitError(message: "配置先が既に存在します: \(path)")
        }
        let baseRef: String
        switch base {
        case .current:
            baseRef = (try? run(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot)) ?? "HEAD"
        case .defaultBranch:
            baseRef = defaultBranch(repoRoot: repoRoot)
        }
        try run(["worktree", "add", "-b", b, path, baseRef], in: repoRoot)
        return path
    }

    public static func removalRisk(worktreePath: String, repoRoot: String, inUse: Bool) -> RemovalRisk {
        let porcelain = (try? run(["status", "--porcelain"], in: worktreePath)) ?? ""
        let hasUpstream = (try? run(["rev-parse", "--abbrev-ref", "@{u}"], in: worktreePath)) != nil
        let ahead = Int((try? run(["rev-list", "--count", "@{u}..HEAD"], in: worktreePath)) ?? "0") ?? 0
        let def = defaultBranch(repoRoot: repoRoot)
        // merge-base --is-ancestor は終了コードのみで判定する: 成功(exit 0)= HEAD が def の祖先。
        // 非0終了(祖先でない)は run が throw するだけで、クラッシュにはならない。
        let merged = (try? run(["merge-base", "--is-ancestor", "HEAD", def], in: worktreePath)) != nil
        // upstream があれば ahead カウントを、無ければ「default ブランチにマージ済みか」を使う。
        let mergedIntoDefault = hasUpstream ? true : merged
        let aheadCount = hasUpstream ? ahead : 0
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
