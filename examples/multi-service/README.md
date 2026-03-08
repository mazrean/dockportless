# multi-service

Three-service example: web (nginx) + api (http-echo) + db (postgres).

## Usage

```bash
# Start with dockportless
dockportless run myapp docker compose up

# Access each service by name
curl http://web.myapp.localhost:7355/
curl http://api.myapp.localhost:7355/
# psql -h db.myapp.localhost -p 7355  (TCP proxy for non-HTTP)
```

## Environment variables set by dockportless

- `WEB_PORT` - mapped port for the web service
- `API_PORT` - mapped port for the api service
- `DB_PORT` - mapped port for the db service
