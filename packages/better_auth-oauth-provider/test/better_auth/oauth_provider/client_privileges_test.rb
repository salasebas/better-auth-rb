# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderClientPrivilegesTest < Minitest::Test
  include OAuthProviderFlowHelpers

  def test_create_client_requires_session_and_respects_create_privilege
    calls = []
    auth = build_auth(client_privileges: ->(info) {
      calls << [info[:action], info[:user]&.fetch("email", nil)]
      info[:user]&.fetch("email", nil) == "allowed@example.com"
    })
    forbidden_cookie = sign_up_cookie(auth, email: "forbidden@example.com")
    allowed_cookie = sign_up_cookie(auth, email: "allowed@example.com")

    assert_raises(BetterAuth::APIError) do
      auth.api.create_oauth_client(body: {redirect_uris: ["https://example.com/cb"]})
    end

    forbidden = assert_raises(BetterAuth::APIError) do
      auth.api.create_oauth_client(headers: {"cookie" => forbidden_cookie}, body: {redirect_uris: ["https://example.com/cb"]})
    end
    assert_equal 401, forbidden.status_code

    client = auth.api.create_oauth_client(headers: {"cookie" => allowed_cookie}, body: {redirect_uris: ["https://example.com/cb"]})

    assert client[:client_id]
    assert client[:client_secret]
    assert_equal [["create", "forbidden@example.com"], ["create", "allowed@example.com"]], calls
  end

  def test_admin_create_client_respects_create_privilege_when_session_headers_are_supplied
    auth = build_auth(
      client_reference: ->(info) { "ref:#{info[:user]["id"]}" },
      client_privileges: ->(info) { info[:user]&.fetch("email", nil) == "allowed-admin@example.com" }
    )
    forbidden_cookie = sign_up_cookie(auth, email: "forbidden-admin@example.com")
    allowed_cookie = sign_up_cookie(auth, email: "allowed-admin@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.admin_create_oauth_client(headers: {"cookie" => forbidden_cookie}, body: {redirect_uris: ["https://example.com/cb"]})
    end
    assert_equal 401, error.status_code

    client = auth.api.admin_create_oauth_client(headers: {"cookie" => allowed_cookie}, body: {redirect_uris: ["https://example.com/cb"]})

    assert client[:client_id]
    assert_nil client[:user_id]
    assert client[:reference_id]
  end

  def test_authenticated_dynamic_registration_respects_create_privilege
    auth = build_auth(client_privileges: ->(_info) { false })
    cookie = sign_up_cookie(auth)

    error = assert_raises(BetterAuth::APIError) do
      register_client(auth, cookie)
    end

    assert_equal 401, error.status_code
  end

  def test_read_list_update_rotate_and_delete_client_respect_privileges
    blocked_actions = %w[read list update rotate delete]
    blocked_actions.each do |blocked_action|
      auth = build_auth(client_privileges: ->(info) { info[:action] != blocked_action })
      cookie = sign_up_cookie(auth, email: "#{blocked_action}@example.com")
      client = auth.api.create_oauth_client(headers: {"cookie" => cookie}, body: {redirect_uris: ["https://example.com/cb"]})

      error = assert_raises(BetterAuth::APIError) do
        case blocked_action
        when "read"
          auth.api.get_oauth_client(headers: {"cookie" => cookie}, query: {client_id: client[:client_id]})
        when "list"
          auth.api.get_oauth_clients(headers: {"cookie" => cookie})
        when "update"
          auth.api.update_oauth_client(headers: {"cookie" => cookie}, body: {client_id: client[:client_id], update: {client_name: "Blocked"}})
        when "rotate"
          auth.api.rotate_oauth_client_secret(headers: {"cookie" => cookie}, body: {client_id: client[:client_id]})
        when "delete"
          auth.api.delete_oauth_client(headers: {"cookie" => cookie}, body: {client_id: client[:client_id]})
        end
      end

      assert_equal 401, error.status_code, "expected #{blocked_action} to be blocked"
    end
  end

  def test_public_client_endpoint_is_readable_without_privilege_check
    auth = build_auth(client_privileges: ->(info) { info[:action] != "read" })
    cookie = sign_up_cookie(auth)
    client = auth.api.create_oauth_client(headers: {"cookie" => cookie}, body: {redirect_uris: ["https://example.com/cb"], client_name: "Readable"})

    public_client = auth.api.get_oauth_client_public(headers: {"cookie" => cookie}, query: {client_id: client[:client_id]})

    assert_equal "Readable", public_client[:client_name]
    refute public_client.key?(:client_secret)
  end

  def test_update_cannot_make_client_public_or_change_client_secret
    auth = build_auth
    cookie = sign_up_cookie(auth)
    client = auth.api.create_oauth_client(
      headers: {"cookie" => cookie},
      body: {
        redirect_uris: ["https://example.com/cb"],
        token_endpoint_auth_method: "client_secret_post"
      }
    )

    updated = auth.api.update_oauth_client(
      headers: {"cookie" => cookie},
      body: {
        client_id: client[:client_id],
        update: {
          public: true,
          token_endpoint_auth_method: "none",
          client_secret: "attacker-secret"
        }
      }
    )

    assert_equal "client_secret_post", updated[:token_endpoint_auth_method]
    assert_equal false, updated[:public]
    refute_equal "attacker-secret", updated[:client_secret]
    assert_nil updated[:client_secret]
  end
end
