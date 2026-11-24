# frozen_string_literal: true

require_relative "../../test_helper"
require "better_auth/sso"

class BetterAuthSSOSAMLStateTest < Minitest::Test
  def setup
    @context = auth_context
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
    cookie = ctx.response_headers.fetch("set-cookie")
    assert_match(/\Abetter-auth\.relay_state=/, cookie)
    assert_includes cookie, "Max-Age=300"
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
    parse_ctx = build_context(body: {RelayState: relay_state})

    parsed = BetterAuth::SSO::SAMLState.parse_relay_state(parse_ctx)

    assert_equal "/dashboard", parsed.fetch("callbackURL")
    assert_equal "http://localhost:3000/api/auth/error", parsed.fetch("errorURL")
    assert_nil ctx.context.internal_adapter.find_verification_value(relay_state)
    assert_includes parse_ctx.response_headers.fetch("set-cookie"), "Max-Age=0"
    assert_invalid_relay_state(parse_ctx)
  end

  def test_cookie_state_strategy_encrypts_relay_state_without_a_verification_and_consumes_cookie
    context = auth_context(
      account: {store_state_strategy: "cookie"},
      advanced: {cookies: {relay_state: {name: "custom.relay_state", attributes: {same_site: "strict", domain: ".example.com"}}}}
    )
    ctx = build_context(body: {callbackURL: "/dashboard"}, context: context)
    relay_state = BetterAuth::SSO::SAMLState.generate_relay_state(ctx, nil, {additionalData: nil})
    cookie = ctx.response_headers.fetch("set-cookie")

    assert_match(/\Acustom\.relay_state=/, cookie)
    assert_includes cookie, "Max-Age=600"
    assert_includes cookie, "SameSite=Strict"
    assert_includes cookie, "Domain=.example.com"
    assert_nil context.internal_adapter.find_verification_value(relay_state)

    parse_ctx = build_context(body: {RelayState: relay_state}, context: context, cookie: cookie.split(";").first)
    encrypted = parse_ctx.get_cookie("custom.relay_state")
    payload = JSON.parse(BetterAuth::Crypto.symmetric_decrypt(key: context.secret_config, data: encrypted))
    assert_equal relay_state, payload.fetch("oauthState")
    assert_nil payload.fetch("additionalData")
    assert_equal "/dashboard", BetterAuth::SSO::SAMLState.parse_relay_state(parse_ctx).fetch("callbackURL")
    assert_includes parse_ctx.response_headers.fetch("set-cookie"), "Max-Age=0"
    assert_invalid_relay_state(build_context(body: {RelayState: relay_state}, context: context))
  end

  def test_parse_relay_state_keeps_malformed_and_mismatched_records_for_validation_failures
    adapter = @context.internal_adapter
    malformed_state = "malformed-relay-state"
    mismatched_state = "mismatched-relay-state"
    expires_at = Time.now + 600
    adapter.create_verification_value(identifier: malformed_state, value: "{", expiresAt: expires_at)
    adapter.create_verification_value(
      identifier: mismatched_state,
      value: JSON.generate(relay_state_payload(mismatched_state, expires_at: expires_at).merge(oauthState: "another-relay-state")),
      expiresAt: expires_at
    )

    assert_invalid_relay_state(build_context(body: {RelayState: malformed_state}))
    assert adapter.find_verification_value(malformed_state)
    assert_invalid_relay_state(build_context(body: {RelayState: mismatched_state}))
    assert adapter.find_verification_value(mismatched_state)
  end

  def test_parse_relay_state_accepts_legacy_missing_oauth_state_and_coerces_link_user_id
    adapter = @context.internal_adapter
    relay_state = "legacy-relay-state"
    expires_at = Time.now + 600
    payload = relay_state_payload(relay_state, expires_at: expires_at).tap { |data| data.delete(:oauthState) }
    payload[:link] = {email: "alice@example.com", userId: 42, ignored: true}
    payload[:additionalData] = nil
    adapter.create_verification_value(identifier: relay_state, value: JSON.generate(payload), expiresAt: expires_at)

    parsed = BetterAuth::SSO::SAMLState.parse_relay_state(build_context(body: {RelayState: relay_state}))

    assert_equal "/dashboard", parsed.fetch("callbackURL")
    assert_equal({"email" => "alice@example.com", "userId" => "42"}, parsed.fetch("link"))
    assert parsed.key?("additionalData")
    assert_nil parsed.fetch("additionalData")
    assert_nil adapter.find_verification_value(relay_state)
  end

  def test_parse_relay_state_coerces_missing_and_null_link_ids
    [[{}, "undefined"], [{userId: nil}, "null"]].each do |fields, expected|
      ctx = build_context(body: {callbackURL: "/dashboard"})
      state = BetterAuth::SSO::SAMLState.generate_relay_state(ctx, {email: "alice@example.com"}.merge(fields))
      ctx.body = {RelayState: state}

      parsed = BetterAuth::SSO::SAMLState.parse_relay_state(ctx)
      assert_equal expected, parsed.dig("link", "userId")
    end
  end

  def test_relay_state_is_valid_at_the_expiration_millisecond
    now = Time.at(1_800_000_000)
    Time.stub(:now, now) do
      ctx = build_context(body: {RelayState: "boundary"})
      ctx.context.internal_adapter.create_verification_value(
        identifier: "boundary", value: JSON.generate(relay_state_payload("boundary", expires_at: now)), expiresAt: now + 1
      )
      assert_equal "/dashboard", BetterAuth::SSO::SAMLState.parse_relay_state(ctx).fetch("callbackURL")
    end
  end

  def test_parse_relay_state_keeps_schema_invalid_records_unconsumed
    adapter = @context.internal_adapter
    expires_at = Time.now + 600
    invalid_payloads = {
      "invalid-callback-url" => {callbackURL: 42},
      "invalid-code-verifier" => {codeVerifier: 42},
      "invalid-expires-at" => {expiresAt: "soon"},
      "invalid-error-url" => {errorURL: nil},
      "invalid-new-user-url" => {newUserURL: 42},
      "invalid-oauth-state" => {oauthState: 42},
      "invalid-link-email" => {link: {email: 42, userId: "user-1"}},
      "invalid-request-sign-up" => {requestSignUp: "true"}
    }

    invalid_payloads.each do |relay_state, invalid_fields|
      adapter.create_verification_value(
        identifier: relay_state,
        value: JSON.generate(relay_state_payload(relay_state, expires_at: expires_at).merge(invalid_fields)),
        expiresAt: expires_at
      )

      assert_invalid_relay_state(build_context(body: {RelayState: relay_state}))
      assert adapter.find_verification_value(relay_state), "#{relay_state} was consumed before schema validation"
    end
  end

  def test_parse_relay_state_rejects_and_consumes_expired_records_and_payloads
    adapter = @context.internal_adapter
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

    assert_invalid_relay_state(build_context(body: {RelayState: expired_record_state}))
    assert_nil adapter.find_verification_value(expired_record_state)
    assert_invalid_relay_state(build_context(body: {RelayState: expired_payload_state}))
    assert_nil adapter.find_verification_value(expired_payload_state)
  end

  def test_parse_relay_state_is_single_use_with_secondary_storage
    storage = MemoryStorage.new
    context = auth_context(secondary_storage: storage)
    ctx = build_context(body: {callbackURL: "/dashboard"}, context: context)
    relay_state = BetterAuth::SSO::SAMLState.generate_relay_state(ctx, nil, false)
    key = "verification:#{relay_state}"
    parse_ctx = build_context(body: {RelayState: relay_state}, context: context)

    assert storage.store.key?(key)
    refute storage.store.key?("verification:saml-relay-state:#{relay_state}")
    assert_operator storage.ttls.fetch(key), :>=, 598
    assert_operator storage.ttls.fetch(key), :<=, 600
    assert_equal "/dashboard", BetterAuth::SSO::SAMLState.parse_relay_state(parse_ctx).fetch("callbackURL")
    refute storage.store.key?(key)
    assert_invalid_relay_state(parse_ctx)
  end

  private

  def assert_invalid_relay_state(ctx)
    error = assert_raises(BetterAuth::APIError) { BetterAuth::SSO::SAMLState.parse_relay_state(ctx) }
    assert_equal 400, error.status_code
    assert_equal "State error: failed to validate relay state", error.message
  end

  def build_context(body:, context: @context, cookie: nil)
    BetterAuth::Endpoint::Context.new(
      path: "/", method: "POST", query: {}, body: body, params: {}, headers: {"cookie" => cookie}, context: context
    )
  end

  def auth_context(**options)
    BetterAuth.auth({
      base_url: "http://localhost:3000", secret: "saml-state-test-secret-0123456789", database: :memory
    }.merge(options)).context
  end

  def relay_state_payload(relay_state, expires_at: Time.now + 600)
    {
      callbackURL: "/dashboard",
      codeVerifier: "code-verifier",
      expiresAt: (expires_at.to_f * 1000).to_i,
      oauthState: relay_state
    }
  end

  class MemoryStorage
    attr_reader :store, :ttls

    def initialize
      @store = {}
      @ttls = {}
    end

    def set(key, value, ttl = nil)
      store[key] = value
      ttls[key] = ttl
    end

    def get(key)
      store[key]
    end

    def delete(key)
      ttls.delete(key)
      store.delete(key)
    end
  end
end
