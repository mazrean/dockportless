# After Machine Restart

After a machine restart, all dockportless proxy processes are gone. This guide covers how to recover proxy routing.

## Quick Recovery

```bash
# Start proxy standalone
dockportless proxy &

# Restart containers in each worktree
cd /home/user/myapp
docker compose up -d

cd /home/user/myapp-feat-login
docker compose up -d
```

The proxy reads existing mapping files and automatically detects new ones via file system watching. Routing updates within ~1 second.

## Why `dockportless proxy`?

`dockportless run` is only needed for the initial setup — it parses the compose file, allocates ports, writes mappings, and starts both the services and the embedded proxy.

After a restart, the mappings already exist. You only need:

1. **`dockportless proxy`** — to restart the proxy that routes requests based on existing mappings
2. **`docker compose up -d`** — to bring containers back up (they retain their port configuration)

## TLS After Restart

The CA certificate installed by `sudo dockportless trust` persists across restarts — no need to re-run. TLS routing resumes automatically when the proxy starts, as long as the generated certificates exist in `$XDG_DATA_HOME/dockportless/certs/`.
