# frozen_string_literal: true

module BetterAuth
  module Telemetry
    module Test
      # Thread-safe, Proc-compatible recorder used by Telemetry tests as a
      # `custom_track` callable. The recorder appends every event passed
      # through `#call` into a `Mutex`-protected internal array so tests can
      # assert on the captured events without spinning up an HTTP server or
      # using a mocking library.
      #
      # The recorder is intentionally permissive:
      #
      #   - `#call(event)` always returns `nil`, never raises.
      #   - When an optional `max_events:` cap is configured and the buffer
      #     is full, the oldest event is dropped to make room for the new
      #     one (the `call` still returns `nil`).
      #   - When `max_events:` is `nil` (the default) the buffer is
      #     unbounded.
      #
      # Usage:
      #
      #     recorder = BetterAuth::Telemetry::Test::RecordingTrack.new
      #     publisher = BetterAuth::Telemetry.create(
      #       {telemetry: {enabled: true}},
      #       {custom_track: recorder, skip_test_check: true}
      #     )
      #     publisher.publish(type: "ping", payload: {})
      #     recorder.events # => [{type: :ping, ...}]
      #
      # Because it responds to `#call` and `#to_proc`, an instance can be
      # passed anywhere a `Proc`/lambda is expected (including `context`
      # entries that are later invoked with `track.call(event)` or
      # `&track`).
      class RecordingTrack
        # @return [Integer, nil] the maximum number of events to retain, or
        #   `nil` when the buffer is unbounded.
        attr_reader :max_events

        # @param max_events [Integer, nil] optional cap on the number of
        #   retained events. When `nil` (default), the buffer is unbounded.
        def initialize(max_events: nil)
          if !max_events.nil? && (!max_events.is_a?(Integer) || max_events <= 0)
            raise ArgumentError, "max_events must be a positive Integer or nil"
          end

          @max_events = max_events
          @mutex = Mutex.new
          @events = []
        end

        # Record an event. Always returns `nil`, never raises.
        #
        # @param event [Object] the event to record (typically a Hash).
        # @return [nil]
        def call(event)
          @mutex.synchronize do
            @events << event
            @events.shift if @max_events && @events.size > @max_events
          end
          nil
        rescue
          nil
        end

        # @return [Array] a snapshot copy of the recorded events.
        def events
          @mutex.synchronize { @events.dup }
        end

        # Remove all recorded events.
        #
        # @return [void]
        def clear
          @mutex.synchronize { @events.clear }
          nil
        end

        # @return [Object, nil] the most recently recorded event, or `nil`
        #   when no events have been recorded.
        def last
          @mutex.synchronize { @events.last }
        end

        # @return [Integer] the number of currently recorded events.
        def size
          @mutex.synchronize { @events.size }
        end

        # Allow the recorder to be passed wherever a `Proc` is expected via
        # the `&` operator.
        #
        # @return [Proc]
        def to_proc
          method(:call).to_proc
        end
      end
    end
  end
end
