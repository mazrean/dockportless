---
name: verifying-dockportless
description: Launches and verifies local dev environments using dockportless with worktree-unique project names. Use when starting docker compose services, checking service accessibility via proxy, enabling TLS/HTTPS routing, or when developing across multiple git worktrees to avoid port collisions.
---

# Verifying with dockportless

Use this skill when you need to start a local development environment with `docker compose` (or compatible tools) via dockportless, and verify that services are accessible. Especially important when **developing in parallel across git worktrees** on the same machine.

## Quick Start

### 1. Derive worktree-unique project name

```bash
PROJECT_NAME="$(basename "$(git rev-parse --show-toplevel)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')"
```

### 2. (If needed) Enable TLS routing

**Skip this step** for HTTP-only services (web apps, REST APIs, etc.).

Run once per machine **only when**:
- Connecting directly to **PostgreSQL**, **Redis**, or **MongoDB** via dockportless proxy (these protocols require TLS for hostname-based routing)
- Accessing services over **HTTPS**

```bash
sudo dockportless trust
```

### 3. Start services

```bash
dockportless run "$PROJECT_NAME" docker compose up -d
```

### 4. Access services

Each service is available at `<service>.<project_name>.localhost:7355`:

```bash
curl http://web.$PROJECT_NAME.localhost:7355/
```

### 5. Verify

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

Services must use `${SERVICE_PORT:-default}` pattern in ports. See [COMPOSE-SETUP.md](references/COMPOSE-SETUP.md) for single-port, multi-port examples, and env var naming rules.

## TLS SNI Routing (requires `dockportless trust`)

**Not needed for HTTP-only services.** Required only for HTTPS, PostgreSQL, Redis, or MongoDB direct access. See [TLS-ROUTING.md](references/TLS-ROUTING.md) for protocol details, decision table, and client examples.

## Workflow

1. **Derive project name** from worktree root (see above)
2. **(If needed) Trust CA** with `sudo dockportless trust` — only for HTTPS, PostgreSQL, Redis, MongoDB access
3. **Start** with `dockportless run "$PROJECT_NAME" <compose-command>`
4. **Verify** services respond at `<service>.$PROJECT_NAME.localhost:7355`
5. **Develop** - make code changes, rebuild containers as needed
6. **Stop** - `docker compose down` (dockportless cleans up mapping on exit)

## Reference

- [COMPOSE-SETUP.md](references/COMPOSE-SETUP.md) - Compose file examples (single-port, multi-port, env var naming)
- [TLS-ROUTING.md](references/TLS-ROUTING.md) - TLS SNI protocol details, decision table, client examples
- [VERIFICATION-GUIDE.md](references/VERIFICATION-GUIDE.md) - Detailed verification steps, multi-worktree scenarios, and troubleshooting
- [AFTER-RESTART.md](references/AFTER-RESTART.md) - Recovering proxy routing after a machine restart
