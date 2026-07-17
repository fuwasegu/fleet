import SwiftUI
import Foundation

struct TokenUsage: Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreation = 0
    var cacheRead = 0
    var sessions = 0
    var total: Int { inputTokens + outputTokens + cacheCreation + cacheRead }
}

/// Claude Code の全セッション transcript(~/.claude/projects/**/*.jsonl)から usage を集計する。
/// ブロッキングなので main 以外から呼ぶこと。ローカル推定であり実請求の根拠にはしない。
enum TokenUsageService {
    static func aggregate() -> TokenUsage {
        var u = TokenUsage()
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: base) else { return u }
        for case let path as String in enumerator where path.hasSuffix(".jsonl") {
            let full = (base as NSString).appendingPathComponent(path)
            guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            u.sessions += 1
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
                    ?? obj["usage"] as? [String: Any]
                guard let usage else { continue }
                u.inputTokens   += (usage["input_tokens"] as? Int) ?? 0
                u.outputTokens  += (usage["output_tokens"] as? Int) ?? 0
                u.cacheCreation += (usage["cache_creation_input_tokens"] as? Int) ?? 0
                u.cacheRead     += (usage["cache_read_input_tokens"] as? Int) ?? 0
            }
        }
        return u
    }
}

struct TokenDashboard: View {
    @State private var usage = TokenUsage()
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("トークン使用量").font(.headline)
            Text("Claude Code 全セッション横断").font(.caption).foregroundStyle(.secondary)

            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                row("入力", usage.inputTokens)
                row("出力", usage.outputTokens)
                row("キャッシュ作成", usage.cacheCreation)
                row("キャッシュ読取", usage.cacheRead)
                Divider()
                row("合計", usage.total, bold: true)
                Text("\(usage.sessions) セッション").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("再読み込み") { reload() }.controlSize(.small)
            }
            Text("※ ローカル推定。実請求の根拠にはしない。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
        .task { reload() }
    }

    private func reload() {
        loading = true
        Task {
            let u = await Task.detached { TokenUsageService.aggregate() }.value
            usage = u
            loading = false
        }
    }

    private func row(_ label: String, _ value: Int, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value.formatted()).monospacedDigit()
        }
        .font(.callout)
        .fontWeight(bold ? .bold : .regular)
    }
}
