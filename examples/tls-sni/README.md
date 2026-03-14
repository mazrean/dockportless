# tls-sni

TLS SNI routing example: HTTPS access to web/api services and PostgreSQL SSL connection through the proxy.

The proxy automatically detects the protocol (HTTP, TLS, PostgreSQL SSL) and routes based on SNI hostname or Host header.

## Setup

```bash
# Trust the dockportless CA certificate (one-time setup)
dockportless trust
```

## Usage

```bash
# Start with dockportless
dockportless run myapp docker compose up

# HTTP access (routed by Host header)
curl http://web.myapp.localhost:7355/
curl http://api.myapp.localhost:7355/

# HTTPS access (routed by TLS SNI)
curl https://web.myapp.localhost:7355/
curl https://api.myapp.localhost:7355/

# PostgreSQL SSL connection (routed by SNI after SSL negotiation)
psql "host=db.myapp.localhost port=7355 dbname=app user=postgres password=devpass sslmode=require"
```

## How it works

1. The proxy listens on port 7355 and inspects the first bytes of each connection
2. **HTTP** requests are routed by the `Host` header
3. **TLS** connections (HTTPS, etc.) are terminated at the proxy, which reads the SNI hostname from the ClientHello and forwards to the correct backend
4. **PostgreSQL SSL** connections send an `SSLRequest` message first; the proxy responds with `S`, then performs a TLS handshake and routes by SNI
5. The proxy generates a wildcard certificate (`*.localhost`) signed by its own CA

## Environment variables set by dockportless

- `WEB_PORT` - mapped port for the web service
- `API_PORT` - mapped port for the api service
- `DB_PORT` - mapped port for the db service
