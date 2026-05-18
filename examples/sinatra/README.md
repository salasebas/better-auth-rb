# Better Auth Sinatra Example

```bash
cd examples/sinatra
bundle install
bundle exec ruby app.rb
```

Open <http://localhost:4567>. Start external services from the repository root:

```bash
docker compose -f examples/compose.yml up -d redis postgres mysql mongodb mssql mongodb-init mssql-init
```

Auto-port launcher:

```bash
examples/bin/serve sinatra
```
