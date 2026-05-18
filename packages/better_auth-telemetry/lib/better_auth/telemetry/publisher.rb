# frozen_string_literal: true

require_relative "project_id"

module BetterAuth
  module Telemetry
    # Publisher returned from {BetterAuth::Telemetry.create} when telemetry is
    # opted-in. The publisher is delivery-agnostic: it does not know whether
    # the configured `track` callable forwards events over HTTP, hands them to
    # a host-supplied `custom_track`, or routes them through the debug logger.
    # All of that branching is built into the `track` lambda once at
    # `create`-time, and the `Publisher` simply normalizes each event and
    # forwards it through (Requirements 5.6, 5.7, 6.10, 15.1, 15.2).
    #
    # ## Responsibilities
    #
    # 1. Short-circuit to `nil` when `enabled` is `false`, so a disabled
    #    publisher is a noop. `#enabled?` reports the flag verbatim.
    # 2. Lazily resolve `anonymous_id` on the first `#publish` call by
    #    delegating to {BetterAuth::Telemetry.project_id} when the publisher
    #    was constructed without one. The result is cached on the instance,
    #    so subsequent `#publish` calls reuse the same `anonymousId`.
    # 3. Normalize each event hash to symbol keys with the upstream wire
    #    shape (`type`, `payload`, `anonymousId`). Both `:type`/`:payload`
    #    and `"type"`/`"payload"` input keys are accepted; missing
    #    `:payload` falls back to `{}`.
    # 4. Forward the normalized event through `track.call(event)` and
    #    rescue any `StandardError` raised by the callable, routing the
    #    failure through `logger.error(...)` and returning `nil`. Errors in
    #    HTTP delivery, custom_track callbacks, or JSON encoding therefore
    #    never escape `#publish`.
    #
    # The publisher is intentionally stateless beyond the cached
    # `anonymous_id`: there is no internal queue and no batching. It calls
    # the supplied `track` lambda synchronously; the HTTP track implementation
    # may then hand the actual POST to a short-lived background thread.
    #
    # @example wiring with a `RecordingTrack` (test seam)
    #   recorder = BetterAuth::Telemetry::Test::RecordingTrack.new
    #   publisher = BetterAuth::Telemetry::Publisher.new(
    #     enabled: true,
    #     anonymous_id: nil,
    #     track: recorder,
    #     base_url: "https://example.com",
    #     logger: BetterAuth::Telemetry::LoggerAdapter.from(nil)
    #   )
    #   publisher.publish(type: "ping", payload: {})
    #   recorder.last # => { type: :ping, payload: {}, anonymousId: "..." }
    class Publisher
      # @param enabled [Boolean] whether the publisher should forward events.
      #   When `false`, every `#publish` call is a noop returning `nil`.
      # @param anonymous_id [String, nil] the resolved anonymous project id,
      #   or `nil` to defer resolution to the first `#publish` call.
      # @param track [#call] callable that receives the normalized event
      #   hash. Built once by `BetterAuth::Telemetry.create` and closes over
      #   the chosen delivery mode (custom_track, debug, or http).
      # @param base_url [String, nil] the host's base URL, forwarded to
      #   {BetterAuth::Telemetry.project_id} when lazy-resolving
      #   `anonymous_id`.
      # @param logger [#error] log adapter used to surface delivery
      #   failures (`StandardError`) raised by `track`.
      def initialize(enabled:, anonymous_id:, track:, base_url:, logger:)
        @enabled = enabled
        @anonymous_id = anonymous_id
        @track = track
        @base_url = base_url
        @logger = logger
      end

      # Forward an event through the configured `track` callable.
      #
      # Returns `nil` when the publisher is disabled. Otherwise normalizes
      # the input event to `{type:, payload:, anonymousId:}` (symbol keys),
      # lazy-resolves `anonymous_id` on first use, and dispatches via
      # `track.call(event_to_emit)`. Any `StandardError` raised by `track`
      # is rescued and logged at error level; the call still returns `nil`.
      #
      # The `event` argument may carry either symbol (`:type`, `:payload`)
      # or string (`"type"`, `"payload"`) keys; missing `:payload` defaults
      # to `{}`. Output keys are always symbols, matching the upstream wire
      # format.
      #
      # @param event [Hash] the event to publish; accepts symbol or string
      #   `:type`/`:payload` keys.
      # @return [nil]
      def publish(event)
        return nil unless @enabled

        @anonymous_id ||= BetterAuth::Telemetry.project_id(@base_url)

        event_to_emit = {
          type: event[:type] || event["type"],
          payload: event[:payload] || event["payload"] || {},
          anonymousId: @anonymous_id
        }

        @track.call(event_to_emit)
        nil
      rescue => e
        @logger.error("[better-auth.telemetry] publish failed: #{e.class}: #{e.message}")
        nil
      end

      # @return [Boolean] whether this publisher is opted-in. `false` means
      #   `#publish` is a noop.
      def enabled?
        @enabled
      end
    end
  end
end
