# TLS SNI Routing

dockportless auto-detects the protocol of incoming connections:

- **HTTP** — Routed by `Host` header. **No TLS setup needed.**
- **TLS (HTTPS, Redis, MongoDB, etc.)** — Routed by SNI hostname with TLS termination
- **PostgreSQL SSL** — Detects `SSLRequest`, upgrades to TLS, then routes by SNI

TLS is required for non-HTTP TCP protocols because dockportless needs a hostname to route to the correct backend. These protocols don't send a hostname in plaintext like HTTP's `Host` header, so TLS SNI is the only way to identify the target service.

## When you need `dockportless trust`

| Use case | Example | `trust` needed? |
|----------|---------|-----------------|
| Web app via HTTP | `curl http://web.myapp.localhost:7355/` | No |
| Web app via HTTPS | `curl https://web.myapp.localhost:7355/` | **Yes** |
| PostgreSQL | `psql "host=db.myapp.localhost port=7355 sslmode=require"` | **Yes** |
| Redis | `redli --tls -h cache.myapp.localhost -p 7355` | **Yes** |
| MongoDB | `mongosh "mongodb://db.myapp.localhost:7355/?tls=true"` | **Yes** |

## Setup

Run once per machine:

```bash
sudo dockportless trust
```

Supported trust stores:
- **Linux**: Debian/Ubuntu, RHEL/Fedora, Arch Linux, SUSE
- **macOS**: System Keychain

## Client examples

### HTTPS

```bash
curl https://web.myapp.localhost:7355/
```

### PostgreSQL SSL

```bash
psql "host=db.myapp.localhost port=7355 sslmode=require"
```

### Redis TLS

```bash
redli --tls -h cache.myapp.localhost -p 7355
```

### MongoDB TLS

```bash
mongosh "mongodb://db.myapp.localhost:7355/?tls=true"
```

## After restart

The CA certificate persists across restarts — no need to re-run `sudo dockportless trust`. TLS routing resumes automatically when the proxy starts, as long as the generated certificates exist in `$XDG_DATA_HOME/dockportless/certs/`.
