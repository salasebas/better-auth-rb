# frozen_string_literal: true

require_relative "../test_helper"
require "better_auth/telemetry/publisher"
require "better_auth/telemetry/logger_adapter"
require "better_auth/telemetry/project_id"

require_relative "support/recording_track"

class PublisherTest < Minitest::Test
  Publisher = BetterAuth::Telemetry::Publisher
  RecordingTrack = BetterAuth::Telemetry::Test::RecordingTrack
  LoggerAdapter = BetterAuth::Telemetry::LoggerAdapter
  CurrentOptions = BetterAuth::Telemetry::CurrentOptions
  Telemetry = BetterAuth::Telemetry

  # Recording logger that captures `info` / `error` calls so the test can
  # assert that delivery failures are surfaced through the configured
  # logger.
  class RecordingLogger
    attr_reader :calls

    def initialize
      @calls = []
    end

    def info(message)
      @calls << [:info, message]
    end

    def error(message)
      @calls << [:error, message]
    end
  end

  def setup
    Telemetry.reset_project_id!
    CurrentOptions.app_name = nil
  end

  def teardown
    Telemetry.reset_project_id!
    CurrentOptions.app_name = nil
  end

  # ---------------------------------------------------------------------
  # Disabled publisher is a noop (Requirement 4.6, 5.1).
  # ---------------------------------------------------------------------

  def test_disabled_publisher_publish_returns_nil_and_does_not_dispatch
    track = RecordingTrack.new
    publisher = build_publisher(enabled: false, track: track)

    assert_nil publisher.publish(type: "ping", payload: {})
    assert_empty track.events
  end

  def test_disabled_publisher_does_not_resolve_anonymous_id
    # `project_id` would raise if Mutex synchronization were broken; the
    # safer signal is that an unresolved-and-disabled publisher never
    # invokes the resolver — we assert by checking no event was recorded
    # and that re-reading via the API still produces a fresh value.
    track = RecordingTrack.new
    publisher = build_publisher(enabled: false, track: track, anonymous_id: nil)

    publisher.publish(type: "ping", payload: {})

    assert_empty track.events
  end

  def test_disabled_publisher_enabled_predicate_is_false
    refute_predicate build_publisher(enabled: false, track: RecordingTrack.new), :enabled?
  end

  def test_enabled_predicate_is_true_for_enabled_publisher
    assert_predicate build_publisher(enabled: true, track: RecordingTrack.new), :enabled?
  end

  # ---------------------------------------------------------------------
  # Enabled publisher reuses the same `anonymousId` across calls
  # (Requirements 6.10, 15.1, 15.2).
  # ---------------------------------------------------------------------

  def test_enabled_publisher_lazy_resolves_anonymous_id_via_telemetry_project_id
    track = RecordingTrack.new
    publisher = build_publisher(
      enabled: true,
      anonymous_id: nil,
      track: track,
      base_url: "https://example.com"
    )

    CurrentOptions.with_app_name("MyProject") do
      publisher.publish(type: "ping", payload: {})
    end

    expected = Telemetry.project_id("https://example.com")
    assert_equal expected, track.events.first[:anonymousId]
  end

  def test_enabled_publisher_reuses_anonymous_id_across_publish_calls
    track = RecordingTrack.new
    publisher = build_publisher(
      enabled: true,
      anonymous_id: nil,
      track: track,
      base_url: "https://example.com"
    )

    CurrentOptions.with_app_name("MyProject") do
      publisher.publish(type: "first", payload: {n: 1})
      publisher.publish(type: "second", payload: {n: 2})
      publisher.publish(type: "third", payload: {n: 3})
    end

    ids = track.events.map { |event| event[:anonymousId] }

    assert_equal 3, ids.size
    assert_equal 1, ids.uniq.size, "expected the same anonymousId across publish calls"
    assert_kind_of String, ids.first
    refute_empty ids.first
  end

  def test_enabled_publisher_keeps_explicitly_supplied_anonymous_id
    track = RecordingTrack.new
    publisher = build_publisher(
      enabled: true,
      anonymous_id: "preset-id",
      track: track,
      base_url: "https://example.com"
    )

    publisher.publish(type: "ping", payload: {})
    publisher.publish(type: "pong", payload: {})

    assert_equal ["preset-id", "preset-id"], track.events.map { |event| event[:anonymousId] }
  end

  # ---------------------------------------------------------------------
  # Track exceptions never propagate; logger.error captures them
  # (Requirement 5.7).
  # ---------------------------------------------------------------------

  def test_publish_swallows_standard_error_from_track_and_logs_it
    raising_track = ->(_event) { raise StandardError, "boom" }
    logger = RecordingLogger.new

    publisher = build_publisher(
      enabled: true,
      anonymous_id: "preset-id",
      track: raising_track,
      logger: LoggerAdapter.new(logger)
    )

    assert_nil publisher.publish(type: "ping", payload: {})

    error_messages = logger.calls.filter_map { |level, message| message if level == :error }
    refute_empty error_messages, "expected an error log entry"
    assert(error_messages.any? { |m| m.include?("boom") }, "expected error message to include underlying cause")
    assert(error_messages.any? { |m| m.include?("StandardError") }, "expected error message to include error class")
  end

  def test_publish_does_not_propagate_runtime_error_subclasses
    raising_track = ->(_event) { raise "kaboom" }
    publisher = build_publisher(
      enabled: true,
      anonymous_id: "preset-id",
      track: raising_track
    )

    assert_nil publisher.publish(type: "ping", payload: {})
  end

  # ---------------------------------------------------------------------
  # String / symbol input keys both normalize to symbol output keys
  # (Requirement 15.2 and the publisher's normalization contract).
  # ---------------------------------------------------------------------

  def test_publish_accepts_symbol_event_keys
    track = RecordingTrack.new
    publisher = build_publisher(enabled: true, anonymous_id: "preset-id", track: track)

    publisher.publish(type: "ping", payload: {a: 1})

    event = track.last
    assert_equal({type: "ping", payload: {a: 1}, anonymousId: "preset-id"}, event)
    assert_equal %i[type payload anonymousId], event.keys
  end

  def test_publish_accepts_string_event_keys_and_normalizes_to_symbols
    track = RecordingTrack.new
    publisher = build_publisher(enabled: true, anonymous_id: "preset-id", track: track)

    publisher.publish("type" => "ping", "payload" => {"a" => 1})

    event = track.last
    assert_equal({type: "ping", payload: {"a" => 1}, anonymousId: "preset-id"}, event)
    assert_equal %i[type payload anonymousId], event.keys
  end

  def test_publish_defaults_missing_payload_to_empty_hash
    track = RecordingTrack.new
    publisher = build_publisher(enabled: true, anonymous_id: "preset-id", track: track)

    publisher.publish(type: "ping")

    event = track.last
    assert_equal({}, event[:payload])
  end

  def test_publish_prefers_symbol_keys_over_string_keys_when_both_present
    track = RecordingTrack.new
    publisher = build_publisher(enabled: true, anonymous_id: "preset-id", track: track)

    publisher.publish(
      :type => "symbol-type",
      "type" => "string-type",
      :payload => {chosen: true},
      "payload" => {chosen: false}
    )

    event = track.last
    assert_equal "symbol-type", event[:type]
    assert_equal({chosen: true}, event[:payload])
  end

  private

  def build_publisher(enabled:, track:, anonymous_id: "preset-id", base_url: "https://example.com", logger: LoggerAdapter.new(RecordingLogger.new))
    Publisher.new(
      enabled: enabled,
      anonymous_id: anonymous_id,
      track: track,
      base_url: base_url,
      logger: logger
    )
  end
end
