# multi-project

Demonstrates running two projects simultaneously with dockportless.
Each project gets its own namespace, and SO_REUSEPORT allows both proxies to share port 7355.

## Usage

```bash
# Terminal 1: start frontend project
cd frontend
dockportless run frontend docker compose up

# Terminal 2: start backend project
cd backend
dockportless run backend docker compose up

# Access all services across both projects
curl http://web.frontend.localhost:7355/
curl http://storybook.frontend.localhost:7355/
curl http://api.backend.localhost:7355/
```

## How it works

1. Each `dockportless run` writes its mapping to `$XDG_RUNTIME_DIR/dockportless/`
2. Both proxies share port 7355 via SO_REUSEPORT
3. File watchers (inotify) detect new mappings from other processes
4. Any proxy instance can route to any project's services
