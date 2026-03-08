---
title: dockportless - Compose-Compatible Local Service Router
status: draft
priority: high
depends-on: []
last-updated: 2026-03-08
---

# dockportless - Compose-Compatible Local Service Router

## TL;DR

CLI ツールで、compose spec 互換のコンテナ構築コマンド（docker compose 等）をラップし、サービスごとに空きポートを自動割り当てした上で `<service>.<project>.localhost:1355` の URL でローカルアクセス可能にする。Zig 製シングルバイナリとして Linux・macOS に対応。

## Requirements

### Functional Requirements

#### ポート自動割り当て

- **FR-1**: `dockportless run <project_name> <command...>` 実行時、compose ファイルを解析して各サービス名を取得し、`<SERVICE_NAME>_PORT` 環境変数に未使用ポート番号を設定した上で指定コマンドを実行する SHALL。
  - Acceptance: compose ファイルに `web` と `api` サービスがある場合、`WEB_PORT` と `API_PORT` が設定され、各ポートが実際に未使用であること。

- **FR-2**: 未使用ポート番号は OS の機能（bind(0) 等）を使って動的に取得する SHALL。
  - Acceptance: 割り当てられたポートが他のプロセスと衝突しないこと。100 回連続実行で衝突ゼロ。

- **FR-3**: ユーザーは compose ファイル内で `${<SERVICE_NAME>_PORT:-<default_port>}` の形式でポート番号を参照できる SHALL。
  - Acceptance: compose ファイルに `${WEB_PORT:-8080}` と記述した場合、dockportless 経由で起動すると自動割り当てポートが使用され、直接 docker compose up した場合は 8080 が使用される。

#### プロキシサーバー

- **FR-4**: dockportless コマンド実行時に内部プロキシサーバーを起動し、`<service_name>.<project_name>.localhost:1355` の URL で各サービスにリクエストを転送する SHALL。
  - Acceptance: `curl http://web.myapp.localhost:1355/` が `WEB_PORT` で起動したサービスにルーティングされること。

- **FR-5**: 複数の dockportless プロジェクトが同時に実行される場合、SO_REUSEPORT を使用して同じポート 1355 で複数のプロキシサーバーを起動できる SHALL。
  - Acceptance: 2 つの dockportless プロジェクトを同時起動し、両方のプロジェクトのサービスに正しくルーティングされること。

- **FR-6**: 特定ディレクトリ下に project_name、service_name、ポート番号のマッピングを記録する SHALL。
  - Acceptance: dockportless 実行後、マッピングファイルが作成され、project_name・service_name・port の組が正しく記録されていること。

- **FR-7**: fsnotify でマッピングディレクトリを監視し、他の dockportless プロセスが追加・削除したプロキシ設定をリアルタイムで反映する SHALL。
  - Acceptance: プロジェクト A 実行中にプロジェクト B を起動すると、プロジェクト A のプロキシからもプロジェクト B のサービスにルーティングできること。反映まで 1 秒以内。

- **FR-8**: リクエストの Host ヘッダーを解析し、どの dockportless プロセスが受信してもマッピング情報に基づいて適切なポートに転送する SHALL。
  - Acceptance: SO_REUSEPORT によりどのプロセスにリクエストが到達しても、正しいサービスにルーティングされること。

#### プロキシ手動起動

- **FR-9**: `dockportless proxy` コマンドでプロキシサーバーのみを手動起動できる SHALL。
  - Acceptance: `dockportless proxy` 実行後、既存のマッピングファイルに基づいてプロキシが動作し、サービスにアクセスできること。

#### compose ファイル解析

- **FR-10**: compose spec 準拠の YAML ファイルからサービス名一覧を取得する SHALL。`docker-compose.yml`、`docker-compose.yaml`、`compose.yml`、`compose.yaml` を検索する。
  - Acceptance: 標準的な compose ファイルからサービス名が正しく抽出されること。

### Non-Functional Requirements

- **NFR-1**: Linux（x86_64, aarch64）および macOS（x86_64, aarch64）で動作する SHALL。
  - Metric: CI で全ターゲットのビルド・テストが成功。

- **NFR-2**: 動的リンクライブラリに依存しないシングルバイナリとして配布する SHALL。
  - Metric: `ldd` で "not a dynamic executable" または libc のみ依存。

- **NFR-3**: プロキシのリクエスト転送レイテンシが 5ms 以下（p99）である SHALL。
  - Metric: ローカルサービスへの 1000 リクエストで p99 < 5ms。

## User Stories

- 開発者として、複数のマイクロサービスをローカルで起動した際にポート番号を覚えずに URL でアクセスしたい。
  - Given compose ファイルに web・api・db の 3 サービスが定義されている、
    when `dockportless run myapp docker compose up` を実行する、
    then `web.myapp.localhost:1355` で web サービスに、`api.myapp.localhost:1355` で api サービスにアクセスできる。

- 開発者として、複数のプロジェクトを同時に開発したい。
  - Given プロジェクト A（frontend）とプロジェクト B（backend）がある、
    when 両方を `dockportless run` で起動する、
    then `web.frontend.localhost:1355` と `api.backend.localhost:1355` の両方にアクセスできる。
  - Given プロジェクト A を先に起動している、
    when プロジェクト B を後から起動する、
    then プロジェクト A のプロキシからもプロジェクト B のサービスにルーティングされる。

- 開発者として、マシン再起動後にプロキシだけ先に起動したい。
  - Given 以前のマッピングファイルが残っている、
    when `dockportless proxy` を実行する、
    then マッピングに基づくプロキシが起動し、後から `dockportless run` でサービスを起動するとアクセス可能になる。

- 開発者として、既存の compose ファイルを最小限の変更で使いたい。
  - Given 既存の compose ファイルでポートが固定されている、
    when `ports` を `${WEB_PORT:-8080}:8080` に変更する、
    then dockportless 経由でも直接 docker compose でも起動できる。

## Constraints

- Zig で実装する（最新の安定版を使用）
- compose ファイルの YAML パースのみ行い、コンテナ操作は一切行わない（ユーザー指定のコマンドに委任）
- プロキシポートは 1355 固定
- localhost ドメインのみ対応（DNS 設定不要）

## Non-Goals

- コンテナの作成・管理（docker compose 等のコマンドに委任）
- HTTPS/TLS 対応
- リモートホストへのプロキシ
- compose ファイルのバリデーション（サービス名取得のみ）
- Windows 対応
- GUI / Web UI
- サービスのヘルスチェック
- compose ファイルの自動生成・修正

## Open Questions

- [ ] マッピングファイルの保存場所は XDG_RUNTIME_DIR を使うべきか？ (@mazrean)
- [ ] プロキシは HTTP のみか、WebSocket も対応すべきか？ (@mazrean)
- [ ] dockportless run 終了時にマッピングファイルをクリーンアップするか？ (@mazrean)
- [ ] compose ファイルのパスをオプションで指定できるようにすべきか（`-f` オプション）？ (@mazrean)

---
<!-- Below this line = L4 (deep reference, loaded only when needed) -->

## Background

ローカル開発で docker compose を使う際、複数プロジェクトのポート衝突が頻繁に発生する。手動でポートを管理するのは煩雑で、プロジェクトごとに異なるポート番号を覚える必要がある。

Vercel の portless は、このポート管理の問題をローカル URL ルーティングで解決するアプローチを取っている。dockportless はこのコンセプトを compose spec 互換のコンテナ環境に適用し、`<service>.<project>.localhost` という直感的な URL でサービスにアクセスできるようにする。

Zig を選択する理由:
- シングルバイナリ配布が容易（動的リンク不要）
- クロスコンパイルが標準サポート
- 低レイテンシのプロキシ実装に適している
- SO_REUSEPORT 等の低レベルソケット操作が可能

## Edge Cases

| Case | Expected Behavior | Requirement |
|------|-------------------|-------------|
| compose ファイルが見つからない | エラーメッセージを表示して終了 | FR-10 |
| サービス名が環境変数名として不正（ハイフン含む等） | ハイフンをアンダースコアに変換、大文字化 | FR-1 |
| 同じ project_name で 2 回起動 | 既存マッピングを上書き | FR-6 |
| dockportless プロセスが異常終了 | マッピングファイルが残る。次回起動時に古いエントリを検出して削除 | FR-6, FR-7 |
| ポート 1355 が他のアプリに占有されている | エラーメッセージを表示して終了 | FR-5 |
| Host ヘッダーに未知のサービス名 | 404 レスポンスを返す | FR-8 |
| compose ファイルにサービスが 0 個 | 警告メッセージを表示、プロキシは起動するがルーティングなし | FR-10 |

## Research

### 類似ツール

- **Vercel portless**: ローカル開発用 URL ルーティング。Node.js ベース。compose 非対応。
- **Traefik**: Docker ラベルベースのリバースプロキシ。高機能だがセットアップが重い。
- **nginx-proxy (jwilder)**: Docker コンテナの自動プロキシ。Docker 専用で compose の外部ツールとしては使えない。

### localhost サブドメイン

RFC 6761 により `*.localhost` は常にループバックに解決される。主要ブラウザ（Chrome, Firefox, Safari）はこの動作をサポートしており、DNS 設定なしで `<service>.<project>.localhost` が利用可能。
