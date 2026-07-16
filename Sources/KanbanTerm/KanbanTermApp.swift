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
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                BoardView()
            }
            .frame(minWidth: 820, minHeight: 520)
        }
        .modelContainer(container)
    }
}
