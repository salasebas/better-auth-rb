# frozen_string_literal: true

require_relative "../test_helper"
require "better_auth/telemetry"
require "timeout"

require_relative "support/env_helpers"

class HttpDispatcherTest < Minitest::Test
  Telemetry = BetterAuth::Telemetry
  EnvHelpers = BetterAuth::Telemetry::Test::EnvHelpers

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
  end

  def test_http_delivery_uses_bounded_worker_thread_for_publish_bursts
    logger = RecordingLogger.new
    calls = Queue.new
    release = Queue.new

    EnvHelpers.with_env(
      "BETTER_AUTH_TELEMETRY" => nil,
      "OPEN_AUTH_TELEMETRY" => nil,
      "BETTER_AUTH_TELEMETRY_ENDPOINT" => "https://telemetry.example.test/collect",
      "OPEN_AUTH_TELEMETRY_ENDPOINT" => nil,
      "BETTER_AUTH_TELEMETRY_DEBUG" => nil,
      "OPEN_AUTH_TELEMETRY_DEBUG" => nil,
      "RACK_ENV" => nil,
      "RAILS_ENV" => nil,
      "APP_ENV" => nil,
      "TEST" => nil
    ) do
      BetterAuth::Telemetry::HttpClient.stub(:post_json, lambda { |url, event, logger:|
        calls << [url, event, logger]
        release.pop
        nil
      }) do
        publisher = Telemetry.create(
          {telemetry: {enabled: true}, logger: logger, base_url: "https://example.com"},
          {skip_test_check: true}
        )

        before = Thread.list.count
        20.times { |i| publisher.publish(type: "burst", payload: {i: i}) }
        after = Thread.list.count

        assert_operator after - before, :<=, 1,
          "HTTP telemetry must not allocate one native thread per published event"

        21.times { release << true }
        first = Timeout.timeout(1) { calls.pop }
        assert_equal "init", first[1][:type]
      end
    end
  end
end
