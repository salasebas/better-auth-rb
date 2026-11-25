# frozen_string_literal: true

require "json"
require "stringio"
require_relative "../test_helper"

class BetterAuthTokenLinkBaseURLTest < Minitest::Test
  SECRET = "token-link-base-url-secret-with-enough-entropy"

  def test_token_link_uses_canonical_url_for_an_unrecognized_request_host
    sent = []
    auth = build_auth(sent: sent)
    create_user(auth, "canonical@example.com")

    status = request_password_reset(auth, "canonical@example.com", host: "attacker.example")

    assert_equal 200, status
    assert_equal 1, sent.length
    assert_match(%r{\Ahttps://auth\.example\.com/api/auth/reset-password/}, sent.first.fetch(:url))
  end

  def test_token_link_uses_an_allowlisted_serving_origin
    sent = []
    auth = build_auth(sent: sent, serving_origins: ["http://tenant.example"])
    create_user(auth, "tenant@example.com")

    status = request_password_reset(auth, "tenant@example.com", host: "tenant.example")

    assert_equal 200, status
    assert_equal 1, sent.length
    assert_match(%r{\Ahttp://tenant\.example/api/auth/reset-password/}, sent.first.fetch(:url))
  end

  def test_missing_user_does_not_send_a_token_link
    sent = []
    auth = build_auth(sent: sent)

    status = request_password_reset(auth, "missing@example.com", host: "attacker.example")

    assert_equal 200, status
    assert_empty sent
    assert_empty auth.context.adapter.find_many(model: "verification")
  end

  def test_dynamic_token_links_use_the_allowlisted_host_or_the_configured_fallback
    sent = []
    auth = build_auth(sent: sent, base_url: {allowed_hosts: ["tenant.example"], fallback: "https://auth.example.com"})
    create_user(auth, "tenant@example.com")

    assert_equal 200, request_password_reset(auth, "tenant@example.com", host: "tenant.example")
    assert_equal 200, request_password_reset(auth, "tenant@example.com", host: "other.example")

    assert_equal ["http://tenant.example", "https://auth.example.com"], sent.map { |data| URI.parse(data.fetch(:url)).origin }
  end

  private

  def build_auth(sent:, base_url: "https://auth.example.com", serving_origins: [])
    BetterAuth.auth(
      secret: SECRET,
      base_url: base_url,
      serving_origins: serving_origins,
      database: :memory,
      email_and_password: {
        enabled: true,
        send_reset_password: ->(data, _request = nil) { sent << data }
      }
    )
  end

  def create_user(auth, email)
    auth.context.internal_adapter.create_user(email: email, name: "Token Link", emailVerified: true)
  end

  def request_password_reset(auth, email, host:)
    payload = JSON.generate(email: email)
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/api/auth/request-password-reset",
      "QUERY_STRING" => "",
      "SERVER_NAME" => host,
      "SERVER_PORT" => "80",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(payload),
      "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => payload.bytesize.to_s,
      "HTTP_HOST" => host
    }

    status, = auth.call(env)
    status
  end
end
