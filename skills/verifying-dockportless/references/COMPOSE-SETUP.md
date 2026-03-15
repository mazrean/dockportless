# Compose File Setup

Services must use environment variable substitution for ports so dockportless can inject allocated ports.

## Single-port services

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

## Multi-port services

When a service exposes multiple ports, use indexed environment variables:

```yaml
services:
  web:
    image: myapp
    ports:
      - "${WEB_PORT_0:-8080}:8080"   # HTTP
      - "${WEB_PORT_1:-8443}:8443"   # HTTPS backend
```

- `WEB_PORT` is an alias for `WEB_PORT_0` (backward-compatible)
- URL for index 0: `web.myapp.localhost:7355` (no prefix)
- URL for index 1+: `1.web.myapp.localhost:7355`

## Environment variable naming

| Service name | Port count | Environment variables |
|-------------|-----------|----------------------|
| `web` | 1 | `WEB_PORT` (= `WEB_PORT_0`) |
| `web` | 2 | `WEB_PORT` (= `WEB_PORT_0`), `WEB_PORT_1` |
| `my-api` | 1 | `MY_API_PORT` (= `MY_API_PORT_0`) |
| `db` | 1 | `DB_PORT` (= `DB_PORT_0`) |
