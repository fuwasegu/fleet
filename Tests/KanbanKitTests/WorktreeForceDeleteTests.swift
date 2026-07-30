import Testing
import Foundation
@testable import KanbanKit

@Suite struct WorktreeForceDeleteParseTests {
    /// porcelain v1 の XY コードが表示グループへ正しく畳まれること。
    /// 分類は安全性の判定ではなく「これは捨てていいゴミか」を即断させるためのグルーピング。
    @Test func classifiesPorcelainCodes() {
        let out = """
        ?? .serena/
        ?? .DS_Store
         M Sources/KanbanKit/WorktreeService.swift
        M  Sources/KanbanTerm/Views/CardView.swift
        MM Sources/KanbanTerm/Views/ColumnView.swift
         D docs/old-note.md
        D  docs/removed.md
        UU Sources/conflict.swift
        """
        let e = WorktreeService.parsePorcelain(out)
        #expect(e.count == 8)
        #expect(e.first(where: { $0.path == ".serena/" })?.kind == .untracked)
        #expect(e.first(where: { $0.path == ".DS_Store" })?.kind == .untracked)
        #expect(e.first(where: { $0.path == "Sources/KanbanKit/WorktreeService.swift" })?.kind == .modified)
        #expect(e.first(where: { $0.path == "Sources/KanbanTerm/Views/CardView.swift" })?.kind == .staged)
        #expect(e.first(where: { $0.path == "Sources/KanbanTerm/Views/ColumnView.swift" })?.kind == .modified)
        #expect(e.first(where: { $0.path == "docs/old-note.md" })?.kind == .deleted)
        #expect(e.first(where: { $0.path == "docs/removed.md" })?.kind == .deleted)
        #expect(e.first(where: { $0.path == "Sources/conflict.swift" })?.kind == .conflicted)
    }

    /// 未追跡ディレクトリは porcelain が末尾スラッシュ付きで畳んで返す。
    /// UI はこれを「ディレクトリ」として表示し、diff の展開対象にしない。
    @Test func detectsUntrackedDirectory() {
        let e = WorktreeService.parsePorcelain("?? .serena/\n?? scratch.md\n")
        #expect(e[0].isDirectory)
        #expect(!e[1].isDirectory)
    }

    /// rename は "old -> new"。ディスク上に存在する new 側を表示する。
    @Test func renameUsesNewPath() {
        let e = WorktreeService.parsePorcelain("R  docs/a.md -> docs/b.md\n")
        #expect(e.count == 1)
        #expect(e[0].path == "docs/b.md")
        #expect(e[0].kind == .staged)
    }

    /// 日本語パスは `core.quotePath=false` 前提でそのまま通る(エスケープ解除は自前でやらない)。
    @Test func keepsNonASCIIPathAsIs() {
        let e = WorktreeService.parsePorcelain("?? docs/日本語メモ.md\n")
        #expect(e[0].path == "docs/日本語メモ.md")
    }

    /// 空行・末尾改行・XY だけでパスが無い壊れた行は捨てる(クラッシュしない)。
    @Test func ignoresBlankAndMalformedLines() {
        let e = WorktreeService.parsePorcelain("\n?? a.txt\n\n?? \nM\n")
        #expect(e.count == 1)
        #expect(e[0].path == "a.txt")
    }

    /// 回帰: 行頭の空白が落ちた行(呼び出し元が出力を trim してしまった場合に起きる)は、
    /// 別のパスへ化けさせずに捨てる。" M README" が trim されて "M README" になると
    /// XY とパスの切り出しが1文字ずれ、path が "EADME" の staged エントリに化けていた。
    @Test func dropsLinesWhoseSeparatorIsMissing() {
        let e = WorktreeService.parsePorcelain("M README\n?? .serena/\n")
        #expect(e.count == 1)
        #expect(e[0].path == ".serena/")
        #expect(!e.contains { $0.path == "EADME" })
    }

    /// kind ごとの取り出しヘルパ(UI のセクション分けが使う)。
    @Test func groupsByKind() {
        let p = WorktreeService.DirtyPreview(
            entries: WorktreeService.parsePorcelain("?? a\n?? b/\n M c\n"),
            statusError: nil
        )
        #expect(p.entries(of: .untracked).count == 2)
        #expect(p.entries(of: .modified).count == 1)
        #expect(p.entries(of: .deleted).isEmpty)
        #expect(p.statusError == nil)
    }
}

@Suite struct WorktreeForceDeleteGitTests {
    /// 既存 WorktreeServiceGitTests と同じ流儀の一時リポジトリ。
    private func tmpRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "wtf-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = try WorktreeService.run(["init", "-b", "main"], in: dir)
        _ = try WorktreeService.run(["config", "user.email", "t@t"], in: dir)
        _ = try WorktreeService.run(["config", "user.name", "t"], in: dir)
        FileManager.default.createFile(atPath: dir + "/README", contents: Data("hi\n".utf8))
        _ = try WorktreeService.run(["add", "."], in: dir)
        _ = try WorktreeService.run(["commit", "-m", "init"], in: dir)
        return dir
    }

    /// 未追跡ファイルと tracked 変更が混ざった worktree を、種類別に見分けられること。
    @Test func previewsUntrackedAndModified() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/preview", baseRef: "main", baseDir: ".fleet-worktrees")

        // 捨てて構わない未追跡ゴミ(この機能の動機そのもの)
        try FileManager.default.createDirectory(atPath: path + "/.serena", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/.serena/cache.json", contents: Data("{}".utf8))
        // tracked ファイルへの本物の変更
        try "hi\nchanged\n".write(toFile: path + "/README", atomically: true, encoding: .utf8)

        let p = WorktreeService.dirtyPreview(worktreePath: path)
        #expect(p.statusError == nil)
        #expect(p.entries(of: .untracked).contains { $0.path == ".serena/" && $0.isDirectory })
        #expect(p.entries(of: .modified).contains { $0.path == "README" })
    }

    /// tracked ファイルの diff が HEAD 比較で取れること。未追跡には呼ばない前提なので
    /// ここでは tracked のみを確認する。
    @Test func fileDiffShowsChangedLines() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/diff", baseRef: "main", baseDir: ".fleet-worktrees")
        try "hi\nchanged\n".write(toFile: path + "/README", atomically: true, encoding: .utf8)

        let d = try WorktreeService.fileDiff(worktreePath: path, path: "README")
        #expect(d.contains("+changed"))
        #expect(d.contains("@@"))
    }

    /// ステージ済みの変更も HEAD 比較で1本化して見えること
    /// (worktree ごと捨てるので index と worktree を分けて見せる意味がない)。
    @Test func fileDiffIncludesStagedChanges() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/staged", baseRef: "main", baseDir: ".fleet-worktrees")
        try "hi\nstaged\n".write(toFile: path + "/README", atomically: true, encoding: .utf8)
        _ = try WorktreeService.run(["add", "README"], in: path)

        let p = WorktreeService.dirtyPreview(worktreePath: path)
        #expect(p.entries(of: .staged).contains { $0.path == "README" })
        let d = try WorktreeService.fileDiff(worktreePath: path, path: "README")
        #expect(d.contains("+staged"))
    }

    /// fail-open ではなく fail-visible: git status が失敗しても throw せず statusError に載せる。
    /// 差分が取れないことを行き止まりにしないため(index.lock 競合で永久に塞がるのが直したい罠)。
    /// 既存 WorktreeServiceGitTests.statusFailureBlocksRemoval と同じく index の権限を剥奪して再現する。
    @Test func statusFailureSurfacesAsStatusError() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/lock", baseRef: "main", baseDir: ".fleet-worktrees")

        let gitFile = try String(contentsOfFile: path + "/.git", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(gitFile.hasPrefix("gitdir: "))
        let indexPath = String(gitFile.dropFirst("gitdir: ".count)) + "/index"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: indexPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: indexPath) }

        let p = WorktreeService.dirtyPreview(worktreePath: path)
        #expect(p.statusError != nil)
        #expect(p.entries.isEmpty)
    }

    /// 使用中(inUse)は強制でも削除しない。走っているプロセスの cwd を消すのは
    /// 差分を失うのとは別種の事故なので、このガードは強制ルートでも外さない。
    @Test func inUseBlocksForceRemoval() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/inuse", baseRef: "main", baseDir: ".fleet-worktrees")
        FileManager.default.createFile(atPath: path + "/dirty.txt", contents: Data("x".utf8))

        #expect(throws: WorktreeService.GitError.self) {
            try WorktreeService.removeForcibly(worktreePath: path, repoRoot: repo, inUse: true)
        }
        #expect(FileManager.default.fileExists(atPath: path))   // 残っている
    }

    /// この機能の本命: 未追跡ゴミ + tracked 変更 + 未プッシュコミットを抱えた worktree を
    /// 強制削除すると、ディレクトリは消えるが **ブランチとそのコミットは残る**。
    /// これが不変条件 NeverLoseCommits(removed => branch_kept)の実行可能な証拠。
    @Test func forceRemovalDiscardsWorkingTreeButKeepsBranchAndCommits() throws {
        let repo = try tmpRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let path = try WorktreeService.create(repoRoot: repo, branch: "feat/force", baseRef: "main", baseDir: ".fleet-worktrees")

        // 未プッシュのコミットを1つ作る(強制削除でも失われてはいけないもの)
        FileManager.default.createFile(atPath: path + "/kept.txt", contents: Data("keep me\n".utf8))
        _ = try WorktreeService.run(["add", "kept.txt"], in: path)
        _ = try WorktreeService.run(["commit", "-m", "unpushed work"], in: path)
        let sha = try WorktreeService.run(["rev-parse", "HEAD"], in: path)

        // 捨てられるべきもの: 未追跡ゴミ + tracked 変更
        try FileManager.default.createDirectory(atPath: path + "/.serena", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/.serena/cache.json", contents: Data("{}".utf8))
        try "hi\nthrow away\n".write(toFile: path + "/README", atomically: true, encoding: .utf8)

        // dirty が unpushed より優先されることの確認(強制ルートの入口は .dirty だけ)
        #expect(WorktreeService.removalRisk(worktreePath: path, repoRoot: repo, inUse: false) == .dirty)

        try WorktreeService.removeForcibly(worktreePath: path, repoRoot: repo, inUse: false)

        #expect(!FileManager.default.fileExists(atPath: path))                        // worktree は消えた
        #expect(WorktreeService.branchExists(repoRoot: repo, branch: "feat/force"))    // ブランチは残る
        let keptSHA = try WorktreeService.run(["rev-parse", "feat/force"], in: repo)
        #expect(keptSHA == sha)                                                        // コミットも残る
        // worktree の登録も掃除されている(prune 済み)
        let list = try WorktreeService.run(["worktree", "list"], in: repo)
        #expect(!list.contains(path))
    }
}
