# multi-port

Multiple ports per service example. Each port gets its own environment variable and proxy route.

## Usage

```bash
# Start with dockportless (auto port + proxy)
dockportless run multi-port docker compose up

# Access via indexed URLs
curl http://0.web.multi-port.localhost:7355/   # -> WEB_PORT_0 (port 80)
curl http://1.web.multi-port.localhost:7355/   # -> WEB_PORT_1 (port 443)
curl http://0.api.multi-port.localhost:7355/   # -> API_PORT_0 (port 5678)

# SERVICE_PORT is an alias for SERVICE_PORT_0
# WEB_PORT == WEB_PORT_0, API_PORT == API_PORT_0
```

## Without dockportless

```bash
# Falls back to default ports
docker compose up
curl http://localhost:8080/
curl http://localhost:8443/
curl http://localhost:5678/
```
