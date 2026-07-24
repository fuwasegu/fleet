import Foundation

/// テストプロセス全体で共有する隔離用 `CLAUDE_HOME`。`TestFleetRoot`(`FLEET_ROOT`)と全く同じ流儀。
///
/// `ClaudeSessionsService` は `CLAUDE_HOME` 環境変数が設定されていればデフォルトの
/// `~/.claude` の代わりにそれを使う。何もしなければテストが実マシンの `~/.claude/projects/`
/// を読みに行ってしまう(実セッションが紛れ込んだり、逆に無いはずのものを「無い」と
/// 誤判定したりで再現性が崩れる)。
///
/// swift-testing はテストを(同一プロセス内で複数スレッドから)並列実行しうるため、環境変数という
/// プロセスグローバルな状態をテストごとに切り替えることはできない。その代わりプロセス全体で
/// 一意な一時ディレクトリを一度だけ用意して `CLAUDE_HOME` に固定し、各テストは(既存の慣習どおり)
/// UUID でセッション id / project ディレクトリ名を一意にすることでテスト間の衝突を避ける。
///
/// `static let` の初期化は Swift ランタイムが thread-safe に一度だけ実行することを保証するため、
/// 複数スレッドから同時に初回アクセスされても安全。
enum TestClaudeHome {
    static let path: String = {
        let dir = NSTemporaryDirectory() + "claude-test-home-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("CLAUDE_HOME", dir, 1)
        atexit { TestClaudeHome.cleanupAtExit() }
        return dir
    }()

    /// `atexit` から呼ばれる(C 関数ポインタ制約上キャプチャできないため static 経由)。
    /// プロセス終了時に一時ツリーごと片付ける(ベストエフォート: 失敗しても実害はない)。
    private static func cleanupAtExit() {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// 各 Suite の `init()` から呼ぶことで、その Suite の最初のテスト本体が実行される前に
    /// `CLAUDE_HOME` が確実に設定されていることを保証する。
    static func bootstrap() { _ = path }
}
