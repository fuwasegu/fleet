# Fleet

並走する Claude Code Agent を「艦隊」として率いる、カンバンボード × Terminal の macOS アプリ。複数の Claude Code セッションを同時に走らせる際の「どのセッションが何をやっているか」を、カンバン上のカード＋Agent状態で一望するためのツール。

🌐 **[fuwasegu.github.io/fleet](https://fuwasegu.github.io/fleet/)** · 📦 **[Download (Releases)](https://github.com/fuwasegu/fleet/releases/latest)**

- 全体仕様: [`SPECIFICATION.md`](SPECIFICATION.md)
- 形式検証モデル (UI/ライフサイクル): [`kanban_ui.fsl`](kanban_ui.fsl)
- 設計ドキュメント: [`docs/superpowers/specs/`](docs/superpowers/specs/)

## インストール

要件: **macOS 26+**。

**Homebrew（推奨）** — Gatekeeper の手動回避も不要:

```sh
brew install --cask fuwasegu/tap/fleet
```

**手動** — [Releases](../../releases/latest) から `Fleet.app.zip` を DL・展開し `Fleet.app` を `/Applications` へ。

> ⚠️ 手動導入は **未署名 / 未 notarize** のため初回起動が Gatekeeper に弾かれます。**右クリック → 開く**、または `xattr -dr com.apple.quarantine /Applications/Fleet.app`。
> （Homebrew 版は cask が自動で検疫属性を除去します）

## 現在の実装状況

**実装済み（スライス1〜4）**
- カンバンボード: 列(状態)の追加・リネーム・削除・**色変更**、カードの追加・編集(モーダル)・削除(確認付き)
- カードの**ドラッグ&ドロップ**（列間移動＋並び替え、`DragGesture`ベース）／SwiftData 永続化
- **ターミナル**（SwiftTerm）: カードから全画面モーダルで起動、外クリック/Escで閉じる、閉じてもセッション保持
- **新規カード作成ショートカット**: 作業ディレクトリ GUI 選択・Agent(Claude)自動起動・危険モードスキップ
- **Agent状態の実検出**: Idle / Working / Blocked / Done（端末タイトル＋バッファ走査）
- **cwd 追従**（`proc_pidinfo`）、既存カードの cwd 手動変更
- **caffeinate** トグル（秒数入力・プロセス終了で自動OFF）
- **Markdownプレビュー**（ターミナルの上層に表示）
- **GitHub PRリンク**（`gh` で現在ブランチのPRを取得）
- **トークン使用量ダッシュボード**（`~/.claude/projects` を横断集計）

**未実装（BACKLOG.md 参照）**
- アプリ再起動後のセッション自動再開（正確な `--resume <session-id>`）
- 一度も開いていないカードの状態表示（バックグラウンド PTY）
- Unknown（素シェル/非claude）のプロセス識別
- 対応エージェントは Claude Code のみ（Codex 非対応）

## 構成

- `Sources/KanbanKit/` — Models (SwiftData) と BoardStore（ロジック層、フレームワーク）
- `Sources/KanbanTerm/` — SwiftUI アプリ（App / Views）
- `Tests/KanbanKitTests/` — BoardStore の Swift Testing 単体テスト（FSL 不変条件に対応）

## ビルド / テスト

Xcode プロジェクトは [XcodeGen](https://github.com/yonaskolb/XcodeGen) で `project.yml` から生成する（`.xcodeproj` は git 管理外）。

```sh
brew install xcodegen           # 未導入の場合
xcodegen generate               # Fleet.xcodeproj を生成
open Fleet.xcodeproj            # Xcode で開く

# CLI ビルド / テスト
xcodebuild build -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS'
xcodebuild test  -project Fleet.xcodeproj -scheme Fleet -destination 'platform=macOS'
```

## リリース

`v*` タグを push すると GitHub Actions（`.github/workflows/release.yml`）が Release ビルド →
`Fleet.app.zip` 生成 → GitHub Release 作成まで自動実行する。

```sh
# project.yml の MARKETING_VERSION も合わせて更新してから
git tag v0.2.0 && git push origin v0.2.0
```

- 手動でビルドだけ検証したい場合は Actions から `Release` を **workflow_dispatch** 実行（Release は作らず zip を artifact 出力）。
- リポジトリ secret に `TAP_GITHUB_TOKEN`（`fuwasegu/homebrew-tap` へ push 可能な PAT）を登録すると、Homebrew cask の version / sha256 も自動更新される。

### コード署名（自己署名）

配布ビルドは **自己署名の安定した証明書**で署名する。これにより macOS の TCC が権限付与
（フルディスクアクセス等）を安定した identity に紐付けて記憶し、更新のたびに権限確認が
再表示されるのを防ぐ（未署名だと毎回聞かれる）。Gatekeeper 対策ではない（notarize は別途 #4）。

- CI は secret `SIGNING_CERT_P12_BASE64` / `SIGNING_CERT_PASSWORD` があれば
  `scripts/sign-app.sh` で署名する（未設定なら未署名のまま継続）。
- 署名鍵（`.p12`）はリポジトリに置かない。ローカル控えは `~/Library/Application Support/Fleet/signing/`。
- 同じ証明書で署名し続ける限り Designated Requirement が一定になり、ユーザーの権限付与が維持される。
  証明書を作り直すと DR が変わり、ユーザーは一度だけ再付与が必要。

要件: macOS 26+, Xcode 26+, Swift 6。開発ツールとして **非サンドボックス**で動かす想定（後続スライスのプロセス列挙のため）。
