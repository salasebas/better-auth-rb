# frozen_string_literal: true

require_relative "test_support"

class BetterAuthAPIKeyValidationTest < Minitest::Test
  include APIKeyTestSupport

  def test_validate_create_update_rejects_client_server_only_fields
    config = BetterAuth::APIKey::Configuration.normalize({})

    error = assert_raises(BetterAuth::APIError) do
      BetterAuth::APIKey::Validation.validate_create_update!(
        {permissions: {repo: ["read"]}},
        config,
        create: true,
        client: true
      )
    end

    assert_equal "BAD_REQUEST", error.status
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("SERVER_ONLY_PROPERTY"), error.message
  end

  def test_validate_create_update_allows_server_remaining_zero_on_create
    config = BetterAuth::APIKey::Configuration.normalize({})

    BetterAuth::APIKey::Validation.validate_create_update!({remaining: 0}, config, create: true, client: false)
  end

  def test_validate_create_update_rejects_mismatched_refill_fields
    config = BetterAuth::APIKey::Configuration.normalize({})

    interval_error = assert_raises(BetterAuth::APIError) do
      BetterAuth::APIKey::Validation.validate_create_update!({refill_interval: 1000}, config, create: true, client: false)
    end
    amount_error = assert_raises(BetterAuth::APIError) do
      BetterAuth::APIKey::Validation.validate_create_update!({refill_amount: 10}, config, create: true, client: false)
    end

    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("REFILL_INTERVAL_AND_AMOUNT_REQUIRED"), interval_error.message
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("REFILL_AMOUNT_AND_INTERVAL_REQUIRED"), amount_error.message
  end

  def test_validate_create_update_rejects_non_positive_refill_amount
    config = BetterAuth::APIKey::Configuration.normalize({})

    [true, false].each do |create|
      error = assert_raises(BetterAuth::APIError) do
        BetterAuth::APIKey::Validation.validate_create_update!(
          {refill_amount: 0, refill_interval: 1000},
          config,
          create: create,
          client: false
        )
      end

      assert_equal "BAD_REQUEST", error.status
      assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("INVALID_REMAINING"), error.message
    end
  end

  def test_update_payload_preserves_false_zero_nil_and_encodes_objects
    config = BetterAuth::APIKey::Configuration.normalize(enable_metadata: true)

    update = BetterAuth::APIKey::Validation.update_payload({
      enabled: false,
      remaining: 0,
      expires_in: nil,
      metadata: {tier: "pro"},
      permissions: {repo: ["read"]}
    }, config)

    assert_equal false, update.fetch(:enabled)
    assert_equal 0, update.fetch(:remaining)
    assert_nil update.fetch(:expiresAt)
    assert_equal({"tier" => "pro"}, JSON.parse(update.fetch(:metadata)))
    assert_equal({"repo" => ["read"]}, JSON.parse(update.fetch(:permissions)))
  end

  def test_usage_update_refills_remaining_after_interval_then_decrements
    config = BetterAuth::APIKey::Configuration.normalize(rate_limit: {enabled: false})
    record = {
      "remaining" => 0,
      "refillAmount" => 3,
      "refillInterval" => 1,
      "lastRefillAt" => Time.now - 60,
      "createdAt" => Time.now - 120
    }

    update = BetterAuth::APIKey::Validation.usage_update(record, config)

    assert_equal 2, update.fetch(:remaining)
    assert update.fetch(:lastRefillAt)
    refute update.key?(:requestCount)
  end

  def test_usage_update_rejects_non_positive_refill_amount_without_negative_remaining
    config = BetterAuth::APIKey::Configuration.normalize(rate_limit: {enabled: false})
    record = {"remaining" => 0, "refillAmount" => 0, "refillInterval" => 1, "lastRefillAt" => Time.now - 60}

    error = assert_raises(BetterAuth::APIError) { BetterAuth::APIKey::Validation.usage_update(record, config) }

    assert_equal "TOO_MANY_REQUESTS", error.status
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("USAGE_EXCEEDED"), error.message
    assert_equal 0, record.fetch("remaining")
  end

  def test_exhausted_non_refillable_key_is_deleted_and_rejected
    auth = build_api_key_auth(default_key_length: 12, rate_limit: {enabled: false})
    cookie = sign_up_cookie(auth, email: "validation-exhausted-delete@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id, remaining: 1})

    assert auth.api.verify_api_key(body: {key: created[:key]})[:valid]
    result = auth.api.verify_api_key(body: {key: created[:key]})

    assert_equal false, result[:valid]
    assert_equal "USAGE_EXCEEDED", result[:error][:code]
    stored = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])
    assert_nil stored
  end

  def test_exhausted_non_refillable_key_deletion_is_deferred
    deferred = []
    auth = build_api_key_auth(
      default_key_length: 12,
      defer_updates: true,
      rate_limit: {enabled: false},
      advanced: {background_tasks: {handler: ->(task) { deferred << task }}}
    )
    cookie = sign_up_cookie(auth, email: "validation-exhausted-deferred-delete@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id, remaining: 1})
    auth.api.verify_api_key(body: {key: created[:key]})
    deferred.clear

    result = auth.api.verify_api_key(body: {key: created[:key]})

    assert_equal false, result[:valid]
    assert_equal "USAGE_EXCEEDED", result[:error][:code]
    assert auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])
    deferred.each(&:call)
    assert_nil auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])
  end

  def test_empty_permission_requirement_precedes_exhausted_key_deletion
    auth = build_api_key_auth(default_key_length: 12, rate_limit: {enabled: false})
    cookie = sign_up_cookie(auth, email: "validation-exhausted-permissions@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id, remaining: 0})

    result = auth.api.verify_api_key(body: {key: created[:key], permissions: {}})

    assert_equal false, result[:valid]
    assert_equal "KEY_NOT_FOUND", result[:error][:code]
    assert auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])
  end

  def test_check_permissions_matches_upstream_key_not_found_failure
    record = {"permissions" => JSON.generate({"repo" => ["read"]})}

    BetterAuth::APIKey::Validation.check_permissions!(record, {repo: ["read"]})
    error = assert_raises(BetterAuth::APIError) do
      BetterAuth::APIKey::Validation.check_permissions!(record, {repo: ["write"]})
    end

    assert_equal "UNAUTHORIZED", error.status
    assert_equal "KEY_NOT_FOUND", error.code
    assert_equal BetterAuth::APIKey::ERROR_CODES.fetch("KEY_NOT_FOUND"), error.message
  end

  def test_validate_api_key_does_not_defer_quota_updates
    deferred = []
    auth = build_api_key_auth(
      default_key_length: 12,
      defer_updates: true,
      rate_limit: {enabled: false},
      advanced: {background_tasks: {handler: ->(task) { deferred << task }}}
    )
    cookie = sign_up_cookie(auth, email: "validation-quota-defer-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id, remaining: 1})

    first = auth.api.verify_api_key(body: {key: created[:key]})
    second = auth.api.verify_api_key(body: {key: created[:key]})

    assert_equal true, first[:valid]
    assert_equal false, second[:valid]
    assert_equal "USAGE_EXCEEDED", second[:error][:code]
  end

  def test_pure_secondary_verification_defers_counter_write
    deferred = []
    storage = MemoryStorage.new
    auth = build_api_key_auth(
      storage: "secondary-storage",
      secondary_storage: storage,
      default_key_length: 12,
      defer_updates: true,
      rate_limit: {enabled: false},
      advanced: {background_tasks: {handler: ->(task) { deferred << task }}}
    )
    cookie = sign_up_cookie(auth, email: "validation-secondary-deferred-counter@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id, remaining: 2})
    stored_key = "api-key:by-id:#{created[:id]}"

    result = auth.api.verify_api_key(body: {key: created[:key]})

    assert_equal true, result[:valid]
    assert_equal 1, result[:key][:remaining]
    assert_equal 2, JSON.parse(storage.get(stored_key)).fetch("remaining")
    deferred.each(&:call)
    assert_equal 1, JSON.parse(storage.get(stored_key)).fetch("remaining")
  end

  def test_pure_secondary_missing_synchronous_persistence_maps_to_failed_update
    storage = MemoryStorage.new
    armed = false
    created = nil
    hashed = nil
    auth = build_api_key_auth(
      storage: "secondary-storage",
      secondary_storage: storage,
      default_key_length: 12,
      rate_limit: {enabled: false},
      custom_api_key_validator: ->(*) {
        if armed
          storage.delete("api-key:#{hashed}")
          storage.delete("api-key:by-id:#{created[:id]}")
        end
        true
      }
    )
    cookie = sign_up_cookie(auth, email: "validation-secondary-missing-update@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {})
    hashed = BetterAuth::APIKey::Keys.hash(created[:key], BetterAuth::APIKey::Configuration.normalize(default_key_length: 12))
    armed = true

    result = auth.api.verify_api_key(body: {key: created[:key]})

    assert_equal false, result[:valid]
    assert_equal "FAILED_TO_UPDATE_API_KEY", result[:error][:code]
  end

  def test_metadata_migration_write_failure_does_not_invalidate_claimed_key
    auth = build_api_key_auth(enable_metadata: true, default_key_length: 12, rate_limit: {enabled: false})
    cookie = sign_up_cookie(auth, email: "validation-metadata-migration-failure@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {metadata: {plan: "current"}})
    original_update = auth.context.adapter.method(:update)
    original_update.call(
      model: "apikey",
      where: [{field: "id", value: created[:id]}],
      update: {metadata: JSON.generate(JSON.generate({plan: "legacy"}))}
    )
    warnings = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |message, *| warnings << message }
    logger.define_singleton_method(:error) { |*| }
    auth.context.define_singleton_method(:logger) { logger }
    auth.context.adapter.define_singleton_method(:update) do |**kwargs|
      if kwargs.fetch(:update).key?(:metadata)
        raise StandardError, "simulated migration failure"
      end

      original_update.call(**kwargs)
    end

    result = auth.api.verify_api_key(body: {key: created[:key]})

    assert_equal true, result[:valid]
    assert_equal({"plan" => "legacy"}, result[:key][:metadata])
    assert_equal 1, warnings.length
  end

  def test_expiration_at_exact_current_time_is_not_expired
    now = Time.at(Time.now.to_i)
    auth = build_api_key_auth(default_key_length: 12, rate_limit: {enabled: false})
    cookie = sign_up_cookie(auth, email: "validation-expiration-equality@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {})
    auth.context.adapter.update(
      model: "apikey",
      where: [{field: "id", value: created[:id]}],
      update: {expiresAt: now}
    )

    result = Time.stub(:now, now) do
      auth.api.verify_api_key(body: {key: created[:key]})
    end

    assert_equal true, result[:valid]
  end

  def test_staggered_quota_updates_never_accept_more_than_the_available_uses
    auth = build_api_key_auth(default_key_length: 12, rate_limit: {enabled: false})
    cookie = sign_up_cookie(auth, email: "validation-quota-thread-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id, remaining: 1})
    original_update = auth.context.adapter.method(:update)
    auth.context.adapter.define_singleton_method(:update) do |**kwargs|
      sleep 0.02 if kwargs[:model].to_s == "apikey"
      original_update.call(**kwargs)
    end
    start = Queue.new
    results = 2.times.map do
      Thread.new do
        start.pop
        auth.api.verify_api_key(body: {key: created[:key]})
      end
    end

    2.times { start << true }
    responses = results.map(&:value)

    assert_operator responses.count { |response| response[:valid] == true }, :<=, 1
    assert responses.filter_map { |response| response.dig(:error, :code) }.all? { |code| ["USAGE_EXCEEDED", "INVALID_API_KEY"].include?(code) }
    stored = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])
    assert(stored.nil? || stored.fetch("remaining") >= 0)
  end

  def test_concurrent_database_verification_accepts_exactly_available_remaining_uses
    gate = arrival_gate(8)
    auth = build_api_key_auth(default_key_length: 12, rate_limit: {enabled: false}, custom_api_key_validator: ->(*) { gate.call })
    cookie = sign_up_cookie(auth, email: "validation-concurrent-remaining@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id, remaining: 2})

    results = 8.times.map { Thread.new { auth.api.verify_api_key(body: {key: created[:key]}) } }.map(&:value)

    assert_equal 2, results.count { |result| result[:valid] }
    assert_includes results.filter_map { |result| result.dig(:error, :code) }, "USAGE_EXCEEDED"
    stored = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])
    assert(stored.nil? || stored.fetch("remaining") >= 0)
  end

  def test_concurrent_database_verification_never_exceeds_rate_limit_max
    gate = nil
    auth = build_api_key_auth(default_key_length: 12, custom_api_key_validator: ->(*) {
      gate&.call
      true
    })
    cookie = sign_up_cookie(auth, email: "validation-concurrent-rate-limit@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id, rateLimitEnabled: true, rateLimitMax: 2, rateLimitTimeWindow: 60_000})
    auth.api.verify_api_key(body: {key: created[:key]})

    gate = arrival_gate(8)
    results = 8.times.map { Thread.new { auth.api.verify_api_key(body: {key: created[:key]}) } }.map(&:value)

    assert_equal 1, results.count { |result| result[:valid] }
    assert_equal ["RATE_LIMITED"], results.filter_map { |result| result.dig(:error, :code) }.uniq
    stored = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])
    assert_equal 2, stored.fetch("requestCount")
  end

  def test_verification_counter_write_does_not_re_enable_key_disabled_after_read
    auth = build_api_key_auth(default_key_length: 12, rate_limit: {enabled: false})
    cookie = sign_up_cookie(auth, email: "validation-disable-during-verify@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id})
    original_find = BetterAuth::APIKey::Adapter.method(:find_by_hash)
    triggered = false
    BetterAuth::APIKey::Adapter.define_singleton_method(:find_by_hash) do |ctx, hashed, config|
      record = original_find.call(ctx, hashed, config)
      unless triggered
        triggered = true
        ctx.context.adapter.update(model: "apikey", where: [{field: "id", value: record["id"]}], update: {enabled: false})
      end
      record
    end

    result = auth.api.verify_api_key(body: {key: created[:key], configId: "default"})
    stored = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])

    assert_equal true, result[:valid]
    assert_equal false, stored.fetch("enabled")
  ensure
    BetterAuth::APIKey::Adapter.define_singleton_method(:find_by_hash, original_find) if original_find
  end

  def test_verification_counter_write_does_not_overwrite_permissions_changed_after_read
    auth = build_api_key_auth(default_key_length: 12, rate_limit: {enabled: false})
    cookie = sign_up_cookie(auth, email: "validation-permissions-during-verify@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id, permissions: {files: ["read"]}})
    original_find = BetterAuth::APIKey::Adapter.method(:find_by_hash)
    triggered = false
    BetterAuth::APIKey::Adapter.define_singleton_method(:find_by_hash) do |ctx, hashed, config|
      record = original_find.call(ctx, hashed, config)
      unless triggered
        triggered = true
        ctx.context.adapter.update(
          model: "apikey",
          where: [{field: "id", value: record["id"]}],
          update: {permissions: JSON.generate({"files" => ["write"]})}
        )
      end
      record
    end

    result = auth.api.verify_api_key(body: {key: created[:key], configId: "default"})
    stored = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])

    assert_equal true, result[:valid]
    assert_equal({"files" => ["write"]}, JSON.parse(stored.fetch("permissions")))
  ensure
    BetterAuth::APIKey::Adapter.define_singleton_method(:find_by_hash, original_find) if original_find
  end

  def test_verification_counter_write_does_not_clear_expiry_changed_after_read
    auth = build_api_key_auth(default_key_length: 12, rate_limit: {enabled: false})
    cookie = sign_up_cookie(auth, email: "validation-expiry-during-verify@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id})
    original_find = BetterAuth::APIKey::Adapter.method(:find_by_hash)
    triggered = false
    BetterAuth::APIKey::Adapter.define_singleton_method(:find_by_hash) do |ctx, hashed, config|
      record = original_find.call(ctx, hashed, config)
      unless triggered
        triggered = true
        ctx.context.adapter.update(model: "apikey", where: [{field: "id", value: record["id"]}], update: {expiresAt: Time.now - 1})
      end
      record
    end

    result = auth.api.verify_api_key(body: {key: created[:key], configId: "default"})
    stored = auth.context.adapter.find_one(model: "apikey", where: [{field: "id", value: created[:id]}])

    assert_equal true, result[:valid]
    assert_operator stored.fetch("expiresAt"), :<, Time.now
  ensure
    BetterAuth::APIKey::Adapter.define_singleton_method(:find_by_hash, original_find) if original_find
  end

  def test_fallback_verification_does_not_evict_cached_ghost_after_authoritative_delete
    storage = MemoryStorage.new
    auth = build_api_key_auth(
      storage: "secondary-storage",
      secondary_storage: storage,
      fallback_to_database: true,
      default_key_length: 12,
      rate_limit: {enabled: false}
    )
    cookie = sign_up_cookie(auth, email: "validation-delete-during-cache-publish@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id})
    original_set = BetterAuth::APIKey::Adapter.method(:set)
    armed = true
    BetterAuth::APIKey::Adapter.define_singleton_method(:set) do |ctx, record, config|
      if armed && record["id"] == created[:id]
        armed = false
        ctx.context.adapter.delete(model: "apikey", where: [{field: "id", value: record["id"]}])
      end
      original_set.call(ctx, record, config)
    end

    result = auth.api.verify_api_key(body: {key: created[:key]})

    assert_equal true, result[:valid]
    assert storage.get("api-key:#{BetterAuth::APIKey::Keys.hash(created[:key], BetterAuth::APIKey::Configuration.normalize(default_key_length: 12))}")
    assert storage.get("api-key:by-id:#{created[:id]}")
  ensure
    BetterAuth::APIKey::Adapter.define_singleton_method(:set, original_set) if original_set
  end

  def test_validate_api_key_uses_bounded_lock_stripes_for_invalid_keys
    auth = build_api_key_auth(default_key_length: 12, rate_limit: {enabled: false})

    20.times do |index|
      auth.api.verify_api_key(body: {key: "missing-key-#{index}"})
    end

    refute BetterAuth::APIKey::Validation.instance_variable_defined?(:@usage_locks)
  end

  def test_validate_api_key_rejects_when_usage_update_cannot_persist
    auth = build_api_key_auth(default_key_length: 12, rate_limit: {enabled: false})
    cookie = sign_up_cookie(auth, email: "validation-update-nil-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    created = auth.api.create_api_key(body: {userId: user_id, remaining: 2})
    original_update = auth.context.adapter.method(:update)
    auth.context.adapter.define_singleton_method(:update) do |**kwargs|
      next nil if kwargs[:model].to_s == "apikey"

      original_update.call(**kwargs)
    end

    result = auth.api.verify_api_key(body: {key: created[:key]})

    assert_equal false, result[:valid]
    assert_equal "INVALID_API_KEY", result[:error][:code]
  end

  def test_validate_api_key_maps_final_persistence_exception_to_invalid_key
    auth = build_api_key_auth(default_key_length: 12, rate_limit: {enabled: false})
    cookie = sign_up_cookie(auth, email: "validation-update-failure-key@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {})
    original_update = auth.context.adapter.method(:update)
    auth.context.adapter.define_singleton_method(:update) do |**kwargs|
      if kwargs.fetch(:update).key?(:updatedAt)
        raise StandardError, "simulated final update failure"
      end

      original_update.call(**kwargs)
    end

    result = auth.api.verify_api_key(body: {key: created[:key]})

    assert_equal false, result[:valid]
    assert_equal "INVALID_API_KEY", result[:error][:code]
  end

  private

  def arrival_gate(size)
    mutex = Mutex.new
    condition = ConditionVariable.new
    arrived = 0
    released = false
    lambda do
      mutex.synchronize do
        arrived += 1
        if arrived >= size
          released = true
          condition.broadcast
        else
          condition.wait(mutex) until released
        end
      end
      true
    end
  end
end
