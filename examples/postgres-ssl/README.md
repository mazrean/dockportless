# postgres-ssl

PostgreSQL SSL routing example. The proxy detects PostgreSQL's SSLRequest message, performs a TLS handshake with the client, reads the SNI hostname, and forwards to the correct backend.

## Setup

```bash
# Trust the dockportless CA certificate (one-time setup)
dockportless trust
```

## Usage

```bash
# Start with dockportless
dockportless run myapp docker compose up

# Connect via SSL through the proxy
psql "host=db.myapp.localhost port=7355 dbname=app user=postgres password=devpass sslmode=require"
```

## How it works

1. The client sends a PostgreSQL `SSLRequest` message
2. The proxy responds with `S` (SSL supported)
3. The client initiates a TLS handshake; the proxy reads the SNI hostname (`db.myapp.localhost`)
4. The proxy connects to the actual PostgreSQL backend on its assigned port (plain TCP)
5. All subsequent traffic is forwarded bidirectionally (TLS on client side, plain TCP on backend side)

## Environment variables set by dockportless

- `DB_PORT` - mapped port for the db service
