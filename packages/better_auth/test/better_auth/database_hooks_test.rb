# frozen_string_literal: true

require_relative "../test_helper"

class BetterAuthDatabaseHooksTest < Minitest::Test
  include BetterAuthTestHelpers

  def test_update_hooks_read_the_original_data_and_run_after_a_miss
    inputs = []
    results = []
    auth = build_auth(
      plugins: [{id: "rename", init: ->(_context) {
        {options: {database_hooks: {user: {update: {before: ->(data, _context) {
          inputs << data.fetch("name")
          {data: {name: "Plugin"}}
        }}}}}}
      }}],
      database_hooks: {user: {update: {
        before: ->(data, _context) {
          inputs << data.fetch("name")
          {data: {image: data.fetch("name")}}
        },
        after: ->(data, _context) { results << data }
      }}}
    )
    internal = auth.context.internal_adapter
    user = internal.create_user(email: "update-hooks@example.com", name: "Original")
    where = [{field: "id", value: user.fetch("id")}]

    updated = internal.update_user(user.fetch("id"), name: "Single")
    assert_equal({"name" => "Plugin", "image" => "Single"}, updated.slice("name", "image"))
    assert_equal 1, internal.hooks.update_many({name: "Bulk"}, where, "user")
    assert_equal({"name" => "Plugin", "image" => "Bulk"}, internal.find_user_by_id(user.fetch("id")).slice("name", "image"))
    assert_nil internal.update_user("missing", name: "Missing")

    assert_equal %w[Single Single Bulk Bulk Missing Missing], inputs
    assert_equal [updated, 1, nil], results
  end

  def test_nested_transaction_runs_after_hooks_when_outer_transaction_finishes
    observed_accounts = []
    internal = nil
    auth = build_auth(database_hooks: {
      user: {create: {after: ->(user, _ctx) {
        next unless user.fetch("email") == "nested@example.com"

        observed_accounts << internal.find_accounts(user.fetch("id")).map { |account| account.fetch("accountId") }
      }}},
      account: {create: {before: ->(account, _ctx) {
        if account.fetch("providerId") == "credential"
          internal.create_oauth_user({email: "nested@example.com", name: "Nested"}, {providerId: "github", accountId: "first"})
          assert_empty observed_accounts
        end
        true
      }}}
    })

    internal = auth.context.internal_adapter
    auth.api.sign_up_email(body: {email: "outer@example.com", name: "Outer", password: "password123"})

    assert_equal [["first"]], observed_accounts
  end

  def test_after_hook_observes_rolled_back_state_after_failed_oauth_write
    observed_users = []
    auth = build_auth(database_hooks: {
      user: {create: {after: ->(user, _context) {
        observed_users << auth.context.internal_adapter.find_user_by_id(user.fetch("id"))
      }}},
      account: {create: {before: ->(_account, _context) { raise "account write failed" }}}
    })

    error = assert_raises(RuntimeError) do
      auth.context.internal_adapter.create_oauth_user({email: "rollback@example.com", name: "Rollback"}, {providerId: "github", accountId: "rollback"})
    end

    assert_equal "account write failed", error.message
    assert_equal [nil], observed_users
  end

  def test_after_hook_error_leaves_oauth_user_and_account_committed
    auth = build_auth(database_hooks: {user: {create: {after: ->(_user, _context) { raise "after hook failed" }}}})
    internal = auth.context.internal_adapter

    error = assert_raises(RuntimeError) do
      internal.create_oauth_user({email: "committed@example.com", name: "Committed"}, {providerId: "github", accountId: "committed"})
    end

    assert_equal "after hook failed", error.message
    user = internal.find_user_by_email("committed@example.com").fetch(:user)
    assert_equal ["committed"], internal.find_accounts(user.fetch("id")).map { |account| account.fetch("accountId") }
  end

  def test_inline_after_hook_retries_once_after_an_error
    calls = []
    auth = build_auth(database_hooks: {user: {create: {after: ->(user, _context) {
      calls << user.fetch("id")
      raise "inline after hook failed" if calls.one?
    }}}})

    user = auth.context.internal_adapter.create_user(email: "inline@example.com", name: "Inline")

    assert_equal [user.fetch("id"), user.fetch("id")], calls
  end

  def test_http_dispatch_defers_after_hooks_and_captures_the_endpoint_context
    calls = []
    endpoint = BetterAuth::Endpoint.new(path: "/verification-hooks", method: "POST") do |ctx|
      internal = ctx.context.internal_adapter
      internal.create_verification_value(identifier: "context", value: "data", expiresAt: Time.now + 60)
      internal.consume_verification_value("context")
      calls << [:endpoint, BetterAuth::RequestState.present?]
      ctx.json({ok: true})
    end
    auth = build_auth(
      plugins: [{id: "verification-hooks", endpoints: {verification_hooks: endpoint}}],
      database_hooks: {verification: {
        create: {after: ->(_value, ctx) { calls << [:create_after, ctx&.path, BetterAuth::RequestState.present?] }},
        delete: {
          before: ->(_value, ctx) { calls << [:delete_before, ctx&.path] },
          after: ->(_value, ctx) { calls << [:delete_after, ctx&.path] }
        }
      }}
    )

    status, = auth.call(json_rack_env("POST", "/api/auth/verification-hooks"))

    assert_equal 200, status
    assert_equal [
      [:delete_before, "/verification-hooks"],
      [:delete_after, "/verification-hooks"],
      [:endpoint, true],
      [:create_after, "/verification-hooks", false]
    ], calls
  end

  def test_queued_create_and_update_hooks_receive_each_write_result
    calls = []
    endpoint = BetterAuth::Endpoint.new(path: "/write-user", method: "POST") do |ctx|
      internal = ctx.context.internal_adapter
      user = internal.create_user(email: "write-user@example.com", name: "Original")
      internal.update_user(user.fetch("id"), name: "First")
      internal.update_user(user.fetch("id"), name: "Second")
      ctx.json({ok: true})
    end
    auth = build_auth(
      plugins: [{id: "write-user", endpoints: {write_user: endpoint}}],
      database_hooks: {user: {
        create: {after: ->(user, _context) { calls << [:create, user.fetch("name")] }},
        update: {after: ->(user, _context) { calls << [:update, user.fetch("name")] }}
      }}
    )

    status, = auth.call(json_rack_env("POST", "/api/auth/write-user"))

    assert_equal 200, status
    assert_equal [[:create, "Original"], [:update, "First"], [:update, "Second"]], calls
  end

  def test_delete_veto_returns_nil_and_leaves_the_row
    auth = build_auth(database_hooks: {user: {delete: {before: ->(_user, _context) { false }}}})
    internal = auth.context.internal_adapter
    user = internal.create_user(email: "veto@example.com", name: "Veto")
    where = [{field: "id", value: user.fetch("id")}]

    assert_nil internal.hooks.delete(where, "user")
    assert_nil internal.hooks.delete_many(where, "user")
    assert_equal user, internal.find_user_by_id(user.fetch("id"))
  end

  def test_delete_uses_a_custom_callback_when_no_row_matches
    internal = build_auth.context.internal_adapter
    where = [{field: "id", value: "missing"}]
    custom = ->(conditions) { conditions.first.fetch(:value) }

    assert_equal "missing", internal.hooks.delete(where, "user", custom: custom)
  end

  def test_failed_delete_lookup_skips_single_delete_and_allows_bulk_delete
    adapter_class = Class.new(BetterAuth::Adapters::Memory) do
      def find_many(model:, **options)
        raise "snapshot unavailable" if model == "user"

        super
      end
    end
    auth = build_auth(database: ->(config) { adapter_class.new(config) })
    internal = auth.context.internal_adapter
    user = internal.create_user(email: "delete-lookup@example.com", name: "Lookup")
    where = [{field: "id", value: user.fetch("id")}]

    assert_nil internal.hooks.delete(where, "user")
    assert_equal 1, internal.count_total_users(where: where)
    assert_equal 1, internal.hooks.delete_many(where, "user")
    assert_equal 0, internal.count_total_users(where: where)
  end
end
