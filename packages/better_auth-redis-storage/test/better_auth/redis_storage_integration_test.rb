# frozen_string_literal: true

require "json"
require "base64"
require "securerandom"
require "stringio"
require "uri"
require "test_helper"

class RedisStorageIntegrationTest < Minitest::Test
  def setup
    skip "set REDIS_INTEGRATION=1 to run real Redis integration" unless ENV["REDIS_INTEGRATION"] == "1"

    redis_url = ENV["REDIS_URL"] || "redis://localhost:6379/15"
    @redis_url = redis_url
    require "redis"
    @client = Redis.new(url: redis_url)
    @client.ping
    @prefix_root = "better-auth-test:#{SecureRandom.hex(6)}"
    @storage = BetterAuth::RedisStorage.new(client: @client, key_prefix: "#{@prefix_root}:")
    @storage.clear
  rescue LoadError
    skip "redis gem is not available"
  rescue => error
    raise unless defined?(Redis::BaseConnectionError) && error.is_a?(Redis::BaseConnectionError)

    skip "Redis is not reachable at #{redis_url}"
  end

  def teardown
    @storage&.clear
    @client&.del("#{@prefix_root}:outside") if @client && @prefix_root
    @client&.close if @client.respond_to?(:close)
  end

  def test_real_redis_round_trip_on_get_set_delete
    @storage.set("a", "one")
    @storage.set("b", "two", 60)

    assert_equal "one", @storage.get("a")
    assert_equal "two", @storage.get("b")

    @storage.delete("a")

    assert_nil @storage.get("a")
  end

  def test_real_redis_get_and_delete_and_fixed_window_increment
    @storage.set("consume", "value")

    assert_equal "value", @storage.get_and_delete("consume")
    assert_nil @storage.get_and_delete("consume")

    assert_equal 1, @storage.increment("counter", 60)
    first_ttl = @client.ttl("#{@prefix_root}:counter")
    assert_equal 2, @storage.increment("counter", 10)
    second_ttl = @client.ttl("#{@prefix_root}:counter")

    assert_operator first_ttl, :>, 0
    assert_operator second_ttl, :>, 0
    assert_operator second_ttl, :>=, first_ttl - 1
  end

  def test_real_redis_set_if_absent_has_one_winner_and_preserves_first_value
    first = isolated_storage("reservation")
    second = BetterAuth::RedisStorage.new(client: @client, key_prefix: first.key_prefix)

    assert first.set_if_absent("key", "first", 60)
    refute second.set_if_absent("key", "second", 60)
    assert_equal "first", second.get("key")
    assert_operator @client.ttl("#{first.key_prefix}key"), :>, 0
  ensure
    first&.clear
  end

  def test_real_redis_json_list_operations_retain_concurrent_ids
    threads = 20.times.map do |index|
      Thread.new { @storage.json_list_add("api-key:by-ref:integration", "id-#{index}") }
    end
    threads.each(&:join)

    assert_equal (0...20).map { |index| "id-#{index}" }.sort, JSON.parse(@storage.get("api-key:by-ref:integration")).sort

    @storage.json_list_remove("api-key:by-ref:integration", "id-0")
    refute_includes JSON.parse(@storage.get("api-key:by-ref:integration")), "id-0"
  end

  def test_real_redis_json_list_operations_reset_corrupt_objects
    key = "api-key:by-ref:corrupt"
    @client.set("#{@storage.key_prefix}#{key}", '{"id":"not-an-array"}')

    @storage.json_list_add(key, "one")
    assert_equal ["one"], JSON.parse(@storage.get(key))

    @client.set("#{@storage.key_prefix}#{key}", '{"1":"one","3":"three"}')
    @storage.json_list_remove(key, "one")
    assert_nil @storage.get(key)
  end

  def test_real_redis_json_list_operations_preserve_arrays_with_json_whitespace
    key = "api-key:by-ref:whitespace"
    @client.set("#{@storage.key_prefix}#{key}", "  [\"kept\"]\n")

    @storage.json_list_add(key, "new")

    assert_equal ["kept", "new"], JSON.parse(@storage.get(key))
  end

  def test_real_redis_expires_direct_ttl_values
    @storage.set("short", "one", 1)

    assert_operator @client.ttl("#{@prefix_root}:short"), :>, 0

    sleep 1.2

    assert_nil @storage.get("short")
  end

  def test_real_redis_stores_session_data_after_email_signup
    @client.set("#{@prefix_root}:outside", "outside")
    storage = isolated_storage("email-signup")
    auth = build_auth(storage, store_session_in_database: false)

    result = auth.api.sign_up_email(
      body: {
        email: "redis-false-#{SecureRandom.hex(4)}@example.com",
        password: "password123",
        name: "Redis User"
      }
    )

    assert result[:token]
    keys = storage.listKeys
    assert_equal 2, keys.length
    assert keys.any? { |key| key.start_with?("active-sessions-") }
    refute_includes keys, "#{@prefix_root}:outside"
    session_data = session_payload_from_storage(storage)
    assert session_data.fetch("user").fetch("id")
    assert session_data.fetch("session").fetch("id")
    assert_equal result[:token], session_data.fetch("session").fetch("token")
  ensure
    storage&.clear
  end

  def test_real_redis_stores_session_id_when_store_session_in_database_is_true
    storage = isolated_storage("database-session")
    auth = build_auth(storage, store_session_in_database: true)

    result = auth.api.sign_up_email(
      body: {
        email: "redis-true-#{SecureRandom.hex(4)}@example.com",
        password: "password123",
        name: "Redis User"
      }
    )

    assert result[:token]
    keys = storage.listKeys
    assert_equal 2, keys.length
    assert keys.any? { |key| key.start_with?("active-sessions-") }
    session_data = session_payload_from_storage(storage)
    assert session_data.fetch("user").fetch("id")
    assert session_data.fetch("session").fetch("id")
    assert_equal result[:token], session_data.fetch("session").fetch("token")
  ensure
    storage&.clear
  end

  def test_real_redis_stores_stateless_google_oauth_session
    storage = isolated_storage("stateless-google")
    auth = build_stateless_google_auth(storage)
    token_exchange = lambda do |_url, _form|
      {
        "accessToken" => "test-access-token",
        "refreshToken" => "test-refresh-token",
        "idToken" => fake_jwt("sub" => "google-1234567890")
      }
    end

    BetterAuth::SocialProviders::Base.stub(:post_form, token_exchange) do
      status, _headers, body = auth.api.sign_in_social(
        body: {provider: "google", callbackURL: "/callback"},
        as_response: true
      )
      sign_in_data = JSON.parse(body.join)
      state = extract_state(sign_in_data.fetch("url"))

      callback_status, callback_headers, _callback_body = auth.api.callback_oauth(
        params: {providerId: "google"},
        query: {state: state, code: "test-authorization-code"},
        as_response: true
      )

      assert_equal 200, status
      assert_equal 302, callback_status
      assert_includes callback_headers.fetch("location"), "/callback"
      keys = storage.listKeys
      assert_equal 2, keys.length
      session_data = session_payload_from_storage(storage)
      assert session_data.fetch("user").fetch("id")
      assert session_data.fetch("session").fetch("id")
      assert_equal "google-user@example.com", session_data.fetch("user").fetch("email")
    end
  ensure
    storage&.clear
  end

  def test_real_redis_google_oauth_uses_custom_authorization_endpoint
    storage = isolated_storage("custom-google-endpoint")
    custom_auth_endpoint = "http://localhost:8080/custom-oauth/authorize"
    auth = build_stateless_google_auth(storage, authorization_endpoint: custom_auth_endpoint)

    status, _headers, body = auth.api.sign_in_social(
      body: {provider: "google", callbackURL: "/dashboard"},
      as_response: true
    )
    sign_in_data = JSON.parse(body.join)
    url = sign_in_data.fetch("url")

    assert_equal 200, status
    assert_includes url, custom_auth_endpoint
    refute_includes url, "accounts.google.com"
    assert_includes url, "localhost:8080"
  ensure
    storage&.clear
  end

  def test_real_redis_rate_limiting_persists_under_secondary_storage
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: "redis-storage-secret-with-enough-entropy-12345",
      database: :memory,
      secondary_storage: @storage,
      rate_limit: {storage: "secondary-storage", enabled: true, max: 1, window: 60},
      plugins: [
        {
          id: "redis-storage-integration",
          endpoints: {
            limited: BetterAuth::Endpoint.new(path: "/limited", method: "GET") { {ok: true} }
          }
        }
      ]
    )

    ready = Queue.new
    start = Queue.new
    threads = 8.times.map do
      Thread.new do
        ready << true
        start.pop
        auth.call(rack_env("GET", "/api/auth/limited")).first
      end
    end
    8.times { ready.pop }
    8.times { start << true }
    statuses = threads.map(&:value)

    assert_equal 1, statuses.count(200)
    assert_equal 7, statuses.count(429)

    key = @storage.list_keys.find { |entry| entry == "127.0.0.1|/limited" }
    refute_nil key
    assert_equal "8", @storage.get(key)
    assert_operator @client.ttl("#{@prefix_root}:#{key}"), :>, 0
  end

  def test_real_redis_verification_values_get_ttl
    auth = build_auth(@storage, store_session_in_database: false)

    verification = auth.context.internal_adapter.create_verification_value(
      identifier: "verify-ttl",
      value: "secret",
      expiresAt: Time.now + 60
    )

    assert_operator @client.ttl("#{@prefix_root}:verification:verify-ttl"), :>, 0
    assert_operator @client.ttl("#{@prefix_root}:verification-id:#{verification.fetch("id")}"), :>, 0
  end

  def test_scan_count_round_trip_lists_keys
    storage = BetterAuth::RedisStorage.new(
      client: @client,
      key_prefix: "#{@prefix_root}:scan:",
      scan_count: 50
    )
    storage.clear
    storage.set("x", "1")
    storage.set("y", "2")

    assert_equal ["x", "y"], storage.list_keys.sort
  ensure
    storage&.clear
  end

  def test_real_redis_scan_count_lists_unique_many_keys_and_clear_removes_all
    storage = BetterAuth::RedisStorage.new(
      client: @client,
      key_prefix: "#{@prefix_root}:many-scan:",
      scan_count: 5
    )
    storage.clear
    300.times { |i| storage.set("k#{i}", "v") }
    @client.set("#{@prefix_root}:many-scan-outside", "outside")

    keys = storage.list_keys

    assert_equal 300, keys.length
    assert_equal keys.uniq.sort, keys.sort

    storage.clear

    assert_empty storage.list_keys
    assert_equal "outside", @client.get("#{@prefix_root}:many-scan-outside")
  ensure
    storage&.clear
    @client&.del("#{@prefix_root}:many-scan-outside") if @client && @prefix_root
  end

  def test_atomic_clear_logically_hides_previous_generation
    storage = BetterAuth::RedisStorage.new(
      client: @client,
      key_prefix: "#{@prefix_root}:atomic:",
      scan_count: 50,
      atomic_clear: true
    )
    storage.clear
    storage.set("x", "1")
    previous_generation = @client.get("#{@prefix_root}:atomic:__generation__")

    storage.clear
    @client.set("#{@prefix_root}:atomic:v#{previous_generation}:late", "stale")

    assert_nil storage.get("x")
    assert_nil storage.get("late")
    assert_nil @client.get("#{@prefix_root}:atomic:v#{previous_generation}:x")
    assert_equal [], storage.list_keys
    storage.set("x", "2")
    assert_equal "2", storage.get("x")
  ensure
    storage&.clear
  end

  def test_atomic_clear_repairs_missing_and_corrupt_markers_without_resurrection
    [:missing, "corrupt"].each do |damaged_marker|
      storage = BetterAuth::RedisStorage.new(
        client: @client,
        key_prefix: "#{@prefix_root}:repair-#{damaged_marker}:",
        atomic_clear: true
      )
      marker_key = "#{storage.key_prefix}__generation__"
      storage.set("session-token", "live-session")
      revoked_generation = @client.get(marker_key)
      storage.clear
      cleared_generation = @client.get(marker_key)
      @client.set("#{storage.key_prefix}v#{revoked_generation}:session-token", "late-session")
      @client.set("#{storage.key_prefix}v#{revoked_generation}:verification:code", "late-verification")
      if damaged_marker == :missing
        @client.del(marker_key)
      else
        @client.set(marker_key, damaged_marker)
      end

      assert_nil storage.get("session-token")
      assert_nil storage.get("verification:code")
      repaired_generation = @client.get(marker_key)
      assert_match(/\A[0-9a-f]{64}\z/, repaired_generation)
      refute_includes [revoked_generation, cleared_generation], repaired_generation
    end
  end

  def test_atomic_clear_preserves_legacy_numeric_generation_and_rotates_without_overflow
    storage = BetterAuth::RedisStorage.new(
      client: @client,
      key_prefix: "#{@prefix_root}:legacy-generation:",
      atomic_clear: true
    )
    marker_key = "#{storage.key_prefix}__generation__"
    maximum = "9223372036854775807"
    @client.set(marker_key, maximum)
    @client.set("#{storage.key_prefix}v#{maximum}:session-token", "legacy-session")

    assert_equal "legacy-session", storage.get("session-token")
    storage.clear

    assert_match(/\A[0-9a-f]{64}\z/, @client.get(marker_key))
    assert_nil storage.get("session-token")
  end

  def test_atomic_clear_concurrent_repair_and_clear_serialize_across_clients
    first_client = Redis.new(url: @redis_url)
    second_client = Redis.new(url: @redis_url)
    prefix = "#{@prefix_root}:concurrent-generation:"
    marker_key = "#{prefix}__generation__"
    first_storage = BetterAuth::RedisStorage.new(client: first_client, key_prefix: prefix, atomic_clear: true)
    second_storage = BetterAuth::RedisStorage.new(client: second_client, key_prefix: prefix, atomic_clear: true)
    first_client.del(marker_key)
    ready = Queue.new
    start = Queue.new
    repair_threads = [[first_storage, first_client], [second_storage, second_client]].map do |storage, client|
      Thread.new do
        ready << true
        start.pop
        [storage.get("session-token"), client.get(marker_key)]
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    repair_results = repair_threads.map(&:value)
    repaired_generations = repair_results.map(&:last)

    assert_equal [nil, nil], repair_results.map(&:first)
    assert_equal 1, repaired_generations.uniq.length
    initial_generation = repaired_generations.first
    assert_match(/\A[0-9a-f]{64}\z/, initial_generation)

    first_storage.set("session-token", "live-session")
    committed = Queue.new
    release = Queue.new
    blocking_client = BlockingAfterRotationRedisClient.new(first_client, committed: committed, release: release)
    blocking_storage = BetterAuth::RedisStorage.new(client: blocking_client, key_prefix: prefix, atomic_clear: true)
    first_clear = Thread.new { blocking_storage.clear }
    middle_generation = committed.pop
    begin
      second_storage.clear
    ensure
      release << true
    end
    first_clear.value
    final_generation = second_client.get(marker_key)

    assert_equal 3, [initial_generation, middle_generation, final_generation].uniq.length
    first_client.set("#{prefix}v#{initial_generation}:session-token", "late-session")
    second_client.set("#{prefix}v#{middle_generation}:verification:code", "late-verification")
    assert_nil first_storage.get("session-token")
    assert_nil second_storage.get("verification:code")
  ensure
    release << true if defined?(release) && release && defined?(first_clear) && first_clear&.alive?
    first_clear&.join
    first_client&.close
    second_client&.close
  end

  def test_real_redis_hashed_verification_identifier_does_not_expose_raw_identifier
    storage = isolated_storage("hashed-verification")
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: "redis-storage-secret-with-enough-entropy-12345",
      database: :memory,
      secondary_storage: storage,
      verification: {store_identifier: "hashed"}
    )
    raw_identifier = "sensitive-token@example.com"

    verification = auth.context.internal_adapter.create_verification_value(
      identifier: raw_identifier,
      value: "secret",
      expiresAt: Time.now + 120
    )

    keys = storage.list_keys
    refute keys.any? { |key| key.include?(raw_identifier) }
    assert_equal "secret", auth.context.internal_adapter.find_verification_value(raw_identifier).fetch("value")

    auth.context.internal_adapter.update_verification_value(verification.fetch("id"), value: "updated")
    assert_equal "updated", auth.context.internal_adapter.find_verification_value(raw_identifier).fetch("value")

    auth.context.internal_adapter.delete_verification_value(verification.fetch("id"))
    assert_nil auth.context.internal_adapter.find_verification_value(raw_identifier)
    assert_empty storage.list_keys
  ensure
    storage&.clear
  end

  private

  def isolated_storage(name)
    BetterAuth::RedisStorage.new(
      client: @client,
      key_prefix: "#{@prefix_root}:#{name}:"
    ).tap(&:clear)
  end

  def build_auth(storage, store_session_in_database:)
    BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: "redis-storage-secret-with-enough-entropy-12345",
      database: :memory,
      secondary_storage: storage,
      email_and_password: {enabled: true},
      session: {store_session_in_database: store_session_in_database}
    )
  end

  def build_stateless_google_auth(storage, authorization_endpoint: nil)
    BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: "redis-storage-secret-with-enough-entropy-12345",
      database: nil,
      secondary_storage: storage,
      session: {
        cookie_cache: {
          enabled: true,
          max_age: 7 * 24 * 60 * 60,
          strategy: "jwe",
          refresh_cache: true
        }
      },
      account: {
        store_state_strategy: "cookie",
        store_account_cookie: true
      },
      social_providers: {
        google: BetterAuth::SocialProviders.google(
          client_id: "demo",
          client_secret: "demo-secret",
          authorization_endpoint: authorization_endpoint,
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "google-1234567890",
                email: "google-user@example.com",
                name: "Google Test User",
                image: "https://lh3.googleusercontent.com/a-/test",
                emailVerified: true
              }
            }
          }
        )
      }
    )
  end

  def extract_state(url)
    Rack::Utils.parse_query(URI.parse(url).query).fetch("state")
  end

  def session_payload_from_storage(storage)
    session_key = storage.listKeys.find { |key| !key.start_with?("active-sessions-") }
    assert session_key
    session_data_string = storage.get(session_key)
    assert session_data_string
    JSON.parse(session_data_string)
  end

  def fake_jwt(payload)
    encoded_header = Base64.urlsafe_encode64(JSON.generate({"alg" => "none"}), padding: false)
    encoded_payload = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
    "#{encoded_header}.#{encoded_payload}."
  end

  def rack_env(method, path)
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "3000",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(""),
      "CONTENT_LENGTH" => "0"
    }
  end

  class BlockingAfterRotationRedisClient
    def initialize(client, committed:, release:)
      @client = client
      @committed = committed
      @release = release
      @blocked = false
    end

    def eval(script, keys: nil, argv: nil, **)
      result = @client.eval(script, keys: keys, argv: argv)
      if script.include?("better-auth:rotate-generation") && !@blocked
        @blocked = true
        @committed << @client.get(keys.fetch(0))
        @release.pop
      end
      result
    end

    def method_missing(name, ...)
      @client.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @client.respond_to?(name, include_private) || super
    end
  end
end
