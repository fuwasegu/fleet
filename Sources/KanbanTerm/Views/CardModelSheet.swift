import SwiftUI
import KanbanKit

/// カードで使うモデルを後から変更する小さなシート。
///
/// `CardView` が既に大きいので別ファイルに置く。固定の選択肢ではなく自由入力にしているのは、
/// 新しいモデルが出るたびに Fleet を更新しないと使えない状態を避けるため
/// (`AgentLaunch.normalizedModel` の説明も参照)。
struct CardModelSheet: View {
    @Environment(\.dismiss) private var dismiss

    let agentKind: AgentKind
    /// 現在の指定(nil = 既定モデル)。
    let current: String?
    /// 正規化済みの値を受け取る。nil は「既定モデルに戻す」。
    let onSave: (String?) -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("モデルを変更").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 340)
                if !trimmed.isEmpty, !isValid {
                    Text("モデル名に使えない文字が含まれています (英数字と . _ - [ ] のみ)")
                        .font(.caption).foregroundStyle(.red)
                } else {
                    Text("空欄にすると CLI の既定モデルに戻ります。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Text("反映は次にこのカードのターミナルを起動したときからです。走っているセッションは起動時のモデルのままです。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 340, alignment: .leading)

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") {
                    onSave(AgentLaunch.normalizedModel(draft))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .onAppear { draft = current ?? "" }
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 空欄は「既定に戻す」なので妥当。入力があるときだけ文字集合を検査する。
    private var isValid: Bool { trimmed.isEmpty || AgentLaunch.isValidModelName(trimmed) }

    private var placeholder: String {
        agentKind == .claude ? "空欄 = 既定 (例: opus / sonnet / claude-opus-5)"
                             : "空欄 = 既定 (例: gpt-5-codex)"
    }
}
