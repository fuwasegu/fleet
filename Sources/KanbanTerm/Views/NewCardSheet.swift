import SwiftUI
import UniformTypeIdentifiers

/// カード新規作成ショートカット: 作業ディレクトリをGUIで選び、Agent自動起動/危険モードを選ぶ。
struct NewCardSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// (title, workingDirPath?, autoStartAgent, dangerSkip)
    let onCreate: (String, String?, Bool, Bool) -> Void

    @State private var title = ""
    @State private var directory: String?
    @State private var picking = false
    @State private var autoStart = false
    @State private var danger = false

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
                    Text(directory ?? "未選択")
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
                TextField(directory.map { ($0 as NSString).lastPathComponent } ?? "タイトル", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Agent (Claude) を最初から起動する", isOn: $autoStart)
            Toggle("危険モードをスキップ (--dangerously-skip-permissions)", isOn: $danger)
                .disabled(!autoStart)
                .padding(.leading, 18)
                .foregroundStyle(autoStart ? .primary : .secondary)

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("作成") {
                    onCreate(resolvedTitle, directory, autoStart, autoStart && danger)
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
