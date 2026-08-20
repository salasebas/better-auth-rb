# frozen_string_literal: true

require_relative "../test_support"

class BetterAuthAPIKeyListRouteTest < Minitest::Test
  include APIKeyTestSupport

  def test_list_route_returns_upstream_pagination_shape
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "list-route-key@example.com")
    auth.api.create_api_key(headers: {"cookie" => cookie}, body: {name: "alpha"})
    auth.api.create_api_key(headers: {"cookie" => cookie}, body: {name: "beta"})

    listed = auth.api.list_api_keys(headers: {"cookie" => cookie}, query: {limit: "1", offset: "1", sortBy: "name", sortDirection: "asc"})

    assert_equal ["beta"], listed[:apiKeys].map { |key| key[:name] }
    assert_equal 2, listed[:total]
    assert_equal 1, listed[:limit]
    assert_equal 1, listed[:offset]
  end

  def test_list_route_requires_session_and_rejects_invalid_query
    auth = build_api_key_auth(default_key_length: 12)

    unauthorized = assert_raises(BetterAuth::APIError) { auth.api.list_api_keys }
    invalid_query = assert_raises(BetterAuth::APIError) do
      cookie = sign_up_cookie(auth, email: "list-route-invalid-key@example.com")
      auth.api.list_api_keys(headers: {"cookie" => cookie}, query: {limit: -1})
    end

    assert_equal "UNAUTHORIZED", unauthorized.status
    assert_equal "BAD_REQUEST", invalid_query.status
  end

  def test_list_route_filters_config_and_never_returns_secret_key
    auth = build_api_key_auth([
      {config_id: "public-api", default_prefix: "pub_", default_key_length: 12},
      {config_id: "internal-api", default_prefix: "int_", default_key_length: 12},
      {config_id: "default", default_prefix: "def_", default_key_length: 12}
    ])
    cookie = sign_up_cookie(auth, email: "list-route-config-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    public_key = auth.api.create_api_key(body: {userId: user_id, configId: "public-api", name: "public"})
    internal_key = auth.api.create_api_key(body: {userId: user_id, configId: "internal-api", name: "internal"})

    listed = auth.api.list_api_keys(headers: {"cookie" => cookie}, query: {configId: "public-api"})
    blank_config = auth.api.list_api_keys(headers: {"cookie" => cookie}, query: {configId: ""})

    assert_equal [public_key[:id]], listed[:apiKeys].map { |key| key[:id] }
    assert_equal 1, listed[:total]
    assert_equal "public-api", listed[:apiKeys].first[:configId]
    refute listed[:apiKeys].first.key?(:key)
    assert_equal [internal_key[:id], public_key[:id]].sort, blank_config[:apiKeys].map { |key| key[:id] }.sort
    assert_equal 2, blank_config[:total]
  end

  # Upstream: packages/api-key/src/routes/list-api-keys.ts:268-279.
  def test_list_route_keeps_blank_organization_reference_but_uses_user_ownership
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "list-route-blank-org-key@example.com")
    auth.api.create_api_key(headers: {"cookie" => cookie}, body: {name: "user-key"})

    listed = auth.api.list_api_keys(headers: {"cookie" => cookie}, query: {organizationId: ""})

    assert_empty listed[:apiKeys]
    assert_equal 0, listed[:total]
  end

  # Upstream sorts each storage group before merging, then paginates the merge.
  # packages/api-key/src/routes/list-api-keys.ts:283-366.
  def test_list_route_sorts_each_storage_group_before_merge_and_pagination
    secondary_storage = APIKeyTestSupport::MemoryStorage.new
    auth = build_api_key_auth([
      {config_id: "default", storage: "database", default_key_length: 12},
      {config_id: "cached", storage: "secondary-storage", custom_storage: secondary_storage, default_key_length: 12}
    ])
    cookie = sign_up_cookie(auth, email: "list-route-group-order-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    auth.api.create_api_key(body: {userId: user_id, configId: "default", name: "zulu"})
    auth.api.create_api_key(body: {userId: user_id, configId: "default", name: "beta"})
    auth.api.create_api_key(body: {userId: user_id, configId: "cached", name: "charlie"})
    auth.api.create_api_key(body: {userId: user_id, configId: "cached", name: "alpha"})

    listed = auth.api.list_api_keys(
      headers: {"cookie" => cookie},
      query: {sortBy: "name", sortDirection: "asc", offset: 1, limit: 2}
    )

    assert_equal %w[zulu alpha], listed[:apiKeys].map { |key| key[:name] }
    assert_equal 4, listed[:total]
  end

  def test_list_route_bounds_parallel_storage_group_queries
    tracker = ConcurrentGetTracker.new
    configurations = 12.times.map do |index|
      {
        config_id: "custom-#{index}",
        storage: "secondary-storage",
        custom_storage: TrackedListStorage.new(tracker),
        default_key_length: 12
      }
    end
    auth = build_api_key_auth(configurations)
    cookie = sign_up_cookie(auth, email: "list-route-group-concurrency-key@example.com")

    listed = auth.api.list_api_keys(headers: {"cookie" => cookie})

    assert_empty listed[:apiKeys]
    assert_equal 10, tracker.max_active
  end

  # Upstream defaults records whose configuration no longer exists to user ownership.
  # packages/api-key/src/routes/list-api-keys.ts:335-349.
  def test_list_route_treats_unknown_record_configuration_as_user_owned
    auth = build_api_key_auth([{config_id: "default", references: "organization", default_key_length: 12}])
    cookie = sign_up_cookie(auth, email: "list-route-removed-config-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    now = Time.now
    record = auth.context.adapter.create(
      model: "apikey",
      force_allow_id: true,
      data: {
        configId: "removed-config",
        referenceId: user_id,
        key: "removed-config-hash",
        createdAt: now,
        updatedAt: now
      }
    )

    listed = auth.api.list_api_keys(headers: {"cookie" => cookie})

    assert_equal [record.fetch("id")], listed[:apiKeys].map { |key| key[:id] }
    assert_equal "removed-config", listed[:apiKeys].first[:configId]
  end

  def test_list_route_sorts_created_at_descending_and_handles_offset_overflow
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "list-route-created-key@example.com")
    auth.api.create_api_key(headers: {"cookie" => cookie}, body: {name: "oldest"})
    sleep 0.01
    auth.api.create_api_key(headers: {"cookie" => cookie}, body: {name: "newest"})

    sorted = auth.api.list_api_keys(headers: {"cookie" => cookie}, query: {sortBy: "createdAt", sortDirection: "desc"})
    overflow = auth.api.list_api_keys(headers: {"cookie" => cookie}, query: {offset: sorted[:total] + 100})

    assert_equal "newest", sorted[:apiKeys].first[:name]
    assert_empty overflow[:apiKeys]
    assert_equal sorted[:total], overflow[:total]
  end

  def test_list_route_returns_parsed_metadata_and_defers_legacy_metadata_migration
    deferred = []
    auth = build_api_key_auth(
      enable_metadata: true,
      default_key_length: 12,
      advanced: {background_tasks: {handler: ->(task) { deferred << task }}}
    )
    cookie = sign_up_cookie(auth, email: "list-route-metadata-migration-key@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {name: "legacy", metadata: {plan: "free"}})
    legacy = JSON.generate(JSON.generate({plan: "legacy"}))
    auth.context.adapter.update(model: "apikey", where: [{field: "id", value: created[:id]}], update: {metadata: legacy})

    listed = auth.api.list_api_keys(headers: {"cookie" => cookie})
    entry = listed.fetch(:apiKeys).find { |key| key.fetch(:id) == created[:id] }
    stored_before_task = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])

    assert_equal({"plan" => "legacy"}, entry.fetch(:metadata))
    assert_equal legacy, stored_before_task.fetch("metadata")
    assert_equal 1, deferred.length

    deferred.each(&:call)
    stored_after_task = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])
    assert_equal({"plan" => "legacy"}, JSON.parse(stored_after_task.fetch("metadata")))
  end

  def test_list_route_does_not_duplicate_database_scans_for_equivalent_configurations
    auth = build_api_key_auth([
      {config_id: "default", default_prefix: "def_", default_key_length: 12},
      {config_id: "service", default_prefix: "svc_", default_key_length: 12},
      {config_id: "internal", default_prefix: "int_", default_key_length: 12}
    ])
    cookie = sign_up_cookie(auth, email: "list-route-storage-group-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    auth.api.create_api_key(body: {userId: user_id, configId: "service", name: "service"})
    auth.api.create_api_key(body: {userId: user_id, configId: "internal", name: "internal"})
    find_many_calls = []
    original_find_many = auth.context.adapter.method(:find_many)
    auth.context.adapter.define_singleton_method(:find_many) do |**kwargs|
      find_many_calls << kwargs if kwargs[:model].to_s == "apikey"
      original_find_many.call(**kwargs)
    end

    listed = auth.api.list_api_keys(headers: {"cookie" => cookie})

    assert_equal 2, listed[:total]
    assert_operator find_many_calls.length, :<=, 2
  end

  def test_list_route_pushes_pagination_to_database_for_explicit_non_default_config
    auth = build_api_key_auth([
      {config_id: "default", default_prefix: "def_", default_key_length: 12},
      {config_id: "service", default_prefix: "svc_", default_key_length: 12}
    ])
    cookie = sign_up_cookie(auth, email: "list-route-db-pagination-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    auth.api.create_api_key(body: {userId: user_id, configId: "service", name: "alpha"})
    auth.api.create_api_key(body: {userId: user_id, configId: "service", name: "beta"})
    auth.api.create_api_key(body: {userId: user_id, configId: "default", name: "default"})
    find_many_calls = []
    original_find_many = auth.context.adapter.method(:find_many)
    auth.context.adapter.define_singleton_method(:find_many) do |**kwargs|
      find_many_calls << kwargs if kwargs[:model].to_s == "apikey"
      original_find_many.call(**kwargs)
    end

    listed = auth.api.list_api_keys(headers: {"cookie" => cookie}, query: {configId: "service", limit: "1", offset: "1", sortBy: "name", sortDirection: "asc"})
    paginated_call = find_many_calls.find { |call| call[:limit] == 1 && call[:offset] == 1 }

    assert_equal 2, listed[:total]
    assert_equal ["beta"], listed[:apiKeys].map { |key| key[:name] }
    refute_nil paginated_call
    assert_equal({field: "name", direction: "asc"}, paginated_call[:sort_by])
  end

  class ConcurrentGetTracker
    attr_reader :max_active

    def initialize
      @lock = Mutex.new
      @active = 0
      @max_active = 0
    end

    def track
      @lock.synchronize do
        @active += 1
        @max_active = [@max_active, @active].max
      end
      sleep 0.01
    ensure
      @lock.synchronize { @active -= 1 }
    end
  end

  class TrackedListStorage < APIKeyTestSupport::MemoryStorage
    def initialize(tracker)
      super()
      @tracker = tracker
    end

    def get(key)
      @tracker.track if key.start_with?("api-key:by-ref:")
      super
    end
  end
end
