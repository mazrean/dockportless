---
title: "dockportless - Technical Design"
status: draft
prd: prd-dockportless.md
last-updated: 2026-03-08
---

# dockportless - Technical Design

## TL;DR

サブコマンド方式の CLI で、compose ファイルの YAML パース→ポート割り当て→環境変数付きコマンド実行を行う `run` と、SO_REUSEPORT による共有リスンソケット＋ Host ヘッダーベースルーティングの HTTP リバースプロキシを起動する `proxy` の 2 コンポーネント構成。プロセス間の設定共有はファイルシステム上の JSON マッピングファイル＋ OS ファイル監視で実現。

## Decision Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| 言語 | Zig 0.15+ | シングルバイナリ、クロスコンパイル、低レベルソケット制御 |
| CLI パーサー | zig-clap | Zig エコシステム標準、comptime パラメータ定義 |
| YAML パース | zig-yaml | Zig ネイティブ YAML パーサー |
| プロキシ | 自前 HTTP リバースプロキシ | std.net ベース、外部依存なし |
| ソケット共有 | SO_REUSEPORT | 独立プロセス間でポート 1355 共有 |
| プロセス間通信 | JSON ファイル + inotify/kqueue | 外部依存なし、シンプル |
| マッピング保存場所 | `$XDG_RUNTIME_DIR/dockportless/` (fallback: `/tmp/dockportless/`) | 揮発性、再起動で自動クリーン |
| ポート取得 | bind(0) + getsockname | OS にポート割り当てを委任 |

## Component Overview

```text
┌─────────────────────────────────────────────────────┐
│                   dockportless CLI                    │
│  ┌─────────────┐                  ┌───────────────┐  │
│  │  run command │                  │ proxy command │  │
│  └──────┬──────┘                  └───────┬───────┘  │
│         │                                 │          │
│  ┌──────▼──────┐                  ┌───────▼───────┐  │
│  │ Compose     │                  │ Proxy Server  │  │
│  │ Parser      │                  │ (SO_REUSEPORT)│  │
│  └──────┬──────┘                  └───────┬───────┘  │
│         │                                 │          │
│  ┌──────▼──────┐     ┌──────────┐ ┌───────▼───────┐  │
│  │ Port        │────>│ Mapping  │<│ File Watcher  │  │
│  │ Allocator   │     │ Files    │ │ (inotify/     │  │
│  └──────┬──────┘     │ (JSON)   │ │  kqueue)      │  │
│         │            └──────────┘ └───────────────┘  │
│  ┌──────▼──────┐                                     │
│  │ Command     │                                     │
│  │ Executor    │                                     │
│  └─────────────┘                                     │
└─────────────────────────────────────────────────────┘
```

### CLI Entry Point

- **Responsibility**: サブコマンドのディスパッチ（`run`, `proxy`）
- **Location**: `src/main.zig`
- **Interface**: `pub fn main() !void`
- **Depends on**: zig-clap

### Compose Parser

- **Responsibility**: compose ファイルからサービス名一覧を抽出
- **Location**: `src/compose.zig`
- **Interface**: `pub fn parseServices(allocator, path) ![]const []const u8`
- **Depends on**: zig-yaml

### Port Allocator

- **Responsibility**: OS から未使用ポートを取得
- **Location**: `src/port.zig`
- **Interface**: `pub fn allocatePort() !u16`
- **Depends on**: std.posix (bind(0) + getsockname)

### Mapping Store

- **Responsibility**: project/service/port マッピングの読み書き
- **Location**: `src/mapping.zig`
- **Interface**: `pub fn write(project, services) !void`, `pub fn readAll(allocator) ![]Mapping`
- **Depends on**: std.fs, std.json

### Command Executor

- **Responsibility**: 環境変数を設定してユーザーコマンドを実行
- **Location**: `src/executor.zig`
- **Interface**: `pub fn exec(allocator, argv, env_map) !void`
- **Depends on**: std.process

### Proxy Server

- **Responsibility**: SO_REUSEPORT で 1355 番ポートを listen し、Host ヘッダーに基づいてリクエストを転送
- **Location**: `src/proxy.zig`
- **Interface**: `pub fn start(allocator, mappings) !void`
- **Depends on**: std.net, std.posix, File Watcher

### File Watcher

- **Responsibility**: マッピングディレクトリの変更を監視し、プロキシの設定をリアルタイム更新
- **Location**: `src/watcher.zig`
- **Interface**: `pub fn watch(allocator, dir_path, callback) !void`
- **Depends on**: Linux: inotify, macOS: kqueue

## Interface Contracts

### Compose Parser

```zig
/// compose ファイルからサービス名一覧を取得
pub fn parseServices(allocator: std.mem.Allocator, file_path: []const u8) ![]const []const u8 {
    // YAML をパースし、トップレベル "services" キーの子キー名を返す
}

/// compose ファイルを自動検出して返す
pub fn findComposeFile(allocator: std.mem.Allocator) ![]const u8 {
    // docker-compose.yml, docker-compose.yaml, compose.yml, compose.yaml の順に検索
}
```

### Port Allocator

```zig
/// OS から未使用ポートを 1 つ取得
pub fn allocatePort() !u16 {
    // 1. bind(0) で OS にポートを割り当てさせる
    // 2. getsockname() でポート番号を取得
    // 3. ソケットを close
    // 4. ポート番号を返す
    // ※ close〜実際の使用までの間に他プロセスがポートを取得するリスクあり（許容）
}

/// 複数ポートを一括取得
pub fn allocatePorts(allocator: std.mem.Allocator, count: usize) ![]u16 {
    // allocatePort を count 回呼び出す
}
```

### Mapping Store

```zig
pub const ServiceMapping = struct {
    service_name: []const u8,
    port: u16,
};

pub const ProjectMapping = struct {
    project_name: []const u8,
    services: []const ServiceMapping,
    pid: i32, // dockportless プロセスの PID（クリーンアップ用）
};

/// マッピングをファイルに書き込む
/// ファイル名: <runtime_dir>/dockportless/<project_name>.json
pub fn writeMapping(project: ProjectMapping) !void {}

/// 全マッピングを読み込む
pub fn readAllMappings(allocator: std.mem.Allocator) ![]ProjectMapping {}

/// マッピングファイルを削除
pub fn removeMapping(project_name: []const u8) !void {}
```

### Proxy Server

```zig
/// プロキシサーバーを起動（ブロッキング）
/// SO_REUSEPORT で :1355 に bind
pub fn start(allocator: std.mem.Allocator, initial_mappings: []const ProjectMapping) !void {}

/// Host ヘッダーから project_name と service_name を抽出
/// 形式: <service_name>.<project_name>.localhost:1355
fn parseHost(host: []const u8) ?struct { service: []const u8, project: []const u8 } {}
```

## Data Model

### Mapping File Format

ファイルパス: `$XDG_RUNTIME_DIR/dockportless/<project_name>.json`

```json
{
  "project_name": "myapp",
  "pid": 12345,
  "services": [
    { "service_name": "web", "port": 49152 },
    { "service_name": "api", "port": 49153 }
  ]
}
```

### ディレクトリ構造

```text
$XDG_RUNTIME_DIR/dockportless/
├── myapp.json
├── frontend.json
└── backend.json
```

## `run` コマンドフロー

```text
1. compose ファイルを検出（findComposeFile）
2. サービス名一覧を取得（parseServices）
3. サービスごとに未使用ポートを割り当て（allocatePorts）
4. マッピングファイルを書き込み（writeMapping）
5. プロキシサーバーをバックグラウンドスレッドで起動（proxy.start）
6. 環境変数 <SERVICE_NAME>_PORT=<port> を設定
7. ユーザー指定コマンドを exec（executor.exec）
8. コマンド終了時にマッピングファイルを削除（removeMapping）
```

## `proxy` コマンドフロー

```text
1. マッピングディレクトリの全ファイルを読み込み（readAllMappings）
2. SO_REUSEPORT でポート 1355 を listen
3. ファイル監視を開始（watcher.watch）
4. リクエスト受信 → Host ヘッダー解析 → マッピング検索 → リバースプロキシ
5. ファイル変更通知 → マッピングを再読み込み
```

## Open Questions

- [ ] zig-yaml は compose spec の YAML を十分にパースできるか？サービス名の抽出のみなので問題ないと思われるが要検証 (@mazrean)
- [ ] WebSocket 対応が必要な場合、HTTP CONNECT/Upgrade のハンドリングが追加で必要 (@mazrean)
- [ ] macOS で kqueue によるディレクトリ監視の粒度は十分か？（ファイル単位の通知が必要） (@mazrean)

---
<!-- Below this line = L4 (deep reference) -->

## Alternatives Considered

### YAML パーサー: 自前実装 vs zig-yaml

- **Approach**: サービス名抽出に必要な最小限の YAML パーサーを自前実装
- **Pros**: 外部依存ゼロ、バイナリサイズ最小
- **Cons**: YAML spec の edge case 対応が大変、メンテナンスコスト
- **Rejected because**: zig-yaml が十分に軽量で、自前実装のコストに見合わない

### プロセス間通信: Unix Domain Socket vs ファイル

- **Approach**: UDS で dockportless プロセス間を接続
- **Pros**: リアルタイム通知、双方向通信
- **Cons**: デーモンプロセスが必要、複雑度が大幅増
- **Rejected because**: ファイル＋inotify/kqueue で十分なリアルタイム性が得られ、シンプル

### プロキシ: iptables/nftables vs ユーザースペースプロキシ

- **Approach**: カーネルレベルのパケット転送
- **Pros**: 最高性能、ゼロコピー
- **Cons**: root 権限必須、Linux 限定、設定が複雑
- **Rejected because**: macOS 対応が必要、root 不要であるべき

## ADR Log

| Date | Decision | Context | Consequences |
|------|----------|---------|-------------|
| 2026-03-08 | JSON ファイル + fs watch for IPC | シンプルさ優先、デーモン不要 | ファイル I/O のオーバーヘッド（許容レベル） |
| 2026-03-08 | SO_REUSEPORT for port sharing | 独立プロセスで同じポートを共有 | 全プロセスが Host ルーティングテーブルを持つ必要あり |
| 2026-03-08 | bind(0) for port allocation | OS に空きポート管理を委任 | close→use 間の TOCTOU リスク（許容） |
