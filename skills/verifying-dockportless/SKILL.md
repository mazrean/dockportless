---
name: verifying-dockportless
description: Launches and verifies local dev environments using dockportless with worktree-unique project names. Use when starting docker compose services, checking service accessibility via proxy, or when developing across multiple git worktrees to avoid port collisions.
---

# Verifying with dockportless

Use this skill when you need to start a local development environment with `docker compose` (or compatible tools) via dockportless, and verify that services are accessible. Especially important when **developing in parallel across git worktrees** on the same machine.

## Quick Start

### 1. Derive worktree-unique project name

```bash
PROJECT_NAME="$(basename "$(git rev-parse --show-toplevel)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')"
```

### 2. Start services

```bash
dockportless run "$PROJECT_NAME" docker compose up -d
```

### 3. Access services

Each service is available at `<service>.<project_name>.localhost:7355`:

```bash
curl http://web.$PROJECT_NAME.localhost:7355/
curl http://api.$PROJECT_NAME.localhost:7355/
```

### 4. Verify

```bash
# Check HTTP response
curl -s -o /dev/null -w '%{http_code}' http://web.$PROJECT_NAME.localhost:7355/
```

## Why Worktree-Unique Names Matter

dockportless stores port mappings per project name internally. If two worktrees use the same project name, one overwrites the other's mapping and proxy routing breaks.

**Derivation strategy**: Use the worktree directory basename, which is guaranteed unique on the filesystem.

```
/home/user/myapp              -> project_name: "myapp"
/home/user/myapp-feat-login   -> project_name: "myapp-feat-login"
/home/user/myapp-fix-auth     -> project_name: "myapp-fix-auth"
```

Each gets its own allocated ports and its own proxy routes.

## Compose File Setup

Services must use environment variable substitution for ports so dockportless can inject allocated ports:

```yaml
services:
  web:
    image: nginx
    ports:
      - "${WEB_PORT:-8080}:80"
  api:
    build: .
    ports:
      - "${API_PORT:-3000}:3000"
```

dockportless sets `WEB_PORT` and `API_PORT` automatically. Without dockportless, the defaults (8080, 3000) are used.

## Workflow

1. **Derive project name** from worktree root (see above)
2. **Start** with `dockportless run "$PROJECT_NAME" <compose-command>`
3. **Verify** services respond at `<service>.$PROJECT_NAME.localhost:7355`
4. **Develop** - make code changes, rebuild containers as needed
5. **Stop** - `docker compose down` (dockportless cleans up mapping on exit)

## Reference

- [VERIFICATION-GUIDE.md](references/VERIFICATION-GUIDE.md) - Detailed verification steps, multi-worktree scenarios, and troubleshooting
- [AFTER-RESTART.md](references/AFTER-RESTART.md) - Recovering proxy routing after a machine restart
