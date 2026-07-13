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

  def test_memory_consume_is_atomic_and_exactly_max_requests_win
    store = BetterAuth::RateLimiter::MemoryStore.new
    ready = Queue.new
    start = Queue.new
    threads = 20.times.map do
      Thread.new do
        ready << true
        start.pop
        store.consume("key", window: 60, max: 5)
      end
    end
    20.times { ready.pop }
    20.times { start << true }

    assert_equal 5, threads.map(&:value).count { |result| result[:allowed] }
  end

  def test_memory_boundary_reset_sweep_and_cap_are_deterministic
    now = 100.0
    clock = -> { now }
    store = BetterAuth::RateLimiter::MemoryStore.new(clock: clock, max_entries: 2)

    assert store.consume("boundary", window: 10, max: 1)[:allowed]
    now = 110.0
    refute store.consume("boundary", window: 10, max: 1)[:allowed]
    now = 110.001
    assert store.consume("boundary", window: 10, max: 1)[:allowed]
    store.set("second", {count: 1}, ttl: 10)
    store.set("third", {count: 1}, ttl: 10)

    assert_equal 2, store.size
    assert_nil store.get("boundary")
  end

  def test_memory_default_cap_is_never_exceeded
    store = BetterAuth::RateLimiter::MemoryStore.new
    100_001.times { |index| store.set("key-#{index}", {count: 1}, ttl: 60) }

    assert_equal 100_000, store.size
    assert_nil store.get("key-0")
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

  def test_custom_consume_is_preferred_and_normalizes_string_result_keys
    storage = AtomicRateLimitStorage.new({"allowed" => false, "retry_after" => 1.2})
    auth = build_auth(rate_limit: {enabled: true, window: 60, max: 2, custom_storage: storage})

    status, headers, = BetterAuth::RateLimiter.new.call(rack_request("GET", "/limited"), auth.context, "/limited")

    assert_equal 429, status
    assert_equal "2", headers.fetch("x-retry-after")
    assert_equal [["127.0.0.1|/limited", {window: 60.0, max: 2}]], storage.calls
    refute storage.legacy_called
  end

  def test_custom_consume_errors_and_malformed_results_propagate
    storage = AtomicRateLimitStorage.new({allowed: true, retry_after: Float::INFINITY})
    auth = build_auth(rate_limit: {enabled: true, custom_storage: storage})
    limiter = BetterAuth::RateLimiter.new

    assert_raises(BetterAuth::APIError) do
      limiter.call(rack_request("GET", "/limited"), auth.context, "/limited")
    end

    storage.error = ArgumentError.new("storage failure")
    error = assert_raises(ArgumentError) do
      limiter.call(rack_request("GET", "/limited"), auth.context, "/limited")
    end
    assert_equal "storage failure", error.message
  end

  def test_legacy_custom_storage_warns_once
    messages = []
    auth = build_auth(
      logger: ->(level, message) { messages << [level, message] },
      rate_limit: {enabled: true, window: 60, max: 10, custom_storage: RecordingRateLimitStorage.new}
    )
    limiter = BetterAuth::RateLimiter.new

    2.times { limiter.call(rack_request("GET", "/limited"), auth.context, "/limited") }

    assert_equal 1, messages.count { |level, message| level == :warn && message.include?("best-effort") }
  end

  def test_secondary_increment_uses_fixed_window_and_migrates_legacy_json_in_place
    storage = IncrementingSecondaryStorage.new
    auth = build_auth(
      secondary_storage: storage,
      rate_limit: {enabled: true, window: 60, max: 1, storage: "secondary-storage"}
    )
    limiter = BetterAuth::RateLimiter.new

    assert_nil limiter.call(rack_request("GET", "/limited"), auth.context, "/limited")
    status, headers, = limiter.call(rack_request("GET", "/limited"), auth.context, "/limited")
    assert_equal 429, status
    assert_equal "60", headers.fetch("x-retry-after")
    assert_equal [60], storage.ttls

    legacy_key = "127.0.0.1|/legacy"
    storage.data[legacy_key] = JSON.generate(key: legacy_key, count: 1, lastRequest: (Time.now.to_f * 1000).to_i)
    status, = limiter.call(rack_request("GET", "/legacy"), auth.context, "/legacy")
    assert_equal 429, status
    assert_kind_of String, storage.data.fetch(legacy_key)
    refute_includes storage.incremented_keys, legacy_key

    storage.data.delete(legacy_key)
    assert_nil limiter.call(rack_request("GET", "/legacy"), auth.context, "/legacy")
    assert_includes storage.incremented_keys, legacy_key
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

  def test_rate_limiter_warns_once_and_uses_shared_bucket_when_client_ip_is_missing
    previous_rack_env = ENV["RACK_ENV"]
    ENV["RACK_ENV"] = "production"
    messages = []
    storage = RecordingRateLimitStorage.new
    auth = build_auth(
      logger: ->(level, message) { messages << [level, message] },
      rate_limit: {enabled: true, window: 60, max: 1, custom_storage: storage}
    )
    limiter = BetterAuth::RateLimiter.new
    env = Rack::MockRequest.env_for("/limited")
    env.delete("REMOTE_ADDR")

    assert_nil limiter.call(Rack::Request.new(env), auth.context, "/limited")
    status, = limiter.call(Rack::Request.new(env), auth.context, "/limited")

    assert_equal 429, status
    assert_equal ["no-trusted-ip|/limited"], storage.keys
    warning_messages = messages.select { |level, message| level == :warn && message.include?("single shared per-path bucket") }
    assert_equal 1, warning_messages.length
  ensure
    if previous_rack_env
      ENV["RACK_ENV"] = previous_rack_env
    else
      ENV.delete("RACK_ENV")
    end
  end

  def test_rotating_raw_forwarded_header_cannot_evade_default_bucket
    auth = build_auth(rate_limit: {enabled: true, window: 60, max: 1})
    limiter = BetterAuth::RateLimiter.new

    assert_nil limiter.call(
      rack_request(
        "GET",
        "/limited",
        headers: {"REMOTE_ADDR" => "203.0.113.10", "HTTP_X_FORWARDED_FOR" => "198.51.100.20"}
      ),
      auth.context,
      "/limited"
    )
    status, = limiter.call(
      rack_request(
        "GET",
        "/limited",
        headers: {"REMOTE_ADDR" => "203.0.113.10", "HTTP_X_FORWARDED_FOR" => "198.51.100.21"}
      ),
      auth.context,
      "/limited"
    )

    assert_equal 429, status
  end

  def test_disable_ip_tracking_still_skips_rate_limiting
    auth = build_auth(
      advanced: {ip_address: {disable_ip_tracking: true}},
      rate_limit: {enabled: true, window: 60, max: 1}
    )
    limiter = BetterAuth::RateLimiter.new

    2.times do
      assert_nil limiter.call(rack_request("GET", "/limited"), auth.context, "/limited")
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

  class AtomicRateLimitStorage
    attr_reader :calls, :legacy_called
    attr_accessor :error

    def initialize(result)
      @result = result
      @calls = []
      @legacy_called = false
    end

    def consume(key, window:, max:)
      raise error if error

      calls << [key, {window: window, max: max}]
      @result
    end

    def get(_key)
      @legacy_called = true
    end

    def set(*)
      @legacy_called = true
    end
  end

  class IncrementingSecondaryStorage
    attr_reader :data, :ttls, :incremented_keys

    def initialize
      @data = {}
      @ttls = []
      @incremented_keys = []
    end

    def get(key)
      data[key]
    end

    def increment(key, ttl)
      incremented_keys << key
      unless data.key?(key)
        data[key] = 0
        ttls << ttl
      end
      data[key] = data[key].to_i + 1
    end

    def set(key, value, _ttl)
      data[key] = value
    end
  end
end
