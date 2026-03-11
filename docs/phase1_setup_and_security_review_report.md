# Phase 1 完了レポート: Ghost OS セキュリティレビュー・セットアップ・導入

## 基本情報

- **実施日**: 2026-03-11
- **環境**: macOS 25.2.0 (Darwin), Apple Silicon (arm64)
- **対象リポジトリ**: https://github.com/ghostwright/ghost-os
- **バージョン**: v2.1.0
- **ライセンス**: MIT

## 概要

Ghost OS（macOS 上のあらゆる GUI アプリを AI エージェントから操作可能にする MCP サーバー）を、セキュリティ観点でレビューした上でクローン・インストール・セットアップを実施した。併せて、この一連のワークフローを再利用可能なスキル `/repo-security-clone` として整備した。

## 実施内容

### 1. セキュリティレビュー

クローン前に以下を `gh` CLI 経由で精査:

| チェック項目 | 結果 |
|---|---|
| ライセンス | MIT（問題なし） |
| 外部依存 | `AXorcist`（macOS Accessibility ラッパー、steipete氏作）のみ。不審なパッケージなし |
| ビルドスクリプト (`scripts/build-release.sh`) | ネットワークアクセス・隠しダウンロード・難読化コードなし |
| Vision サイドカー (`vision-sidecar/server.py`) | ローカル推論のみ、外部データ送信なし |
| インストールフック | `postinstall` 等の不審なフック なし |
| CI/CD | `.github/workflows/` なし（CI 未設定） |
| **総合判定** | **問題なし** |

### 2. クローン

```
git clone https://github.com/ghostwright/ghost-os.git
→ /Users/kazuyaegusa/KEWORK/ghost-os/
```

- コミット数: 60
- Swift ソースファイル: 21 ファイル / 7,740 行
- 全変更量: 40 ファイル, 8,217 行追加

### 3. Homebrew インストール・セットアップ

```bash
brew install ghostwright/ghost-os/ghost-os
ghost setup
```

`ghost setup` で自動設定された項目:

| 項目 | 状態 |
|---|---|
| Accessibility 権限 | 付与済み（19 アプリ読み取り可能） |
| Screen Recording 権限 | 付与済み |
| MCP 設定 | 自動設定済み（auto-approved） |
| バンドルレシピ | 4件インストール（gmail-send, slack-send, arxiv-download, finder-create-folder） |
| Vision 環境 | Python venv 作成済み、mlx/mlx-vlm インストール済み |
| ShowUI-2B モデル | ダウンロード済み（~2.8 GB） |

### 4. `ghost doctor` による検証

```
[ok] Accessibility: granted
[ok] Screen Recording: granted
[ok] Processes: no ghost MCP processes running
[ok] MCP Config: ghost-os configured
[ok] Recipes: 4 installed
[ok] AX Tree: 19/19 apps readable
[ok] ghost-vision: /opt/homebrew/bin/ghost-vision
[!]  ShowUI-2B model: not found (パス検出の問題、実ファイルは存在)
[ok] Vision Sidecar: not running (auto-starts when needed)
```

### 5. スキル化

ワークフロー全体を `/repo-security-clone` スキルとして整備:

- ファイル: `~/.claude/skills/repo-security-clone/SKILL.md`
- `kazuyaegusa/claude-skills` リポに push 済み
- 全デバイスへ launchd 自動同期（5分間隔）

## テスト結果

```
swift test → ビルドエラー
Tests/GhostOSTests/LocatorBuilderTests.swift:4:8: error: no such module 'Testing'
```

- Swift Testing フレームワーク（Swift 6.2 の `import Testing`）が現在のツールチェーンで未対応
- テスト自体は LocatorBuilder のユニットテスト 1 ファイルのみ
- **本体のビルド (`swift build`) は Homebrew 経由で成功済み**

## プロジェクト構成

```
ghost-os/
├── Sources/
│   ├── GhostOS/           # ライブラリ本体
│   │   ├── Actions/       # クリック・タイプ・スクロール等の操作
│   │   ├── Common/        # 型定義
│   │   ├── MCP/           # MCP サーバー・ツール定義・ディスパッチ
│   │   ├── Perception/    # AX Tree 読み取り・アノテーション
│   │   ├── Recipes/       # レシピエンジン
│   │   ├── Screenshot/    # スクリーンキャプチャ
│   │   └── Vision/        # ShowUI-2B 連携・CDP ブリッジ
│   └── ghost/             # CLI エントリポイント (setup, doctor)
├── Tests/GhostOSTests/    # ユニットテスト
├── recipes/               # バンドルレシピ (JSON)
├── vision-sidecar/        # Python Vision サーバー
├── scripts/               # ビルドスクリプト
└── docs/                  # ドキュメント
```

## 発見された問題・注意点

1. **ShowUI-2B モデルパス検出**: `ghost doctor` がモデルを検出できない（実ファイルは `~/.ghost-os/models/ShowUI-2B/` に存在）。`ghost_ground` 初回呼び出し時に自動起動するため実用上は問題なし
2. **Swift Testing 互換性**: `import Testing` が現在のツールチェーンで利用不可。テスト実行には Swift 6.2 の正式リリース版が必要
3. **HuggingFace 認証**: モデルダウンロード時に未認証警告。`HF_TOKEN` 設定でレート制限回避可能

## 次フェーズへの申し送り

- Ghost OS の実運用テスト（Gmail 送信、Slack 操作、arXiv ダウンロード等）
- ShowUI-2B Vision グラウンディングの動作検証
- カスタムレシピの作成・チーム共有フローの確立
- `/repo-security-clone` スキルの実運用フィードバック収集
