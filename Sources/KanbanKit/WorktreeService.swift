import Foundation
import Darwin

public enum WorktreeBase: Hashable, Sendable { case current, defaultBranch }

public struct WorktreeService {
    /// Fleet 管理 worktree の既定の格納先(リポジトリルート相対)。
    public static let defaultWorktreeBaseDir = "../.fleet-worktrees"

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

    public enum RemovalRisk: Sendable { case clean, dirty, unpushed, inUse }

    public static func classifyRemoval(porcelain: String, aheadCount: Int, mergedIntoDefault: Bool, inUse: Bool) -> RemovalRisk {
        if inUse { return .inUse }
        if !porcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .dirty }
        if aheadCount > 0 || !mergedIntoDefault { return .unpushed }
        return .clean
    }
}

extension WorktreeService {
    public struct GitError: Error, Sendable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    /// シェルコマンド文字列へ安全に埋め込むための単一引用符クオート。
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `git -C <dir> <args...>` を実行し、非0終了で `GitError` を投げる。stdout は trim して返す。
    ///
    /// ログイン zsh 経由で実行することで、`/usr/bin/env` 直接起動では欠落する Homebrew 等の
    /// ユーザー PATH を継承する(git-lfs の filter.lfs.process 解決に必要)。
    /// zsh 内で git がコマンド列の唯一/最後のコマンドなので、`terminationStatus` は git の
    /// 終了コードのまま(merge-base --is-ancestor 等の 0/1 判定はそのまま機能する)。
    @discardableResult
    public static func run(_ args: [String], in dir: String) throws -> String {
        try run(args, in: dir, extraEnv: [:])
    }

    /// `run(_:in:)` の環境変数拡張版。`extraEnv` が空なら `Process.environment` を触らず
    /// (nil のまま = 親プロセスの環境をそのまま継承)、既存呼び出し元の挙動を完全に維持する。
    /// `fetchBase` が `GIT_TERMINAL_PROMPT=0` 等を注入するために使う。タイムアウト無し
    /// (`run(_:in:extraEnv:timeout:)` に `timeout: nil` を渡すのと同じ)。
    @discardableResult
    static func run(_ args: [String], in dir: String, extraEnv: [String: String]) throws -> String {
        try run(args, in: dir, extraEnv: extraEnv, timeout: nil)
    }

    /// `run(_:in:extraEnv:)` のタイムアウト付き版。`timeout` が nil ならタイムアウト監視を
    /// 一切行わず(既存呼び出し元と完全に同じ挙動)、非nil なら壁時計で `timeout` 秒待って
    /// 終わらなければ子プロセスのプロセスグループへ SIGTERM → (2秒待って) SIGKILL を送り、
    /// `GitError` (タイムアウトメッセージ) を throw する。
    ///
    /// プロセスグループへ kill できる前提: `zsh -lc "<単一コマンド>"` は job control により
    /// 実行前に新しい pgrp (pgid == 自分の pid) を作ってから対象コマンドへ exec するため、
    /// `p.processIdentifier` は git 自身の pid かつそのままプロセスグループの pgid として使える
    /// (`TerminalSessions.close` の `killpg(pid, SIGTERM)` と同じ前提)。
    /// `run` と同じだが stdout を trim しない。
    ///
    /// `git status --porcelain` のように**行頭の空白が意味を持つ**出力に必ずこちらを使う
    /// (" M path" = worktree 側の変更 / "M  path" = ステージ済み は別の状態で、trim すると
    /// 1行目の先頭空白が落ちて分類が丸ごとずれる)。
    @discardableResult
    static func runRaw(_ args: [String], in dir: String) throws -> String {
        try run(args, in: dir, extraEnv: [:], timeout: nil, trimmingOutput: false)
    }

    /// - Parameter trimmingOutput: false なら stdout をそのまま返す。行頭の空白が意味を持つ
    ///   出力(porcelain 等)では false にする。既定 true は既存呼び出し元の挙動を維持するため。
    @discardableResult
    static func run(_ args: [String], in dir: String, extraEnv: [String: String], timeout: TimeInterval?, trimmingOutput: Bool = true) throws -> String {
        let argv = ["git", "-C", dir] + args
        let command = argv.map(shellQuote).joined(separator: " ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            p.environment = env
        }
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        // stdout/stderr を並行して読み切ってから waitUntilExit する。
        // 大量出力(例: status --porcelain が数千件の untracked を返す)でパイプの
        // OS バッファ(~64KB)が埋まると、先に waitUntilExit してしまうとプロセス側が
        // write でブロックし続けてデッドロックする。読み取りを先に(同時に)進めることで防ぐ。
        var outData = Data()
        var errData = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        var timedOut = false
        if let timeout {
            // waitUntilExit 自体には期限を付けられないので、terminationHandler の発火を
            // シグナルとして DispatchGroup で期限付き待機する。
            let exitGroup = DispatchGroup()
            exitGroup.enter()
            p.terminationHandler = { _ in exitGroup.leave() }
            try p.run()
            if exitGroup.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                let pid = p.processIdentifier
                if pid > 0 {
                    killpg(pid, SIGTERM)
                    _ = exitGroup.wait(timeout: .now() + 2)
                    killpg(pid, SIGKILL)
                }
            }
        } else {
            try p.run()
        }

        readGroup.wait()
        p.waitUntilExit()

        if timedOut {
            throw GitError(message: "タイムアウト (\(Int(timeout ?? 0))秒)")
        }

        let o = String(data: outData, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            let e = String(data: errData, encoding: .utf8) ?? ""
            throw GitError(message: e.isEmpty ? o : e)
        }
        return trimmingOutput ? o.trimmingCharacters(in: .whitespacesAndNewlines) : o
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

    /// `branch` の push 先リモート名を推定する。`branch.<branch>.remote` の設定(upstream)を
    /// 優先し、無ければ `git remote` の最初の1行(=多くのリポジトリでは "origin")を使う。
    /// リモートが1つも登録されていなければ nil。
    public static func remoteName(repoRoot: String, forBranch branch: String) -> String? {
        if let configured = try? run(["config", "--get", "branch.\(branch).remote"], in: repoRoot),
           !configured.isEmpty {
            return configured
        }
        if let remotes = try? run(["remote"], in: repoRoot) {
            if let first = remotes.split(separator: "\n").first {
                let name = String(first).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    /// `<remote>/<branch>` の追跡ブランチを最新化する(タグは取得しない)。
    ///
    /// CRITICAL: ブロックしたいのは「対話プロンプトによるハング」であって「認証そのもの」では
    /// ない。以前は `-c credential.helper=` で credential helper 自体を無効化していたが、これは
    /// 過剰だった — macOS の osxkeychain や `gh auth setup-git` が設定するヘルパーは、資格情報が
    /// 既にキャッシュされていれば非対話(=ハングしない)で返すだけなので、これを塞ぐと
    /// 認証済みユーザーの HTTPS fetch まで常に `could not read Username` で失敗してしまう
    /// (実際に発生したバグ)。
    ///
    /// 対話プロンプトだけを狙って止める:
    /// - `GIT_TERMINAL_PROMPT=0` で git 自身の端末プロンプト(HTTPS のユーザ名/パスワード入力等)を止める。
    /// - `GIT_SSH_COMMAND=ssh -oBatchMode=yes` で SSH のパスフレーズ/known_hosts 対話を止める。
    /// - `core.askPass=` は付けない(簡素化。上記2つで非対話化は十分カバーでき、GUI askpass に
    ///   フォールバックする余地もそもそも無い環境が前提)。
    ///
    /// これでも「プロンプトを出さずに応答が返らないだけ」のリモート(ネットワーク断・
    /// firewall drop 等)はハングしうるため、実効的な anti-hang 保証は `run` に渡す壁時計
    /// タイムアウト(20秒)で行う。タイムアウト時は子プロセスのプロセスグループへ
    /// SIGTERM → SIGKILL を送って確実に終了させる。
    public static func fetchBase(repoRoot: String, remote: String, branch: String) throws {
        try run(
            ["fetch", "--no-tags", remote, branch],
            in: repoRoot,
            extraEnv: [
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_SSH_COMMAND": "ssh -oBatchMode=yes",
            ],
            timeout: 20
        )
    }

    /// `resolveFreshBase` の結果。`ref` は `WorktreeService.create` の `baseRef` にそのまま渡せる。
    public struct ResolvedBase: Sendable {
        /// `create` の baseRef に渡す実際の ref(`<remote>/<base>` または `base` そのもの)。
        public let ref: String
        /// true なら fetch 済みのリモート追跡ブランチを使った(= 最新化に成功した)。
        public let usedRemote: Bool
        /// フォールバック(= 陳腐化しうるローカル `base` を使った)の場合のみ、その理由。
        /// 呼び出し元は note が非nilなら必ずユーザー/Agent に見せること(サイレントな陳腐化を防ぐ)。
        public let note: String?

        public init(ref: String, usedRemote: Bool, note: String? = nil) {
            self.ref = ref
            self.usedRemote = usedRemote
            self.note = note
        }
    }

    /// worktree のベースを "最新化" して解決する。
    ///
    /// `base` はローカルブランチ名(UI のピッカーや intent の "current"/"default" 解決結果)。
    /// ユーザーのローカルブランチには一切変更を加えない(pull もフェッチ後のFF更新もしない)。
    /// これは他所(別 worktree 等)で checkout 中のブランチと衝突しないための最小びっくり設計。
    /// 代わりに `<remote>/<base>` をfetchし、それが使えるならそちらを ref として返す。
    ///
    /// 失敗しうる分岐(リモート無し/fetch失敗/リモートにブランチが無い)は全て `note` 付きで
    /// ローカル `base` へフォールバックする。この関数自身は決して throw しない
    /// (呼び出し元は常にそのまま `create` に渡せる ref を得られる)。
    public static func resolveFreshBase(repoRoot: String, base: String, fetch: Bool) -> ResolvedBase {
        guard fetch else {
            return ResolvedBase(ref: base, usedRemote: false, note: nil)
        }
        guard let remote = remoteName(repoRoot: repoRoot, forBranch: base) else {
            return ResolvedBase(ref: base, usedRemote: false,
                                 note: "リモートが無いためローカルの \(base) から作成します")
        }
        do {
            try fetchBase(repoRoot: repoRoot, remote: remote, branch: base)
        } catch let e as GitError {
            let reason = e.message.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init) ?? e.message
            return ResolvedBase(ref: base, usedRemote: false,
                                 note: "\(remote) の取得に失敗したためローカルの \(base) から作成します(\(reason))")
        } catch {
            return ResolvedBase(ref: base, usedRemote: false,
                                 note: "\(remote) の取得に失敗したためローカルの \(base) から作成します(\(error))")
        }
        let remoteRef = "refs/remotes/\(remote)/\(base)"
        if let out = try? run(["rev-parse", "--verify", "--quiet", remoteRef], in: repoRoot), !out.isEmpty {
            return ResolvedBase(ref: "\(remote)/\(base)", usedRemote: true, note: nil)
        }
        return ResolvedBase(ref: base, usedRemote: false,
                             note: "リモートに \(base) が無いためローカルから作成します")
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
