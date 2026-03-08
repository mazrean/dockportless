# Verification Guide

Detailed procedures for verifying that your local dev environment is running correctly with dockportless, especially in multi-worktree setups.

## Prerequisites

- `dockportless` installed and available in PATH
- Docker and Docker Compose (or compatible tool) running
- Compose file with `${SERVICE_PORT:-default}` port substitution pattern

## Single Worktree Verification

### Step 1: Derive project name

```bash
PROJECT_NAME="$(basename "$(git rev-parse --show-toplevel)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')"
echo "Project: $PROJECT_NAME"
```

### Step 2: Start environment

```bash
dockportless run "$PROJECT_NAME" docker compose up -d
```

### Step 3: Verify services respond

```bash
# List services from compose file
SERVICES=$(docker compose config --services)

# Check each service
for SVC in $SERVICES; do
  STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
    "http://${SVC}.${PROJECT_NAME}.localhost:7355/" --max-time 5 2>/dev/null || echo "000")
  echo "$SVC: HTTP $STATUS"
done
```

## Multi-Worktree Parallel Verification

When developing multiple features in parallel using git worktrees:

### Setup

```bash
# Main worktree
cd /home/user/myapp
PROJECT_A=$(basename "$(git rev-parse --show-toplevel)")
dockportless run "$PROJECT_A" docker compose up -d

# Feature worktree
cd /home/user/myapp-feat-login
PROJECT_B=$(basename "$(git rev-parse --show-toplevel)")
dockportless run "$PROJECT_B" docker compose up -d
```

### Verify isolation

```bash
# Access project A's web service
curl http://web.myapp.localhost:7355/

# Access project B's web service (different port, same URL pattern)
curl http://web.myapp-feat-login.localhost:7355/
```

## Troubleshooting

### Service returns HTTP 000 (connection refused)

1. Container may not be ready yet. Wait a few seconds and retry.
2. Check container status: `docker compose ps`
3. Check container logs: `docker compose logs <service>`
4. Verify the compose file uses `${SERVICE_PORT:-default}` pattern for port mapping.

### "Address already in use" on port 7355

dockportless uses SO_REUSEPORT, so multiple dockportless instances can share port 7355. This error means a non-dockportless process occupies it:

```bash
ss -tlnp | grep 7355
```

### Wrong service name in URL

Service names in the URL must match exactly what's defined under `services:` in the compose file. Check with:

```bash
docker compose config --services
```
