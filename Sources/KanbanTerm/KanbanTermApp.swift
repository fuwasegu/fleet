import SwiftUI
import SwiftData
import KanbanKit

@main
struct KanbanTermApp: App {
    let container: ModelContainer

    // 言語(system=システム追従 / en / ja)。TerminalSettings.languageKey と共有。
    @AppStorage("appLanguage") private var appLanguage = "system"

    private var appLocale: Locale {
        switch appLanguage {
        case "en": return Locale(identifier: "en")
        case "ja": return Locale(identifier: "ja")
        default:   return Locale.autoupdatingCurrent
        }
    }

    init() {
        do {
            container = try Self.makeContainer()
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        // 起動時: 端末セッションは消えているので、全カードを CC 未起動状態にリセットする。
        MainActor.assumeIsolated {
            try? BoardStore(context: container.mainContext).resetAgentStates()
        }
    }

    /// SwiftData ストアの置き場所を決める。
    ///
    /// `FLEET_ROOT` が指定されているときは **その中に** ストアを置く。開発版を仕事用の Fleet と
    /// 並べて動かすときに、盤面(SwiftData)まで隔離できないと2プロセスが同じストアを同時に
    /// 書くことになる(SwiftData は複数プロセスからの同時書き込みを想定していない)。
    /// `~/.fleet` 側だけ分けてもストアが共通では意味がないので、1つの環境変数で全部が
    /// 分かれるようにしておく。
    ///
    /// 未指定なら従来どおり既定の場所(= 仕事で使っている盤面)。
    static func makeContainer() throws -> ModelContainer {
        let models: [any PersistentModel.Type] = [BoardColumn.self, Card.self, Channel.self, ClaudeProfile.self]
        let schema = Schema(models)
        guard let override = ProcessInfo.processInfo.environment["FLEET_ROOT"], !override.isEmpty else {
            return try ModelContainer(for: schema)
        }
        let dir = URL(fileURLWithPath: override, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = ModelConfiguration(url: dir.appending(path: "board.store"))
        NSLog("[Fleet] FLEET_ROOT=\(dir.path) — 隔離モードで起動します(盤面もこの中)")
        return try ModelContainer(for: schema, configurations: config)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                BoardView()
            }
            .frame(minWidth: 820, minHeight: 520)
            .preferredColorScheme(.dark)   // サイバー基調に統一(常時ダーク)
            .environment(\.locale, appLocale)   // アプリ言語のライブ切替
            .id(appLanguage)                    // 言語変更時に確実に再構築
        }
        .modelContainer(container)
    }
}
