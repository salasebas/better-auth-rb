# frozen_string_literal: true

require "rack"
require_relative "../../test_helper"

class BetterAuthPluginsDubTest < Minitest::Test
  SECRET = "dub-plugin-secret-with-enough-entropy-123"

  FakeDubTrack = Struct.new(:leads, :raise_on_lead) do
    def lead(payload)
      raise raise_on_lead if raise_on_lead

      leads << payload
      true
    end
  end

  FakeDubClient = Struct.new(:track)

  RubySdkTrack = Struct.new(:requests) do
    def lead(request: nil, timeout_ms: nil)
      requests << {request: request, timeout_ms: timeout_ms}
      true
    end
  end

  def test_tracks_signup_lead_from_dub_id_cookie_and_expires_cookie
    track = FakeDubTrack.new(leads: [])
    auth = build_auth(dub_client: FakeDubClient.new(track: track))

    result = sign_up(auth, email: "dub-lead@example.com", headers: {"cookie" => "dub_id=click_123"})

    assert_equal 1, track.leads.length
    assert_equal "click_123", track.leads.first.fetch(:click_id)
    assert_equal "Sign Up", track.leads.first.fetch(:event_name)
    assert_equal result[:response][:user]["id"], track.leads.first.fetch(:customer_external_id)
    assert_equal "Dub Lead", track.leads.first.fetch(:customer_name)
    assert_equal "dub-lead@example.com", track.leads.first.fetch(:customer_email)
    assert_expired_dub_cookie result[:headers].fetch("set-cookie")
  end

  def test_tracks_signup_lead_with_custom_event_name
    track = FakeDubTrack.new(leads: [])
    auth = build_auth(
      dub_client: FakeDubClient.new(track: track),
      dub_options: {lead_event_name: "Created Account"}
    )

    sign_up(auth, email: "custom-event@example.com", headers: {"cookie" => "dub_id=click_event"})

    assert_equal "Created Account", track.leads.first.fetch(:event_name)
  end

  def test_default_dub_tracking_errors_are_logged_and_do_not_block_signup
    error = RuntimeError.new("dub unavailable")
    track = FakeDubTrack.new(leads: [], raise_on_lead: error)
    logged = []
    auth = build_auth(
      dub_client: FakeDubClient.new(track: track),
      logger: ->(level, message, *) { logged << [level, message] }
    )

    result = sign_up(auth, email: "error-lead@example.com", headers: {"cookie" => "dub_id=click_error"})

    assert_equal "error-lead@example.com", result[:response][:user]["email"]
    assert_equal [[:error, error]], logged
    assert_expired_dub_cookie result[:headers].fetch("set-cookie")
  end

  def test_default_dub_tracking_supports_ruby_sdk_keyword_request_signature
    track = RubySdkTrack.new(requests: [])
    auth = build_auth(dub_client: FakeDubClient.new(track: track))

    sign_up(auth, email: "ruby-sdk@example.com", headers: {"cookie" => "dub_id=click_ruby_sdk"})

    assert_equal 1, track.requests.length
    assert_equal "click_ruby_sdk", track.requests.first.fetch(:request).fetch(:click_id)
    assert_nil track.requests.first.fetch(:timeout_ms)
  end

  def test_disable_lead_tracking_skips_dub_call_and_cookie_cleanup
    track = FakeDubTrack.new(leads: [])
    auth = build_auth(
      dub_client: FakeDubClient.new(track: track),
      dub_options: {disable_lead_tracking: true}
    )

    result = sign_up(auth, email: "disabled-lead@example.com", headers: {"cookie" => "dub_id=click_disabled"})

    assert_empty track.leads
    refute_includes result[:headers].fetch("set-cookie"), "dub_id="
  end

  def test_custom_lead_track_replaces_default_dub_call
    track = FakeDubTrack.new(leads: [])
    custom_calls = []
    auth = build_auth(
      dub_client: FakeDubClient.new(track: track),
      dub_options: {
        custom_lead_track: ->(user, ctx) {
          custom_calls << {
            user_id: user.fetch("id"),
            email: user.fetch("email"),
            dub_id: ctx.get_cookie("dub_id")
          }
        }
      }
    )

    result = sign_up(auth, email: "custom-lead@example.com", headers: {"cookie" => "dub_id=click_custom"})

    assert_empty track.leads
    assert_equal [
      {
        user_id: result[:response][:user]["id"],
        email: "custom-lead@example.com",
        dub_id: "click_custom"
      }
    ], custom_calls
    assert_expired_dub_cookie result[:headers].fetch("set-cookie")
  end

  def test_dub_link_requires_oauth_configuration
    auth = build_auth(dub_client: FakeDubClient.new(track: FakeDubTrack.new(leads: [])))
    cookie = sign_up(auth, email: "oauth-required@example.com")[:cookie]

    error = assert_raises(BetterAuth::APIError) do
      auth.api.dub_link(headers: {"cookie" => cookie}, body: {callbackURL: "/settings"})
    end

    assert_equal 404, error.status_code
    assert_equal "Dub OAuth is not configured", error.message
  end

  def test_dub_link_generates_dub_oauth_authorization_url_for_current_user
    auth = build_auth(
      dub_client: FakeDubClient.new(track: FakeDubTrack.new(leads: [])),
      dub_options: {
        oauth: {
          client_id: "dub-client-id",
          client_secret: "dub-client-secret"
        }
      }
    )
    cookie = sign_up(auth, email: "link@example.com")[:cookie]

    result = auth.api.dub_link(headers: {"cookie" => cookie}, body: {callbackURL: "/settings"})
    uri = URI.parse(result[:url])
    params = Rack::Utils.parse_query(uri.query)

    assert_equal true, result[:redirect]
    assert_equal "https", uri.scheme
    assert_equal "app.dub.co", uri.host
    assert_equal "/oauth/authorize", uri.path
    assert_equal "dub-client-id", params.fetch("client_id")
    assert_equal "code", params.fetch("response_type")
    assert_equal "http://localhost:3000/api/auth/oauth2/callback/dub", params.fetch("redirect_uri")
    assert params.fetch("state")
  end

  def test_dub_oauth_callback_endpoint_is_registered_when_oauth_is_configured
    auth = build_auth(
      dub_client: FakeDubClient.new(track: FakeDubTrack.new(leads: [])),
      dub_options: {
        oauth: {
          client_id: "dub-client-id",
          client_secret: "dub-client-secret"
        }
      }
    )

    assert_includes auth.api.endpoints.keys, :dub_o_auth2_callback
    assert_equal "/oauth2/callback/:providerId", auth.api.endpoints.fetch(:dub_o_auth2_callback).path
  end

  private

  def build_auth(dub_client:, dub_options: {}, logger: nil)
    BetterAuth.auth(
      secret: SECRET,
      base_url: "http://localhost:3000",
      email_and_password: {enabled: true},
      logger: logger,
      plugins: [
        BetterAuth::Plugins.dub({dub_client: dub_client}.merge(dub_options))
      ]
    )
  end

  def sign_up(auth, email:, headers: {})
    result = auth.api.sign_up_email(
      body: {
        email: email,
        password: "password123",
        name: "Dub Lead"
      },
      headers: headers,
      return_headers: true
    )
    result.merge(cookie: cookie_header(result[:headers].fetch("set-cookie")))
  end

  def cookie_header(set_cookie)
    set_cookie.to_s.lines.map { |line| line.split(";").first }.join("; ")
  end

  def assert_expired_dub_cookie(set_cookie)
    line = set_cookie.to_s.lines.find { |entry| entry.start_with?("dub_id=;") }
    assert line, "expected expired dub_id cookie in #{set_cookie.inspect}"
    assert_includes line, "Max-Age=0"
  end
end
