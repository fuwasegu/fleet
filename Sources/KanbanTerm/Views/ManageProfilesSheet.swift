import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import KanbanKit

/// Claude プロファイル(`CLAUDE_CONFIG_DIR` 切替用)の一覧管理シート。
/// 現状 Settings シーンが無いアプリなので、`NewCardSheet` から「プロファイルを管理…」で開く
/// スタンドアロンシートとして提供する。ラベル + configDir のペアを追加/編集/削除できる。
struct ManageProfilesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: BoardStore

    @State private var profiles: [ClaudeProfile] = []
    @State private var editing: ClaudeProfile?
    @State private var addingNew = false
    @State private var deleteTarget: ClaudeProfile?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if profiles.isEmpty {
                ContentUnavailableView(
                    "プロファイルがありません",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("「追加」から Claude の設定ディレクトリ(CLAUDE_CONFIG_DIR)を登録できます。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(profiles) { profile in
                        row(profile)
                    }
                }
                .listStyle(.inset)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 480, height: 360)
        .sheet(item: $editing) { profile in
            ProfileEditSheet(mode: .edit(profile)) { label, dir in
                do {
                    try store.updateProfile(profile, label: label, configDirPath: dir)
                    reload()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .sheet(isPresented: $addingNew) {
            ProfileEditSheet(mode: .add) { label, dir in
                do {
                    _ = try store.addProfile(label: label, configDirPath: dir)
                    reload()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert("プロファイルを削除しますか?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("削除", role: .destructive) {
                if let target = deleteTarget { delete(target) }
                deleteTarget = nil
            }
            Button("キャンセル", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("「\(deleteTarget?.label ?? "")」を削除します。このプロファイルを割り当てたカードは既定 (~/.claude) に戻ります。")
        }
        .task { reload() }
    }

    private var header: some View {
        HStack {
            Text("Claude プロファイル").font(.headline)
            Spacer()
            Button("追加…") { addingNew = true }
            Button("閉じる") { dismiss() }
        }
        .padding(16)
    }

    private func row(_ profile: ClaudeProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.label).font(.body)
                Text(profile.configDirPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button {
                editing = profile
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                deleteTarget = profile
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        do {
            profiles = try store.profiles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ profile: ClaudeProfile) {
        do {
            try store.deleteProfile(profile)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// プロファイルの追加/編集フォーム。ラベル(TextField) + 設定ディレクトリ(フォルダピッカー)。
private struct ProfileEditSheet: View {
    enum Mode {
        case add
        case edit(ClaudeProfile)
    }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let onSave: (String, String) -> Void

    @State private var label: String = ""
    @State private var configDirPath: String = ""
    @State private var picking = false

    private var isValid: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !configDirPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var title: String {
        switch mode {
        case .add: return "プロファイルを追加"
        case .edit: return "プロファイルを編集"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("ラベル").font(.caption).foregroundStyle(.secondary)
                TextField("例: 仕事用", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("設定ディレクトリ (CLAUDE_CONFIG_DIR)").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    (configDirPath.isEmpty ? Text("フォルダを選択") : Text(configDirPath))
                        .font(.callout)
                        .foregroundStyle(configDirPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("選択…") { picking = true }
                }
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 400)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                configDirPath = url.path
            }
        }
        .onAppear {
            if case .edit(let profile) = mode {
                label = profile.label
                configDirPath = profile.configDirPath
            }
        }
    }

    private func save() {
        onSave(label.trimmingCharacters(in: .whitespacesAndNewlines),
               configDirPath.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}
