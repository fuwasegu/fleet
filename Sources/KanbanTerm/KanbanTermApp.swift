import SwiftUI
import SwiftData
import KanbanKit

@main
struct KanbanTermApp: App {
    let container: ModelContainer

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
        }
        .modelContainer(container)
    }
}
