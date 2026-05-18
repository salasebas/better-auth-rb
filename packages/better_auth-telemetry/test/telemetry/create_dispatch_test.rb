# frozen_string_literal: true

require_relative "../test_helper"
require "better_auth/telemetry"
require "json"
require "timeout"

require_relative "support/env_helpers"
require_relative "support/local_endpoint_server"
require_relative "support/recording_track"

# Verifies the three dispatch paths {BetterAuth::Telemetry.create} wires
# into its `track` lambda (Requirements 5.2, 5.3, 5.4, 5.7, 5.9, 21.1,
# 21.2):
#
# 1. `custom_track` present — invoked with every event.
# 2. debug mode active — events go through `logger.info(JSON.pretty)`
#    and never reach the HTTP endpoint.
# 3. otherwise — JSON POST to `BETTER_AUTH_TELEMETRY_ENDPOINT` via
#    {HttpClient.post_json}, captured by a {LocalEndpointServer}.
#
# The decision-table layer is exercised separately in
# `create_decision_test.rb`; here every case is `skip_test_check: true`
# with `options[:telemetry][:enabled] = true` so the table outcome is
# always "enabled" and the assertions can focus on the dispatcher.
class CreateDispatchTest < Minitest::Test
  Telemetry = BetterAuth::Telemetry
  Publisher = BetterAuth::Telemetry::Publisher
  EnvHelpers = BetterAuth::Telemetry::Test::EnvHelpers
  RecordingTrack = BetterAuth::Telemetry::Test::RecordingTrack
  LocalEndpointServer = BetterAuth::Telemetry::Test::LocalEndpointServer

  # Logger that records every dispatched message keyed by level. Mirrors
  # the {LoggerAdapter} surface (`#info` / `#error`) so it can be passed
  # straight into telemetry options.
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
  end

  def teardown
    Telemetry.reset_project_id!
    @server&.stop
  end

  # ---------------------------------------------------------------------
  # Path 1: `custom_track` injection (Requirement 5.2).
  # ---------------------------------------------------------------------

  def test_custom_track_receives_every_event_when_injected
    recorder = RecordingTrack.new
    logger = RecordingLogger.new

    EnvHelpers.with_env(neutral_env_overrides) do
      publisher = Telemetry.create(
        {telemetry: {enabled: true}, logger: logger, base_url: "https://example.com"},
        {custom_track: recorder, skip_test_check: true}
      )

      assert_kind_of Publisher, publisher
      assert_predicate publisher, :enabled?

      publisher.publish(type: "ping", payload: {n: 1})
      publisher.publish(type: "pong", payload: {n: 2})
    end

    # `create` emits the init event through the same track at create
    # time (Requirement 6.1, task 5.3), so the recorder sees three
    # events total: init + two user-published events.
    events = recorder.events
    assert_equal 3, events.size, "expected init + every user event to reach custom_track"
    assert_equal "init", events[0][:type]

    user_events = events.drop(1)
    assert_equal "ping", user_events[0][:type]
    assert_equal({n: 1}, user_events[0][:payload])
    assert_equal "pong", user_events[1][:type]
    assert_equal({n: 2}, user_events[1][:payload])

    refute(
      logger.calls.any? { |level, _| level == :error },
      "custom_track path must not log errors on success"
    )
  end

  # ---------------------------------------------------------------------
  # Path 2: debug mode (Requirements 5.4, 5.9).
  # ---------------------------------------------------------------------

  def test_debug_mode_via_options_logs_event_and_skips_http_endpoint
    @server = LocalEndpointServer.new
    logger = RecordingLogger.new

    EnvHelpers.with_env(
      neutral_env_overrides.merge(
        "BETTER_AUTH_TELEMETRY_ENDPOINT" => @server.url,
        "BETTER_AUTH_TELEMETRY_DEBUG" => nil,
        "OPEN_AUTH_TELEMETRY_DEBUG" => nil
      )
    ) do
      publisher = Telemetry.create(
        {
          telemetry: {enabled: true, debug: true},
          logger: logger,
          base_url: "https://example.com"
        },
        {skip_test_check: true}
      )

      assert_kind_of Publisher, publisher
      publisher.publish(type: "ping", payload: {n: 1})
    end

    info_messages = logger.calls.filter_map { |level, message| message if level == :info }
    # `create` emits the init event through the debug logger at create
    # time (Requirement 6.1, task 5.3), so the logger sees the init
    # message followed by the user-published `ping` message.
    assert_equal 2, info_messages.size, "debug mode should emit init + user events as info logs"

    init_parsed = JSON.parse(info_messages[0])
    assert_equal "init", init_parsed["type"]

    parsed = JSON.parse(info_messages[1])
    assert_equal "ping", parsed["type"]
    assert_equal({"n" => 1}, parsed["payload"])
    assert parsed["anonymousId"].is_a?(String) && !parsed["anonymousId"].empty?
    # JSON.pretty_generate emits multi-line output.
    assert_includes info_messages[1], "\n", "debug log should be JSON.pretty_generate output"

    assert_nil @server.captured, "debug mode must not perform HTTP delivery"
  end

  def test_debug_mode_via_env_var_logs_event_and_skips_http_endpoint
    @server = LocalEndpointServer.new
    logger = RecordingLogger.new

    EnvHelpers.with_env(
      neutral_env_overrides.merge(
        "BETTER_AUTH_TELEMETRY_ENDPOINT" => @server.url,
        "BETTER_AUTH_TELEMETRY_DEBUG" => "1"
      )
    ) do
      publisher = Telemetry.create(
        {
          telemetry: {enabled: true},
          logger: logger,
          base_url: "https://example.com"
        },
        {skip_test_check: true}
      )

      publisher.publish(type: "ping", payload: {n: 1})
    end

    info_messages = logger.calls.filter_map { |level, message| message if level == :info }
    # init event + user-published `ping` event both go through the
    # debug logger.
    assert_equal 2, info_messages.size

    assert_nil @server.captured, "debug mode (env) must not perform HTTP delivery"
  end

  # ---------------------------------------------------------------------
  # Path 3: HTTP delivery (Requirements 5.3, 5.6, 5.8).
  # ---------------------------------------------------------------------

  def test_http_path_posts_event_to_resolved_endpoint
    @server = LocalEndpointServer.new
    logger = RecordingLogger.new

    EnvHelpers.with_env(
      neutral_env_overrides.merge(
        "BETTER_AUTH_TELEMETRY_ENDPOINT" => @server.url,
        "BETTER_AUTH_TELEMETRY_DEBUG" => nil,
        "OPEN_AUTH_TELEMETRY_DEBUG" => nil
      )
    ) do
      publisher = Telemetry.create(
        {
          telemetry: {enabled: true},
          logger: logger,
          base_url: "https://example.com"
        },
        {skip_test_check: true}
      )

      assert_kind_of Publisher, publisher
      publisher.publish(type: "ping", payload: {n: 1})
    end

    captured = wait_for_captured(@server)
    refute_nil captured, "expected the LocalEndpointServer to capture the POST"
    assert_equal "/telemetry", captured.path
    assert_equal "application/json", captured.headers["content-type"]
    assert_match(%r{\Abetter_auth-telemetry/}, captured.headers["user-agent"])

    # The LocalEndpointServer retains only the first POST, which is
    # now the init event emitted at create time (Requirement 6.1,
    # task 5.3). Asserting on the init event still validates the
    # HTTP delivery contract.
    parsed = JSON.parse(captured.body)
    assert_equal "init", parsed["type"]
    assert_kind_of Hash, parsed["payload"]
    assert parsed["anonymousId"].is_a?(String) && !parsed["anonymousId"].empty?

    refute(
      logger.calls.any? { |level, _| level == :error },
      "http success path must not log errors"
    )
    refute(
      logger.calls.any? { |level, _| level == :info },
      "http path must not write to the debug logger"
    )
  end

  def test_http_path_dispatches_init_event_without_blocking_create
    logger = RecordingLogger.new
    captured = Queue.new

    EnvHelpers.with_env(
      neutral_env_overrides.merge(
        "BETTER_AUTH_TELEMETRY_ENDPOINT" => "https://telemetry.example.test/collect",
        "BETTER_AUTH_TELEMETRY_DEBUG" => nil,
        "OPEN_AUTH_TELEMETRY_DEBUG" => nil
      )
    ) do
      BetterAuth::Telemetry::HttpClient.stub(:post_json, lambda { |url, event, logger:|
        sleep 0.25
        captured << [url, event, logger]
        nil
      }) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        publisher = Telemetry.create(
          {
            telemetry: {enabled: true},
            logger: logger,
            base_url: "https://example.com"
          },
          {skip_test_check: true}
        )
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_kind_of Publisher, publisher
        assert_operator elapsed, :<, 0.1, "HTTP dispatch must not block Telemetry.create"

        url, event, dispatched_logger = Timeout.timeout(1) { captured.pop }
        assert_equal "https://telemetry.example.test/collect", url
        assert_equal "init", event[:type]
        assert_kind_of BetterAuth::Telemetry::LoggerAdapter, dispatched_logger
      end
    end
  end

  private

  # Baseline ENV state shared across the three dispatch tests: clear all
  # telemetry variables and the test-env markers so each test sets only
  # what it needs to drive the dispatcher.
  def neutral_env_overrides
    {
      "BETTER_AUTH_TELEMETRY" => nil,
      "OPEN_AUTH_TELEMETRY" => nil,
      "BETTER_AUTH_TELEMETRY_ENDPOINT" => nil,
      "OPEN_AUTH_TELEMETRY_ENDPOINT" => nil,
      "BETTER_AUTH_TELEMETRY_DEBUG" => nil,
      "OPEN_AUTH_TELEMETRY_DEBUG" => nil,
      "RACK_ENV" => nil,
      "RAILS_ENV" => nil,
      "APP_ENV" => nil
    }
  end

  def wait_for_captured(server)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1

    loop do
      captured = server.captured
      return captured if captured
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end

    nil
  end
end
