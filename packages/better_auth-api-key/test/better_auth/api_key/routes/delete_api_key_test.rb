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

  def test_fallback_delete_removes_secondary_cache_before_database
    events = []
    storage = APIKeyTestSupport::MemoryStorage.new
    auth = build_api_key_auth(
      storage: "secondary-storage",
      fallback_to_database: true,
      secondary_storage: storage,
      default_key_length: 12
    )
    cookie = sign_up_cookie(auth, email: "delete-route-fallback-order-key@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {})
    original_storage_delete = storage.method(:delete)
    storage.define_singleton_method(:delete) do |key|
      events << :secondary
      original_storage_delete.call(key)
    end
    original_database_delete = auth.context.adapter.method(:delete)
    auth.context.adapter.define_singleton_method(:delete) do |**kwargs|
      events << :database if kwargs[:model].to_s == "apikey"
      original_database_delete.call(**kwargs)
    end

    result = auth.api.delete_api_key(headers: {"cookie" => cookie}, body: {keyId: created[:id]})

    assert_equal({success: true}, result)
    assert_equal :database, events.last
    assert events[0...-1].all? { |event| event == :secondary }
  end

  def test_delete_route_wraps_cache_failure_and_leaves_fallback_database_record
    storage = APIKeyTestSupport::MemoryStorage.new
    auth = build_api_key_auth(
      storage: "secondary-storage",
      fallback_to_database: true,
      secondary_storage: storage,
      default_key_length: 12
    )
    cookie = sign_up_cookie(auth, email: "delete-route-fallback-error-key@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {})
    storage.define_singleton_method(:delete) do |_key|
      raise StandardError, "simulated cache delete failure"
    end

    error = assert_raises(BetterAuth::APIError) do
      auth.api.delete_api_key(headers: {"cookie" => cookie}, body: {keyId: created[:id]})
    end
    stored = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])

    assert_equal "INTERNAL_SERVER_ERROR", error.status
    assert_equal "simulated cache delete failure", error.message
    refute_nil stored
  end
end
