# frozen_string_literal: true

require "json"
require_relative "../../test_helper"

class BetterAuthPasskeyChallengesTest < Minitest::Test
  def test_store_challenge_sets_cookie_and_verification_value_with_context
    ctx = fake_ctx(query: {context: "signup-token"})

    BetterAuth::Passkey::Challenges.store_challenge(ctx, config, "challenge-123", {"id" => "user-1", "name" => "User"}, ceremony: "registration")

    assert_equal "better-auth-passkey", ctx.cookies.first.fetch(:name)
    verification_token = ctx.cookies.first.fetch(:value)
    verification = ctx.context.internal_adapter.verifications.fetch(verification_token)
    assert_equal verification_token, verification.fetch(:identifier)
    assert_operator verification.fetch(:expiresAt), :>, Time.now

    value = JSON.parse(verification.fetch(:value))
    assert_equal "challenge-123", value.fetch("expectedChallenge")
    assert_equal "user-1", value.fetch("userData").fetch("id")
    assert_equal "signup-token", value.fetch("context")
    assert_equal "registration", value.fetch("type")
  end

  def test_find_challenge_returns_nil_for_expired_or_invalid_json
    expired_ctx = fake_ctx
    expired_ctx.context.internal_adapter.verifications["token-1"] = {
      "value" => JSON.generate(expectedChallenge: "challenge"),
      "expiresAt" => Time.now - 1
    }
    invalid_ctx = fake_ctx
    invalid_ctx.context.internal_adapter.verifications["token-1"] = {
      "value" => "{",
      "expiresAt" => Time.now + 60
    }

    assert_nil BetterAuth::Passkey::Challenges.find_challenge(expired_ctx, "token-1")
    assert_nil BetterAuth::Passkey::Challenges.find_challenge(invalid_ctx, "token-1")
  end

  def test_challenge_rejects_cross_ceremony_and_accepts_legacy_missing_type
    mismatched = fake_ctx
    mismatched.context.internal_adapter.verifications["token-1"] = {
      "value" => JSON.generate(expectedChallenge: "challenge", type: "registration"),
      "expiresAt" => Time.now + 60
    }
    assert_nil BetterAuth::Passkey::Challenges.find_challenge(mismatched, "token-1", ceremony: "authentication")
    assert_nil mismatched.context.internal_adapter.find_verification_value("token-1")

    legacy = fake_ctx
    legacy.context.internal_adapter.verifications["token-1"] = {
      "value" => JSON.generate(expectedChallenge: "legacy"),
      "expiresAt" => Time.now + 60
    }
    assert_equal "legacy", BetterAuth::Passkey::Challenges.find_challenge(legacy, "token-1", ceremony: "authentication").fetch("expectedChallenge")
  end

  private

  def config
    {advanced: {web_authn_challenge_cookie: "better-auth-passkey"}}
  end

  def fake_ctx(query: {})
    auth_cookie = Struct.new(:name, :attributes)
    context = Struct.new(:secret, :internal_adapter) do
      def create_auth_cookie(name, max_age: nil)
        attributes = {}
        attributes[:max_age] = max_age if max_age
        Struct.new(:name, :attributes).new(name, attributes)
      end
    end
    ctx_class = Struct.new(:query, :context, :cookies) do
      def set_signed_cookie(name, value, secret, attributes)
        cookies << {name: name, value: value, secret: secret, attributes: attributes}
      end

      def get_signed_cookie(_name, _secret)
        "token-1"
      end
    end

    _unused = auth_cookie
    ctx_class.new(query, context.new("secret", FakeInternalAdapter.new), [])
  end

  class FakeInternalAdapter
    attr_reader :verifications

    def initialize
      @verifications = {}
    end

    def create_verification_value(value)
      @verifications[value.fetch(:identifier)] = value
    end

    def find_verification_value(identifier)
      @verifications[identifier]
    end

    def consume_verification_value(identifier)
      verification = @verifications.delete(identifier)
      return nil if verification && verification["expiresAt"] && verification["expiresAt"] <= Time.now

      verification
    end
  end
end
