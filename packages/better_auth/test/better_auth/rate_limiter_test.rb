# frozen_string_literal: true

require "rack/mock"
require_relative "../test_helper"

class BetterAuthRateLimiterTest < Minitest::Test
  SECRET = "test-secret-that-is-long-enough-for-validation"

  def test_memory_store_expires_entries_after_ttl
    store = BetterAuth::RateLimiter::MemoryStore.new
    store.set("key", {count: 1}, ttl: 0.01, update: false)

    assert_equal({count: 1}, store.get("key"))
    sleep 0.02
    assert_nil store.get("key")
  end

  def test_rate_limiter_returns_nil_when_disabled
    auth = build_auth(rate_limit: {enabled: false})
    limiter = BetterAuth::RateLimiter.new
    request = rack_request("GET", "/limited")

    assert_nil limiter.call(request, auth.context, "/limited")
  end

  def test_rate_limiter_honors_false_custom_rule_without_counting
    auth = build_auth(
      rate_limit: {
        enabled: true,
        window: 60,
        max: 1,
        custom_rules: {"/unlimited" => false}
      }
    )
    limiter = BetterAuth::RateLimiter.new

    3.times do
      assert_nil limiter.call(rack_request("GET", "/unlimited"), auth.context, "/unlimited")
    end
  end

  def test_rate_limiter_honors_callable_custom_rule
    auth = build_auth(
      rate_limit: {
        enabled: true,
        window: 60,
        max: 100,
        custom_rules: {
          "/dynamic" => ->(_request, current) { current.merge(max: 1) }
        }
      }
    )
    limiter = BetterAuth::RateLimiter.new

    assert_nil limiter.call(rack_request("GET", "/dynamic"), auth.context, "/dynamic")
    status, = limiter.call(rack_request("GET", "/dynamic"), auth.context, "/dynamic")

    assert_equal 429, status
  end

  def test_rate_limiter_accepts_custom_storage_positional_ttl_and_update_flag
    storage = PositionalRateLimitStorage.new
    auth = build_auth(rate_limit: {enabled: true, window: 60, max: 2, custom_storage: storage})
    limiter = BetterAuth::RateLimiter.new

    assert_nil limiter.call(rack_request("GET", "/limited"), auth.context, "/limited")
    assert_nil limiter.call(rack_request("GET", "/limited"), auth.context, "/limited")

    assert_equal 2, storage.calls.length
    assert_equal [false, true], storage.calls.map(&:last)
    storage.calls.each do |(_key, _value, ttl, _update)|
      assert_equal 60, ttl
    end
  end

  def test_rate_limiter_applies_plugin_path_matcher_rule
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      rate_limit: {enabled: true, window: 60, max: 100},
      plugins: [
        {
          id: "plugin-rate-limit",
          rate_limit: [{path_matcher: ->(path) { path.start_with?("/plugin") }, window: 60, max: 1}],
          endpoints: {
            plugin_limited: BetterAuth::Endpoint.new(path: "/plugin/limited", method: "GET") { {ok: true} }
          }
        }
      ]
    )
    limiter = BetterAuth::RateLimiter.new

    assert_nil limiter.call(rack_request("GET", "/plugin/limited"), auth.context, "/plugin/limited")
    status, = limiter.call(rack_request("GET", "/plugin/limited"), auth.context, "/plugin/limited")

    assert_equal 429, status
  end

  def test_rate_limiter_warns_once_when_client_ip_is_missing_outside_development
    previous_rack_env = ENV["RACK_ENV"]
    ENV["RACK_ENV"] = "production"
    messages = []
    auth = build_auth(
      logger: ->(level, message) { messages << [level, message] },
      rate_limit: {enabled: true, window: 60, max: 1}
    )
    limiter = BetterAuth::RateLimiter.new
    env = Rack::MockRequest.env_for("/limited")
    env.delete("REMOTE_ADDR")

    2.times { limiter.call(Rack::Request.new(env), auth.context, "/limited") }

    warning_messages = messages.select { |level, message| level == :warn && message.include?("could not determine client IP address") }
    assert_equal 1, warning_messages.length
  ensure
    if previous_rack_env
      ENV["RACK_ENV"] = previous_rack_env
    else
      ENV.delete("RACK_ENV")
    end
  end

  def test_rate_limiter_uses_request_ip_normalization_for_rate_limit_keys
    storage = RecordingRateLimitStorage.new
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      advanced: {ip_address: {ip_address_headers: ["x-forwarded-for"], ipv6_subnet: 64}},
      rate_limit: {enabled: true, window: 60, max: 1, custom_storage: storage},
      plugins: [
        {
          id: "limited",
          endpoints: {
            limited: BetterAuth::Endpoint.new(path: "/limited", method: "GET") { {ok: true} }
          }
        }
      ]
    )
    limiter = BetterAuth::RateLimiter.new
    first_ip = "2001:db8:abcd:1234:0000:0000:0000:0001"
    second_ip = "2001:db8:abcd:1234:ffff:ffff:ffff:ffff"

    limiter.call(rack_request("GET", "/limited", headers: {"HTTP_X_FORWARDED_FOR" => first_ip}), auth.context, "/limited")
    limiter.call(rack_request("GET", "/limited", headers: {"HTTP_X_FORWARDED_FOR" => second_ip}), auth.context, "/limited")

    assert_equal 1, storage.keys.length
    assert_match(/\A2001:db8:abcd:1234::\|\/limited\z/, storage.keys.first)
  end

  def test_rate_limiter_applies_default_sign_in_special_rule
    auth = build_auth(rate_limit: {enabled: true, window: 10, max: 100})
    limiter = BetterAuth::RateLimiter.new

    3.times do
      assert_nil limiter.call(rack_request("POST", "/sign-in/email"), auth.context, "/sign-in/email")
    end
    status, = limiter.call(rack_request("POST", "/sign-in/email"), auth.context, "/sign-in/email")

    assert_equal 429, status
  end

  private

  def build_auth(overrides = {})
    BetterAuth.auth(
      {
        base_url: "http://localhost:3000",
        secret: SECRET,
        rate_limit: {enabled: true, window: 60, max: 1},
        plugins: [
          {
            id: "limited",
            endpoints: {
              limited: BetterAuth::Endpoint.new(path: "/limited", method: "GET") { {ok: true} }
            }
          }
        ]
      }.merge(overrides)
    )
  end

  def rack_request(method, path, headers: {})
    Rack::Request.new(
      Rack::MockRequest.env_for(
        path,
        "REQUEST_METHOD" => method,
        "REMOTE_ADDR" => "127.0.0.1"
      ).merge(headers)
    )
  end

  class PositionalRateLimitStorage
    attr_reader :calls

    def initialize
      @data = {}
      @calls = []
    end

    def get(key)
      @data[key]
    end

    def set(*args, **kwargs)
      raise ArgumentError, "keyword arguments are not supported" if kwargs.any?

      key, value, ttl, update = args
      @calls << [key, value, ttl, update]
      @data[key] = value
    end
  end

  class RecordingRateLimitStorage
    attr_reader :keys

    def initialize
      @data = {}
      @keys = []
    end

    def get(key)
      @data[key]
    end

    def set(key, value, ttl: nil, update: false)
      @keys << key unless @keys.include?(key)
      @data[key] = value
    end
  end
end
