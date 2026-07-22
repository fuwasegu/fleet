<p align="center">
  <img src="docs/assets/icon.png" width="120" height="120" alt="Fleet icon">
</p>

<h1 align="center">Fleet</h1>

<p align="center">
  複数の Claude Code エージェントを「艦隊」として率いる、カンバン × ターミナルの macOS アプリ。<br>
  どのエージェントが動作中か・承認待ちか・完了したかを、ターミナルを開かずに一望。
</p>

<p align="center">
  <a href="https://fuwasegu.github.io/fleet/">Website</a> ·
  <a href="https://github.com/fuwasegu/fleet/releases/latest">ダウンロード</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26+-blue" alt="macOS 26+">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT">
</p>

## インストール

```sh
brew install --cask fuwasegu/tap/fleet
```

要件は **macOS 26+**。または [Releases](https://github.com/fuwasegu/fleet/releases/latest) から `Fleet.app.zip` を入手。

## スクリーンショット

<img src="docs/assets/hero.png" alt="Fleet ボード">

## 特徴

- **本当に協調する Agent 群 (A2A)** — カードを曲線でつなぐと、その Agent 群が1つの文脈チャンネルに入る。同梱のローカル MCP サーバ経由で:
  - **共有メモリ** — `fleet_recall` / `fleet_remember`。種別(decision/blocker/artifact/question)と参照(ファイル/PR)を付与、「前回以降の新着」も取得可
  - **仲間のライブ状態** — `fleet_peers` で各 agent の状態(working/blocked/idle/done)・branch・PR・詰まっている内容が見える
  - **push と引き継ぎ** — `fleet_message` / `fleet_handoff` が相手の手が空いた瞬間にセッションへ直接届く(読まれないかもしれないノートではなく)
  - **衝突回避** — `fleet_claim` / `fleet_release` の advisory ロックで、同じリポジトリを触る agent 同士のファイル衝突を防ぐ
  - **盤面の操作** — `fleet_create_card` / `fleet_move_card` / `fleet_board`。agent がサブタスクを実カードとして切り出し(チャンネルに自動参加)、委譲できる

  並走する Agent が重複作業をやめて協調し始める。すべてローカル完結（クラウド不要）。
- **エージェントの状態を一目で** — 動作中 / 承認待ち / 完了 / 待機 を各ターミナルから自動検出（OSC タイトル + 構造照合、herdr 方式）。承認待ちカードにはエージェントの *実際の問い* を表示。
- **Claude Code と Codex** — カード毎にエージェント種別を選べる。どちらも A2A ツールが自動配線され（Claude は `--mcp-config`、Codex はカード毎の `CODEX_HOME`/`config.toml`）、種別ごとの状態検知が効く。（Codex 対応は新機能。不具合は報告歓迎）
- **カードごとにフル装備のターミナル** — 各カードから本物のターミナル（SwiftTerm）を全画面起動。閉じてもセッションは動き続ける。
- **過去セッションから再開** — 以前の Claude Code セッションを直近会話のプレビュー付きで選んで `claude --resume`。誤ったセッションを掴まない。
- **各カードに文脈を集約** — 作業ディレクトリ・git ブランチ・紐づく GitHub PR。Mermaid 図とシンタックスハイライト対応の Markdown プレビュー（完全オフライン）。
- **自分好みに** — ターミナルの配色テーマとフォント、トークン使用量ダッシュボード（今日 / 今週 / 今月 / 全期間）。
- **動くカンバン** — カードの列間移動、列の並べ替え、列ごとのアクセントカラー。
- **英語 / 日本語** — システム言語に追従。

## 要件

- macOS 26 以降
- [Claude Code](https://claude.com/claude-code)（各カードの中で動かすエージェント本体）

## 開発

Fleet は非サンドボックスの SwiftUI アプリ。Xcode プロジェクトは `project.yml` から [XcodeGen] で生成（`.xcodeproj` は git 管理外）。

```sh
brew install xcodegen
xcodegen generate
xcodebuild build -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS'
xcodebuild test  -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS'
```

<details>
<summary>リリース</summary>

`v*` タグを push すると、GitHub Actions がビルド → 自己署名 → GitHub Release 公開 → Homebrew cask 更新 まで自動実行する。

```sh
# project.yml の MARKETING_VERSION を上げてから:
git tag v1.2.3 && git push origin v1.2.3
```

配布ビルドは **自己署名**（notarize なし）。これにより更新をまたいで権限付与が維持され、Homebrew 版は cask がインストール時に検疫属性を除去する。詳細は [`docs/`](docs/) と [`docs/superpowers/specs/`](docs/superpowers/specs/)。

</details>

## ライセンス

MIT — [LICENSE](LICENSE) を参照。

[XcodeGen]: https://github.com/yonaskolb/XcodeGen
