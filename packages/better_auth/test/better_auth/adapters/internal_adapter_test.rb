# frozen_string_literal: true

require "json"
require_relative "../../test_helper"

class BetterAuthInternalAdapterTest < Minitest::Test
  SECRET = "test-secret-that-is-long-enough-for-validation"

  MemoryStorage = Struct.new(:store, :ttls) do
    class << self
      def lock_for(store)
        @lock_registry_guard ||= Mutex.new
        @lock_registry_guard.synchronize { (@locks_by_store ||= {})[store.object_id] ||= Mutex.new }
      end
    end

    def initialize(store = {}, ttls = {})
      super
    end

    def set(key, value, ttl = nil)
      store[key] = value
      ttls[key] = ttl if ttl
    end

    def get(key)
      store[key]
    end

    def delete(key)
      store.delete(key)
      ttls.delete(key)
    end

    def get_and_delete(key)
      value = store.delete(key)
      ttls.delete(key)
      value
    end

    def set_if_absent(key, value, ttl = nil)
      lock.synchronize do
        next false if store.key?(key)

        set(key, value, ttl)
        true
      end
    end

    private

    def lock
      self.class.lock_for(store)
    end
  end

  LegacyMemoryStorage = Struct.new(:store, :ttls) do
    def initialize
      super({}, {})
    end

    def set(key, value, ttl = nil)
      store[key] = value
      ttls[key] = ttl if ttl
    end

    def get(key)
      store[key]
    end

    def delete(key)
      store.delete(key)
      ttls.delete(key)
    end
  end

  def test_auth_initializes_default_memory_and_internal_adapters
    auth = BetterAuth.auth(secret: SECRET)

    assert_instance_of BetterAuth::Adapters::Memory, auth.context.adapter
    assert_instance_of BetterAuth::Adapters::InternalAdapter, auth.context.internal_adapter
  end

  def test_create_oauth_user_and_find_oauth_user
    internal = internal_adapter

    result = internal.create_oauth_user(
      {email: "PERSON@example.com", name: "Person", emailVerified: true},
      {providerId: "github", accountId: "github-1", accessToken: "secret"}
    )

    assert_equal "person@example.com", result[:user]["email"]
    assert_equal result[:user]["id"], result[:account]["userId"]

    found = internal.find_oauth_user("PERSON@example.com", "github-1", "github")

    assert_equal result[:user], found[:user]
    assert_equal result[:account], found[:linked_account]
    assert_equal [result[:account]], found[:accounts]
  end

  def test_create_oauth_user_uses_custom_generate_id_and_plugin_hooks
    calls = []
    ids = Enumerator.new do |yielder|
      yielder << "user-1"
      yielder << "account-1"
    end
    internal = internal_adapter(
      advanced: {database: {generate_id: -> { ids.next }}},
      database_hooks: {
        user: {
          create: {
            before: ->(user, _context) {
              calls << [:app_before, user["email"]]
              {data: user}
            },
            after: ->(user, _context) { calls << [:app_after, user["id"]] }
          }
        }
      },
      plugins: [
        {
          id: "test-plugin",
          options: {
            database_hooks: {
              user: {
                create: {
                  before: ->(user, _context) {
                    calls << [:plugin_before, user["email"]]
                    {data: user.merge("image" => "from-plugin")}
                  },
                  after: ->(user, _context) { calls << [:plugin_after, user["image"]] }
                }
              }
            }
          }
        }
      ]
    )

    result = internal.create_oauth_user(
      {email: "hooked@example.com", name: "Hooked", emailVerified: false},
      {providerId: "github", accountId: "github-hooked"}
    )

    assert_equal "user-1", result[:user]["id"]
    assert_equal "account-1", result[:account]["id"]
    assert_equal "user-1", result[:account]["userId"]
    assert_equal "from-plugin", result[:user]["image"]
    assert_equal [
      [:app_before, "hooked@example.com"],
      [:plugin_before, "hooked@example.com"],
      [:app_after, "user-1"],
      [:plugin_after, "from-plugin"]
    ], calls
  end

  def test_user_create_hook_preserves_forced_uuid_when_generate_id_is_uuid
    existing_id = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
    internal = internal_adapter(
      advanced: {database: {generate_id: "uuid"}},
      database_hooks: {
        user: {
          create: {
            before: ->(user, _context) { {data: user.merge("id" => existing_id)} }
          }
        }
      }
    )

    created = internal.create_user(name: "Forced", email: "forced@example.com")
    found = internal.adapter.find_one(model: "user", where: [{field: "id", value: existing_id}])

    assert_equal existing_id, created["id"]
    assert_equal existing_id, found["id"]
    assert_equal "forced@example.com", found["email"]
  end

  def test_find_session_honors_custom_session_user_id_field_name
    internal = internal_adapter(session: {fields: {userId: "user_id"}})
    user = internal.create_user(name: "Ada", email: "custom-user-id@example.com")
    session = internal.create_session(user["id"])

    found = internal.find_session(session["token"])

    assert_equal session["token"], found[:session]["token"]
    assert_equal user["id"], found[:user]["id"]
  end

  def test_where_values_are_coerced_to_field_types
    internal = internal_adapter(
      user: {
        additional_fields: {
          age: {type: "number", required: false},
          scores: {type: "number[]", required: false}
        }
      }
    )
    internal.create_user(name: "False", email: "false@example.com", emailVerified: false, age: 25, scores: [25, 30])
    internal.create_user(name: "True", email: "true@example.com", emailVerified: true, age: 30, scores: [30, 40])

    by_boolean = internal.adapter.find_many(model: "user", where: [{field: "emailVerified", value: "false"}])
    by_number = internal.adapter.find_many(model: "user", where: [{field: "age", value: "25"}])
    by_number_in = internal.adapter.find_many(model: "user", where: [{field: "age", operator: "in", value: ["25", "30"]}])

    assert_equal ["false@example.com"], by_boolean.map { |user| user["email"] }
    assert_equal ["false@example.com"], by_number.map { |user| user["email"] }
    assert_equal ["false@example.com", "true@example.com"], by_number_in.map { |user| user["email"] }.sort
  end

  def test_create_find_update_and_delete_session_with_secondary_storage
    storage = MemoryStorage.new
    internal = internal_adapter(secondary_storage: storage)
    user = internal.create_user(name: "Ada", email: "ada@example.com")

    session = internal.create_session(user["id"], false, {token: "token-1"}, true)
    active_key = "active-sessions-#{user["id"]}"

    assert_equal "token-1", session["token"]
    stored = JSON.parse(storage.get(active_key))
    assert_equal "token-1", stored.fetch(0).fetch("token")
    assert_in_delta session["expiresAt"].to_f * 1000, stored.fetch(0).fetch("expiresAt"), 10

    found = internal.find_session("token-1")
    assert_equal user["id"], found[:user]["id"]
    assert_equal "token-1", found[:session]["token"]

    internal.update_session("token-1", {userAgent: "new-agent"})
    assert_equal "new-agent", internal.find_session("token-1")[:session]["userAgent"]

    internal.delete_session("token-1")
    assert_nil storage.get(active_key)
    assert_nil internal.find_session("token-1")
  end

  def test_delete_user_removes_secondary_only_sessions_and_active_index
    storage = MemoryStorage.new
    internal = internal_adapter(secondary_storage: storage)
    user = internal.create_user(name: "Ada", email: "secondary-delete@example.com")
    session = internal.create_session(user["id"], false, {token: "secondary-delete-token"}, true)
    active_key = "active-sessions-#{user["id"]}"

    assert storage.get(session["token"])
    assert storage.get(active_key)

    internal.delete_user(user["id"])

    assert_nil storage.get(session["token"])
    assert_nil storage.get(active_key)
    assert_nil internal.find_session(session["token"])
  end

  def test_revoke_unproven_account_access_removes_credentials_and_database_sessions_only
    internal = internal_adapter
    user = internal.create_user(name: "Ada", email: "unproven@example.com", emailVerified: false)
    2.times do |index|
      internal.create_account(userId: user["id"], providerId: "credential", accountId: "credential-#{index}", password: "secret")
    end
    social = internal.create_account(userId: user["id"], providerId: "github", accountId: "github-1")
    2.times { internal.create_session(user["id"]) }

    internal.revoke_unproven_account_access(user["id"])

    assert_equal [social["id"]], internal.find_accounts(user["id"]).map { |account| account["id"] }
    assert_empty internal.list_sessions(user["id"])
    refute internal.find_user_by_id(user["id"])["emailVerified"]
  end

  def test_revoke_unproven_account_access_leaves_verified_user_unchanged
    internal = internal_adapter
    user = internal.create_user(name: "Ada", email: "verified@example.com", emailVerified: true)
    credential = internal.create_account(userId: user["id"], providerId: "credential", accountId: user["id"], password: "secret")
    session = internal.create_session(user["id"])

    internal.revoke_unproven_account_access(user["id"])

    assert_equal credential["id"], internal.find_accounts(user["id"]).first["id"]
    assert_equal session["token"], internal.list_sessions(user["id"]).first["token"]
  end

  def test_revoke_unproven_account_access_removes_secondary_and_dual_written_sessions
    storage = MemoryStorage.new
    internal = internal_adapter(secondary_storage: storage, session: {store_session_in_database: true})
    user = internal.create_user(name: "Ada", email: "secondary-unproven@example.com", emailVerified: false)
    session = internal.create_session(user["id"], false, {token: "unproven-secondary-token"}, true)
    active_key = "active-sessions-#{user["id"]}"

    internal.revoke_unproven_account_access(user["id"])

    assert_nil storage.get(session["token"])
    assert_nil storage.get(active_key)
    assert_empty internal.adapter.find_many(model: "session", where: [{field: "userId", value: user["id"]}])
  end

  def test_revoke_unproven_account_access_raises_on_delete_veto_and_rolls_back
    internal = internal_adapter(
      database_hooks: {
        account: {delete: {before: ->(_account, _context) { false }}}
      }
    )
    user = internal.create_user(name: "Ada", email: "vetoed@example.com", emailVerified: false)
    credential = internal.create_account(userId: user["id"], providerId: "credential", accountId: user["id"], password: "secret")
    session = internal.create_session(user["id"])

    assert_raises(BetterAuth::Error) { internal.revoke_unproven_account_access(user["id"]) }

    assert internal.find_account_by_provider_id(credential["accountId"], "credential")
    assert internal.find_session(session["token"])
    refute internal.find_user_by_id(user["id"])["emailVerified"]
  end

  def test_revoke_unproven_account_access_raises_on_session_delete_veto_and_rolls_back
    internal = internal_adapter(
      database_hooks: {
        session: {delete: {before: ->(_session, _context) { false }}}
      }
    )
    user = internal.create_user(name: "Ada", email: "session-vetoed@example.com", emailVerified: false)
    credential = internal.create_account(userId: user["id"], providerId: "credential", accountId: user["id"], password: "secret")
    session = internal.create_session(user["id"])

    assert_raises(BetterAuth::Error) { internal.revoke_unproven_account_access(user["id"]) }

    assert internal.find_account_by_provider_id(credential["accountId"], "credential")
    assert internal.find_session(session["token"])
    refute internal.find_user_by_id(user["id"])["emailVerified"]
  end

  def test_revoke_unproven_account_access_propagates_secondary_storage_failure_and_rolls_back_database
    storage = MemoryStorage.new
    internal = internal_adapter(secondary_storage: storage, session: {store_session_in_database: true})
    user = internal.create_user(name: "Ada", email: "storage-failure@example.com", emailVerified: false)
    credential = internal.create_account(userId: user["id"], providerId: "credential", accountId: user["id"], password: "secret")
    session = internal.create_session(user["id"], false, {token: "storage-failure-token"}, true)
    storage.define_singleton_method(:delete) do |key|
      raise "storage unavailable" if key == session["token"]

      super(key)
    end

    error = assert_raises(RuntimeError) { internal.revoke_unproven_account_access(user["id"]) }

    assert_equal "storage unavailable", error.message
    assert internal.find_account_by_provider_id(credential["accountId"], "credential")
    refute internal.find_user_by_id(user["id"])["emailVerified"]
  end

  def test_store_session_in_database_keeps_hooked_db_copy_and_falls_back_when_secondary_storage_misses
    storage = MemoryStorage.new
    internal = internal_adapter(
      secondary_storage: storage,
      session: {store_session_in_database: true},
      database_hooks: {
        session: {
          create: {
            before: ->(_data, _context) { {data: {userAgent: "from-hook"}} }
          }
        }
      }
    )
    user = internal.create_user(name: "Ada", email: "ada@example.com")

    session = internal.create_session(user["id"], false, {token: "token-db"}, true)
    stored_db_session = internal.adapter.find_one(model: "session", where: [{field: "token", value: "token-db"}])

    assert_equal "from-hook", session["userAgent"]
    assert_equal "from-hook", stored_db_session["userAgent"]

    storage.delete("token-db")
    found = internal.find_session("token-db")

    assert_equal "token-db", found[:session]["token"]
    assert_equal user["id"], found[:user]["id"]
  end

  def test_update_session_with_secondary_storage_updates_database_copy_when_enabled
    storage = MemoryStorage.new
    internal = internal_adapter(secondary_storage: storage, session: {store_session_in_database: true})
    user = internal.create_user(name: "Ada", email: "ada@example.com")
    internal.create_session(user["id"], false, {token: "token-update"}, true)

    internal.update_session("token-update", {userAgent: "updated-agent"})
    stored_db_session = internal.adapter.find_one(model: "session", where: [{field: "token", value: "token-update"}])

    assert_equal "updated-agent", internal.find_session("token-update")[:session]["userAgent"]
    assert_equal "updated-agent", stored_db_session["userAgent"]
  end

  def test_list_sessions_deduplicates_secondary_storage_active_session_tokens
    storage = MemoryStorage.new
    internal = internal_adapter(secondary_storage: storage)
    user = internal.create_user(name: "Ada", email: "ada@example.com")
    session = internal.create_session(user["id"], false, {token: "token-dup"}, true)
    expires_ms = (session["expiresAt"].to_f * 1000).to_i

    storage.set("active-sessions-#{user["id"]}", JSON.generate([
      {"token" => "token-dup", "expiresAt" => expires_ms},
      {"token" => "token-dup", "expiresAt" => expires_ms}
    ]), 60)

    assert_equal ["token-dup"], internal.list_sessions(user["id"]).map { |entry| entry["token"] }
  end

  def test_list_sessions_skips_missing_and_corrupt_secondary_storage_entries
    storage = MemoryStorage.new
    internal = internal_adapter(secondary_storage: storage)
    user = internal.create_user(name: "Ada", email: "ada@example.com")
    session = internal.create_session(user["id"], false, {token: "token-valid"}, true)
    expires_ms = (session["expiresAt"].to_f * 1000).to_i
    storage.set("token-corrupt", "{bad-json", 60)
    storage.set("token-malformed", JSON.generate({session: nil, user: nil}), 60)
    storage.set("active-sessions-#{user["id"]}", JSON.generate([
      {"token" => "token-valid", "expiresAt" => expires_ms},
      {"token" => "token-missing", "expiresAt" => expires_ms},
      {"token" => "token-corrupt", "expiresAt" => expires_ms},
      {"token" => "token-malformed", "expiresAt" => expires_ms}
    ]), 60)

    assert_equal ["token-valid"], internal.list_sessions(user["id"]).map { |entry| entry["token"] }
    assert_equal ["token-valid"], internal.find_sessions(["token-valid", "token-corrupt"]).map { |entry| entry[:session]["token"] }
  end

  def test_find_session_uses_adapter_join_when_experimental_joins_enabled
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory, experimental: {joins: true})
    adapter = BetterAuth::Adapters::Memory.new(config)
    internal = BetterAuth::Adapters::InternalAdapter.new(adapter, config)
    user = internal.create_user("name" => "Ada", "email" => "ada@example.com")
    session = internal.create_session(user["id"])

    found = internal.find_session(session["token"])

    assert_equal session["token"], found[:session]["token"]
    assert_equal user["id"], found[:user]["id"]
  end

  def test_find_session_falls_back_to_separate_queries_when_experimental_joins_disabled
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory, experimental: {joins: false})
    adapter = BetterAuth::Adapters::Memory.new(config)
    internal = BetterAuth::Adapters::InternalAdapter.new(adapter, config)
    user = internal.create_user("name" => "Ada", "email" => "ada@example.com")
    session = internal.create_session(user["id"])

    found = internal.find_session(session["token"])

    assert_equal session["token"], found[:session]["token"]
    assert_equal user["id"], found[:user]["id"]
  end

  def test_verification_lifecycle_runs_hooks_and_cleans_expired_values
    calls = []
    internal = internal_adapter(
      database_hooks: {
        verification: {
          create: {
            before: ->(data, _context) {
              calls << [:before_create, data["identifier"]]
              {data: data.merge("value" => "mutated")}
            },
            after: ->(data, _context) { calls << [:after_create, data["value"]] }
          },
          delete: {
            before: ->(data, _context) { calls << [:before_delete, data["identifier"]] },
            after: ->(data, _context) { calls << [:after_delete, data["identifier"]] }
          }
        }
      }
    )

    expired = internal.create_verification_value(identifier: "verify-1", value: "initial", expiresAt: Time.now - 60)

    assert_equal "mutated", expired["value"]
    assert_equal "verify-1", internal.find_verification_value("verify-1")["identifier"]
    assert_nil internal.find_verification_value("verify-1")
    assert_includes calls, [:before_create, "verify-1"]
    assert_includes calls, [:after_create, "mutated"]
    assert_includes calls, [:before_delete, "verify-1"]
    assert_includes calls, [:after_delete, "verify-1"]
  end

  def test_verification_values_use_secondary_storage_by_default
    storage = MemoryStorage.new
    internal = internal_adapter(secondary_storage: storage)
    expires_at = Time.now + 120

    verification = internal.create_verification_value(identifier: "verify-secondary", value: "initial", expiresAt: expires_at)

    assert verification["id"]
    assert_empty internal.adapter.find_many(model: "verification")
    stored = JSON.parse(storage.get("verification:verify-secondary"))
    assert_equal verification["id"], stored.fetch("id")
    assert_equal "initial", stored.fetch("value")
    assert_in_delta 120, storage.ttls.fetch("verification:verify-secondary"), 2

    assert_equal "initial", internal.find_verification_value("verify-secondary")["value"]

    internal.update_verification_value(verification["id"], value: "updated")
    assert_equal "updated", internal.find_verification_value("verify-secondary")["value"]

    internal.delete_verification_value(verification["id"])
    assert_nil storage.get("verification:verify-secondary")
  end

  def test_delete_verification_by_identifier_skips_adapter_delete_when_record_is_missing
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory, verification: {store_in_database: true})
    adapter = RecordingMemoryAdapter.new(config)
    internal = BetterAuth::Adapters::InternalAdapter.new(adapter, config)
    verification = internal.create_verification_value(identifier: "missing-entity-test", value: "secret", expiresAt: Time.now + 120)
    adapter.delete_many(model: "verification", where: [{field: "identifier", value: verification["identifier"]}])
    adapter.deleted_models.clear

    internal.delete_verification_by_identifier("missing-entity-test")

    refute_includes adapter.deleted_models, "verification"
  end

  def test_verification_store_in_database_falls_back_when_secondary_storage_misses
    storage = MemoryStorage.new
    internal = internal_adapter(secondary_storage: storage, verification: {store_in_database: true})

    verification = internal.create_verification_value(identifier: "verify-dual", value: "initial", expiresAt: Time.now + 120)

    assert storage.get("verification:verify-dual")
    assert_equal verification["id"], internal.adapter.find_many(model: "verification").first["id"]

    storage.delete("verification:verify-dual")
    found = internal.find_verification_value("verify-dual")

    assert_equal verification["id"], found["id"]
    assert_equal "initial", found["value"]
  end

  def test_verification_secondary_storage_hashes_identifiers_when_configured
    storage = MemoryStorage.new
    internal = internal_adapter(secondary_storage: storage, verification: {store_identifier: "hashed"})
    hashed = BetterAuth::Crypto.sha256("verify-hashed", encoding: :base64url)

    verification = internal.create_verification_value(identifier: "verify-hashed", value: "secret", expiresAt: Time.now + 120)

    assert_nil storage.get("verification:verify-hashed")
    assert storage.get("verification:#{hashed}")
    assert_equal hashed, verification["identifier"]
    assert_equal "secret", internal.find_verification_value("verify-hashed")["value"]
  end

  def test_hashed_verification_lookup_falls_back_to_plain_tokens
    plain_internal = internal_adapter(verification: {store_identifier: "plain"})
    plain_internal.create_verification_value(identifier: "old-token", value: "old-value", expiresAt: Time.now + 120)

    hashed_config = BetterAuth::Configuration.new(secret: SECRET, database: :memory, verification: {store_identifier: "hashed"})
    hashed_adapter = BetterAuth::Adapters::Memory.new(hashed_config, plain_internal.adapter.db)
    hashed_internal = BetterAuth::Adapters::InternalAdapter.new(hashed_adapter, hashed_config)

    found = hashed_internal.find_verification_value("old-token")

    assert_equal "old-value", found["value"]
    assert_equal "old-token", found["identifier"]
  end

  def test_verification_secondary_storage_supports_identifier_overrides
    storage = MemoryStorage.new
    internal = internal_adapter(
      secondary_storage: storage,
      verification: {
        store_identifier: {
          default: "plain",
          overrides: {
            "custom:" => {hash: ->(identifier) { "stored-#{identifier.delete_prefix("custom:")}" }}
          }
        }
      }
    )

    internal.create_verification_value(identifier: "custom:token", value: "secret", expiresAt: Time.now + 120)
    internal.create_verification_value(identifier: "plain:token", value: "visible", expiresAt: Time.now + 120)

    assert storage.get("verification:stored-token")
    assert storage.get("verification:plain:token")
    assert_equal "secret", internal.find_verification_value("custom:token")["value"]
    assert_equal "visible", internal.find_verification_value("plain:token")["value"]
  end

  def test_consume_verification_value_has_one_winner_and_rejects_expired_rows
    internal = internal_adapter
    internal.create_verification_value(identifier: "consume-race", value: "winner", expiresAt: Time.now + 120)
    ready = Queue.new
    start = Queue.new
    threads = 8.times.map do
      Thread.new do
        ready << true
        start.pop
        internal.consume_verification_value("consume-race")
      end
    end
    8.times { ready.pop }
    8.times { start << true }

    assert_equal ["winner"], threads.map(&:value).compact.map { |row| row.fetch("value") }
    assert_nil internal.find_verification_value("consume-race")

    internal.create_verification_value(identifier: "consume-expired", value: "expired", expiresAt: Time.now - 1)
    assert_nil internal.consume_verification_value("consume-expired")
    assert_nil internal.find_verification_value("consume-expired")
  end

  def test_consume_verification_value_supports_hashed_secondary_and_database_modes
    storage = MemoryStorage.new
    secondary = internal_adapter(secondary_storage: storage, verification: {store_identifier: "hashed"})
    secondary.create_verification_value(identifier: "consume-hashed", value: "secondary", expiresAt: Time.now + 120)

    assert_equal "secondary", secondary.consume_verification_value("consume-hashed").fetch("value")
    assert_nil secondary.consume_verification_value("consume-hashed")
    assert_empty storage.store

    dual_storage = MemoryStorage.new
    dual = internal_adapter(secondary_storage: dual_storage, verification: {store_in_database: true})
    verification = dual.create_verification_value(identifier: "consume-dual", value: "database", expiresAt: Time.now + 120)

    assert_equal "database", dual.consume_verification_value("consume-dual").fetch("value")
    assert_nil dual.adapter.find_one(model: "verification", where: [{field: "id", value: verification.fetch("id")}])
    assert_nil dual_storage.get("verification:consume-dual")
    assert_nil dual_storage.get("verification-id:#{verification.fetch("id")}")
  end

  def test_reserve_verification_value_has_one_winner_and_hashes_identifiers
    internal = internal_adapter(verification: {store_identifier: "hashed"})
    data = {identifier: "reserve-race", value: "marker", expiresAt: Time.now + 120}
    ready = Queue.new
    start = Queue.new
    threads = 8.times.map do
      Thread.new do
        ready << true
        start.pop
        internal.reserve_verification_value(data)
      end
    end
    8.times { ready.pop }
    8.times { start << true }
    results = threads.map(&:value)

    assert_equal 1, results.count(true)
    assert_equal 7, results.count(false)
    stored = internal.find_verification_value("reserve-race")
    assert_equal BetterAuth::Crypto.sha256("reserve-race", encoding: :base64url), stored.fetch("identifier")
    assert_equal "marker", stored.fetch("value")
  end

  def test_reserve_verification_value_coordinates_independent_internal_adapters_sharing_a_memory_database
    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory)
    first_database_adapter = BetterAuth::Adapters::Memory.new(config)
    second_database_adapter = BetterAuth::Adapters::Memory.new(config, first_database_adapter.db)
    internals = [
      BetterAuth::Adapters::InternalAdapter.new(first_database_adapter, config),
      BetterAuth::Adapters::InternalAdapter.new(second_database_adapter, config)
    ]
    data = {identifier: "shared-db-reservation", value: "marker", expiresAt: Time.now + 120}
    ready = Queue.new
    start = Queue.new
    threads = internals.map do |internal|
      Thread.new do
        ready << true
        start.pop
        internal.reserve_verification_value(data)
      end
    end
    2.times { ready.pop }
    2.times { start << true }

    assert_equal [false, true], threads.map(&:value).sort_by(&:to_s)
    assert_equal 1, first_database_adapter.find_many(model: "verification").length
  end

  def test_expired_reservation_can_be_won_again
    internal = internal_adapter
    expired = {identifier: "expired-reservation", value: "old", expiresAt: Time.now - 1}
    fresh = {identifier: "expired-reservation", value: "new", expiresAt: Time.now + 120}

    assert internal.reserve_verification_value(expired)
    assert internal.reserve_verification_value(fresh)
    assert_equal "new", internal.find_verification_value("expired-reservation").fetch("value")
  end

  def test_database_backed_reservation_omits_non_atomic_reverse_index
    storage = MemoryStorage.new
    internal = internal_adapter(secondary_storage: storage, verification: {store_in_database: true})
    identifier = "reservation-with-cache"
    reservation_id = BetterAuth::Crypto.sha256("reserve:#{identifier}", encoding: :base64url)

    assert internal.reserve_verification_value(identifier: identifier, value: "marker", expiresAt: Time.now + 120)
    assert storage.get("verification:#{identifier}")
    assert_nil storage.get("verification-id:#{reservation_id}")

    assert_equal "marker", internal.consume_verification_value(identifier).fetch("value")
    assert_nil storage.get("verification:#{identifier}")
    assert_nil storage.get("verification-id:#{reservation_id}")
  end

  def test_reserve_verification_value_uses_atomic_conditional_set_across_storage_wrappers
    shared_store = {}
    shared_ttls = {}
    storages = [MemoryStorage.new(shared_store, shared_ttls), MemoryStorage.new(shared_store, shared_ttls)]
    internals = storages.map { |storage| internal_adapter(secondary_storage: storage) }
    data = {identifier: "shared-storage-reservation", value: "marker", expiresAt: Time.now + 120}
    ready = Queue.new
    start = Queue.new
    threads = internals.map do |internal|
      Thread.new do
        ready << true
        start.pop
        internal.reserve_verification_value(data)
      end
    end
    2.times { ready.pop }
    2.times { start << true }

    assert_equal [false, true], threads.map(&:value).sort_by(&:to_s)
    assert shared_store.key?("verification:shared-storage-reservation")
  end

  def test_legacy_secondary_verification_helpers_fail_closed
    storage = LegacyMemoryStorage.new
    internal = internal_adapter(secondary_storage: storage)

    internal.create_verification_value(identifier: "legacy-consume", value: "value", expiresAt: Time.now + 120)
    consume_error = assert_raises(BetterAuth::Error) do
      internal.consume_verification_value("legacy-consume")
    end
    reserve_error = assert_raises(BetterAuth::Error) do
      internal.reserve_verification_value(identifier: "legacy-reserve", value: "value", expiresAt: Time.now + 120)
    end

    assert_includes consume_error.message, "get_and_delete"
    assert_includes reserve_error.message, "set_if_absent"
  end

  def test_user_and_account_helpers
    internal = internal_adapter
    user = internal.create_user(name: "Ada", email: "ADA@example.com")
    credential = internal.create_account(userId: user["id"], providerId: "credential", accountId: user["id"], password: "old")
    social = internal.link_account(userId: user["id"], providerId: "github", accountId: "github-1")

    assert_equal user, internal.find_user_by_email("ada@example.com")[:user]
    assert_equal user, internal.find_user_by_id(user["id"])
    assert_equal 2, internal.find_accounts(user["id"]).length

    internal.update_password(user["id"], "new")
    assert_equal "new", internal.find_account_by_provider_id(credential["accountId"], "credential")["password"]

    internal.delete_account(social["id"])
    assert_nil internal.find_account_by_provider_id("github-1", "github")

    internal.delete_accounts(user["id"])
    assert_empty internal.find_accounts(user["id"])
  end

  private

  def internal_adapter(options = {})
    config = BetterAuth::Configuration.new({secret: SECRET, database: :memory}.merge(options))
    adapter = BetterAuth::Adapters::Memory.new(config)
    BetterAuth::Adapters::InternalAdapter.new(adapter, config)
  end

  class RecordingMemoryAdapter < BetterAuth::Adapters::Memory
    attr_reader :deleted_models

    def initialize(*)
      super
      @deleted_models = []
    end

    def delete(model:, where:)
      deleted_models << model.to_s
      super
    end
  end
end
