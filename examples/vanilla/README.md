# Better Auth Vanilla Rack Example

```bash
cd examples/vanilla
bundle install
bundle exec puma
```

Open <http://localhost:9292>. Start external services from the repository root:

```bash
docker compose -f examples/compose.yml up -d redis postgres mysql mongodb mssql mongodb-init mssql-init
```

Auto-port launcher:

```bash
examples/bin/serve vanilla
```
