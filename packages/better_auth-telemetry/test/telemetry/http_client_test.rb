# frozen_string_literal: true

require_relative "../test_helper"
require "better_auth/telemetry/http_client"
require "better_auth/telemetry/version"
require_relative "support/local_endpoint_server"
require "json"

class HttpClientTest < Minitest::Test
  HttpClient = BetterAuth::Telemetry::HttpClient
  LocalEndpointServer = BetterAuth::Telemetry::Test::LocalEndpointServer

  # Logger that records every dispatched message keyed by level. Mirrors
  # the {LoggerAdapter} surface (`#info` / `#error`) so it can be passed
  # straight into `HttpClient.post_json`.
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

  def teardown
    @server&.stop
  end

  # ---------------------------------------------------------------------
  # Success path: posts to LocalEndpointServer and asserts captured wire
  # format (path, headers, body).
  # ---------------------------------------------------------------------

  def test_post_json_delivers_payload_to_local_endpoint
    @server = LocalEndpointServer.new
    logger = RecordingLogger.new

    payload = {
      type: "init",
      anonymousId: "test-anon-id",
      payload: {config: {redacted: true}, runtime: {name: "ruby"}}
    }

    result = HttpClient.post_json(@server.url, payload, logger: logger)

    assert_nil result, "post_json must always return nil"
    assert_empty logger.calls, "logger must not be touched on success"

    captured = @server.captured
    refute_nil captured, "LocalEndpointServer should have captured the POST"

    assert_equal "/telemetry", captured.path
    assert_equal "application/json", captured.headers["content-type"]
    assert_equal(
      "better_auth-telemetry/#{BetterAuth::Telemetry::VERSION}",
      captured.headers["user-agent"]
    )

    parsed = JSON.parse(captured.body)
    expected = {
      "type" => "init",
      "anonymousId" => "test-anon-id",
      "payload" => {
        "config" => {"redacted" => true},
        "runtime" => {"name" => "ruby"}
      }
    }
    assert_equal expected, parsed
  end

  # ---------------------------------------------------------------------
  # Failure path: closed port → rescue, log error, return nil.
  # ---------------------------------------------------------------------

  def test_post_json_returns_nil_and_logs_error_when_endpoint_is_unreachable
    logger = RecordingLogger.new

    result = HttpClient.post_json(
      "http://127.0.0.1:1",
      {type: "init", payload: {}},
      logger: logger
    )

    assert_nil result, "post_json must always return nil, even on failure"

    error_calls = logger.calls.select { |entry| entry.first == :error }
    assert_equal 1, error_calls.size, "logger.error must be called exactly once on failure"

    _level, message = error_calls.first
    assert_includes message, "[better-auth.telemetry]"
    assert_includes message, "http delivery failed"
  end
end
