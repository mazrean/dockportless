# Repository Guidelines — dockportless

compose spec 互換コンテナ構築コマンドをラップし、ポート自動割り当て＋ローカル URL ルーティングを提供する Zig 製 CLI ツール。

> Agent configuration is managed via [apm](https://github.com/microsoft/apm).
> Common conventions live in `mazrean/apm-plackage/common`; per-stack rules
> come from `mazrean/apm-plackage/{zig,goreleaser}`. Run `apm install` locally.

## Active Specs

- `specs/prd-dockportless.md` — ポート自動割り当て＋ローカルプロキシルーティング
- `specs/design-dockportless.md` — 技術設計（CLI, プロキシ, マッピング）

## Tech Stack

- Zig 0.15+, zig-clap (CLI), zig-yaml (YAML パース)
- SO_REUSEPORT, inotify/kqueue, std.net HTTP プロキシ

## Build & Test

- `zig build` — build CLI
- `zig build test` — run unit tests
- `goreleaser release --snapshot --clean` — cross-build snapshot for local testing

## Conventions

- Specs go under `specs/`. Use the `writing-feature-spec` / `writing-technical-design` /
  `writing-implementation-tasks` skills from `mazrean/agent-skills`.
- For multi-process socket sharing patterns, see `sharing-sockets-with-so-reuseport-in-zig`.
- For releases, see `releasing-zig-with-goreleaser`.
- Commit via the `committing-code` skill (Conventional Commits).
