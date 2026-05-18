# frozen_string_literal: true

require "json"

require_relative "env"
require_relative "http_client"
require_relative "http_dispatcher"
require_relative "noop_publisher"
require_relative "options"
require_relative "project_id"
require_relative "publisher"

require_relative "detectors/auth_config"
require_relative "detectors/database"
require_relative "detectors/environment"
require_relative "detectors/framework"
require_relative "detectors/project_info"
require_relative "detectors/runtime"
require_relative "detectors/system_info"

module BetterAuth
  module Telemetry
    # Process-environment variables that mark the host as running inside a
    # test suite. Mirrors {BetterAuth::Configuration#test_environment?}
    # without taking a hard dependency on a `Configuration` instance — the
    # `create` entry point also accepts raw hashes and `nil`.
    TEST_ENV_VARS = %w[RACK_ENV RAILS_ENV APP_ENV].freeze

    # Public entry point used by `BetterAuth::Auth#initialize` (and by
    # tests that exercise the publisher in isolation) to build a
    # publisher tailored to the host's opt-in state.
    #
    # ## Pipeline
    #
    # 1. Normalize the heterogeneous `options` and `context` arguments
    #    into {NormalizedOptions} / {NormalizedContext} value objects so
    #    the rest of the pipeline does not have to repeatedly do
    #    snake/camelCase key lookups.
    # 2. Resolve `endpoint = Env.get("BETTER_AUTH_TELEMETRY_ENDPOINT")`,
    #    honoring the `OPEN_AUTH_*` alias prefix.
    # 3. **Short-circuit**: when both the endpoint and `custom_track`
    #    are absent there is no delivery channel and the publisher
    #    cannot do useful work, so we hand back a {NoopPublisher} and
    #    bypass the rest of the pipeline (Requirement 5.1).
    # 4. **Decision table** (Property 3 / Requirements 4.1–4.7):
    #    compute `enabled` from `(options_enabled, env_truthy,
    #    in_test_env, skip_test_check)` using
    #
    #        opt_in       = options_enabled == true || (options_enabled.nil? && env_truthy)
    #        overridden   = options_enabled == false   # explicit false beats env truthy
    #        in_test_gate = in_test_env && !skip_test_check
    #        enabled      = opt_in && !overridden && !in_test_gate
    #
    # 5. When enabled, build the delivery `track` lambda via
    #    {.build_track}: `custom_track` wins, then debug-mode logging,
    #    then HTTP delivery (Requirements 5.2–5.4, 5.7, 5.9). Each
    #    branch is wrapped in a `rescue StandardError` that routes the
    #    failure through the configured logger (Requirements 21.1,
    #    21.2) so a misbehaving sink never propagates out of the track
    #    callable.
    # 6. **Compose and emit the init event** (Requirement 6): resolve a
    #    stable {.project_id} for the host (scoped to the
    #    {CurrentOptions.with_app_name} block so the `from_app_name`
    #    rule sees the configured `app_name`), invoke each detector
    #    inside {.safely} so a single misbehaving probe degrades to
    #    `nil` instead of aborting the init event, build the
    #    upstream-shaped `{type: "init", anonymousId:, payload: {...}}`
    #    event with camelCase keys, and fire it through the track
    #    lambda exactly once. Errors raised by the dispatch itself
    #    surface through the rescue inside the track lambda.
    # 7. Return a fully-initialized {Publisher} that closes over the
    #    same `track` / `anonymous_id` / `enabled` state so subsequent
    #    `#publish` calls reuse the already-resolved id (Requirement
    #    6.10).
    #
    # The method itself never raises: detectors are wrapped in
    # {.safely}, the track lambda swallows transport failures, and the
    # decision-layer logic is plain hash lookups and env reads.
    #
    # @param options [BetterAuth::Configuration, Hash, nil] the host's
    #   options. `nil` is equivalent to `{}`. When a `Hash`, both
    #   snake_case and camelCase keys are accepted.
    # @param context [Hash, nil] optional caller-supplied context with
    #   `custom_track` / `database` / `adapter` / `skip_test_check`
    #   keys (snake_case or camelCase).
    # @return [NoopPublisher, Publisher] a noop publisher when telemetry
    #   has no delivery channel or is disabled, otherwise a fully-formed
    #   {Publisher}.
    def self.create(options, context = nil)
      norm_opts = NormalizedOptions.from(options)
      norm_ctx = NormalizedContext.from(context)
      logger = norm_opts.logger

      endpoint = Env.get("BETTER_AUTH_TELEMETRY_ENDPOINT")

      # No delivery channel -> short-circuit to noop, regardless of opt-in.
      return NoopPublisher.new if endpoint_absent?(endpoint) && norm_ctx.custom_track.nil?

      enabled = compute_enabled(
        options_enabled: norm_opts.telemetry_enabled,
        env_truthy: Env.truthy?(Env.get("BETTER_AUTH_TELEMETRY")),
        in_test_env: in_test_env?,
        skip_test_check: norm_ctx.skip_test_check ? true : false
      )

      return NoopPublisher.new unless enabled

      track = build_track(
        custom_track: norm_ctx.custom_track,
        debug: debug_mode?(norm_opts),
        endpoint: endpoint,
        logger: logger
      )

      # Resolve the anonymous id under a `with_app_name` scope so the
      # `from_app_name` rule in `ProjectId.resolve_project_name` reads
      # the configured `app_name` even when the underlying
      # `BetterAuth::Telemetry.project_id` cache is cold. Once cached
      # the value is reused for the lifetime of the process; the scope
      # only matters on the very first call.
      anonymous_id = CurrentOptions.with_app_name(norm_opts.app_name) do
        BetterAuth::Telemetry.project_id(norm_opts.base_url)
      end

      init_event = compose_init_event(
        options: options,
        norm_ctx: norm_ctx,
        anonymous_id: anonymous_id
      )

      track.call(init_event)

      Publisher.new(
        enabled: true,
        anonymous_id: anonymous_id,
        track: track,
        base_url: norm_opts.base_url,
        logger: logger
      )
    end

    # Apply the Property 3 decision table.
    #
    # @api private
    # @param options_enabled [Boolean, nil]
    # @param env_truthy [Boolean]
    # @param in_test_env [Boolean]
    # @param skip_test_check [Boolean]
    # @return [Boolean]
    def self.compute_enabled(options_enabled:, env_truthy:, in_test_env:, skip_test_check:)
      opt_in = options_enabled == true || (options_enabled.nil? && env_truthy)
      overridden = options_enabled == false
      in_test_gate = in_test_env && !skip_test_check

      opt_in && !overridden && !in_test_gate
    end

    # @api private
    def self.endpoint_absent?(endpoint)
      endpoint.nil? || (endpoint.respond_to?(:empty?) && endpoint.empty?)
    end

    # @api private
    def self.in_test_env?
      TEST_ENV_VARS.any? { |k| ENV[k] == "test" } || Env.truthy?(ENV["TEST"])
    end

    # Decide whether debug mode is active. The option-layer flag wins
    # when explicitly `true`; otherwise we defer to the env classifier
    # via {Env.truthy?} on `BETTER_AUTH_TELEMETRY_DEBUG` (which honors
    # the `OPEN_AUTH_*` alias prefix as well). Mirrors Requirement 5.4.
    #
    # @api private
    # @param norm_opts [NormalizedOptions]
    # @return [Boolean]
    def self.debug_mode?(norm_opts)
      norm_opts.telemetry_debug == true || Env.truthy?(Env.get("BETTER_AUTH_TELEMETRY_DEBUG"))
    end

    # Build the delivery `track` lambda. Three branches, in priority
    # order (Requirements 5.2 → 5.4):
    #
    # 1. `custom_track` present — invoke `custom_track.call(event)`.
    #    Primary testing seam and the only branch that runs without
    #    requiring `BETTER_AUTH_TELEMETRY_ENDPOINT` to be set.
    # 2. Debug mode active — log the JSON-pretty event via
    #    `logger.info(...)` and skip HTTP entirely (Requirement 5.9).
    # 3. Default — fire-and-forget JSON `POST` through a bounded
    #    {HttpDispatcher}, which calls {HttpClient.post_json} from a
    #    single short-lived worker.
    #
    # Every branch wraps its dispatch in a `rescue StandardError` that
    # routes the failure through `logger.error(...)`, so callable /
    # logger-encoding / HTTP failures never propagate out of the track
    # lambda. The lambda always returns `nil`.
    #
    # @api private
    # @param custom_track [#call, nil]
    # @param debug [Boolean]
    # @param endpoint [String, nil]
    # @param logger [LoggerAdapter]
    # @return [Proc] a one-arg lambda accepting a normalized event hash.
    def self.build_track(custom_track:, debug:, endpoint:, logger:)
      if custom_track
        lambda do |event|
          custom_track.call(event)
          nil
        rescue => e
          logger.error("[better-auth.telemetry] custom_track failed: #{e.class}: #{e.message}")
          nil
        end
      elsif debug
        lambda do |event|
          logger.info(JSON.pretty_generate(event))
          nil
        rescue => e
          logger.error("[better-auth.telemetry] debug log failed: #{e.class}: #{e.message}")
          nil
        end
      else
        dispatcher = HttpDispatcher.new(endpoint: endpoint, logger: logger)
        lambda do |event|
          dispatcher.call(event)
          nil
        rescue => e
          logger.error("[better-auth.telemetry] http dispatch failed: #{e.class}: #{e.message}")
          nil
        end
      end
    end

    # Compose the init event hash emitted at create time.
    #
    # Each detector is invoked through {.safely} so a single failing
    # probe degrades that field to `nil` rather than aborting the
    # whole event composition (Requirement 6.4 / 9.11). The output
    # matches the upstream wire shape: top-level `type`,
    # `anonymousId`, and a `payload` hash with the seven camelCase
    # keys `config`, `runtime`, `database`, `framework`,
    # `environment`, `systemInfo`, `packageManager`
    # (Requirements 6.1, 6.3).
    #
    # `AuthConfig.call` and `Database.call` are passed the original
    # `options` argument (not the {NormalizedOptions} wrapper) because
    # both detectors transparently accept either a
    # {BetterAuth::Configuration} or a raw hash; the normalized view
    # is only consumed by the decision/track-building layer.
    #
    # @api private
    # @param options [BetterAuth::Configuration, Hash, nil]
    # @param norm_ctx [NormalizedContext]
    # @param anonymous_id [String]
    # @return [Hash{Symbol => Object}]
    def self.compose_init_event(options:, norm_ctx:, anonymous_id:)
      payload = {
        config: safely { Detectors::AuthConfig.call(options, norm_ctx) },
        runtime: safely { Detectors::Runtime.call },
        database: safely { Detectors::Database.call(options, norm_ctx) },
        framework: safely { Detectors::Framework.call },
        environment: safely { Detectors::Environment.call },
        systemInfo: safely { Detectors::SystemInfo.call },
        packageManager: safely { Detectors::ProjectInfo.call }
      }

      {
        type: "init",
        anonymousId: anonymous_id,
        payload: payload
      }
    end

    # Run `block` and rescue any `StandardError` to `nil`. Used to
    # bound each detector invocation in {.compose_init_event} so a
    # raising probe degrades only that field rather than aborting the
    # whole init event.
    #
    # Non-`StandardError` exceptions (`Interrupt`, `SystemExit`,
    # `SignalException`, `NoMemoryError`) are intentionally allowed to
    # propagate.
    #
    # @api private
    # @yield the probe to run.
    # @return [Object, nil] whatever the block returns, or `nil` if
    #   the block raised a `StandardError`.
    def self.safely
      yield
    rescue
      nil
    end
  end
end
