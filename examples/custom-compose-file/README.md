# custom-compose-file

Example using `-f` flag to specify compose files with non-standard names.

## Usage

```bash
# Specify a single compose file with -f
dockportless run myapp docker compose -f compose.dev.yml up

# Access via local URL
curl http://web.myapp.localhost:1355/
curl http://api.myapp.localhost:1355/
```

## Multiple compose files

```bash
# Merge multiple compose files with multiple -f flags
dockportless run myapp docker compose -f compose.dev.yml -f compose.prod.yml up

# All services from both files are available
curl http://web.myapp.localhost:1355/
curl http://api.myapp.localhost:1355/
# redis-cli -h cache.myapp.localhost -p 1355
```

## Also works with podman

```bash
dockportless run myapp podman compose -f compose.dev.yml up
```

## Files

- `compose.dev.yml` - Development config (web + api)
- `compose.prod.yml` - Production config (web + api + cache)
