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
            container = try ModelContainer(for: BoardColumn.self, Card.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        // 起動時: 端末セッションは消えているので、全カードを CC 未起動状態にリセットする。
        MainActor.assumeIsolated {
            try? BoardStore(context: container.mainContext).resetAgentStates()
        }
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
