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

/// 集計期間。cutoff より前は集計しない(nil = 全期間)。
enum UsagePeriod: String, CaseIterable, Identifiable {
    case today, week, month, all
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .today: return "今日"
        case .week:  return "今週"
        case .month: return "今月"
        case .all:   return "全期間"
        }
    }

    /// 集計の開始時刻(nil = 全期間)。ローカルタイムの区切り。
    func cutoff(now: Date = Date()) -> Date? {
        let cal = Calendar.current
        switch self {
        case .all:   return nil
        case .today: return cal.startOfDay(for: now)
        case .week:  return cal.dateInterval(of: .weekOfYear, for: now)?.start
        case .month: return cal.dateInterval(of: .month, for: now)?.start
        }
    }
}

/// Claude Code の全セッション transcript(~/.claude/projects/**/*.jsonl)から usage を集計する。
/// ブロッキングなので main 以外から呼ぶこと。ローカル推定であり実請求の根拠にはしない。
enum TokenUsageService {
    static func aggregate(since cutoff: Date?) -> TokenUsage {
        var u = TokenUsage()
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: base) else { return u }

        // UTC ISO 文字列で行タイムスタンプと直接比較する(Date パースより安価)。
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let cutoffISO: String? = cutoff.map { isoFormatter.string(from: $0) }

        for case let path as String in enumerator where path.hasSuffix(".jsonl") {
            let full = (base as NSString).appendingPathComponent(path)

            // 期間指定時: ファイルの最終更新が cutoff より前なら全行が期間外なので丸ごとスキップ(高速化)。
            if let cutoff,
               let mtime = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date,
               mtime < cutoff {
                continue
            }
            guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { continue }

            var counted = false
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let cutoffISO {
                    guard let ts = obj["timestamp"] as? String, ts >= cutoffISO else { continue }
                }
                let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
                    ?? obj["usage"] as? [String: Any]
                guard let usage else { continue }
                u.inputTokens   += (usage["input_tokens"] as? Int) ?? 0
                u.outputTokens  += (usage["output_tokens"] as? Int) ?? 0
                u.cacheCreation += (usage["cache_creation_input_tokens"] as? Int) ?? 0
                u.cacheRead     += (usage["cache_read_input_tokens"] as? Int) ?? 0
                counted = true
            }
            if counted { u.sessions += 1 }
        }
        return u
    }
}

struct TokenDashboard: View {
    @State private var usage = TokenUsage()
    @State private var loading = true
    @State private var period: UsagePeriod = .week

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("トークン使用量").font(.headline)
            Text("Claude Code 全セッション横断").font(.caption).foregroundStyle(.secondary)

            Picker("期間", selection: $period) {
                ForEach(UsagePeriod.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if loading {
                ProgressView().frame(maxWidth: .infinity).frame(height: 130)
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
        .onChange(of: period) { _, _ in reload() }
    }

    private func reload() {
        loading = true
        let cutoff = period.cutoff()
        Task {
            let u = await Task.detached { TokenUsageService.aggregate(since: cutoff) }.value
            usage = u
            loading = false
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: Int, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value.formatted()).monospacedDigit()
        }
        .font(.callout)
        .fontWeight(bold ? .bold : .regular)
    }
}
