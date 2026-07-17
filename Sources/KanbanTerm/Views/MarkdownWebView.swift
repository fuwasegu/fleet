import SwiftUI
import WebKit

/// WKWebView ベースの Markdown プレビュー。
/// marked.js で描画し、```mermaid は mermaid.js、その他コードは highlight.js でハイライトする。
/// (dev ツールなのでスクリプトは CDN から取得。オフラインだと図/装飾は出ないが本文は表示される)
struct MarkdownWebView: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.underPageBackgroundColor = NSColor(red: 0x12/255, green: 0x15/255, blue: 0x18/255, alpha: 1)
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(markdown, into: web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.load(markdown, into: web)
    }

    final class Coordinator {
        private var last: String?
        func load(_ md: String, into web: WKWebView) {
            guard md != last else { return }
            last = md
            // baseURL は nil(不透明オリジン)。ローカルの Markdown が実在ホストのオリジンを
            // 名乗る origin-confusion を防ぐ。CDN スクリプトは crossorigin=anonymous + CORS(*) で読める。
            web.loadHTMLString(MarkdownHTML.page(markdown: md), baseURL: nil)
        }
    }
}

/// Markdown を埋め込んだ HTML ページを生成する。
/// レンダリング用ライブラリ(marked / highlight.js / mermaid / DOMPurify)はアプリ同梱の
/// ローカルアセットをインライン展開する。ネットワーク不要・CDN 非依存・オフラインで動作する。
enum MarkdownHTML {
    static func page(markdown: String) -> String {
        // JSON 文字列に埋め込む。JSONEncoder は "<" を素通しするため、Markdown 内の
        // "</script>" がインライン script を途中終了させ HTML 注入を許す。"<" を < に
        // 逃がして script ブレイクアウトを防ぐ(U+2028/2029 も JS 文字列を壊すため合わせて逃がす)。
        let json = (try? String(data: JSONEncoder().encode(markdown), encoding: .utf8))?
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            ?? "\"\""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(asset("github-dark.min", "css"))</style>
        <style>\(css)</style>
        <script>\(js("marked.min"))</script>
        <script>\(js("highlight.min"))</script>
        <script>\(js("mermaid.min"))</script>
        <script>\(js("purify.min"))</script>
        </head><body><div id="content"></div>
        <script>
        window.addEventListener('load', function () {
          const md = \(json);
          try { marked.setOptions({ breaks: true, gfm: true }); } catch (e) {}
          const el = document.getElementById('content');
          try {
            // 信頼できない Markdown 由来の HTML は DOMPurify で必ずサニタイズ(XSS 対策)
            const raw = marked.parse(md);
            el.innerHTML = DOMPurify.sanitize(raw, { USE_PROFILES: { html: true } });
          } catch (e) {
            const pre = document.createElement('pre'); pre.textContent = md; el.appendChild(pre); return;
          }
          // ```mermaid を図として描画するため div.mermaid に置換
          el.querySelectorAll('code.language-mermaid').forEach(function (code) {
            const div = document.createElement('div');
            div.className = 'mermaid';
            div.textContent = code.textContent;
            code.parentElement.replaceWith(div);
          });
          // 残りのコードブロックをハイライト
          el.querySelectorAll('pre code:not(.language-mermaid)').forEach(function (block) {
            try { hljs.highlightElement(block); } catch (e) {}
          });
          try {
            mermaid.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'strict' });
            mermaid.run({ querySelector: '.mermaid' });
          } catch (e) {}
        });
        </script>
        </body></html>
        """
    }

    /// 同梱アセットを文字列で読む(見つからなければ空)。
    private static func asset(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }

    /// 同梱 JS をインライン展開用に読む。ライブラリ内の "</script" が
    /// インライン script タグを閉じてしまわないよう無害化する。
    private static func js(_ name: String) -> String {
        asset(name, "js").replacingOccurrences(of: "</script", with: "<\\/script")
    }

    private static let css = """
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    body {
      margin: 0; padding: 28px 32px;
      background: #121518;
      color: #CBCDD4;
      font: 14px/1.7 -apple-system, "SF Pro Text", system-ui, sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    #content { max-width: 820px; margin: 0 auto; }
    h1, h2, h3, h4 { color: #F2F3F5; font-weight: 700; line-height: 1.3; margin: 1.6em 0 0.6em; }
    h1 { font-size: 1.7em; border-bottom: 1px solid #2A2F35; padding-bottom: 0.3em; }
    h2 { font-size: 1.35em; border-bottom: 1px solid #22262B; padding-bottom: 0.25em; }
    h3 { font-size: 1.12em; }
    h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }
    p { margin: 0.7em 0; }
    a { color: #6FB0FF; text-decoration: none; }
    a:hover { text-decoration: underline; }
    strong { color: #EDEEF0; }
    ul, ol { padding-left: 1.5em; margin: 0.6em 0; }
    li { margin: 0.25em 0; }
    blockquote {
      margin: 0.9em 0; padding: 0.4em 1em;
      border-left: 3px solid #7FD962; background: #171B1B; color: #9AA1A9;
      border-radius: 0 6px 6px 0;
    }
    code {
      font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.9em;
      background: #1B2024; padding: 0.15em 0.4em; border-radius: 4px; color: #E6C07B;
    }
    pre {
      background: #0E0F11 !important; border: 1px solid #22262B; border-radius: 10px;
      padding: 14px 16px; overflow-x: auto; margin: 1em 0;
    }
    pre code { background: none; padding: 0; color: inherit; font-size: 0.86em; line-height: 1.6; }
    .mermaid {
      background: #0E0F11; border: 1px solid #22262B; border-radius: 10px;
      padding: 16px; margin: 1em 0; text-align: center;
    }
    table { border-collapse: collapse; margin: 1em 0; display: block; overflow-x: auto; }
    th, td { border: 1px solid #2A2F35; padding: 7px 12px; }
    th { background: #1B2024; color: #EDEEF0; font-weight: 600; }
    tr:nth-child(even) td { background: #15181B; }
    hr { border: none; border-top: 1px solid #2A2F35; margin: 1.6em 0; }
    img { max-width: 100%; border-radius: 8px; }
    """
}
