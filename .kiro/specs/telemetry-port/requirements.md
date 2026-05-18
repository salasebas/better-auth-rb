# Requirements Document

## Introduction

This feature ports the upstream `@better-auth/telemetry` package (vendored at
`upstream/better-auth/1.6.9/packages/telemetry/`) into this Ruby monorepo as a
pair of gems that follow the existing canonical/alias pattern used by
`better_auth-stripe` + `openauth-stripe`.

The port is **not a 1:1 source translation**. The upstream package ships two
build entrypoints (`src/index.ts` for browser/edge and `src/node.ts` for Node)
because it must run in heterogeneous JavaScript runtimes. This Ruby
repository is server-only, so the Ruby port collapses both upstream variants
into a single server-side implementation. Detectors and runtime probes are
adapted to idiomatic Ruby (using `RUBY_VERSION`, `RbConfig`, `Etc`,
`Gem.loaded_specs`, `Bundler`, and `BetterAuth::Configuration`) instead of
porting the Node `package.json`/`node_modules` discovery machinery.

The port is opt-in only, preserves the upstream redaction rules for the auth
config payload, supports both the `BETTER_AUTH_*` and `OPEN_AUTH_*`
environment variable prefixes (via the existing `BetterAuth::Env.get` helper),
keeps the `customTrack` injection seam from upstream so tests do not need to
mock HTTP, and integrates softly into `BetterAuth::Auth.new` so core remains a
no-op when the telemetry gem is not installed.

## Glossary

- **Telemetry_Package**: The new canonical gem `better_auth-telemetry` living
  at `packages/better_auth-telemetry/`, namespace `BetterAuth::Telemetry`,
  version constant `BetterAuth::Telemetry::VERSION` defined in
  `lib/better_auth/telemetry/version.rb`.
- **Telemetry_Alias_Package**: The alias gem `openauth-telemetry` living at
  `packages/openauth-telemetry/`. Exposes `OpenAuth::Telemetry` as an alias of
  `BetterAuth::Telemetry` and pins a literal dependency on
  `better_auth-telemetry`.
- **Telemetry_Publisher**: The object returned by
  `BetterAuth::Telemetry.create(options, context = nil)`. Responds to
  `#publish(event)`. Mirrors the upstream `createTelemetry` return value
  `{ publish }`.
- **Init_Event**: The single telemetry event emitted on
  `Telemetry_Publisher` creation when telemetry is enabled, with
  `type: "init"` and the upstream payload shape (`config`, `runtime`,
  `database`, `framework`, `environment`, `systemInfo`, `packageManager`,
  plus `anonymousId`).
- **Anonymous_Project_Id**: The opaque string identifying a project for
  telemetry. Computed by `Telemetry_Project_Id` and reused for every event
  emitted by a single `Telemetry_Publisher`.
- **Telemetry_Project_Id**: The Ruby module that derives
  `Anonymous_Project_Id` from the project name plus base URL, using
  `Digest::SHA256` and `Base64`, with a fallback to a random 32-char id.
- **Telemetry_Auth_Config**: The redacted view of `BetterAuth::Configuration`
  emitted as `payload[:config]` in the `Init_Event`. Boolean-redacts the
  same fields the upstream `getTelemetryAuthConfig` boolean-redacts (cookie
  prefix, custom domain, etc.).
- **Telemetry_Detectors**: The set of detector modules under
  `BetterAuth::Telemetry::Detectors` (`Runtime`, `Environment`,
  `SystemInfo`, `Database`, `Framework`, `ProjectInfo`, `AuthConfig`).
- **Telemetry_Endpoint**: The URL the publisher POSTs JSON events to,
  resolved from `BETTER_AUTH_TELEMETRY_ENDPOINT` (or its `OPEN_AUTH_*`
  alias).
- **Custom_Track**: A caller-supplied callable in
  `context[:custom_track]` that receives every event instead of HTTP
  delivery. Mirrors upstream `context.customTrack` and is the testing seam.
- **Env_Helper**: The existing `BetterAuth::Env.get(name)` helper which
  resolves the `OPEN_AUTH_*` form first and falls back to `BETTER_AUTH_*`.
  Defined in `packages/better_auth/lib/better_auth/env.rb`.
- **Truthy_Env_Value**: A non-empty environment string that is not `"0"` and
  not (case-insensitive) `"false"`. Matches the upstream `getBooleanEnvVar`
  semantics in
  `upstream/better-auth/1.6.9/packages/core/src/env/env-impl.ts`.
- **Test_Environment**: A Ruby process where `RACK_ENV`, `RAILS_ENV`, or
  `APP_ENV` equals `"test"`, matching the existing
  `BetterAuth::Configuration#test_environment?` detection.
- **Soft_Load_Hook**: The integration point in `BetterAuth::Auth#initialize`
  that requires `better_auth/telemetry` only when the gem is installed and
  invokes the publisher with the live options + context, mirroring how
  `better_auth.rb` already soft-loads `better_auth/plugins/stripe` and
  `better_auth/plugins/expo`.
- **Release_Manifest**: The repository file `.release.yml`. Drives release
  tooling for `version_files`, `literal_gemspec_versions`, and
  `pinned_dependencies`.
- **Upstream_Tree**: The directory `upstream/better-auth/1.6.9/`. Treated as
  read-only vendored reference source per the repository `AGENTS.md`.

## Requirements

### Requirement 1: Canonical telemetry gem package layout

**User Story:** As a maintainer, I want a `better_auth-telemetry` gem under
`packages/better_auth-telemetry/`, so that telemetry follows the same
canonical-package layout as every other Better Auth Ruby plugin.

#### Acceptance Criteria

1. THE Telemetry_Package SHALL be located at the absolute path
   `packages/better_auth-telemetry/` relative to the repository root.
2. THE Telemetry_Package SHALL declare a gemspec at
   `packages/better_auth-telemetry/better_auth-telemetry.gemspec` whose
   `spec.name` equals `"better_auth-telemetry"`.
3. THE Telemetry_Package SHALL define `BetterAuth::Telemetry::VERSION` in the
   file `packages/better_auth-telemetry/lib/better_auth/telemetry/version.rb`.
4. THE Telemetry_Package SHALL set `BetterAuth::Telemetry::VERSION` to the
   string `"0.8.0"` for the initial release, matching the
   `version: "0.8.0"` line in the Release_Manifest.
5. THE Telemetry_Package SHALL provide a top-level entrypoint at
   `packages/better_auth-telemetry/lib/better_auth/telemetry.rb` that, when
   required, loads the public surface `BetterAuth::Telemetry.create`,
   `BetterAuth::Telemetry::Publisher`, and the Telemetry_Detectors namespace.
6. THE Telemetry_Package gemspec SHALL declare `spec.required_ruby_version`
   compatible with the rest of the monorepo (`>= 3.2.0`, matching
   `better_auth-stripe.gemspec`).
7. THE Telemetry_Package gemspec SHALL declare a runtime dependency on
   `better_auth` using the same version constraint shape used by
   `better_auth-stripe.gemspec` (`spec.add_dependency "better_auth", "~> 0.1"`).
8. THE Telemetry_Package gemspec SHALL NOT declare any runtime dependency on
   an external HTTP client gem; the publisher SHALL use Ruby's standard
   library (`Net::HTTP`, `URI`, `JSON`) for HTTP delivery.
9. THE Telemetry_Package SHALL ship a `README.md` describing opt-in
   instructions, the supported environment variables (with both
   `BETTER_AUTH_*` and `OPEN_AUTH_*` prefixes), debug mode, and the
   Custom_Track injection seam.

### Requirement 2: openauth-telemetry alias gem

**User Story:** As an OpenAuth user, I want an `openauth-telemetry` alias gem,
so that I can install telemetry under the OpenAuth naming the same way I do
for Stripe, Passkey, and other plugins.

#### Acceptance Criteria

1. THE Telemetry_Alias_Package SHALL be located at the absolute path
   `packages/openauth-telemetry/` relative to the repository root.
2. THE Telemetry_Alias_Package SHALL declare a gemspec at
   `packages/openauth-telemetry/openauth-telemetry.gemspec` whose
   `spec.name` equals `"openauth-telemetry"`.
3. THE Telemetry_Alias_Package gemspec SHALL set `spec.version` to the same
   literal string `"0.8.0"` used by the Telemetry_Package, matching how
   `openauth-stripe.gemspec` literally pins `spec.version = "0.8.0"`.
4. THE Telemetry_Alias_Package gemspec SHALL declare its runtime dependency on
   `better_auth-telemetry` using a literal pinned version
   (`spec.add_dependency "better_auth-telemetry", "0.8.0"`), matching the
   literal pin pattern enforced by Release_Manifest's
   `literal_gemspec_versions` and `pinned_dependencies`.
5. THE Telemetry_Alias_Package SHALL provide
   `packages/openauth-telemetry/lib/openauth/telemetry.rb` that, when
   required, loads `openauth` and `better_auth/telemetry` and assigns
   `OpenAuth::Telemetry = BetterAuth::Telemetry` while invoking
   `OpenAuth.alias_better_auth_constants!` exactly as
   `packages/openauth-stripe/lib/openauth/stripe.rb` does.
6. THE Telemetry_Alias_Package SHALL ship a `README.md` matching the format
   of `packages/openauth-stripe/README.md`, naming `openauth-telemetry`,
   referencing `better_auth-telemetry`, and showing both the gem install line
   and the `require "openauth/telemetry"` line.
7. THE Telemetry_Alias_Package SHALL NOT contain any telemetry logic of its
   own; all behavior SHALL be re-exported from the Telemetry_Package.

### Requirement 3: Environment variable resolution with dual prefix

**User Story:** As an operator, I want telemetry env vars to be read from
both the `BETTER_AUTH_*` and `OPEN_AUTH_*` prefixes, so that operators of
either branding can configure the same package without rewriting variable
names.

#### Acceptance Criteria

1. THE Telemetry_Package SHALL resolve every telemetry environment variable
   through the Env_Helper at `BetterAuth::Env.get(name)`.
2. THE Telemetry_Package SHALL recognize the environment variable name
   `BETTER_AUTH_TELEMETRY` as the opt-in toggle, mirroring upstream `ENV`
   keys.
3. THE Telemetry_Package SHALL recognize the environment variable name
   `BETTER_AUTH_TELEMETRY_DEBUG` as the debug-mode toggle, mirroring
   upstream.
4. THE Telemetry_Package SHALL recognize the environment variable name
   `BETTER_AUTH_TELEMETRY_ENDPOINT` as the HTTP endpoint URL, mirroring
   upstream.
5. WHEN the Env_Helper reads any of the three telemetry variables, THE
   Telemetry_Package SHALL receive the value of the `OPEN_AUTH_*`-prefixed
   variant when it is set and non-empty, falling back to the
   `BETTER_AUTH_*`-prefixed variant otherwise, exactly as
   `BetterAuth::Env.get` already implements.
6. THE Telemetry_Package SHALL treat an environment value as truthy
   (Truthy_Env_Value) only when the resolved string is non-empty, not equal
   to `"0"`, and not equal to `"false"` (case-insensitive), matching upstream
   `getBooleanEnvVar` semantics.
7. WHERE no `BETTER_AUTH_*` or `OPEN_AUTH_*` variant is set, THE
   Telemetry_Package SHALL treat the variable as absent rather than as
   falsy-with-string-presence.
8. THE Telemetry_Package SHALL NOT introduce any new environment variable
   names beyond the three documented above.

### Requirement 4: Opt-in semantics and test-environment skip

**User Story:** As a Better Auth Ruby user, I want telemetry to be disabled
by default and skipped during tests, so that no data leaves my application
unless I explicitly opt in.

#### Acceptance Criteria

1. THE Telemetry_Package SHALL treat telemetry as disabled by default when
   neither `options[:telemetry][:enabled]` is explicitly `true` nor the
   resolved `BETTER_AUTH_TELEMETRY` env value is a Truthy_Env_Value.
2. WHEN `options[:telemetry][:enabled]` is the literal `true`, THE
   Telemetry_Package SHALL treat telemetry as opted-in subject to the
   Test_Environment skip rule.
3. WHEN the resolved `BETTER_AUTH_TELEMETRY` env value is a Truthy_Env_Value,
   THE Telemetry_Package SHALL treat telemetry as opted-in subject to the
   Test_Environment skip rule.
4. WHILE the process is running in a Test_Environment, THE Telemetry_Package
   SHALL treat telemetry as disabled regardless of the opt-in state, unless
   the caller explicitly sets `context[:skip_test_check]` to `true`.
5. WHERE `context[:skip_test_check]` is `true`, THE Telemetry_Package SHALL
   bypass the Test_Environment skip only and SHALL still require the opt-in
   state from Requirements 4.2 or 4.3 to be true before treating telemetry
   as enabled. `context[:skip_test_check]` SHALL NOT force-enable telemetry
   on its own.
6. WHEN telemetry is disabled, THE Telemetry_Publisher returned from
   `BetterAuth::Telemetry.create` SHALL respond to `#publish(event)` without
   raising and without performing any HTTP, logging, or Custom_Track
   delivery.
7. WHEN `options[:telemetry][:enabled]` is the literal `false`, THE
   Telemetry_Package SHALL treat telemetry as disabled even if
   `BETTER_AUTH_TELEMETRY` is a Truthy_Env_Value, matching the upstream
   precedence in which an explicit option overrides the env opt-in.

### Requirement 5: Endpoint, debug, and noop modes

**User Story:** As an operator, I want clear delivery semantics for the
publisher, so that I know exactly when events go out over HTTP, when they
get logged for debugging, and when nothing happens.

#### Acceptance Criteria

1. WHEN the resolved `BETTER_AUTH_TELEMETRY_ENDPOINT` is absent and
   `context[:custom_track]` is also absent, THE
   `BetterAuth::Telemetry.create` method SHALL return a Telemetry_Publisher
   whose `#publish(event)` is a noop.
2. WHEN telemetry is opted-in and `context[:custom_track]` is provided, THE
   Telemetry_Package SHALL invoke `context[:custom_track].call(event)` for
   every event instead of performing HTTP delivery.
3. WHEN telemetry is opted-in, `context[:custom_track]` is absent, the
   resolved `BETTER_AUTH_TELEMETRY_ENDPOINT` is set, and neither
   `options[:telemetry][:debug]` nor `BETTER_AUTH_TELEMETRY_DEBUG` is a
   Truthy_Env_Value, THE Telemetry_Package SHALL POST the event as JSON to
   the resolved endpoint using `Net::HTTP` with `Content-Type: application/json`.
4. WHEN telemetry is opted-in and either `options[:telemetry][:debug]` is
   `true` or `BETTER_AUTH_TELEMETRY_DEBUG` is a Truthy_Env_Value, THE
   Telemetry_Package SHALL log the event as JSON via the configured logger
   instead of performing HTTP delivery, mirroring the upstream
   `logger.info("telemetry event", JSON.stringify(event, null, 2))`
   behavior.
5. THE Telemetry_Package SHALL emit log output through the same logger
   abstraction used by the rest of `BetterAuth` (currently
   `BetterAuth::Logger`); when no logger is configured, telemetry SHALL fall
   back to `BetterAuth::Logger.default` (or equivalent module-level logger)
   so that no `NoMethodError` is raised on missing logger setup.
6. IF the HTTP POST raises any `StandardError` (including network errors,
   timeouts, or non-2xx responses surfaced as exceptions), THEN THE
   Telemetry_Package SHALL rescue the error, log it at error level, and
   return normally, mirroring the upstream `.catch(logger.error)` behavior.
7. IF `context[:custom_track].call(event)` raises any `StandardError`, THEN
   THE Telemetry_Package SHALL rescue the error, log it at error level, and
   return normally, mirroring the upstream `customTrack(event).catch(logger.error)`.
8. THE Telemetry_Package SHALL apply a bounded HTTP timeout (open + read) of
   no more than 5 seconds for endpoint delivery, so that telemetry never
   blocks application initialization for an unbounded period.
9. WHEN debug mode is active, THE Telemetry_Package SHALL NOT make any
   network request to the resolved endpoint.

### Requirement 6: Init event payload shape

**User Story:** As a maintainer porting upstream behavior, I want the init
event payload to mirror upstream so existing telemetry consumers can ingest
events from Ruby projects without schema branching.

#### Acceptance Criteria

1. WHEN telemetry is opted-in, THE Telemetry_Package SHALL emit exactly one
   event with `type: "init"` during `BetterAuth::Telemetry.create(...)`.
2. THE Init_Event SHALL include an `anonymousId` string field set to the
   value returned by `Telemetry_Project_Id.get(base_url)` for the resolved
   base URL.
3. THE Init_Event SHALL include a `payload` object with exactly these
   top-level keys: `config`, `runtime`, `database`, `framework`,
   `environment`, `systemInfo`, `packageManager`. Keys SHALL match the
   upstream camelCase casing exactly so consumers do not need a separate
   schema for the Ruby variant.
4. THE Init_Event `payload[:config]` SHALL be the value returned by
   `BetterAuth::Telemetry::Detectors::AuthConfig.call(options, context)` and
   SHALL preserve all top-level keys present in the upstream
   `getTelemetryAuthConfig` return value (`emailVerification`,
   `emailAndPassword`, `socialProviders`, `plugins`, `user`, `verification`,
   `session`, `account`, `hooks`, `secondaryStorage`, `advanced`,
   `trustedOrigins`, `rateLimit`, `onAPIError`, `logger`, `databaseHooks`,
   `database`, `adapter`).
5. THE Init_Event `payload[:runtime]` SHALL be a hash of the form
   `{ name: "ruby", version: <RUBY_VERSION>, engine: <RUBY_ENGINE> }`.
6. THE Init_Event `payload[:environment]` SHALL be one of the literal
   strings `"production"`, `"ci"`, `"test"`, or `"development"`.
7. THE Init_Event `payload[:database]` and `payload[:framework]` SHALL each
   be either a hash of the form
   `{ name: <String>, version: <String|nil> }` or `nil` when no detection
   matches.
8. THE Init_Event `payload[:systemInfo]` SHALL include all of these keys:
   `deploymentVendor`, `systemPlatform`, `systemRelease`,
   `systemArchitecture`, `cpuCount`, `cpuModel`, `memory`, `isWSL`,
   `isDocker`, `isTTY`. Any of those keys MAY be `nil` when not portably
   detectable on the host. The key `cpuSpeed` MAY be omitted or set to `nil`
   when not portably available on Ruby; this Ruby-specific deviation SHALL
   be documented in the Telemetry_Package README.
9. THE Init_Event `payload[:packageManager]` SHALL be a hash of the form
   `{ name: "bundler", version: <Bundler::VERSION> }` when Bundler is
   loadable, otherwise `nil`. The Ruby-specific deviation from upstream's
   `npm_config_user_agent`-based detection SHALL be documented in the
   README.
10. THE Telemetry_Publisher `#publish(event)` method SHALL forward the
    given event with the same `anonymousId` used for the Init_Event when
    telemetry is opted-in, preserving the caller's `event[:type]` and
    `event[:payload]` unchanged.

### Requirement 7: Runtime detector

**User Story:** As a telemetry consumer, I want a Ruby-shaped runtime
detector, so that the runtime field accurately describes the Ruby
interpreter and version.

#### Acceptance Criteria

1. THE `BetterAuth::Telemetry::Detectors::Runtime.call` method SHALL return
   a hash whose `:name` key equals the literal string `"ruby"`.
2. THE `BetterAuth::Telemetry::Detectors::Runtime.call` method SHALL return
   a hash whose `:version` key equals the value of the constant
   `RUBY_VERSION`.
3. THE `BetterAuth::Telemetry::Detectors::Runtime.call` method SHALL return
   a hash whose `:engine` key equals the value of the constant
   `RUBY_ENGINE` (e.g., `"ruby"`, `"jruby"`, `"truffleruby"`).
4. THE `BetterAuth::Telemetry::Detectors::Runtime.call` method SHALL NOT
   reference Node, Bun, Deno, or edge runtime branches from upstream; this
   Ruby-specific deviation is intentional.

### Requirement 8: Environment detector

**User Story:** As a telemetry consumer, I want production/test/CI/development
classification, so that I can segment events by deployment stage.

#### Acceptance Criteria

1. WHEN any of `RACK_ENV`, `RAILS_ENV`, or `APP_ENV` equals the literal
   string `"production"`, THE
   `BetterAuth::Telemetry::Detectors::Environment.call` method SHALL return
   the literal string `"production"`.
2. WHEN none of `RACK_ENV`, `RAILS_ENV`, or `APP_ENV` equals `"production"`
   AND any of the upstream-listed CI environment variables (`CI`,
   `BUILD_ID`, `BUILD_NUMBER`, `CI_APP_ID`, `CI_BUILD_ID`,
   `CI_BUILD_NUMBER`, `CI_NAME`, `CONTINUOUS_INTEGRATION`, `RUN_ID`) is
   present in the process environment with a non-empty value other than
   `"false"`, THE
   `BetterAuth::Telemetry::Detectors::Environment.call` method SHALL return
   the literal string `"ci"`.
3. WHEN none of the rules above match AND any of `RACK_ENV`, `RAILS_ENV`, or
   `APP_ENV` equals `"test"`, THE
   `BetterAuth::Telemetry::Detectors::Environment.call` method SHALL return
   the literal string `"test"`.
4. WHEN none of the rules above match, THE
   `BetterAuth::Telemetry::Detectors::Environment.call` method SHALL return
   the literal string `"development"`.

### Requirement 9: System info detector

**User Story:** As a telemetry consumer, I want platform, container, and
deployment-vendor signals, so that I can understand the host where Better
Auth Ruby is running.

#### Acceptance Criteria

1. THE `BetterAuth::Telemetry::Detectors::SystemInfo.call` method SHALL
   return a hash with keys `deploymentVendor`, `systemPlatform`,
   `systemRelease`, `systemArchitecture`, `cpuCount`, `cpuModel`, `memory`,
   `isWSL`, `isDocker`, `isTTY`.
2. THE `systemPlatform` field SHALL be derived from
   `RbConfig::CONFIG["host_os"]` (or `Gem::Platform.local.os`) and reduced
   to a short identifier matching the upstream `os.platform()` style
   (`"linux"`, `"darwin"`, `"windows"`, etc.).
3. THE `systemArchitecture` field SHALL be derived from
   `RbConfig::CONFIG["host_cpu"]` (or `Gem::Platform.local.cpu`) and use
   the upstream `os.arch()`-style values (`"arm64"`, `"x64"`, etc.).
4. THE `systemRelease` field SHALL be derived from `Etc.uname[:release]`
   when `Etc` is available, otherwise from `RbConfig::CONFIG["host_os"]`
   tail.
5. THE `cpuCount` field SHALL be the value returned by `Etc.nprocessors`,
   reported verbatim including `0` when `Etc.nprocessors` returns `0`. IF
   `Etc.nprocessors` raises, THEN THE `cpuCount` field SHALL be `nil`. THE
   `cpuModel` field SHALL be `nil` when no portable Ruby API surfaces it.
6. THE `memory` field SHALL be the total system memory in bytes when
   available from `/proc/meminfo` on Linux or `sysctl hw.memsize` on
   macOS, otherwise `nil`.
7. WHEN the file `/.dockerenv` exists OR the file `/proc/self/cgroup`
   exists and contains the literal substring `"docker"`, THE `isDocker`
   field SHALL be `true`; otherwise `false`.
8. WHEN `RUBY_PLATFORM` indicates Linux AND either `Etc.uname[:release]`
   contains the case-insensitive substring `"microsoft"` OR `/proc/version`
   exists and contains the case-insensitive substring `"microsoft"`, AND
   the host is not detected as inside a non-Docker container, THE `isWSL`
   field SHALL be `true`; otherwise `false`.
9. THE `isTTY` field SHALL equal `$stdout.tty?`.
10. THE `deploymentVendor` field SHALL be derived from environment variables
    using the same vendor detection list and order as the upstream
    `getVendor` function in
    `upstream/better-auth/1.6.9/packages/telemetry/src/detectors/detect-system-info.ts`,
    covering at minimum: cloudflare, vercel, netlify, render, aws, gcp,
    azure, deno-deploy, fly-io, railway, heroku, digitalocean, koyeb. THE
    field SHALL be `nil` when no vendor matches.
11. IF any individual detector probe raises, THEN THE
    `BetterAuth::Telemetry::Detectors::SystemInfo.call` method SHALL
    rescue and return `nil` for that field rather than raising.

### Requirement 10: Database detector

**User Story:** As a telemetry consumer, I want to know which database the
Better Auth Ruby application uses, so that I can segment metrics by storage
backend.

#### Acceptance Criteria

1. WHEN `context[:database]` is provided as a non-empty string, THE
   `BetterAuth::Telemetry::Detectors::Database.call` method SHALL return
   `{ name: context[:database], version: nil }` so that callers can
   override detection (mirroring the upstream `context.database` field).
2. WHEN `context[:database]` is not provided AND the
   `BetterAuth::Configuration#database` value is a known adapter
   identifier (`:postgres`, `:mysql`, `:sqlite`, `:mssql`, `:memory`) or a
   `BetterAuth::Adapters::*` instance whose class maps to one of those
   identifiers, THE
   `BetterAuth::Telemetry::Detectors::Database.call` method SHALL return
   `{ name: <identifier_string>, version: nil }`.
3. WHEN neither rule above matches AND `Gem.loaded_specs` includes any of
   `"sequel"`, `"pg"`, `"mysql2"`, `"sqlite3"`, `"activerecord"`,
   `"mongoid"`, `"mongo"`, `"rom-sql"`, THE
   `BetterAuth::Telemetry::Detectors::Database.call` method SHALL return
   the first match in that order as
   `{ name: <gem_name>, version: <Gem::Version#to_s> }`.
4. WHEN none of the rules above match, THE
   `BetterAuth::Telemetry::Detectors::Database.call` method SHALL return
   `nil`.

### Requirement 11: Framework detector

**User Story:** As a telemetry consumer, I want to know which Ruby framework
hosts Better Auth, so that I can segment metrics by framework.

#### Acceptance Criteria

1. THE `BetterAuth::Telemetry::Detectors::Framework.call` method SHALL
   inspect `Gem.loaded_specs` for the gem names `"rails"`, `"sinatra"`,
   `"hanami"`, `"hanami-router"`, `"roda"`, `"grape"`, `"rack"`, in that
   order.
2. WHEN one of those gem names is loaded, THE
   `BetterAuth::Telemetry::Detectors::Framework.call` method SHALL return
   the first match as
   `{ name: <gem_name>, version: <loaded_spec.version.to_s> }`.
3. WHEN none of those gem names is loaded, THE
   `BetterAuth::Telemetry::Detectors::Framework.call` method SHALL return
   `nil`.
4. THE `BetterAuth::Telemetry::Detectors::Framework.call` method SHALL NOT
   probe for Node-only frameworks (`next`, `nuxt`, `astro`, `sveltekit`,
   `solid-start`, `tanstack-start`, `hono`, `express`, `elysia`, `expo`);
   this Ruby-specific deviation is intentional.

### Requirement 12: Project info detector

**User Story:** As a telemetry consumer, I want a "package manager" signal
adapted to Ruby, so that I know the project is a Bundler-managed app.

#### Acceptance Criteria

1. WHEN `Bundler` is `defined?` AND a Gemfile is locatable via
   `Bundler.default_gemfile`, THE
   `BetterAuth::Telemetry::Detectors::ProjectInfo.call` method SHALL return
   `{ name: "bundler", version: Bundler::VERSION }`.
2. WHEN Bundler is not loaded or no Gemfile is locatable, THE
   `BetterAuth::Telemetry::Detectors::ProjectInfo.call` method SHALL return
   `nil`.
3. THE `BetterAuth::Telemetry::Detectors::ProjectInfo.call` method SHALL
   NOT read `npm_config_user_agent` or any Node package-manager environment
   variable; this Ruby-specific deviation is intentional and SHALL be
   documented in the Telemetry_Package README.

### Requirement 13: Auth config detector and redaction parity

**User Story:** As a privacy-conscious operator, I want the same redaction
rules as upstream applied to the auth config payload, so that secrets and
domains never leak through telemetry.

#### Acceptance Criteria

1. THE `BetterAuth::Telemetry::Detectors::AuthConfig.call(options, context)`
   method SHALL accept `options` either as a `BetterAuth::Configuration`
   instance or as the raw hash passed to `BetterAuth::Auth.new`.
2. THE auth config payload SHALL include exactly these top-level keys to
   match upstream `getTelemetryAuthConfig`: `database`, `adapter`,
   `emailVerification`, `emailAndPassword`, `socialProviders`, `plugins`,
   `user`, `verification`, `session`, `account`, `hooks`, `secondaryStorage`,
   `advanced`, `trustedOrigins`, `rateLimit`, `onAPIError`, `logger`,
   `databaseHooks`. Keys SHALL use upstream camelCase even though the Ruby
   `BetterAuth::Configuration` stores them as snake_case internally.
3. THE auth config payload SHALL boolean-redact every field that the
   upstream `getTelemetryAuthConfig` boolean-redacts (replacing the value
   with the result of "is this configured" rather than the raw value),
   including at minimum: `emailAndPassword.password.hash`,
   `emailAndPassword.password.verify`,
   `emailAndPassword.sendResetPassword`, `emailAndPassword.onPasswordReset`,
   `emailVerification.sendVerificationEmail`,
   `emailVerification.beforeEmailVerification`,
   `emailVerification.afterEmailVerification`, `hooks.before`,
   `hooks.after`, `secondaryStorage`, `advanced.cookiePrefix`,
   `advanced.cookies`, `advanced.crossSubDomainCookies.domain`,
   `advanced.defaultCookieAttributes.domain`, `onAPIError.onError`,
   `logger.log`, `rateLimit.customStorage`, and every leaf under
   `databaseHooks.{user,session,account,verification}.{create,update}.{before,after}`.
4. THE auth config payload SHALL preserve raw scalar values for fields that
   upstream preserves raw, including: `emailVerification.expiresIn`,
   `emailAndPassword.maxPasswordLength`,
   `emailAndPassword.minPasswordLength`,
   `emailAndPassword.resetPasswordTokenExpiresIn`,
   `session.cookieCache.enabled`, `session.expiresIn`, `session.updateAge`,
   `session.freshAge`, `account.encryptOAuthTokens`,
   `advanced.database.generateId`,
   `advanced.database.defaultFindManyLimit`, `advanced.useSecureCookies`,
   `advanced.disableCSRFCheck`,
   `advanced.defaultCookieAttributes.{expires,secure,sameSite,path,httpOnly}`,
   `rateLimit.window`, `rateLimit.max`, `rateLimit.storage`,
   `rateLimit.modelName`, `onAPIError.errorURL`, `onAPIError.throw`,
   `logger.disabled`, `logger.level`.
5. THE auth config payload `socialProviders` SHALL be an array of hashes,
   one per configured provider, with the keys upstream produces (`id`,
   `mapProfileToUser`, `disableDefaultScope`, `disableIdTokenSignIn`,
   `disableImplicitSignUp`, `disableSignUp`, `getUserInfo`,
   `overrideUserInfoOnSignIn`, `prompt`, `verifyIdToken`, `scope`,
   `refreshAccessToken`).
6. THE auth config payload `plugins` SHALL be an array of plugin id strings
   (`options.plugins.map(&:id).map(&:to_s)`) or `nil` when no plugins are
   configured, matching upstream.
7. THE auth config payload `trustedOrigins` SHALL be the Integer count of
   configured trusted origins (matching upstream `options.trustedOrigins?.length`)
   rather than the raw list of origin strings.
8. THE auth config payload SHALL NOT include the resolved `secret`, the
   raw `cookiePrefix` string, the raw `crossSubDomainCookies.domain` string,
   the raw `defaultCookieAttributes.domain` string, or any other field that
   upstream redacts.
9. THE auth config payload `database` and `adapter` keys SHALL pass through
   the values from `context[:database]` and `context[:adapter]` unchanged
   when provided, otherwise `nil`.

### Requirement 14: Project ID derivation

**User Story:** As a telemetry consumer, I want a stable anonymous project
id derived without sending a raw base URL, so that events from the same
project deduplicate over time without exposing the operator's URL.

#### Acceptance Criteria

1. THE `BetterAuth::Telemetry.project_id(base_url)` method SHALL accept a
   `String` or `nil` for `base_url`.
2. WHEN a project name is resolvable AND `base_url` is a non-empty string,
   THE `BetterAuth::Telemetry.project_id` method SHALL return the Base64
   encoding of the SHA-256 digest of the byte concatenation
   `base_url + project_name`.
3. WHEN a project name is resolvable AND `base_url` is `nil` or empty, THE
   `BetterAuth::Telemetry.project_id` method SHALL return the Base64
   encoding of the SHA-256 digest of `project_name`.
4. WHEN no project name is resolvable AND `base_url` is a non-empty string,
   THE `BetterAuth::Telemetry.project_id` method SHALL return the Base64
   encoding of the SHA-256 digest of `base_url`.
5. WHEN no project name is resolvable AND `base_url` is `nil` or empty,
   THE `BetterAuth::Telemetry.project_id` method SHALL return a random
   identifier produced by `SecureRandom`-backed alphanumeric generation of
   length 32 (matching upstream `generateId(32)` over `[a-zA-Z0-9]`).
6. THE `BetterAuth::Telemetry.project_id` method SHALL memoize its return
   value per process so that subsequent calls with any `base_url` argument
   return the cached value, mirroring the upstream module-level
   `projectIdCached` variable.
7. THE `BetterAuth::Telemetry.project_id` method SHALL resolve the project
   name from, in order: `options.app_name` when not the default
   `"Better Auth"`, the value of `Bundler.locked_gems&.specs&.first&.name`
   when a Gemfile.lock is present, or `File.basename(Bundler.root.to_s)`
   when Bundler is loaded; SHALL return `nil` for the project name
   otherwise.
8. THE `BetterAuth::Telemetry.project_id` method SHALL NOT raise when
   Bundler is not loaded or `Bundler.locked_gems` raises; failures SHALL
   degrade to the next fallback in the chain.

### Requirement 15: Public API surface

**User Story:** As a Better Auth Ruby user, I want a small, well-named public
surface for the telemetry gem, so that I can call it from my own code or
from the integration point in core.

#### Acceptance Criteria

1. THE Telemetry_Package SHALL expose the module method
   `BetterAuth::Telemetry.create(options, context = nil)`. THE return value
   SHALL respond to `#publish(event)` and SHALL be safe to call from any
   thread.
2. THE Telemetry_Package SHALL expose the class
   `BetterAuth::Telemetry::Publisher`. Instances SHALL respond to
   `#publish(event)` and SHALL accept a hash event with at minimum
   `:type` (String) and `:payload` (Hash) keys.
3. THE Telemetry_Package SHALL expose the namespace
   `BetterAuth::Telemetry::Detectors` containing at least the modules
   `Runtime`, `Environment`, `SystemInfo`, `Database`, `Framework`,
   `ProjectInfo`, and `AuthConfig`. Each module SHALL respond to `.call`
   with the contracts defined in Requirements 7 through 13.
4. THE Telemetry_Package SHALL accept the same `context` keys as upstream:
   `:custom_track`, `:database`, `:adapter`, `:skip_test_check`. Snake_case
   keys SHALL be the canonical Ruby form; the package SHALL also accept
   the camelCase variants (`customTrack`, `skipTestCheck`) for parity with
   callers that mirror upstream type definitions.

### Requirement 16: Soft integration into BetterAuth::Auth

**User Story:** As a `better_auth` core user who has not installed
`better_auth-telemetry`, I want core to keep working unchanged, so that
telemetry stays a strictly additive package.

#### Acceptance Criteria

1. WHEN the `better_auth/telemetry` file is loadable via `require`, THE
   `BetterAuth::Auth#initialize` method SHALL invoke
   `BetterAuth::Telemetry.create(@options, telemetry_context)` where
   `telemetry_context` provides `database:` and `adapter:` populated from
   the resolved adapter class name.
2. IF `require "better_auth/telemetry"` raises a `LoadError`, THEN THE
   `BetterAuth::Auth#initialize` method SHALL rescue the `LoadError` and
   continue initializing core without raising, mirroring how
   `better_auth.rb` already soft-loads
   `better_auth/plugins/stripe` and `better_auth/plugins/expo`.
3. THE telemetry invocation in `BetterAuth::Auth#initialize` SHALL run
   AFTER plugin registry initialization and adapter setup, so that
   `telemetry_context[:adapter]` reflects the final adapter class.
4. THE telemetry invocation in `BetterAuth::Auth#initialize` SHALL NOT
   block initialization for more than the bounded HTTP timeout from
   Requirement 5.8 even if the endpoint is unreachable.
5. IF telemetry creation raises any `StandardError`, THEN THE
   `BetterAuth::Auth#initialize` method SHALL rescue the error, log it at
   error level, and continue, so that telemetry never breaks application
   startup.
6. THE Telemetry_Publisher instance returned from creation SHALL be
   exposed on the `BetterAuth::Auth` instance via a reader (for example
   `BetterAuth::Auth#telemetry`) so that subsequent code can call
   `auth.telemetry.publish(...)`. WHEN telemetry was disabled or the gem
   was not loadable, THE reader SHALL return a noop publisher whose
   `#publish(event)` is safe to call.

### Requirement 17: Release manifest updates

**User Story:** As a release engineer, I want `.release.yml` updated, so
that release tooling versions, pins, and cuts both telemetry packages
correctly.

#### Acceptance Criteria

1. THE Release_Manifest SHALL list the path
   `packages/better_auth-telemetry/lib/better_auth/telemetry/version.rb`
   under the `version_files` array.
2. THE Release_Manifest SHALL list the path
   `packages/openauth-telemetry/openauth-telemetry.gemspec` under the
   `literal_gemspec_versions` array.
3. THE Release_Manifest SHALL include a key
   `packages/openauth-telemetry/openauth-telemetry.gemspec` under the
   `pinned_dependencies` map whose value is a list containing the literal
   string `"better_auth-telemetry"`.
4. THE Release_Manifest top-level `version` field SHALL remain `"0.8.0"`
   for the initial release and SHALL NOT be modified by this feature.

### Requirement 18: AGENTS.md update

**User Story:** As a future maintainer, I want the repository AGENTS.md to
list the new packages, so that the package table stays the canonical index
of monorepo gems.

#### Acceptance Criteria

1. THE root file `AGENTS.md` SHALL include a table row for
   `packages/better_auth-telemetry` whose Purpose column describes it as
   the canonical telemetry gem (opt-in usage analytics, port of
   `@better-auth/telemetry`).
2. THE root file `AGENTS.md` SHALL include a table row for
   `packages/openauth-telemetry` consistent with the existing
   `packages/openauth*` row note (alias gem that installs the
   corresponding `better_auth-telemetry` package).
3. THE update to `AGENTS.md` SHALL preserve the existing alphabetical
   grouping and column structure of the Packages table.

### Requirement 19: Upstream files remain unmodified

**User Story:** As a maintainer who treats the vendored upstream as a
read-only source of truth, I want the port to leave upstream files alone,
so that we can re-vendor cleanly on future upstream releases.

#### Acceptance Criteria

1. THE port SHALL NOT modify any file under the Upstream_Tree directory
   `upstream/better-auth/1.6.9/`.
2. THE port SHALL NOT modify
   `upstream/better-auth/1.6.9/.github/workflows/release.yml` or any other
   file under `upstream/better-auth/1.6.9/.github/`.
3. WHERE this repository's own CI workflow under `.github/workflows/` is
   already responsible for releasing gems listed in the Release_Manifest,
   THE port SHALL achieve telemetry-package release coverage by updating
   only the Release_Manifest as defined in Requirement 17, and SHALL NOT
   require new repo-level workflow files.

### Requirement 20: Test injection seam and telemetry-specific tests

**User Story:** As a contributor, I want the Telemetry_Package to be
testable without mocking HTTP, so that the test suite stays fast,
deterministic, and free of network dependencies.

#### Acceptance Criteria

1. THE Telemetry_Package SHALL accept `context[:custom_track]` (and the
   camelCase alias `:customTrack`) as a callable. WHEN provided, the
   publisher SHALL forward every event to that callable instead of
   issuing HTTP requests.
2. THE Telemetry_Package SHALL ship a Minitest test suite under
   `packages/better_auth-telemetry/test/` that exercises:
   1. opt-in via `options[:telemetry][:enabled] = true` plus
      `context[:skip_test_check] = true`,
   2. opt-in via `BETTER_AUTH_TELEMETRY=1` plus `skip_test_check`,
   3. opt-out by default in a Test_Environment without `skip_test_check`,
   4. explicit `options[:telemetry][:enabled] = false` overriding env
      opt-in,
   5. noop behavior when both endpoint and `custom_track` are absent,
   6. debug mode logging without HTTP delivery,
   7. init payload shape (top-level keys + `anonymousId` + `runtime` +
      `environment`),
   8. config redaction parity for the fields enumerated in Requirement
      13.3 (using a representative `BetterAuth::Configuration`),
   9. `Custom_Track` raising does not propagate out of `#publish`,
   10. project_id memoization across repeated calls.
3. THE Telemetry_Package tests SHALL NOT use mocks for HTTP delivery; they
   SHALL exercise HTTP paths either by injecting `custom_track` or by
   spinning up a local `WEBrick`/`TCPServer`-based recording endpoint and
   pointing `BETTER_AUTH_TELEMETRY_ENDPOINT` at it.
4. THE Telemetry_Package tests SHALL include round-trip property coverage
   for the emitted JSON payload: for any generated event whose values are
   JSON-encodable Ruby primitives, `JSON.parse(JSON.generate(event))`
   SHALL equal the original event with deeply normalized keys (string vs
   symbol equivalence treated according to the package's documented
   normalization).
5. THE Telemetry_Package tests SHALL include a property that, for any
   generated `BetterAuth::Configuration`-shaped options hash with fields
   from the redaction list in Requirement 13.3 set to non-empty strings,
   the corresponding telemetry payload field equals `true` (boolean
   redaction is applied) and never leaks the original string.
6. THE Telemetry_Package tests SHALL include a property that
   `BetterAuth::Telemetry.project_id` is idempotent across repeated calls
   within a single process: calling it N times with any sequence of
   `base_url` arguments after the first call SHALL return a value `==` to
   the first call's return value.
7. THE Telemetry_Package tests SHALL include a property that the
   environment classifier returns one of `{"production", "ci", "test",
   "development"}` for any generated combination of relevant env
   variables, and that the precedence rule
   `production > ci > test > development` from Requirement 8 holds.
8. WHERE the `prop_check` gem (the property-testing library already used
   elsewhere in this repository, if installed) is available, THE
   Telemetry_Package tests SHALL use it for the properties listed in
   20.4 through 20.7; otherwise the tests SHALL implement those
   properties using Minitest plus deterministic `SecureRandom`-seeded
   inputs covering the boundary cases enumerated in those requirements.

### Requirement 21: Logging hook reuse

**User Story:** As an operator with a custom logger configured on
`BetterAuth::Configuration`, I want telemetry diagnostics to flow through
that same logger, so that I do not need a second logging configuration for
the telemetry path.

#### Acceptance Criteria

1. WHEN `options.logger` is configured, THE Telemetry_Package SHALL emit
   debug-mode event logs and rescued-error logs through `options.logger`.
2. WHEN `options.logger` is not configured, THE Telemetry_Package SHALL
   emit debug-mode event logs and rescued-error logs through the default
   `BetterAuth::Logger` (the same default fallback used elsewhere in
   `packages/better_auth/`).
3. IF the configured logger raises while logging, THEN THE
   Telemetry_Package SHALL rescue the logging error and continue, so that
   logging failures never propagate out of `#publish`.
