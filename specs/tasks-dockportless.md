---
title: "dockportless - Implementation Tasks"
status: done
prd: prd-dockportless.md
design: design-dockportless.md
last-updated: 2026-03-08
---

# dockportless - Implementation Tasks

## Progress

- [x] Task 1: プロジェクト初期セットアップ
- [x] Task 2: Compose ファイルパーサー
- [x] Task 3: ポートアロケーター
- [x] Task 4: マッピングストア
- [x] Task 5: コマンドエグゼキューター
- [x] Task 6: `run` コマンド統合
- [x] Task 7: HTTP リバースプロキシ
- [x] Task 8: ファイルウォッチャー
- [x] Task 9: `proxy` コマンド統合
- [x] Task 10: GoReleaser セットアップ

---

## Task 1: プロジェクト初期セットアップ

- **Status**: done
- **Depends on**: none
- **Spec refs**: NFR-1, NFR-2
- **Scope**: `build.zig`, `build.zig.zon`, `src/main.zig`
- **Verify**: `zig build`

### What to do

Zig 0.15+ プロジェクトを初期化する。`build.zig` と `build.zig.zon` を作成し、zig-clap を依存に追加する。`src/main.zig` で `run` と `proxy` のサブコマンドをパースするエントリポイントを実装する。クロスコンパイル対応の target/optimize オプションを含める。

writing-zig-cli-tools スキルの Quick Start を参照。

### Done when

- [ ] `zig build` が成功する
- [ ] `zig build run -- --help` でサブコマンド一覧が表示される
- [ ] `zig build run -- run --help` と `zig build run -- proxy --help` が動作する

---

## Task 2: Compose ファイルパーサー

- **Status**: done
- **Depends on**: Task 1
- **Spec refs**: FR-10
- **Scope**: `src/compose.zig`
- **Verify**: `zig build test`

### What to do

compose ファイル（`docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml`）を検出し、YAML をパースしてトップレベルの `services` キー配下のサービス名一覧を返す。zig-yaml を依存に追加する。

design-dockportless.md の Compose Parser インターフェースに従う。

### Done when

- [ ] `zig build test` で compose パーサーのユニットテストが通る
- [ ] サンプル compose ファイルからサービス名が正しく抽出される
- [ ] compose ファイルが見つからない場合に適切なエラーを返す

---

## Task 3: ポートアロケーター

- **Status**: done
- **Depends on**: Task 1
- **Spec refs**: FR-2
- **Scope**: `src/port.zig`
- **Verify**: `zig build test`

### What to do

`bind(0)` + `getsockname()` を使って OS から未使用ポートを取得する関数を実装する。複数ポートの一括取得もサポートする。

design-dockportless.md の Port Allocator インターフェースに従う。

### Done when

- [ ] `zig build test` でポートアロケーターのユニットテストが通る
- [ ] 取得したポートが実際に未使用であること（bind で確認）
- [ ] 複数ポート取得で重複がないこと

---

## Task 4: マッピングストア

- **Status**: done
- **Depends on**: Task 1
- **Spec refs**: FR-6
- **Scope**: `src/mapping.zig`
- **Verify**: `zig build test`

### What to do

`$XDG_RUNTIME_DIR/dockportless/`（fallback: `/tmp/dockportless/`）に JSON 形式でマッピングを読み書きする。project 名をファイル名とし、サービス名・ポート番号・PID を記録する。

design-dockportless.md の Mapping Store インターフェースと Data Model に従う。

### Done when

- [ ] `zig build test` でマッピングストアのユニットテストが通る
- [ ] write → readAll のラウンドトリップが正しく動作する
- [ ] removeMapping でファイルが削除される

---

## Task 5: コマンドエグゼキューター

- **Status**: done
- **Depends on**: Task 1
- **Spec refs**: FR-1, FR-3
- **Scope**: `src/executor.zig`
- **Verify**: `zig build test`

### What to do

環境変数マップを受け取り、現在の環境変数にマージした上でユーザー指定のコマンドを `execve` で実行する。`<SERVICE_NAME>_PORT` 環境変数の設定ロジックを含む（サービス名はアッパーケース、ハイフンはアンダースコアに変換）。

design-dockportless.md の Command Executor インターフェースに従う。

### Done when

- [ ] `zig build test` でエグゼキューターのユニットテストが通る
- [ ] サービス名 `my-web` に対して `MY_WEB_PORT` 環境変数が設定される

---

## Task 6: `run` コマンド統合

- **Status**: done
- **Depends on**: Task 2, Task 3, Task 4, Task 5
- **Spec refs**: FR-1, FR-2, FR-3, FR-10
- **Scope**: `src/main.zig`, `src/run.zig`
- **Verify**: 手動テスト

### What to do

Task 2〜5 のコンポーネントを統合して `run` サブコマンドを実装する。design-dockportless.md の「`run` コマンドフロー」に従う。

1. compose ファイル検出・パース
2. ポート割り当て
3. マッピング書き込み
4. 環境変数設定＋コマンド実行
5. 終了時にマッピング削除（defer/シグナルハンドリング）

プロキシの起動は Task 9 で統合するため、この段階では省略。

### Done when

- [ ] `zig build run -- run myapp echo hello` でコマンドが実行される
- [ ] 実行中に `$XDG_RUNTIME_DIR/dockportless/myapp.json` が作成される
- [ ] `*_PORT` 環境変数が設定された状態でコマンドが実行される
- [ ] コマンド終了後にマッピングファイルが削除される

---

## Task 7: HTTP リバースプロキシ

- **Status**: done
- **Depends on**: Task 1
- **Spec refs**: FR-4, FR-5, FR-8, NFR-3
- **Scope**: `src/proxy.zig`
- **Verify**: `zig build test` + 手動テスト

### What to do

SO_REUSEPORT でポート 7355 に bind し、HTTP リクエストを受信して Host ヘッダー（`<service>.<project>.localhost`）に基づいてバックエンドサービスにリバースプロキシする。

- sharing-sockets-with-so-reuseport-in-zig スキルを参照して SO_REUSEPORT を設定
- Host ヘッダーのパース（`parseHost` 関数）
- マッピングからバックエンドポートを検索
- HTTP リクエスト/レスポンスの転送
- 未知のホストには 404 を返す

### Done when

- [ ] `zig build test` でプロキシのユニットテストが通る（Host パース等）
- [ ] ローカルで HTTP サーバーを起動し、プロキシ経由でアクセスできる
- [ ] 2 つのプロセスが同じポート 7355 で同時に listen できる

---

## Task 8: ファイルウォッチャー

- **Status**: done
- **Depends on**: Task 1
- **Spec refs**: FR-7
- **Scope**: `src/watcher.zig`
- **Verify**: `zig build test`

### What to do

Linux では inotify、macOS では kqueue を使ってマッピングディレクトリの変更を監視し、コールバックを呼び出す。ファイルの作成・変更・削除を検出する。

design-dockportless.md の File Watcher インターフェースに従う。

### Done when

- [ ] `zig build test` でウォッチャーのユニットテストが通る
- [ ] ファイル作成/変更/削除がコールバックで通知される
- [ ] Linux (inotify) と macOS (kqueue) の両方でコンパイルが通る

---

## Task 9: `proxy` コマンド統合 + `run` へのプロキシ統合

- **Status**: done
- **Depends on**: Task 6, Task 7, Task 8
- **Spec refs**: FR-4, FR-5, FR-7, FR-8, FR-9
- **Scope**: `src/main.zig`, `src/run.zig`, `src/proxy.zig`
- **Verify**: 手動テスト（E2E）

### What to do

1. `proxy` サブコマンド: マッピング読み込み＋プロキシ起動＋ファイル監視
2. `run` サブコマンドにプロキシのバックグラウンド起動を追加
3. ファイル監視によるマッピングのリアルタイム更新をプロキシに接続

design-dockportless.md の「`proxy` コマンドフロー」に従う。

### Done when

- [ ] `zig build run -- proxy` でプロキシが起動し、リクエストを転送できる
- [ ] `zig build run -- run myapp docker compose up` でプロキシ付きでコマンドが実行される
- [ ] 2 プロジェクト同時起動で両方のサービスにルーティングできる
- [ ] プロジェクト追加時にファイル監視で自動的にルーティングが更新される

---

## Task 10: GoReleaser セットアップ

- **Status**: done
- **Depends on**: Task 9
- **Spec refs**: NFR-1, NFR-2
- **Scope**: `.goreleaser.yaml`, `.github/workflows/release.yml`
- **Verify**: `goreleaser check`

### What to do

releasing-zig-with-goreleaser スキルを参照して GoReleaser を設定する。

- Zig クロスコンパイルビルド（linux/amd64, linux/arm64, darwin/amd64, darwin/arm64）
- Homebrew tap
- apt/yum/apk パッケージ
- GitHub Releases

### Done when

- [ ] `goreleaser check` が成功する
- [ ] GitHub Actions でタグプッシュ時にリリースが実行される設定がある
- [ ] Homebrew, apt, yum, apk の設定が含まれている
