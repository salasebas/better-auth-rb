# Changelog

## Unreleased

- Honored plugin migration controls in the Sinatra migration integration.

## 0.10.0 - 2026-05-21

- Removed obsolete helper wiring and expanded mounted app, migration, and routing coverage.
- Updated Sinatra docs for current mounting and integration behavior.

## 0.7.0 - 2026-05-05

- Fixed auth dispatch when Rack splits mounted paths across `SCRIPT_NAME` and `PATH_INFO`.
- Rejected `better_auth at: "/"` to avoid capturing every Sinatra route.
- Stopped swallowing real migration bookkeeping query errors while preserving empty-state behavior for missing schema tables.
- Split simple single-line multi-statement SQL migration files.
- Passed versioned `secrets` through Sinatra configuration to core auth.
- Warned when `better_auth` is configured more than once on the same Sinatra app class.
- Returned JSON-shaped 401 responses from `require_authentication` when JSON is preferred.
- Removed duplicate Rake task wiring and clarified `better_auth:routes` output.
- Documented mount path, Rack nesting, SQL migration, and helper auth caveats.

## 0.1.1 - 2026-04-29

- Fixed mounted base-path propagation when creating the Sinatra auth instance.
- Fixed session helper request preparation and migration dialect normalization for PostgreSQL and SQLite aliases.

## 0.1.0

- Initial Sinatra adapter.
