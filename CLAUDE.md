# dockportless

compose spec 互換コンテナ構築コマンドをラップし、ポート自動割り当て＋ローカル URL ルーティングを提供する Zig 製 CLI ツール。

## Active Specs

- `specs/prd-dockportless.md` - ポート自動割り当て＋ローカルプロキシルーティング
- `specs/design-dockportless.md` - 技術設計（CLI, プロキシ, マッピング）

## Tech Stack

- Zig 0.15+, zig-clap (CLI), zig-yaml (YAML パース)
- SO_REUSEPORT, inotify/kqueue, std.net HTTP プロキシ

## Current Work

All tasks in specs/tasks-dockportless.md are complete (Task 1-10).
