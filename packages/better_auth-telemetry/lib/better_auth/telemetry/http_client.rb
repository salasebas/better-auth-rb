# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "version"

module BetterAuth
  module Telemetry
    # Synchronous JSON-over-HTTP delivery used by the telemetry publisher
    # when an endpoint is configured and debug mode is off. Implemented on
    # top of `Net::HTTP` so the gem ships with zero external HTTP runtime
    # dependencies (Requirement 1.8).
    #
    # Every transport-level failure (DNS errors, refused connections, TLS
    # errors, JSON encoding errors, malformed URLs, timeouts, non-2xx
    # responses surfaced as exceptions) is rescued at the `StandardError`
    # boundary and routed through the supplied logger at error level.
    # Non-`StandardError` exceptions (`Interrupt`, `SystemExit`,
    # `SignalException`, `NoMemoryError`) are intentionally allowed to
    # propagate, matching the "fail closed on signals" convention used by
    # the rest of the telemetry pipeline.
    #
    # The method always returns `nil`, regardless of success, failure, or
    # response status. Callers MUST treat it strictly as fire-and-forget;
    # the response body and status are intentionally not exposed because
    # consumers should never make publish decisions based on transport
    # outcomes (Requirements 5.3, 5.6, 5.8).
    #
    # ## Timeouts
    #
    # `open_timeout` and `read_timeout` are both bounded at 5 seconds so
    # telemetry delivery can never block application initialization for
    # an unbounded period (Requirement 5.8).
    #
    # ## Headers
    #
    # - `Content-Type: application/json`
    # - `User-Agent: better_auth-telemetry/<VERSION>` where `<VERSION>` is
    #   {BetterAuth::Telemetry::VERSION}.
    #
    # @example successful delivery
    #   BetterAuth::Telemetry::HttpClient.post_json(
    #     "https://telemetry.example.com/ingest",
    #     { type: "init", payload: {} },
    #     logger: logger_adapter
    #   ) # => nil
    #
    # @example unreachable host
    #   BetterAuth::Telemetry::HttpClient.post_json(
    #     "http://127.0.0.1:1",
    #     { type: "init", payload: {} },
    #     logger: logger_adapter
    #   ) # => nil; logger.error called once
    module HttpClient
      # Bounded `open_timeout` for `Net::HTTP.start`. See Requirement 5.8.
      OPEN_TIMEOUT_SECONDS = 5

      # Bounded `read_timeout` for `Net::HTTP.start`. See Requirement 5.8.
      READ_TIMEOUT_SECONDS = 5

      # Bounded `write_timeout` for request-body writes when supported by
      # the active Ruby runtime.
      WRITE_TIMEOUT_SECONDS = 5

      # Issue a synchronous JSON `POST` to `url`. Always returns `nil` and
      # never raises a `StandardError`.
      #
      # @param url [String] the absolute endpoint URL. `https` is treated
      #   as TLS-enabled (`use_ssl: true`).
      # @param body [Hash, Array, Object] the payload, encoded via
      #   `JSON.generate`.
      # @param logger [#error] a logger-shaped object (typically
      #   {BetterAuth::Telemetry::LoggerAdapter}) used to record
      #   transport failures at error level.
      # @return [nil]
      def self.post_json(url, body, logger:)
        uri = URI.parse(url)

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["User-Agent"] = "better_auth-telemetry/#{BetterAuth::Telemetry::VERSION}"
        request.body = JSON.generate(body)

        Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: OPEN_TIMEOUT_SECONDS,
          read_timeout: READ_TIMEOUT_SECONDS,
          write_timeout: WRITE_TIMEOUT_SECONDS
        ) do |http|
          response = http.request(request)
          unless response.is_a?(Net::HTTPSuccess)
            logger.error(
              "[better-auth.telemetry] http delivery failed: HTTP #{response.code} #{response.message}"
            )
          end
        end

        nil
      rescue => e
        logger.error("[better-auth.telemetry] http delivery failed: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
