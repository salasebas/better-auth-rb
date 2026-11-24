# frozen_string_literal: true

require_relative "../test_support"

class BetterAuthAPIKeyDeleteRouteTest < Minitest::Test
  include APIKeyTestSupport

  def test_delete_route_removes_key
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "delete-route-key@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {})

    assert_equal({success: true}, auth.api.delete_api_key(headers: {"cookie" => cookie}, body: {keyId: created[:id]}))
    assert_raises(BetterAuth::APIError) do
      auth.api.get_api_key(headers: {"cookie" => cookie}, query: {id: created[:id]})
    end
  end

  def test_delete_route_unknown_key_is_not_found
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "delete-route-missing-key@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.delete_api_key(headers: {"cookie" => cookie}, body: {keyId: "missing"})
    end

    assert_equal "NOT_FOUND", error.status
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("KEY_NOT_FOUND"), error.message
  end

  def test_delete_route_rejects_wrong_user_as_not_found
    auth = build_api_key_auth(default_key_length: 12)
    owner_cookie = sign_up_cookie(auth, email: "delete-route-owner-key@example.com")
    other_cookie = sign_up_cookie(auth, email: "delete-route-other-key@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => owner_cookie}, body: {})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.delete_api_key(headers: {"cookie" => other_cookie}, body: {keyId: created[:id]})
    end

    assert_equal "NOT_FOUND", error.status
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("KEY_NOT_FOUND"), error.message
  end

  def test_delete_route_removes_secondary_storage_keys_and_reference_list
    storage = APIKeyTestSupport::MemoryStorage.new
    auth = build_api_key_auth(storage: "secondary-storage", secondary_storage: storage, default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "delete-route-storage-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id})

    result = auth.api.delete_api_key(headers: {"cookie" => cookie}, body: {keyId: created[:id]})

    assert_equal({success: true}, result)
    assert_nil storage.get("api-key:by-id:#{created[:id]}")
    refute_includes JSON.parse(storage.get("api-key:by-ref:#{user_id}") || "[]"), created[:id]
  end
end
