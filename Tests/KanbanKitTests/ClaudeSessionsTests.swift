import Foundation
import Testing
@testable import KanbanKit

/// `ClaudeSessionsService.resolveLaunchMode` は「今どの id で、`--resume` と `--session-id` の
/// どちらで `claude` を起動するか」を決める純関数。過去2回の本番不具合(worktree で cwd が
/// 変わって見失う / プロファイルで CLAUDE_CONFIG_DIR が変わって見失う)は、どちらも
/// この決定ロジック自体ではなく「存在チェックの基準(root)がずれる」ことが原因だった。
/// なので存在チェックはクロージャとして注入し、ここではファイルシステムに一切触れずに
/// 「どの id が選ばれ、どちらのモードになるか」だけを検証する。
@Suite struct ClaudeLaunchModeResolutionTests {
    @Test func pinnedExisting_resumesPinned() {
        let mode = ClaudeSessionsService.resolveLaunchMode(
            explicitResumeID: nil,
            pinnedSessionID: "pinned-1",
            newSessionID: "fresh-1",
            sessionExists: { $0 == "pinned-1" }
        )
        #expect(mode == .resume("pinned-1"))
    }

    @Test func pinnedMissing_createsNewWithPinnedID() {
        let mode = ClaudeSessionsService.resolveLaunchMode(
            explicitResumeID: nil,
            pinnedSessionID: "pinned-2",
            newSessionID: "fresh-2",
            sessionExists: { _ in false }
        )
        #expect(mode == .createNew("pinned-2"))
    }

    @Test func explicitResumeWinsOverPinned() {
        let mode = ClaudeSessionsService.resolveLaunchMode(
            explicitResumeID: "explicit-3",
            pinnedSessionID: "pinned-3",
            newSessionID: "fresh-3",
            sessionExists: { $0 == "explicit-3" }
        )
        #expect(mode == .resume("explicit-3"))
    }

    @Test func explicitResumeMissing_stillWinsOverPinnedButCreatesNew() {
        // 明示指定があれば、たとえそれが存在しなくてもピンより優先して選ばれる
        // (存在しないので --session-id になるが、id はピンではなく明示指定のもの)。
        let mode = ClaudeSessionsService.resolveLaunchMode(
            explicitResumeID: "explicit-4",
            pinnedSessionID: "pinned-4",
            newSessionID: "fresh-4",
            sessionExists: { _ in false }
        )
        #expect(mode == .createNew("explicit-4"))
    }

    @Test func noPinnedNoExplicit_missingSession_createsNew() {
        let mode = ClaudeSessionsService.resolveLaunchMode(
            explicitResumeID: nil,
            pinnedSessionID: nil,
            newSessionID: "fresh-6",
            sessionExists: { _ in false }
        )
        #expect(mode == .createNew("fresh-6"))
    }
}

/// 実ファイルシステムに触れる方(パス解決と、過去2回の本番リグレッションの再現)。
/// `CLAUDE_HOME` はプロセス全体で一度だけ隔離用の一時ディレクトリに固定し(`TestClaudeHome`)、
/// 各テストは UUID でセッション id / project ディレクトリ名を一意にして衝突を避ける。
@Suite struct ClaudeSessionsPathResolutionTests {
    init() { TestClaudeHome.bootstrap() }

    @Test func projectDirNameReplacesSlashesAndDotsWithDashes() {
        // "/" と "." の両方を含む cwd で、実装が実際に返す変換(両方とも "-" に置換)を確認する。
        let slug = ClaudeSessionsService.projectDirName(for: "/Users/x.y/Projects/foo")
        #expect(slug == "-Users-x-y-Projects-foo")
    }

    /// リグレッション1(worktree): worktree カードは cwd がその都度変わる。ピン留めした
    /// セッションは元 repo の cwd 由来の project ディレクトリに存在するが、`sessionExistsAnywhere`
    /// は cwd を問わず projects 配下のどのディレクトリでも探すので、"現在の" cwd が別物(worktree)
    /// になっていても見つかる ―― これが壊れると「実在するのに無い」と誤判定して
    /// --session-id を新規発行し "already in use" になる。
    @Test func sessionExistsAnywhere_isRootWide_notCwdScoped() throws {
        let sessionID = UUID().uuidString
        let cwdA = "/tmp/fleet-test-repo-a-\(UUID().uuidString)"      // セッションが実際に作られた cwd
        let cwdB = "/tmp/fleet-test-worktree-b-\(UUID().uuidString)"  // 「今の」cwd(worktree, 別物)

        let slugA = ClaudeSessionsService.projectDirName(for: cwdA)
        let projectDir = (TestClaudeHome.path as NSString)
            .appendingPathComponent("projects/\(slugA)")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        let jsonlPath = (projectDir as NSString).appendingPathComponent("\(sessionID).jsonl")
        try "{}".write(toFile: jsonlPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: projectDir) }

        // cwdB (worktree) が「今の」cwd であっても、configDir 未指定(デフォルト root)なら見つかる。
        _ = cwdB   // このテストの主張上、cwdB 自体は存在チェックには使わない(root-wide だから)。
        #expect(ClaudeSessionsService.sessionExistsAnywhere(id: sessionID, configDir: nil) == true)
    }

    /// リグレッション2(プロファイル): カードに `ClaudeProfile` が割り当てられていると、
    /// セッション履歴はデフォルトの `~/.claude`(ここでは `CLAUDE_HOME`)ではなく
    /// `configDir` の下に生成される。存在チェックがデフォルト root しか見ないと
    /// 「実在するのに無い」と誤判定し、"already in use" を再現してしまう。
    @Test func sessionExistsAnywhere_respectsCustomConfigDir() throws {
        let sessionID = UUID().uuidString
        let customConfigDir = NSTemporaryDirectory() + "fleet-test-claude-profile-" + UUID().uuidString
        let projectDir = (customConfigDir as NSString).appendingPathComponent("projects/some-project")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        let jsonlPath = (projectDir as NSString).appendingPathComponent("\(sessionID).jsonl")
        try "{}".write(toFile: jsonlPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: customConfigDir) }

        // カスタム configDir を渡せば見つかる。
        #expect(ClaudeSessionsService.sessionExistsAnywhere(id: sessionID, configDir: customConfigDir) == true)
        // デフォルト root(CLAUDE_HOME)にはこのセッションは存在しないので false のまま
        // ―― まさにこのズレが "already in use" の原因だった。
        #expect(ClaudeSessionsService.sessionExistsAnywhere(id: sessionID, configDir: nil) == false)
    }
}
