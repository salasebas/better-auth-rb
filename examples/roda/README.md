# Better Auth Roda Example

```bash
cd examples/roda
bundle install
bundle exec rackup -p 9293
```

Open <http://localhost:9293>. Start shared databases from the repository root with:

```bash
docker compose -f examples/compose.yml up -d redis postgres mysql mongodb mssql mongodb-init mssql-init
```

Auto-port launcher:

```bash
examples/bin/serve roda
```
