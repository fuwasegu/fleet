import SwiftUI
import AppKit

/// ターミナルの配色テーマ(背景/文字/カーソル)。ANSI16色一括APIは SwiftTerm に無いため基本3色。
struct TermTheme: Identifiable, Hashable {
    let id: String       // UserDefaults 保存キー
    let name: String
    let bg: String
    let fg: String
    let caret: String

    static let all: [TermTheme] = [
        .init(id: "midnight",  name: "Midnight",       bg: "0E0F11", fg: "CBCDD4", caret: "7FD962"),
        .init(id: "solarized", name: "Solarized Dark", bg: "002B36", fg: "839496", caret: "93A1A1"),
        .init(id: "dracula",   name: "Dracula",        bg: "282A36", fg: "F8F8F2", caret: "FF79C6"),
        .init(id: "nord",      name: "Nord",           bg: "2E3440", fg: "D8DEE9", caret: "88C0D0"),
        .init(id: "light",     name: "Light",          bg: "FFFFFF", fg: "1A1A1A", caret: "0A84FF"),
    ]
    static let `default` = all[0]
    static func by(id: String) -> TermTheme { all.first { $0.id == id } ?? .default }
}

/// ターミナルのフォント設定。UserDefaults に永続化し、既存/新規セッション双方へ適用する。
enum TerminalSettings {
    static let fontNameKey = "terminalFontName"     // "" = システム等幅(SF Mono)
    static let fontSizeKey = "terminalFontSize"
    static let themeKey    = "terminalThemeID"
    static let systemSentinel = ""                  // システム等幅を表す番兵
    static let defaultSize: Double = 12

    static func resolvedTheme() -> TermTheme {
        TermTheme.by(id: UserDefaults.standard.string(forKey: themeKey) ?? TermTheme.default.id)
    }

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

extension NSColor {
    /// "RRGGBB" 16進から生成(失敗時は黒)。
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// ツールバーから開くフォント設定ポップオーバー。変更は即座に開いているターミナルへ反映。
struct TerminalSettingsPopover: View {
    let sessions: TerminalSessions

    @AppStorage(TerminalSettings.fontNameKey) private var fontName = TerminalSettings.systemSentinel
    @AppStorage(TerminalSettings.fontSizeKey) private var fontSize = TerminalSettings.defaultSize
    @AppStorage(TerminalSettings.themeKey) private var themeID = TermTheme.default.id

    private let families = TerminalSettings.monospacedFamilies()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ターミナル").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("テーマ").font(.caption).foregroundStyle(.secondary)
                Picker("テーマ", selection: $themeID) {
                    ForEach(TermTheme.all) { theme in
                        HStack(spacing: 6) {
                            swatch(theme)
                            Text(theme.name)
                        }.tag(theme.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

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

            // プレビュー(テーマ配色 + 選択フォント)
            let theme = TermTheme.by(id: themeID)
            HStack(spacing: 0) {
                Text("agent ~/project ▸ ").foregroundStyle(Color(hex: theme.fg)!)
                Text("$ claude").foregroundStyle(Color(hex: theme.caret)!)
            }
            .font(Font(TerminalSettings.font(name: fontName, size: fontSize)))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: theme.bg)!, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
        .frame(width: 280)
        .onChange(of: fontName) { _, _ in sessions.applyFont() }
        .onChange(of: fontSize) { _, _ in sessions.applyFont() }
        .onChange(of: themeID) { _, _ in sessions.applyTheme() }
    }

    private func swatch(_ theme: TermTheme) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(hex: theme.bg)!)
            .frame(width: 20, height: 14)
            .overlay(
                Circle().fill(Color(hex: theme.caret)!).frame(width: 5, height: 5),
                alignment: .center
            )
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.15)))
    }
}
