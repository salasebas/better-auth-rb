# frozen_string_literal: true

require_relative "logger_adapter"

module BetterAuth
  module Telemetry
    # Value objects that normalize the heterogeneous shapes the
    # `BetterAuth::Telemetry.create(options, context)` entry point accepts
    # into the small, well-typed surface the rest of the pipeline depends
    # on.
    #
    # Two normalizers ship together:
    #
    # - {NormalizedOptions} wraps the host-supplied `options`. The argument
    #   may be a {BetterAuth::Configuration}, a raw `Hash`, or `nil`.
    # - {NormalizedContext} wraps the optional `context` hash that callers
    #   use to override telemetry-side detection (`custom_track`,
    #   `database`, `adapter`, `skip_test_check`).
    #
    # Both accept either snake_case (`:custom_track`, `:skip_test_check`,
    # `:database`, `:adapter`) or camelCase (`:customTrack`,
    # `:skipTestCheck`) keys, in either symbol or string form, so callers
    # mirroring the upstream TypeScript API do not have to translate keys
    # by hand.
    #
    # Neither value object raises on missing or `nil` input. Missing keys
    # surface as `nil` readers (or `false` for the boolean-defaulting
    # `skip_test_check`).
    module Options
    end

    # Normalized view of the host `options` argument supplied to
    # {BetterAuth::Telemetry.create}.
    #
    # `NormalizedOptions.from(options)` accepts:
    #
    # - a {BetterAuth::Configuration} instance (production path: the value
    #   `BetterAuth::Auth#initialize` passes in),
    # - a `Hash` with snake_case or camelCase keys (mirrors the upstream
    #   `BetterAuthOptions` shape and the common test seam),
    # - or `nil` (every reader returns `nil` / a default-fallback logger).
    #
    # ## Telemetry opt-in precedence
    #
    # `telemetry_enabled` and `telemetry_debug` use the upstream
    # `nil`/`true`/`false` precedence semantics:
    #
    # - `nil` means "not configured at the option layer" (the env layer
    #   may still opt the process in via `BETTER_AUTH_TELEMETRY`).
    # - `true` is an explicit opt-in (subject to the test-environment skip
    #   unless `skip_test_check` overrides it).
    # - `false` is an explicit opt-out that overrides every env opt-in.
    #
    # The readers resolve `telemetry[:enabled]` and `telemetry[:debug]`
    # from either a {BetterAuth::Configuration} or a raw Hash.
    #
    # ## Logger
    #
    # The {#logger} reader always returns a usable {LoggerAdapter}.
    # When the host supplies no logger we fall back to
    # `BetterAuth::Logger.create` via {LoggerAdapter.from} so callers
    # never have to nil-check.
    class NormalizedOptions
      # @return [BetterAuth::Configuration, nil] the raw configuration
      #   instance when the host passed one, otherwise `nil`. Useful for
      #   detectors that want to read additional fields without going
      #   through this value object.
      attr_reader :configuration

      # @return [String, nil] the resolved `app_name` from the
      #   configuration or hash, or `nil` when not configured.
      attr_reader :app_name

      # @return [String, nil] the resolved `base_url` from the
      #   configuration or hash, or `nil` when not configured.
      attr_reader :base_url

      # @return [Boolean, nil] explicit option-layer opt-in / opt-out for
      #   telemetry. `nil` defers to env. See class docs for precedence.
      attr_reader :telemetry_enabled

      # @return [Boolean, nil] explicit option-layer toggle for debug
      #   mode. `nil` defers to `BETTER_AUTH_TELEMETRY_DEBUG`.
      attr_reader :telemetry_debug

      # @return [LoggerAdapter] always-usable logger adapter. Falls back
      #   to the default {BetterAuth::Logger} when no logger was supplied.
      attr_reader :logger

      # Build a {NormalizedOptions} from a {BetterAuth::Configuration},
      # a `Hash`, or `nil`.
      #
      # @param options [BetterAuth::Configuration, Hash, nil]
      # @return [NormalizedOptions]
      def self.from(options)
        if options.is_a?(::BetterAuth::Configuration)
          from_configuration(options)
        elsif options.is_a?(Hash)
          from_hash(options)
        else
          new(
            configuration: nil,
            app_name: nil,
            base_url: nil,
            telemetry_enabled: nil,
            telemetry_debug: nil,
            raw_logger: nil
          )
        end
      end

      # @api private
      def self.from_configuration(configuration)
        telemetry =
          if configuration.respond_to?(:telemetry) && configuration.telemetry.is_a?(Hash)
            configuration.telemetry
          else
            {}
          end
        new(
          configuration: configuration,
          app_name: configuration.app_name,
          base_url: configuration.base_url,
          telemetry_enabled: Options.fetch_key(telemetry, :enabled, :enabled),
          telemetry_debug: Options.fetch_key(telemetry, :debug, :debug),
          raw_logger: configuration.logger
        )
      end

      # @api private
      def self.from_hash(hash)
        telemetry = Options.fetch_key(hash, :telemetry, :telemetry)
        telemetry = telemetry.is_a?(Hash) ? telemetry : {}

        new(
          configuration: nil,
          app_name: Options.fetch_key(hash, :app_name, :appName),
          base_url: Options.fetch_key(hash, :base_url, :baseURL),
          telemetry_enabled: Options.fetch_key(telemetry, :enabled, :enabled),
          telemetry_debug: Options.fetch_key(telemetry, :debug, :debug),
          raw_logger: Options.fetch_key(hash, :logger, :logger)
        )
      end

      # @api private
      def initialize(configuration:, app_name:, base_url:, telemetry_enabled:, telemetry_debug:, raw_logger:)
        @configuration = configuration
        @app_name = app_name
        @base_url = base_url
        @telemetry_enabled = telemetry_enabled
        @telemetry_debug = telemetry_debug
        @logger = LoggerAdapter.from(raw_logger)
      end
    end

    # Normalized view of the optional `context` argument supplied to
    # {BetterAuth::Telemetry.create}.
    #
    # `NormalizedContext.from(context)` accepts:
    #
    # - a `Hash` with snake_case or camelCase keys (`:custom_track` /
    #   `:customTrack`, `:skip_test_check` / `:skipTestCheck`,
    #   `:database`, `:adapter`),
    # - or `nil` (every reader returns its default).
    #
    # Defaults:
    #
    # - {#custom_track} — `nil` when missing.
    # - {#database} — `nil` when missing.
    # - {#adapter} — `nil` when missing.
    # - {#skip_test_check} — `false` when missing or `nil`. Any other
    #   value is preserved as-is so the decision layer can apply its own
    #   truthiness check.
    class NormalizedContext
      # @return [#call, nil] caller-supplied tracker. When present, every
      #   event is delivered to `custom_track.call(event)` instead of via
      #   HTTP. The primary testing seam.
      attr_reader :custom_track

      # @return [String, nil] override for the database name reported in
      #   the init event. Bypasses the {Detectors::Database} chain when
      #   present.
      attr_reader :database

      # @return [String, nil] adapter class name, populated by
      #   `BetterAuth::Auth#initialize`. Pass-through into the auth-config
      #   payload's `adapter` key.
      attr_reader :adapter

      # @return [Boolean] whether to bypass the
      #   `RACK_ENV/RAILS_ENV/APP_ENV == "test"` skip. Does NOT
      #   force-enable telemetry on its own; the opt-in from
      #   {NormalizedOptions} or env still has to be in place.
      attr_reader :skip_test_check

      # Build a {NormalizedContext} from a `Hash` or `nil`.
      #
      # @param context [Hash, nil]
      # @return [NormalizedContext]
      def self.from(context)
        hash = context.is_a?(Hash) ? context : {}
        skip = Options.fetch_key(hash, :skip_test_check, :skipTestCheck)
        new(
          custom_track: Options.fetch_key(hash, :custom_track, :customTrack),
          database: Options.fetch_key(hash, :database, :database),
          adapter: Options.fetch_key(hash, :adapter, :adapter),
          skip_test_check: skip.nil? ? false : skip
        )
      end

      # @api private
      def initialize(custom_track:, database:, adapter:, skip_test_check:)
        @custom_track = custom_track
        @database = database
        @adapter = adapter
        @skip_test_check = skip_test_check
      end
    end

    module Options
      # Look up a key in a hash, accepting symbol and string forms of both
      # the snake_case and camelCase variants. Returns `nil` when nothing
      # matches; an explicit `nil` value also returns `nil`.
      #
      # @param hash [Hash]
      # @param snake [Symbol] snake_case key (canonical Ruby form).
      # @param camel [Symbol] camelCase key (upstream form).
      # @return [Object, nil]
      def self.fetch_key(hash, snake, camel)
        return nil unless hash.is_a?(Hash)

        keys = [snake, camel, snake.to_s, camel.to_s].uniq
        keys.each do |key|
          return hash[key] if hash.key?(key)
        end
        nil
      end
    end
  end
end
