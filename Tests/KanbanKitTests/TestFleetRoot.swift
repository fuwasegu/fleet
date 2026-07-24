import Foundation

/// テストプロセス全体で共有する隔離用 `FLEET_ROOT`。
///
/// `BoardStore.connectCards` などは `ChannelStore` 経由で実際にファイルを書く。何もしなければ
/// テストが実マシンの `~/.fleet/channels|cards/` を汚染してしまう(leaked directories 問題)。
/// `ChannelStore.fleetRoot()` は環境変数 `FLEET_ROOT` を優先するので、テストプロセス内で最初に
/// `ChannelStore` へ触れるより前にこれを設定しておけば、以降の全テストが確実にこの一時
/// ディレクトリだけを触るようになる。
///
/// swift-testing はテストを(同一プロセス内で複数スレッドから)並列実行しうるため、環境変数という
/// プロセスグローバルな状態をテストごとに切り替えることはできない。その代わりプロセス全体で
/// 一意な一時ディレクトリを一度だけ用意して `FLEET_ROOT` に固定し、各テストは(既存の慣習どおり)
/// UUID で自分のチャンネル/カードディレクトリを一意にすることでテスト間の衝突を避ける。
///
/// `static let` の初期化は Swift ランタイムが thread-safe に一度だけ実行することを保証するため、
/// 複数スレッドから同時に初回アクセスされても安全(競合して二重に作られたり、片方が未設定の
/// `FLEET_ROOT` を見てしまったりしない)。
enum TestFleetRoot {
    static let path: String = {
        let dir = NSTemporaryDirectory() + "fleet-test-root-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("FLEET_ROOT", dir, 1)
        atexit { TestFleetRoot.cleanupAtExit() }
        return dir
    }()

    /// `atexit` から呼ばれる(C 関数ポインタ制約上キャプチャできないため static 経由)。
    /// プロセス終了時に一時ツリーごと片付ける(ベストエフォート: 失敗しても実害はない)。
    private static func cleanupAtExit() {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// 各 Suite の `init()` から呼ぶことで、その Suite の最初のテスト本体が実行される前に
    /// `FLEET_ROOT` が確実に設定されていることを保証する。
    static func bootstrap() { _ = path }
}
