# simple-web

Single service example using nginx.

## Usage

```bash
# Start with dockportless (auto port + proxy)
dockportless run simple-web docker compose up

# Access via local URL
curl http://web.simple-web.localhost:1355/
```

## Without dockportless

```bash
# Falls back to default port 8080
docker compose up
curl http://localhost:8080/
```
