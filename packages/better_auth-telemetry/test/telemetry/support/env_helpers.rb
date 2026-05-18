# frozen_string_literal: true

module BetterAuth
  module Telemetry
    module Test
      # Test helper for safely mutating `ENV` inside a single test case.
      # Snapshots only the keys named in `overrides`, applies the new
      # values for the duration of the block, and restores the prior
      # state on the way out — even when the block raises.
      #
      # The classifier (Requirement 8) and opt-in semantics
      # (Requirement 4) read live `ENV`, so individual tests need a
      # narrow, reversible way to drive those code paths without
      # leaking state into the rest of the suite.
      #
      # Usage as a top-level helper:
      #
      #     BetterAuth::Telemetry::Test::EnvHelpers.with_env(
      #       "RAILS_ENV" => "test",
      #       "CI" => nil
      #     ) do
      #       # ENV inside the block reflects the overrides
      #     end
      #
      # Or mixed into a Minitest::Test subclass:
      #
      #     class MyTest < Minitest::Test
      #       include BetterAuth::Telemetry::Test::EnvHelpers
      #
      #       def test_something
      #         with_env("RAILS_ENV" => "production") { ... }
      #       end
      #     end
      #
      # Semantics:
      #
      #   - Only the keys listed in `overrides` are touched. Other
      #     `ENV` entries are left alone.
      #   - A value of `nil` deletes the key for the duration of the
      #     block, regardless of whether it was previously set.
      #   - Non-`nil` values must respond to `#to_s`; the resulting
      #     string is assigned to `ENV[key]` (matching `ENV[]=`
      #     semantics).
      #   - On block exit (normal return, raised exception, or thrown
      #     symbol) every snapshotted key is restored to its prior
      #     value — keys that were originally absent are deleted again,
      #     keys that were originally set are reassigned to their
      #     captured string value.
      #   - The block's return value is propagated to the caller.
      module EnvHelpers
        extend self

        # Run `block` with `ENV` temporarily set to `overrides`,
        # restoring the prior values afterwards.
        #
        # @param overrides [Hash{String=>String,nil}] keys to set, with
        #   `nil` indicating the key should be deleted for the duration
        #   of the block.
        # @yield with `ENV` mutated according to `overrides`.
        # @return [Object] whatever the block returns.
        # @raise [ArgumentError] when no block is given, or when an
        #   override key is not a String.
        def with_env(overrides)
          raise ArgumentError, "with_env requires a block" unless block_given?
          unless overrides.is_a?(Hash)
            raise ArgumentError, "with_env overrides must be a Hash, got #{overrides.class}"
          end

          snapshot = {}
          overrides.each_key do |key|
            unless key.is_a?(String)
              raise ArgumentError, "with_env keys must be Strings, got #{key.inspect}"
            end
            snapshot[key] = ENV[key]
          end

          begin
            overrides.each do |key, value|
              ENV[key] = value&.to_s
            end
            yield
          ensure
            snapshot.each do |key, prior|
              ENV[key] = prior
            end
          end
        end
      end
    end
  end
end
