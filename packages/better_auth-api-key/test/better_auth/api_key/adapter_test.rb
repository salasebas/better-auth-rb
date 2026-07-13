# frozen_string_literal: true

require_relative "test_support"

class BetterAuthAPIKeyAdapterTest < Minitest::Test
  include APIKeyTestSupport

  def test_storage_key_builders_match_upstream_layout
    assert_equal "api-key:hashed", BetterAuth::APIKey::Adapter.storage_key_by_hash("hashed")
    assert_equal "api-key:by-id:key-id", BetterAuth::APIKey::Adapter.storage_key_by_id("key-id")
    assert_equal "api-key:by-ref:user-id", BetterAuth::APIKey::Adapter.storage_key_by_reference("user-id")
  end

  def test_storage_record_serializes_and_deserializes_times
    now = Time.now
    record = {
      "id" => "key-id",
      "createdAt" => now,
      "updatedAt" => now,
      "expiresAt" => now,
      "lastRefillAt" => now,
      "lastRequest" => now
    }

    serialized = BetterAuth::APIKey::Adapter.storage_record(record)
    restored = BetterAuth::APIKey::Adapter.deserialize_record(serialized.dup)

    assert_instance_of String, serialized.fetch("createdAt")
    assert_instance_of Time, restored.fetch("createdAt")
    assert_instance_of Time, restored.fetch("lastRequest")
  end

  def test_secondary_storage_ttl_is_set_for_expiring_key
    storage = APIKeyTestSupport::MemoryStorage.new
    auth = build_api_key_auth(storage: "secondary-storage", secondary_storage: storage, default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "adapter-storage-key@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {expiresIn: 60 * 60 * 24 + 1})

    assert_operator storage.ttls.fetch("api-key:by-id:#{created[:id]}"), :>, 0
  end

  def test_migrate_legacy_metadata_updates_double_stringified_database_value
    auth = build_api_key_auth(enable_metadata: true, default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "adapter-metadata-key@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {metadata: {plan: "free"}})
    legacy_metadata = JSON.generate(JSON.generate({plan: "legacy"}))
    auth.context.adapter.update(model: "apikey", where: [{field: "id", value: created[:id]}], update: {metadata: legacy_metadata})
    record = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])

    migrated = BetterAuth::APIKey::Adapter.migrate_legacy_metadata(auth, record, storage: "database")

    assert_equal JSON.generate({"plan" => "legacy"}), migrated.fetch("metadata")
    stored = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])
    assert_equal({"plan" => "legacy"}, JSON.parse(stored.fetch("metadata")))
  end

  def test_migrate_legacy_metadata_leaves_null_and_object_values_unchanged
    auth = build_api_key_auth(enable_metadata: true, default_key_length: 12)
    null_record = {"id" => "null-metadata-key", "metadata" => nil}
    object_record = {"id" => "object-metadata-key", "metadata" => JSON.generate({"plan" => "pro"})}

    assert_same null_record, BetterAuth::APIKey::Adapter.migrate_legacy_metadata(auth, null_record, storage: "database")
    assert_equal object_record, BetterAuth::APIKey::Adapter.migrate_legacy_metadata(auth, object_record, storage: "database")
  end

  def test_custom_storage_takes_precedence_over_context_secondary_storage
    custom_storage = APIKeyTestSupport::MemoryStorage.new
    context_storage = APIKeyTestSupport::MemoryStorage.new
    auth = build_api_key_auth(
      storage: "secondary-storage",
      custom_storage: custom_storage,
      secondary_storage: context_storage,
      default_key_length: 12
    )
    cookie = sign_up_cookie(auth, email: "adapter-custom-storage-key@example.com")

    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {})

    assert custom_storage.get("api-key:by-id:#{created[:id]}")
    assert_nil context_storage.get("api-key:by-id:#{created[:id]}")
  end

  def test_reference_list_helpers_add_remove_and_ignore_invalid_json
    storage = APIKeyTestSupport::MemoryStorage.new
    reference_key = BetterAuth::APIKey::Adapter.storage_key_by_reference("user-id")

    BetterAuth::APIKey::Adapter.ref_list_add(storage, reference_key, "first")
    BetterAuth::APIKey::Adapter.ref_list_add(storage, reference_key, "first")
    BetterAuth::APIKey::Adapter.ref_list_add(storage, reference_key, "second")
    assert_equal ["first", "second"], JSON.parse(storage.get(reference_key))

    BetterAuth::APIKey::Adapter.ref_list_remove(storage, reference_key, "first")
    assert_equal ["second"], JSON.parse(storage.get(reference_key))

    storage.set(reference_key, "{")
    assert_equal [], BetterAuth::APIKey::Adapter.safe_parse_id_list(storage.get(reference_key))
  end

  def test_reference_list_helpers_accept_raw_array_values_from_custom_storage
    assert_equal ["first", "second"], BetterAuth::APIKey::Adapter.safe_parse_id_list(["first", "second"])
  end

  def test_reference_list_helpers_serialize_concurrent_custom_storage_writers_in_process
    storage = APIKeyTestSupport::MemoryStorage.new
    reference_key = BetterAuth::APIKey::Adapter.storage_key_by_reference("concurrent-user")
    threads = 20.times.map do |index|
      Thread.new { BetterAuth::APIKey::Adapter.ref_list_add(storage, reference_key, "id-#{index}") }
    end
    threads.each(&:join)

    assert_equal (0...20).map { |index| "id-#{index}" }.sort, JSON.parse(storage.get(reference_key)).sort
  end

  def test_populate_reference_batches_fallback_cache_writes_when_supported
    storage = BatchTrackingStorage.new
    auth = build_api_key_auth(storage: "secondary-storage", secondary_storage: storage, fallback_to_database: true, default_key_length: 12)
    ctx = Struct.new(:context).new(auth.context)
    now = Time.now
    records = [
      {
        "id" => "first-key",
        "key" => "hashed-first",
        "referenceId" => "user-batch",
        "createdAt" => now,
        "updatedAt" => now,
        "expiresAt" => nil
      },
      {
        "id" => "second-key",
        "key" => "hashed-second",
        "referenceId" => "user-batch",
        "createdAt" => now,
        "updatedAt" => now,
        "expiresAt" => nil
      }
    ]
    config = BetterAuth::APIKey::Configuration.normalize(
      storage: "secondary-storage",
      fallback_to_database: true
    )

    BetterAuth::APIKey::Adapter.populate_reference(ctx, "user-batch", records, config)

    assert_equal 1, storage.write_groups.length
    assert_equal [
      "api-key:hashed-first",
      "api-key:by-id:first-key",
      "api-key:hashed-second",
      "api-key:by-id:second-key",
      "api-key:by-ref:user-batch"
    ], storage.write_groups.first
  end

  def test_list_for_reference_warns_on_corrupt_reference_index_json
    storage = APIKeyTestSupport::MemoryStorage.new
    ref = "user-corrupt"
    storage.set(BetterAuth::APIKey::Adapter.storage_key_by_reference(ref), "{bad")

    warnings = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |msg| warnings << msg }

    auth = build_api_key_auth(
      storage: "secondary-storage",
      secondary_storage: storage,
      fallback_to_database: false,
      default_key_length: 12
    )
    auth.context.define_singleton_method(:logger) { logger }

    ctx = Struct.new(:context).new(auth.context)
    config = BetterAuth::APIKey::Configuration.normalize({})[:configurations].first
    config = config.merge(storage: "secondary-storage", fallback_to_database: false)

    result = BetterAuth::APIKey::Adapter.list_for_reference(ctx, ref, config)

    assert_equal [], result
    assert_equal 1, warnings.length
    assert_match(/Corrupt api-key reference index/i, warnings.first)
  end

  def test_deferred_update_record_logs_failures
    deferred = []
    errors = []
    auth = build_api_key_auth(
      defer_updates: true,
      advanced: {background_tasks: {handler: ->(task) { deferred << task }}}
    )
    logger = Object.new
    logger.define_singleton_method(:error) { |message, *| errors << message }
    auth.context.define_singleton_method(:logger) { logger }
    auth.context.adapter.define_singleton_method(:update) do |**|
      raise StandardError, "simulated update failure"
    end
    ctx = Struct.new(:context).new(auth.context)
    config = BetterAuth::APIKey::Configuration.normalize(defer_updates: true)
    record = {"id" => "deferred-key", "remaining" => 2}

    BetterAuth::APIKey::Adapter.update_record(ctx, record, {remaining: 1}, config, defer: true)
    deferred.each(&:call)

    assert_equal 1, errors.length
    assert_match(/simulated update failure/, errors.first)
  end

  def test_deferred_record_delete_logs_failures
    deferred = []
    errors = []
    auth = build_api_key_auth(
      defer_updates: true,
      advanced: {background_tasks: {handler: ->(task) { deferred << task }}}
    )
    logger = Object.new
    logger.define_singleton_method(:error) { |message, *| errors << message }
    auth.context.define_singleton_method(:logger) { logger }
    auth.context.adapter.define_singleton_method(:delete) do |**|
      raise StandardError, "simulated delete failure"
    end
    ctx = Struct.new(:context).new(auth.context)
    config = BetterAuth::APIKey::Configuration.normalize(defer_updates: true)
    record = {"id" => "deferred-delete-key", "key" => "hashed", "referenceId" => "user-id"}

    BetterAuth::APIKey::Adapter.schedule_record_delete(ctx, record, config)
    deferred.each(&:call)

    assert_equal 1, errors.length
    assert_match(/simulated delete failure/, errors.first)
  end

  class BatchTrackingStorage < APIKeyTestSupport::MemoryStorage
    attr_reader :write_groups

    def initialize
      super
      @write_groups = []
      @current_group = nil
    end

    def set(key, value, ttl = nil)
      record_write(key)
      super
    end

    def delete(key)
      record_write(key)
      super
    end

    def batch
      @current_group = []
      yield
      @write_groups << @current_group unless @current_group.empty?
      @current_group = nil
    end

    private

    def record_write(key)
      if @current_group
        @current_group << key
      else
        @write_groups << [key]
      end
    end
  end
end
