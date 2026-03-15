# Verification Guide

Detailed procedures for verifying that your local dev environment is running correctly with dockportless, especially in multi-worktree setups.

## Prerequisites

- `dockportless` installed and available in PATH
- Docker and Docker Compose (or compatible tool) running
- Compose file with `${SERVICE_PORT:-default}` port substitution pattern
- `sudo dockportless trust` run once — **only if** connecting to PostgreSQL/Redis/MongoDB directly or using HTTPS

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

# Check each service via HTTP
for SVC in $SERVICES; do
  STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
    "http://${SVC}.${PROJECT_NAME}.localhost:7355/" --max-time 5 2>/dev/null || echo "000")
  echo "$SVC: HTTP $STATUS"
done
```

### Step 4: Verify TLS routing (only for HTTPS / direct DB access)

This step is **only needed** when:
- Accessing services over HTTPS
- Connecting directly to PostgreSQL, Redis, or MongoDB via dockportless proxy

Skip for HTTP-only web services.

```bash
# Check HTTPS (requires prior `sudo dockportless trust`)
for SVC in $SERVICES; do
  STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
    "https://${SVC}.${PROJECT_NAME}.localhost:7355/" --max-time 5 2>/dev/null || echo "000")
  echo "$SVC: HTTPS $STATUS"
done

# Check PostgreSQL SSL
psql "host=db.${PROJECT_NAME}.localhost port=7355 sslmode=require" -c "SELECT 1"

# Check Redis TLS
redli --tls -h cache.${PROJECT_NAME}.localhost -p 7355 PING
```

## Multi-Port Verification

When a service exposes multiple ports, verify each port index:

```bash
# Index 0 (no prefix)
curl http://web.${PROJECT_NAME}.localhost:7355/

# Index 1+
curl http://1.web.${PROJECT_NAME}.localhost:7355/
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

### TLS/HTTPS not working (for HTTPS, PostgreSQL, Redis, MongoDB)

1. Ensure `sudo dockportless trust` has been run at least once. Not needed for HTTP-only services.
2. Check that the CA certificate was installed successfully (no errors from the trust command).
3. Some clients may need to be restarted to pick up the new CA certificate.

### Multi-port URL not resolving

For services with multiple ports, index 0 uses no prefix (`web.myapp.localhost`), while index 1+ uses a numeric prefix (`1.web.myapp.localhost`). Ensure:

1. The compose file lists ports in the correct order.
2. Environment variables use the indexed form: `${WEB_PORT_0:-8080}`, `${WEB_PORT_1:-8443}`.
3. `WEB_PORT` (without index) is an alias for `WEB_PORT_0` and works for single-port services.
