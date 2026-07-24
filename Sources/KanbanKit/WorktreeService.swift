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
