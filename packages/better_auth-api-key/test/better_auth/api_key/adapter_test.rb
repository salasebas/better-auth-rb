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
    now = Time.new(2026, 8, 20, 12, 34, 56.789123, "+06:00")
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

    assert_equal "2026-08-20T06:34:56.789Z", serialized.fetch("createdAt")
    assert_instance_of Time, restored.fetch("createdAt")
    assert_instance_of Time, restored.fetch("lastRequest")
    assert_equal 789_000, restored.fetch("createdAt").usec
    assert_equal 6 * 60 * 60, record.fetch("createdAt").utc_offset
  end

  def test_secondary_storage_ttl_is_set_for_expiring_key
    storage = APIKeyTestSupport::MemoryStorage.new
    auth = build_api_key_auth(storage: "secondary-storage", secondary_storage: storage, default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "adapter-storage-key@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {expiresIn: 60 * 60 * 24 + 1})

    assert_operator storage.ttls.fetch("api-key:by-id:#{created[:id]}"), :>, 0
  end

  def test_secondary_storage_omits_nonpositive_and_sub_second_ttls
    storage = APIKeyTestSupport::MemoryStorage.new
    ctx = Struct.new(:context).new(nil)
    config = {storage: "secondary-storage", fallback_to_database: false, custom_storage: storage}
    now = Time.utc(2026, 8, 20, 12, 0, 0)

    Time.stub(:now, now) do
      [2.9, 0.9, 0, -0.1].each_with_index do |offset, index|
        BetterAuth::APIKey::Adapter.set(ctx, {
          "id" => "ttl-#{index}",
          "key" => "hash-#{index}",
          "referenceId" => "reference",
          "expiresAt" => now + offset
        }, config)
      end
    end

    ttl_calls = storage.set_calls.select { |key, _value, _ttl| key.start_with?("api-key:by-id:ttl-") }
    assert_equal [2, nil, nil, nil], ttl_calls.map(&:last)
  end

  def test_by_hash_and_id_treat_non_string_storage_values_as_cache_misses
    storage = APIKeyTestSupport::MemoryStorage.new
    ctx = Struct.new(:context).new(nil)
    config = {storage: "secondary-storage", fallback_to_database: false, custom_storage: storage}
    storage.values["api-key:hash"] = {"id" => "key-id"}
    storage.values["api-key:by-id:key-id"] = ["key-id"]
    storage.values["api-key:by-id:null-key"] = "null"

    assert_nil BetterAuth::APIKey::Adapter.find_by_hash(ctx, "hash", config)
    assert_nil BetterAuth::APIKey::Adapter.find_by_id(ctx, "key-id", config)
    assert_nil BetterAuth::APIKey::Adapter.find_by_id(ctx, "null-key", config)
    assert_equal ["api-key:hash", "api-key:by-id:key-id", "api-key:by-id:null-key"], storage.get_calls
  end

  def test_json_scalar_and_array_storage_values_match_upstream_object_spread
    storage = APIKeyTestSupport::MemoryStorage.new
    database = Object.new
    database.define_singleton_method(:find_one) { |**| raise "database fallback must not run" }
    context = Struct.new(:adapter).new(database)
    ctx = Struct.new(:context).new(context)
    config = {storage: "secondary-storage", fallback_to_database: true, custom_storage: storage}
    storage.values["api-key:false"] = "false"
    storage.values["api-key:by-id:array"] = JSON.generate(["first", "second"])

    scalar = BetterAuth::APIKey::Adapter.find_by_hash(ctx, "false", config)
    array = BetterAuth::APIKey::Adapter.find_by_id(ctx, "array", config)

    assert_equal({
      "createdAt" => nil,
      "updatedAt" => nil,
      "expiresAt" => nil,
      "lastRefillAt" => nil,
      "lastRequest" => nil
    }, scalar)
    assert_equal "first", array["0"]
    assert_equal "second", array["1"]
    assert array.key?("createdAt")
  end

  def test_non_string_by_id_cache_value_falls_back_to_database
    storage = APIKeyTestSupport::MemoryStorage.new
    auth = build_api_key_auth(
      storage: "secondary-storage",
      secondary_storage: storage,
      fallback_to_database: true,
      default_key_length: 12
    )
    cookie = sign_up_cookie(auth, email: "adapter-invalid-cache-key@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {})
    storage.values["api-key:by-id:#{created[:id]}"] = {"invalid" => true}

    fetched = auth.api.get_api_key(headers: {"cookie" => cookie}, query: {id: created[:id]})

    assert_equal created[:id], fetched[:id]
    assert_instance_of String, storage.values.fetch("api-key:by-id:#{created[:id]}")
  end

  def test_secondary_storage_uses_only_upstream_key_namespaces
    storage = APIKeyTestSupport::MemoryStorage.new
    ctx = Struct.new(:context).new(nil)
    config = {storage: "secondary-storage", fallback_to_database: false, custom_storage: storage}
    record = {"id" => "key-id", "key" => "hash", "referenceId" => "reference"}
    serialized = JSON.generate(record)
    storage.values["api-key:key:hash"] = serialized
    storage.values["api-key:id:key-id"] = serialized
    storage.values["api-key:user:reference"] = JSON.generate(["key-id"])

    assert_nil BetterAuth::APIKey::Adapter.find_by_hash(ctx, "hash", config)
    assert_nil BetterAuth::APIKey::Adapter.find_by_id(ctx, "key-id", config)
    assert_equal [], BetterAuth::APIKey::Adapter.list_for_reference(ctx, "reference", config)

    BetterAuth::APIKey::Adapter.delete(ctx, record, config)

    assert_equal [
      "api-key:hash",
      "api-key:by-id:key-id",
      "api-key:by-ref:reference",
      "api-key:by-ref:reference"
    ], storage.get_calls
    assert_equal [
      "api-key:hash",
      "api-key:by-id:key-id",
      "api-key:by-ref:reference"
    ], storage.delete_calls
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

  # Upstream: packages/api-key/src/adapter.ts:8,725-734.
  def test_populate_reference_bounds_parallel_cache_writes_and_sets_reference_last
    storage = ConcurrentTrackingStorage.new
    auth = build_api_key_auth(storage: "secondary-storage", secondary_storage: storage, fallback_to_database: true, default_key_length: 12)
    ctx = Struct.new(:context).new(auth.context)
    now = Time.now
    records = 12.times.map do |index|
      {
        "id" => "key-#{index}",
        "key" => "hashed-#{index}",
        "referenceId" => "user-batch",
        "createdAt" => now,
        "updatedAt" => now,
        "expiresAt" => nil
      }
    end
    config = BetterAuth::APIKey::Configuration.normalize(
      storage: "secondary-storage",
      fallback_to_database: true
    )

    BetterAuth::APIKey::Adapter.populate_reference(ctx, "user-batch", records, config)

    assert_equal 10, storage.max_concurrent_id_sets
    assert_equal "api-key:by-ref:user-batch", storage.write_order.last
    assert_equal records.map { |record| record.fetch("id") }, JSON.parse(storage.get("api-key:by-ref:user-batch"))
  end

  # Upstream: packages/api-key/src/adapter.ts:8,657-692,739-778.
  def test_list_for_reference_bounds_parallel_secondary_reads_and_preserves_id_order
    storage = ConcurrentTrackingStorage.new
    auth = build_api_key_auth(storage: "secondary-storage", secondary_storage: storage, default_key_length: 12)
    ctx = Struct.new(:context).new(auth.context)
    now = Time.now
    ids = 12.times.map { |index| "key-#{index}" }
    ids.each do |id|
      storage.values["api-key:by-id:#{id}"] = JSON.generate(
        "id" => id,
        "key" => "hashed-#{id}",
        "referenceId" => "user-read",
        "configId" => "default",
        "createdAt" => now,
        "updatedAt" => now
      )
    end
    storage.values["api-key:by-ref:user-read"] = JSON.generate(ids)
    config = BetterAuth::APIKey::Configuration.normalize(storage: "secondary-storage")

    records = BetterAuth::APIKey::Adapter.list_for_reference(ctx, "user-read", config)

    assert_equal 10, storage.max_concurrent_id_gets
    assert_equal ids, records.map { |record| record.fetch("id") }
  end

  # A non-empty fallback reference list is authoritative in upstream v1.7.1,
  # even when none of its per-key cache entries exist (adapter.ts:675-693).
  def test_list_for_reference_does_not_fallback_when_nonempty_index_records_are_missing
    storage = APIKeyTestSupport::MemoryStorage.new
    auth = build_api_key_auth(storage: "secondary-storage", secondary_storage: storage, fallback_to_database: true, default_key_length: 12)
    ctx = Struct.new(:context).new(auth.context)
    now = Time.now
    database_record = auth.context.adapter.create(
      model: "apikey",
      force_allow_id: true,
      data: {
        configId: "default",
        referenceId: "user-stale-index",
        key: "database-hash",
        createdAt: now,
        updatedAt: now
      }
    )
    storage.set("api-key:by-ref:user-stale-index", JSON.generate([database_record.fetch("id")]))
    config = BetterAuth::APIKey::Configuration.normalize(storage: "secondary-storage", fallback_to_database: true)

    records = BetterAuth::APIKey::Adapter.list_for_reference(ctx, "user-stale-index", config)

    assert_empty records
    assert_nil storage.get("api-key:by-id:#{database_record.fetch("id")}")
    assert_equal [database_record.fetch("id")], JSON.parse(storage.get("api-key:by-ref:user-stale-index"))
  end

  def test_find_by_id_treats_non_string_secondary_value_as_cache_miss
    storage = APIKeyTestSupport::MemoryStorage.new
    auth = build_api_key_auth(storage: "secondary-storage", secondary_storage: storage, fallback_to_database: true, default_key_length: 12)
    ctx = Struct.new(:context).new(auth.context)
    now = Time.now
    database_record = auth.context.adapter.create(
      model: "apikey",
      force_allow_id: true,
      data: {
        configId: "default",
        referenceId: "user-invalid-cache",
        key: "database-hash",
        createdAt: now,
        updatedAt: now
      }
    )
    storage.values["api-key:by-id:#{database_record.fetch("id")}"] = {"invalid" => true}
    config = BetterAuth::APIKey::Configuration.normalize(storage: "secondary-storage", fallback_to_database: true)

    record = BetterAuth::APIKey::Adapter.find_by_id(ctx, database_record.fetch("id"), config)

    assert_equal database_record.fetch("id"), record.fetch("id")
    assert_instance_of String, storage.get("api-key:by-id:#{database_record.fetch("id")}")
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

  class ConcurrentTrackingStorage < APIKeyTestSupport::MemoryStorage
    attr_reader :max_concurrent_id_gets, :max_concurrent_id_sets, :write_order

    def initialize
      super
      @tracking_lock = Mutex.new
      @active_id_gets = 0
      @active_id_sets = 0
      @max_concurrent_id_gets = 0
      @max_concurrent_id_sets = 0
      @write_order = []
    end

    def get(key)
      return super unless key.start_with?("api-key:by-id:")

      begin_operation(:get)
      sleep 0.01
      super
    ensure
      end_operation(:get)
    end

    def set(key, value, ttl = nil)
      if key.start_with?("api-key:by-id:")
        begin_operation(:set)
        begin
          sleep 0.01
          result = super
        ensure
          end_operation(:set)
        end
      else
        result = super
      end
      @tracking_lock.synchronize { @write_order << key }
      result
    end

    private

    def begin_operation(operation)
      @tracking_lock.synchronize do
        if operation == :get
          @active_id_gets += 1
          @max_concurrent_id_gets = [@max_concurrent_id_gets, @active_id_gets].max
        else
          @active_id_sets += 1
          @max_concurrent_id_sets = [@max_concurrent_id_sets, @active_id_sets].max
        end
      end
    end

    def end_operation(operation)
      @tracking_lock.synchronize do
        if operation == :get
          @active_id_gets -= 1 if @active_id_gets.positive?
        elsif @active_id_sets.positive?
          @active_id_sets -= 1
        end
      end
    end
  end
end
