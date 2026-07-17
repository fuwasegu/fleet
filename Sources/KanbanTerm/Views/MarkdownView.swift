import SwiftUI
import Foundation

/// 依存なしの軽量 Markdown プレビュー(行ベース)。
/// 見出し / 箇条書き / 引用 / コードフェンス / 段落 に対応し、インライン(太字・リンク等)は
/// AttributedString(markdown:) に委譲する。README 程度の閲覧用途。
struct MarkdownView: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    block
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .textSelection(.enabled)
        }
    }

    private var blocks: [AnyView] {
        var result: [AnyView] = []
        var inCode = false
        var codeLines: [String] = []

        for raw in text.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    result.append(AnyView(codeBlock(codeLines.joined(separator: "\n"))))
                    codeLines = []
                }
                inCode.toggle()
                continue
            }
            if inCode { codeLines.append(raw); continue }

            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("### ")      { result.append(AnyView(heading(String(t.dropFirst(4)), .title3))) }
            else if t.hasPrefix("## ")  { result.append(AnyView(heading(String(t.dropFirst(3)), .title2))) }
            else if t.hasPrefix("# ")   { result.append(AnyView(heading(String(t.dropFirst(2)), .title))) }
            else if t.hasPrefix("> ")   { result.append(AnyView(quote(String(t.dropFirst(2))))) }
            else if t.hasPrefix("- ") || t.hasPrefix("* ") { result.append(AnyView(bullet(String(t.dropFirst(2))))) }
            else { result.append(AnyView(inline(raw).font(.body))) }
        }
        if inCode { result.append(AnyView(codeBlock(codeLines.joined(separator: "\n")))) }
        return result
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s) { return Text(a) }
        return Text(s)
    }

    private func heading(_ s: String, _ font: Font) -> some View {
        inline(s).font(font).fontWeight(.bold)
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            inline(s)
        }
        .font(.body)
    }

    private func quote(_ s: String) -> some View {
        inline(s)
            .font(.body)
            .italic()
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle().frame(width: 3).foregroundStyle(.secondary.opacity(0.5))
            }
    }

    private func codeBlock(_ s: String) -> some View {
        Text(s)
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}
