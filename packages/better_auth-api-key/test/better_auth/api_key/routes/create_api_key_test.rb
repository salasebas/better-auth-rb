# frozen_string_literal: true

require_relative "../test_support"

class BetterAuthAPIKeyCreateRouteTest < Minitest::Test
  include APIKeyTestSupport

  def test_create_route_uses_upstream_record_shape
    auth = build_api_key_auth(default_key_length: 12, enable_metadata: true)
    cookie = sign_up_cookie(auth, email: "create-route-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]

    created = auth.api.create_api_key(body: {userId: user_id, name: "route", metadata: {plan: "pro"}})

    assert_equal "route", created[:name]
    assert_equal user_id, created[:referenceId]
    refute created.key?(:userId)
    assert_equal({"plan" => "pro"}, created[:metadata])
  end

  def test_create_route_applies_defaults_hashing_start_and_rate_limit
    auth = build_api_key_auth(default_key_length: 12, default_prefix: "ba_", rate_limit: {enabled: false, time_window: 1000, max_requests: 25})
    cookie = sign_up_cookie(auth, email: "create-route-defaults-key@example.com")

    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {})
    stored = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])

    assert_match(/\Aba_[A-Za-z]{12}\z/, created[:key])
    assert_equal "ba_", created[:prefix]
    assert_equal created[:key][0, 6], created[:start]
    assert_equal false, created[:rateLimitEnabled]
    assert_equal 1000, created[:rateLimitTimeWindow]
    assert_equal 25, created[:rateLimitMax]
    refute_equal created[:key], stored.fetch("key")
  end

  def test_create_route_rejects_authenticated_client_server_only_fields
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "create-route-server-only-key@example.com")

    %i[permissions refillAmount refillInterval rateLimitMax rateLimitTimeWindow rateLimitEnabled remaining].each do |field|
      error = assert_raises(BetterAuth::APIError) do
        auth.api.create_api_key(headers: {"cookie" => cookie}, body: {field => 10})
      end

      assert_equal "BAD_REQUEST", error.status
      assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("SERVER_ONLY_PROPERTY"), error.message
    end
  end

  def test_create_route_rejects_request_mode_user_id_without_session
    auth = build_api_key_auth(default_key_length: 12)

    status, body = rack_json_response(auth, "POST", "/api-key/create", body: {userId: "target-user-id"})

    assert_equal 401, status
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("UNAUTHORIZED_SESSION"), body.fetch("message")
    assert_nil auth.context.adapter.find_one(model: "apikey", where: [{field: "referenceId", value: "target-user-id"}])
  end

  def test_create_route_rejects_request_mode_user_id_mismatch_with_session
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "create-route-user-id-mismatch-key@example.com")

    status, body = request_mode_api_response(auth, :create_api_key, body: {userId: "someone-else"}, cookie: cookie)

    assert_equal 401, status
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("UNAUTHORIZED_SESSION"), body.fetch("message")
    assert_nil auth.context.adapter.find_one(model: "apikey", where: [{field: "referenceId", value: "someone-else"}])
  end

  def test_create_route_rejects_request_mode_user_id_matching_session
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "create-route-user-id-match-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]

    status, body = rack_json_response(auth, "POST", "/api-key/create", body: {userId: user_id}, cookie: cookie)

    assert_equal 401, status
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("UNAUTHORIZED_SESSION"), body.fetch("message")
    assert_nil auth.context.adapter.find_one(model: "apikey", where: [{field: "referenceId", value: user_id}])
  end

  def test_create_route_rejects_server_only_fields_before_request_user_id
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "create-route-user-id-server-only-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]

    status, body = rack_json_response(
      auth,
      "POST",
      "/api-key/create",
      body: {userId: user_id, refillAmount: 10},
      cookie: cookie
    )

    assert_equal 400, status
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("SERVER_ONLY_PROPERTY"), body.fetch("message")
  end

  def test_create_route_respects_nil_expiration_and_refill_without_remaining
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "create-route-nil-expiration-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]

    no_expiration = auth.api.create_api_key(body: {userId: user_id, expiresIn: nil})
    refill = auth.api.create_api_key(body: {userId: user_id, refillAmount: 10, refillInterval: 1000})

    assert_nil no_expiration[:expiresAt]
    assert_nil refill[:remaining]
    assert_equal 10, refill[:refillAmount]
    assert_equal 1000, refill[:refillInterval]
  end

  def test_create_route_applies_default_expiration_to_explicit_nil
    auth = build_api_key_auth(
      default_key_length: 12,
      key_expiration: {
        default_expires_in: 120,
        disable_custom_expires_time: true
      }
    )

    before = Time.now
    created = auth.api.create_api_key(body: {userId: "server-user", expiresIn: nil})

    assert_operator created[:expiresAt], :>=, before + 119
    assert_operator created[:expiresAt], :<, before + 122
  end

  def test_create_route_accepts_empty_optional_name
    auth = build_api_key_auth(default_key_length: 12)

    created = auth.api.create_api_key(body: {userId: "server-user", name: ""})

    assert_equal "", created[:name]
  end

  def test_create_route_accepts_array_metadata_when_enabled
    auth = build_api_key_auth(default_key_length: 12, enable_metadata: true)

    created = auth.api.create_api_key(body: {userId: "server-user", metadata: ["first", false]})
    stored = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])

    assert_equal ["first", false], created[:metadata]
    assert_equal ["first", false], JSON.parse(stored.fetch("metadata"))
  end

  def test_create_route_returns_false_metadata_but_persists_null
    auth = build_api_key_auth(default_key_length: 12, enable_metadata: false)

    created = auth.api.create_api_key(body: {userId: "server-user", metadata: false})
    stored = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])

    assert_equal false, created[:metadata]
    assert_nil stored.fetch("metadata")
  end

  def test_create_route_treats_zero_refill_interval_like_upstream
    auth = build_api_key_auth(default_key_length: 12)

    created = auth.api.create_api_key(body: {userId: "server-user", refillInterval: 0})

    assert_equal 0, created[:refillInterval]
    assert_nil created[:refillAmount]

    error = assert_raises(BetterAuth::APIError) do
      auth.api.create_api_key(body: {userId: "server-user", refillAmount: 10, refillInterval: 0})
    end
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("REFILL_AMOUNT_AND_INTERVAL_REQUIRED"), error.message
  end

  def test_create_route_uses_configured_id_generator_for_pure_secondary_storage
    storage = MemoryStorage.new
    calls = []
    generator = lambda do |options|
      calls << options
      "configured-api-key-id"
    end
    auth = build_api_key_auth(
      storage: "secondary-storage",
      secondary_storage: storage,
      default_key_length: 12,
      advanced: {database: {generate_id: generator}}
    )

    created = auth.api.create_api_key(body: {userId: "server-user"})

    assert_equal "configured-api-key-id", created[:id]
    assert_equal [{model: "apikey"}], calls
    assert storage.get("api-key:by-id:configured-api-key-id")
  end

  def test_create_route_falls_back_when_configured_id_is_javascript_falsy
    storage = MemoryStorage.new
    auth = build_api_key_auth(
      storage: "secondary-storage",
      secondary_storage: storage,
      default_key_length: 12,
      advanced: {database: {generate_id: ->(_options) { "" }}}
    )

    created = auth.api.create_api_key(body: {userId: "server-user"})

    assert_match(/\A[A-Za-z0-9]{32}\z/, created[:id])
    assert storage.get("api-key:by-id:#{created[:id]}")
  end

  def test_create_route_rejects_non_positive_refill_amount
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "create-route-invalid-refill-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]

    error = assert_raises(BetterAuth::APIError) do
      auth.api.create_api_key(body: {userId: user_id, refillAmount: 0, refillInterval: 1000})
    end

    assert_equal "BAD_REQUEST", error.status
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("INVALID_REMAINING"), error.message
  end

  def test_create_route_rejects_revoked_cookie_cache_session
    auth = build_api_key_auth(
      default_key_length: 12,
      session: {cookie_cache: {enabled: true, strategy: "jwe", max_age: 300}},
      secondary_storage: MemoryStorage.new
    )
    cookie = sign_up_cookie(auth, email: "create-route-revoked-cookie@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})
    auth.context.internal_adapter.delete_session(session[:session]["token"])

    status, body = rack_json_response(auth, "POST", "/api-key/create", body: {}, cookie: cookie)

    assert_equal 401, status
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("UNAUTHORIZED_SESSION"), body.fetch("message")
  end

  def test_create_route_deletes_expired_database_keys_like_upstream
    BetterAuth::APIKey::Routes.instance_variable_set(:@last_expired_check, nil)
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "create-route-cleanup-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    expired = auth.api.create_api_key(body: {userId: user_id})
    auth.context.adapter.update(
      model: "apikey",
      where: [{field: "id", value: expired[:id]}],
      update: {expiresAt: Time.now - 60}
    )
    BetterAuth::APIKey::Routes.instance_variable_set(:@last_expired_check, nil)

    auth.api.create_api_key(body: {userId: user_id})

    assert_nil auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: expired[:id]}])
  end
end
