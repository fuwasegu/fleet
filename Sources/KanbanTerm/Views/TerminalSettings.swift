import SwiftUI
import AppKit

/// ターミナルのフォント設定。UserDefaults に永続化し、既存/新規セッション双方へ適用する。
enum TerminalSettings {
    static let fontNameKey = "terminalFontName"     // "" = システム等幅(SF Mono)
    static let fontSizeKey = "terminalFontSize"
    static let systemSentinel = ""                  // システム等幅を表す番兵
    static let defaultSize: Double = 12

    /// 現在の設定を解決した NSFont。
    static func resolvedFont() -> NSFont {
        let name = UserDefaults.standard.string(forKey: fontNameKey) ?? systemSentinel
        let size = UserDefaults.standard.object(forKey: fontSizeKey) as? Double ?? defaultSize
        return font(name: name, size: size)
    }

    static func font(name: String, size: Double) -> NSFont {
        if name == systemSentinel {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFont(name: name, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// インストール済みの等幅フォント名(固定ピッチのみ)。
    static func monospacedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let f = NSFont(name: family, size: 12) else { return false }
            return f.isFixedPitch
        }.sorted()
    }
}

/// ツールバーから開くフォント設定ポップオーバー。変更は即座に開いているターミナルへ反映。
struct TerminalSettingsPopover: View {
    let sessions: TerminalSessions

    @AppStorage(TerminalSettings.fontNameKey) private var fontName = TerminalSettings.systemSentinel
    @AppStorage(TerminalSettings.fontSizeKey) private var fontSize = TerminalSettings.defaultSize

    private let families = TerminalSettings.monospacedFamilies()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ターミナル").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("フォント").font(.caption).foregroundStyle(.secondary)
                Picker("フォント", selection: $fontName) {
                    Text("システム等幅 (SF Mono)").tag(TerminalSettings.systemSentinel)
                    Divider()
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("サイズ").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(fontSize)) pt").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $fontSize, in: 9...24, step: 1)
            }

            // プレビュー
            Text("agent ~/project ▸ $ claude")
                .font(Font(TerminalSettings.font(name: fontName, size: fontSize)))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "0E0F11")!, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(16)
        .frame(width: 280)
        .onChange(of: fontName) { _, _ in sessions.applyFont() }
        .onChange(of: fontSize) { _, _ in sessions.applyFont() }
    }
}
