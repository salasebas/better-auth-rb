# Better Auth Rails Example

```bash
cd examples/rails-app
bundle install
bin/rails server
```

Open <http://localhost:3000>. Start external services from the repository root:

```bash
docker compose -f examples/compose.yml up -d redis postgres mysql mongodb mssql mongodb-init mssql-init
```

If `3000` is busy, prefer the auto-port launcher from the repository root:

```bash
examples/bin/serve rails
```

The dashboard at `/` can switch database providers and rate-limit storage at
runtime. Better Auth is mounted through the Rails adapter at `/api/auth`.
