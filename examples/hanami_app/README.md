# Better Auth Hanami Example

```bash
cd examples/hanami_app
bundle install
bundle exec hanami server
```

Open <http://localhost:2300>. Start external services from the repository root:

```bash
docker compose -f examples/compose.yml up -d redis postgres mysql mongodb mssql mongodb-init mssql-init
```

Auto-port launcher:

```bash
examples/bin/serve hanami
```

The dashboard at `/` can switch database providers and rate-limit storage at
runtime. Better Auth is mounted through the Hanami routing adapter at `/api/auth`.
