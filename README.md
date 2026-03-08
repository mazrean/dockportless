# dockportless

**Compose-compatible local service router with automatic port assignment.**

No more port conflicts. No more remembering port numbers. Just `<service>.<project>.localhost`.

## Overview

dockportless wraps any compose-compatible command (like `docker compose up`) and automatically:

1. Parses your `compose.yml` to discover services
2. Assigns an available port to each service
3. Sets `<SERVICE_NAME>_PORT` environment variables
4. Starts a reverse proxy so you can access services via `<service>.<project>.localhost:7355`

It's like [Vercel](https://vercel.com/) routing, but for your local Docker Compose services.

## Features

- **Zero-config port management** — OS-level port allocation via `bind(0)`, no collisions
- **Pretty local URLs** — Access services at `web.myapp.localhost:7355` instead of `localhost:49152`
- **Multi-project support** — Run multiple compose projects simultaneously with `SO_REUSEPORT`
- **Live reload** — File-watching (inotify/kqueue) syncs routing across processes in real time
- **Single binary** — Built in Zig, no runtime dependencies
- **Compose-compatible** — Works with `docker compose`, `podman-compose`, or any compose-spec tool

## Installation

### Homebrew

```bash
brew install mazrean/tap/dockportless
```

### apt (Debian / Ubuntu)

```bash
# Download the .deb from the latest release
curl -LO https://github.com/mazrean/dockportless/releases/latest/download/dockportless_amd64.deb
sudo dpkg -i dockportless_amd64.deb
```

### yum / dnf (Fedora / RHEL)

```bash
# Download the .rpm from the latest release
curl -LO https://github.com/mazrean/dockportless/releases/latest/download/dockportless_amd64.rpm
sudo rpm -i dockportless_amd64.rpm
```

### apk (Alpine)

```bash
# Download the .apk from the latest release
curl -LO https://github.com/mazrean/dockportless/releases/latest/download/dockportless_amd64.apk
sudo apk add --allow-untrusted dockportless_amd64.apk
```

### From releases

Download the latest binary from [GitHub Releases](https://github.com/mazrean/dockportless/releases).

### Build from source

Requires [Zig 0.15+](https://ziglang.org/download/):

```bash
zig build -Doptimize=ReleaseSafe
```

## Quick Start

Given a `compose.yml`:

```yaml
services:
  web:
    image: nginx:alpine
    ports:
      - "${WEB_PORT:-8080}:80"
```

Run it with dockportless:

```bash
dockportless run myapp docker compose up
```

Access your service at: **http://web.myapp.localhost:7355**

> [!TIP]
> Your compose file still works without dockportless — `docker compose up` will use the default port (`8080` in this example).

## Usage

### `dockportless run`

Wraps a command with auto-assigned ports and starts the proxy.

```bash
dockportless run <project_name> <command...>
```

**Examples:**

```bash
# Basic usage
dockportless run myapp docker compose up

# With a custom compose file
dockportless run myapp docker compose -f compose.dev.yml up

# With podman
dockportless run myapp podman-compose up
```

Each service in your compose file gets a `<SERVICE_NAME>_PORT` environment variable. Use them in your compose file:

```yaml
services:
  web:
    image: nginx:alpine
    ports:
      - "${WEB_PORT:-3000}:80"
  api:
    image: node:22-alpine
    ports:
      - "${API_PORT:-5678}:5678"
```

Access them at:
- `http://web.myapp.localhost:7355`
- `http://api.myapp.localhost:7355`

### `dockportless proxy`

Starts only the proxy server (useful for connecting to already-running services).

```bash
dockportless proxy
```

## Multi-Project Setup

Run multiple projects at the same time — each gets its own namespace:

```bash
# Terminal 1
cd frontend && dockportless run frontend docker compose up

# Terminal 2
cd backend && dockportless run backend docker compose up
```

All services are accessible through the same port:
- `http://web.frontend.localhost:7355`
- `http://storybook.frontend.localhost:7355`
- `http://api.backend.localhost:7355`

> [!NOTE]
> Multiple dockportless processes share port 7355 using `SO_REUSEPORT`. Any process can route to any project's services.

## How It Works

```
Browser → http://web.myapp.localhost:7355
                    │
                    ▼
         ┌─────────────────┐
         │  dockportless    │
         │  reverse proxy   │  ← SO_REUSEPORT on :7355
         │  (Host routing)  │
         └────────┬────────┘
                  │ parse Host header
                  ▼
         ┌─────────────────┐
         │  mapping store   │  ← JSON files in $XDG_RUNTIME_DIR
         │  web.myapp:54321 │     watched via inotify/kqueue
         └────────┬────────┘
                  │
                  ▼
         localhost:54321 (auto-assigned port)
```

## Examples

See the [`examples/`](examples/) directory:

| Example | Description |
|---------|-------------|
| [simple-web](examples/simple-web/) | Single nginx service |
| [multi-service](examples/multi-service/) | Web + API + DB |
| [multi-project](examples/multi-project/) | Frontend and backend as separate projects |
| [custom-compose-file](examples/custom-compose-file/) | Using `-f` flag with different compose files |

## Supported Platforms

| Platform | Architecture |
|----------|-------------|
| Linux | x86_64, aarch64 |
| macOS | x86_64, aarch64 |
