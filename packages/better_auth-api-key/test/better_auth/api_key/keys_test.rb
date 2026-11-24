# frozen_string_literal: true

require_relative "test_support"

class BetterAuthAPIKeyKeysTest < Minitest::Test
  Context = Struct.new(:headers)

  def test_generate_uses_letters_and_prefix_by_default
    key = BetterAuth::APIKey::Keys.generate({default_key_length: 12}, "ba_")

    assert_match(/\Aba_[A-Za-z]{12}\z/, key)
  end

  def test_generate_delegates_to_custom_generator
    key = BetterAuth::APIKey::Keys.generate({
      default_key_length: 8,
      custom_key_generator: ->(options) { "#{options.fetch(:prefix)}custom-#{options.fetch(:length)}" }
    }, "ba_")

    assert_equal "ba_custom-8", key
  end

  def test_normalize_body_preserves_nil_metadata
    body = BetterAuth::APIKey::Keys.normalize_body({"metadata" => nil, "expiresIn" => nil})

    assert body.key?(:metadata)
    assert_nil body[:metadata]
    assert body.key?(:expires_in)
    assert_nil body[:expires_in]
  end

  def test_hash_respects_disabled_hashing
    assert_equal "raw-key", BetterAuth::APIKey::Keys.hash("raw-key", {disable_key_hashing: true})
    assert_equal BetterAuth::Crypto.sha256("raw-key", encoding: :base64url),
      BetterAuth::APIKey::Keys.hash("raw-key", {disable_key_hashing: false})
  end

  def test_expires_at_uses_body_then_default_then_nil
    before = Time.now
    body_expiration = BetterAuth::APIKey::Keys.expires_at({expires_in: 60}, {key_expiration: {default_expires_in: 120}})
    default_expiration = BetterAuth::APIKey::Keys.expires_at({}, {key_expiration: {default_expires_in: 120}})
    no_expiration = BetterAuth::APIKey::Keys.expires_at({expires_in: nil}, {key_expiration: {default_expires_in: 120}})

    assert_operator body_expiration, :>=, before + 59
    assert_operator body_expiration, :<, before + 62
    assert_operator default_expiration, :>=, before + 119
    assert_operator default_expiration, :<, before + 122
    assert_nil no_expiration
  end

  def test_from_headers_checks_configured_headers_in_order
    ctx = Context.new({"x-api-key" => nil, "x-secondary-key" => "secret"})

    assert_equal "secret", BetterAuth::APIKey::Keys.from_headers(ctx, api_key_headers: ["x-api-key", "x-secondary-key"])
  end

  def test_from_headers_delegates_to_custom_getter
    ctx = Context.new({})
    config = {custom_api_key_getter: ->(request_ctx) { request_ctx.headers.fetch("custom", "generated-key") }}

    assert_equal "generated-key", BetterAuth::APIKey::Keys.from_headers(ctx, config)
  end
end
