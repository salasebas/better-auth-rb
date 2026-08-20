# frozen_string_literal: true

require_relative "../../test_helper"
require "better_auth/sso"

class BetterAuthSSOSAMLStateTest < Minitest::Test
  ContextWrapper = Struct.new(:body, :context) do
    def set_signed_cookie(*args)
      context.cookies << args
    end

    def set_cookie(name, value, options = {})
      context.cookies << [name, value, options]
      if options.key?(:max_age) && options[:max_age].to_i.zero?
        context.cookie_values.delete(name)
      else
        context.cookie_values[name] = value
      end
    end

    def get_cookie(name)
      context.cookie_values[name]
    end

    def response_headers
      @response_headers ||= {}
    end
  end
  ContextOptions = Struct.new(:account)
  Context = Struct.new(:secret, :internal_adapter, :cookies, :cookie_values, :store_state_strategy, :auth_cookie_name, :auth_cookie_attributes) do
    def secret_config
      secret
    end

    def options
      ContextOptions.new({store_state_strategy: store_state_strategy})
    end

    def create_auth_cookie(cookie_name, override_attributes = {})
      BetterAuth::Cookies::Cookie.new(
        name: auth_cookie_name || cookie_name,
        attributes: auth_cookie_attributes.merge(override_attributes)
      )
    end
  end

  def test_generate_relay_state_requires_callback_url
    ctx = build_context(body: {})

    error = assert_raises(BetterAuth::APIError) do
      BetterAuth::SSO::SAMLState.generate_relay_state(ctx, nil, {})
    end

    assert_equal 400, error.status_code
    assert_instance_of BetterAuth::APIError, error
    assert_match(/callbackURL is required/, error.message)
  end

  def test_generate_relay_state_stores_upstream_state_shape_with_link_and_optional_additional_data
    ctx = build_context(
      body: {
        callbackURL: "/dashboard",
        errorCallbackURL: "/error",
        newUserCallbackURL: "/welcome",
        requestSignUp: true
      }
    )

    relay_state = BetterAuth::SSO::SAMLState.generate_relay_state(
      ctx,
      {email: "alice@example.com", userId: "user-1"},
      {providerId: "saml-provider"}
    )
    stored = ctx.context.internal_adapter.find_verification_value(relay_state)
    payload = JSON.parse(stored.fetch("value"))

    assert_match(/\A[a-zA-Z0-9_-]{32}\z/, relay_state)
    assert_equal relay_state, stored.fetch("identifier")
    assert_nil ctx.context.internal_adapter.find_verification_value("saml-relay-state:#{relay_state}")
    assert_equal "/dashboard", payload.fetch("callbackURL")
    assert_equal "/error", payload.fetch("errorURL")
    assert_equal "/welcome", payload.fetch("newUserURL")
    assert_equal true, payload.fetch("requestSignUp")
    assert_equal "saml-provider", payload.fetch("providerId")
    assert_equal({"email" => "alice@example.com", "userId" => "user-1"}, payload.fetch("link"))
    assert_equal 128, payload.fetch("codeVerifier").length
    assert_equal relay_state, payload.fetch("oauthState")
    assert_operator payload.fetch("expiresAt"), :>, (Time.now.to_f * 1000).to_i
    assert_in_delta 600, stored.fetch("expiresAt") - Time.now, 2
    cookie = ctx.context.cookies.first
    assert_equal "relay_state", cookie.first
    assert_equal 300, cookie.last.fetch(:max_age)
  end

  def test_generate_relay_state_omits_false_additional_data_but_keeps_link
    ctx = build_context(body: {callbackURL: "/dashboard"})

    relay_state = BetterAuth::SSO::SAMLState.generate_relay_state(
      ctx,
      {email: "alice@example.com", userId: "user-1"},
      false
    )
    stored = ctx.context.internal_adapter.find_verification_value(relay_state)
    payload = JSON.parse(stored.fetch("value"))

    assert_equal "/dashboard", payload.fetch("callbackURL")
    assert_equal({"email" => "alice@example.com", "userId" => "user-1"}, payload.fetch("link"))
    refute payload.key?("providerId")
    refute payload.key?("errorURL")
    refute payload.key?("newUserURL")
    refute payload.key?("requestSignUp")
  end

  def test_generate_relay_state_omits_nil_internal_values_without_dropping_additional_data
    ctx = build_context(body: {callbackURL: "/dashboard"})

    relay_state = BetterAuth::SSO::SAMLState.generate_relay_state(ctx, nil, {additionalData: nil})
    stored = ctx.context.internal_adapter.find_verification_value(relay_state)
    payload = JSON.parse(stored.fetch("value"))

    assert payload.key?("additionalData")
    assert_nil payload.fetch("additionalData")
    refute payload.key?("errorURL")
    refute payload.key?("newUserURL")
    refute payload.key?("link")
    refute payload.key?("requestSignUp")
  end

  def test_parse_relay_state_reads_body_relay_state_without_requiring_cookie_and_consumes_it
    ctx = build_context(body: {callbackURL: "/dashboard"})
    relay_state = BetterAuth::SSO::SAMLState.generate_relay_state(ctx, nil, false)
    parse_ctx = build_context(body: {RelayState: relay_state}, adapter: ctx.context.internal_adapter)

    parsed = BetterAuth::SSO::SAMLState.parse_relay_state(parse_ctx)

    assert_equal "/dashboard", parsed.fetch("callbackURL")
    assert_nil ctx.context.internal_adapter.find_verification_value(relay_state)
    assert_equal 0, parse_ctx.context.cookies.last.fetch(2).fetch(:max_age)
    assert_nil BetterAuth::SSO::SAMLState.parse_relay_state(parse_ctx)
  end

  def test_cookie_state_strategy_encrypts_relay_state_without_a_verification_and_consumes_cookie
    adapter = FakeVerificationAdapter.new
    cookie_attributes = {path: "/", http_only: true, same_site: "strict", domain: ".example.com"}
    ctx = build_context(
      body: {callbackURL: "/dashboard"},
      adapter: adapter,
      store_state_strategy: "cookie",
      auth_cookie_name: "custom.relay_state",
      auth_cookie_attributes: cookie_attributes
    )

    relay_state = BetterAuth::SSO::SAMLState.generate_relay_state(ctx, nil, {additionalData: nil})
    cookie = ctx.context.cookies.fetch(0)
    encrypted_payload = cookie.fetch(1)
    payload = JSON.parse(BetterAuth::Crypto.symmetric_decrypt(key: ctx.context.secret_config, data: encrypted_payload))
    parse_ctx = build_context(
      body: {RelayState: relay_state},
      adapter: adapter,
      cookie_values: ctx.context.cookie_values,
      store_state_strategy: "cookie",
      auth_cookie_name: "custom.relay_state",
      auth_cookie_attributes: cookie_attributes
    )

    assert_equal "custom.relay_state", cookie.fetch(0)
    assert_equal 600, cookie.last.fetch(:max_age)
    assert_equal "strict", cookie.last.fetch(:same_site)
    assert_equal ".example.com", cookie.last.fetch(:domain)
    assert_equal relay_state, payload.fetch("oauthState")
    assert payload.key?("additionalData")
    assert_nil payload.fetch("additionalData")
    assert_nil adapter.find_verification_value(relay_state)
    assert_equal "/dashboard", BetterAuth::SSO::SAMLState.parse_relay_state(parse_ctx).fetch("callbackURL")
    assert_nil parse_ctx.get_cookie("custom.relay_state")
    assert_equal 0, parse_ctx.context.cookies.last.fetch(2).fetch(:max_age)
    assert_nil BetterAuth::SSO::SAMLState.parse_relay_state(parse_ctx)
  end

  def test_parse_relay_state_keeps_malformed_and_mismatched_records_for_validation_failures
    adapter = FakeVerificationAdapter.new
    malformed_state = "malformed-relay-state"
    mismatched_state = "mismatched-relay-state"
    expires_at = Time.now + 600
    adapter.create_verification_value(identifier: malformed_state, value: "{", expiresAt: expires_at)
    adapter.create_verification_value(
      identifier: mismatched_state,
      value: JSON.generate(relay_state_payload(mismatched_state, expires_at: expires_at).merge(oauthState: "another-relay-state")),
      expiresAt: expires_at
    )

    assert_nil BetterAuth::SSO::SAMLState.parse_relay_state(build_context(body: {RelayState: malformed_state}, adapter: adapter))
    assert adapter.find_verification_value(malformed_state)
    assert_nil BetterAuth::SSO::SAMLState.parse_relay_state(build_context(body: {RelayState: mismatched_state}, adapter: adapter))
    assert adapter.find_verification_value(mismatched_state)
  end

  def test_parse_relay_state_accepts_legacy_missing_oauth_state_and_coerces_link_user_id
    adapter = FakeVerificationAdapter.new
    relay_state = "legacy-relay-state"
    expires_at = Time.now + 600
    payload = relay_state_payload(relay_state, expires_at: expires_at).tap { |data| data.delete(:oauthState) }
    payload[:link] = {email: "alice@example.com", userId: 42, ignored: true}
    payload[:additionalData] = nil
    adapter.create_verification_value(identifier: relay_state, value: JSON.generate(payload), expiresAt: expires_at)

    parsed = BetterAuth::SSO::SAMLState.parse_relay_state(build_context(body: {RelayState: relay_state}, adapter: adapter))

    assert_equal "/dashboard", parsed.fetch("callbackURL")
    assert_equal({"email" => "alice@example.com", "userId" => "42"}, parsed.fetch("link"))
    assert parsed.key?("additionalData")
    assert_nil parsed.fetch("additionalData")
    assert_nil adapter.find_verification_value(relay_state)
  end

  def test_parse_relay_state_keeps_schema_invalid_records_unconsumed
    adapter = FakeVerificationAdapter.new
    expires_at = Time.now + 600
    invalid_payloads = {
      "invalid-callback-url" => {callbackURL: 42},
      "invalid-code-verifier" => {codeVerifier: 42},
      "invalid-expires-at" => {expiresAt: "soon"},
      "invalid-error-url" => {errorURL: nil},
      "invalid-new-user-url" => {newUserURL: 42},
      "invalid-oauth-state" => {oauthState: 42},
      "invalid-link-email" => {link: {email: 42, userId: "user-1"}},
      "invalid-link-user-id" => {link: {email: "alice@example.com"}},
      "invalid-request-sign-up" => {requestSignUp: "true"}
    }

    invalid_payloads.each do |relay_state, invalid_fields|
      adapter.create_verification_value(
        identifier: relay_state,
        value: JSON.generate(relay_state_payload(relay_state, expires_at: expires_at).merge(invalid_fields)),
        expiresAt: expires_at
      )

      assert_nil BetterAuth::SSO::SAMLState.parse_relay_state(build_context(body: {RelayState: relay_state}, adapter: adapter))
      assert adapter.find_verification_value(relay_state), "#{relay_state} was consumed before schema validation"
    end
  end

  def test_parse_relay_state_rejects_and_consumes_expired_records_and_payloads
    adapter = FakeVerificationAdapter.new
    expired_record_state = "expired-record-relay-state"
    expired_payload_state = "expired-payload-relay-state"
    adapter.create_verification_value(
      identifier: expired_record_state,
      value: JSON.generate(relay_state_payload(expired_record_state, expires_at: Time.now - 60)),
      expiresAt: Time.now - 60
    )
    adapter.create_verification_value(
      identifier: expired_payload_state,
      value: JSON.generate(relay_state_payload(expired_payload_state, expires_at: Time.now - 60)),
      expiresAt: Time.now + 600
    )

    assert_nil BetterAuth::SSO::SAMLState.parse_relay_state(build_context(body: {RelayState: expired_record_state}, adapter: adapter))
    assert_nil adapter.find_verification_value(expired_record_state)
    assert_nil BetterAuth::SSO::SAMLState.parse_relay_state(build_context(body: {RelayState: expired_payload_state}, adapter: adapter))
    assert_nil adapter.find_verification_value(expired_payload_state)
  end

  def test_parse_relay_state_is_single_use_with_database_verifications
    adapter = internal_adapter
    ctx = build_context(body: {callbackURL: "/dashboard"}, adapter: adapter)
    relay_state = BetterAuth::SSO::SAMLState.generate_relay_state(ctx, nil, false)
    parse_ctx = build_context(body: {RelayState: relay_state}, adapter: adapter)

    assert adapter.find_verification_value(relay_state)
    assert_equal "/dashboard", BetterAuth::SSO::SAMLState.parse_relay_state(parse_ctx).fetch("callbackURL")
    assert_nil adapter.find_verification_value(relay_state)
    assert_nil BetterAuth::SSO::SAMLState.parse_relay_state(parse_ctx)
  end

  def test_parse_relay_state_is_single_use_with_atomic_secondary_storage
    storage = AtomicMemoryStorage.new
    adapter = internal_adapter(secondary_storage: storage)
    ctx = build_context(body: {callbackURL: "/dashboard"}, adapter: adapter)
    relay_state = BetterAuth::SSO::SAMLState.generate_relay_state(ctx, nil, false)
    key = "verification:#{relay_state}"
    parse_ctx = build_context(body: {RelayState: relay_state}, adapter: adapter)

    assert storage.store.key?(key)
    refute storage.store.key?("verification:saml-relay-state:#{relay_state}")
    assert_operator storage.ttls.fetch(key), :>=, 598
    assert_operator storage.ttls.fetch(key), :<=, 600
    assert_equal "/dashboard", BetterAuth::SSO::SAMLState.parse_relay_state(parse_ctx).fetch("callbackURL")
    assert_includes storage.get_and_delete_calls, key
    refute storage.store.key?(key)
    assert_nil BetterAuth::SSO::SAMLState.parse_relay_state(parse_ctx)
  end

  private

  def build_context(body:, adapter: FakeVerificationAdapter.new, cookie_values: nil, store_state_strategy: "database", auth_cookie_name: nil, auth_cookie_attributes: {})
    ContextWrapper.new(
      body,
      Context.new(
        "saml-state-test-secret",
        adapter,
        [],
        cookie_values || {},
        store_state_strategy,
        auth_cookie_name,
        {path: "/", http_only: true, same_site: "lax"}.merge(auth_cookie_attributes)
      )
    )
  end

  def internal_adapter(options = {})
    config = BetterAuth::Configuration.new({base_url: "http://localhost:3000", secret: "saml-state-test-secret", database: :memory}.merge(options))
    adapter = BetterAuth::Adapters::Memory.new(config)
    BetterAuth::Adapters::InternalAdapter.new(adapter, config)
  end

  def relay_state_payload(relay_state, expires_at: Time.now + 600)
    {
      callbackURL: "/dashboard",
      codeVerifier: "code-verifier",
      expiresAt: (expires_at.to_f * 1000).to_i,
      oauthState: relay_state
    }
  end

  class FakeVerificationAdapter
    def initialize
      @values = {}
    end

    def create_verification_value(identifier:, value:, **options)
      expires_at = options.fetch(:expiresAt)
      @values[identifier] = {
        "identifier" => identifier,
        "value" => value,
        "expiresAt" => expires_at
      }
    end

    def find_verification_value(identifier)
      @values[identifier]
    end

    def consume_verification_value(identifier)
      verification = @values.delete(identifier)
      return nil unless verification

      (verification.fetch("expiresAt") > Time.now) ? verification : nil
    end
  end

  class AtomicMemoryStorage
    attr_reader :store, :ttls, :get_and_delete_calls

    def initialize
      @store = {}
      @ttls = {}
      @get_and_delete_calls = []
      @lock = Mutex.new
    end

    def set(key, value, ttl = nil)
      @lock.synchronize do
        store[key] = value
        ttls[key] = ttl if ttl
      end
    end

    def get(key)
      @lock.synchronize { store[key] }
    end

    def delete(key)
      @lock.synchronize do
        store.delete(key)
        ttls.delete(key)
      end
    end

    def get_and_delete(key)
      @lock.synchronize do
        get_and_delete_calls << key
        ttls.delete(key)
        store.delete(key)
      end
    end
  end
end
