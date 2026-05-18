# frozen_string_literal: true

module BetterAuth
  module Telemetry
    # Publisher returned from {BetterAuth::Telemetry.create} when telemetry is
    # disabled, when no `BETTER_AUTH_TELEMETRY_ENDPOINT` is configured and no
    # `custom_track` is supplied, or when the soft-load fallback inside
    # {BetterAuth::Auth#initialize} cannot load the telemetry gem.
    #
    # Calling `#publish` on a `NoopPublisher` is always safe: the method
    # accepts any event-shaped argument, performs no work, raises no error,
    # and returns `nil`. `#enabled?` always reports `false`. This lets
    # callers treat `auth.telemetry` as a non-nullable, always-callable
    # collaborator without having to nil-check before each `publish` call.
    #
    # @example
    #   publisher = BetterAuth::Telemetry::NoopPublisher.new
    #   publisher.publish(type: "ping", payload: {}) # => nil
    #   publisher.enabled?                           # => false
    class NoopPublisher
      # @param _event [Object] any event payload; ignored.
      # @return [nil]
      def publish(_event)
        nil
      end

      # @return [Boolean] always `false`.
      def enabled?
        false
      end
    end
  end
end
