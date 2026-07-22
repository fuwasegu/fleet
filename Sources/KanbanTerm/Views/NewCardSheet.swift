import SwiftUI
import UniformTypeIdentifiers
import KanbanKit

/// カード新規作成ショートカット: 作業ディレクトリをGUIで選び、Agent種別/自動起動/危険モードを選ぶ。
struct NewCardSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// (title, workingDirPath?, autoStartAgent, dangerSkip, agentKind)
    let onCreate: (String, String?, Bool, Bool, AgentKind) -> Void

    @State private var title = ""
    @State private var directory: String?
    @State private var picking = false
    @State private var danger = false
    @State private var kind: AgentKind = .claude

    private var resolvedTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let dir = directory { return (dir as NSString).lastPathComponent }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新しいカード").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("作業ディレクトリ").font(.caption).foregroundStyle(.secondary)
                HStack {
                    (directory.map(Text.init) ?? Text("未選択"))
                        .font(.callout)
                        .foregroundStyle(directory == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("選択…") { picking = true }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("タイトル").font(.caption).foregroundStyle(.secondary)
                TextField(directory.map { ($0 as NSString).lastPathComponent } ?? String(localized: "タイトル"), text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("エージェント").font(.caption).foregroundStyle(.secondary)
                Picker("エージェント", selection: $kind) {
                    ForEach(AgentKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // カードを開くと Agent は自動起動・自動復帰するので、起動トグルは廃止。
            Toggle("権限確認をスキップ (自動承認)", isOn: $danger)

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("作成") {
                    onCreate(resolvedTitle, directory, true, danger, kind)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(resolvedTitle.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                directory = url.path
            }
        }
    }
}
