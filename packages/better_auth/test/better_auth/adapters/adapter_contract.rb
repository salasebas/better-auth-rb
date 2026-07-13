# frozen_string_literal: true

module BetterAuthAdapterContract
  ATOMIC_THREAD_COUNT = 8

  def test_adapter_contract_create_if_absent_has_exactly_one_concurrent_winner
    config = contract_config

    with_contract_adapter(config) do |adapter|
      data = {id: "create-if-absent", name: "Winner", email: "create-if-absent@example.com"}
      ready = Queue.new
      start = Queue.new
      threads = ATOMIC_THREAD_COUNT.times.map do
        Thread.new do
          ready << true
          start.pop
          adapter.create_if_absent(model: "user", data: data, conflict_field: "id", force_allow_id: true)
        end
      end
      ATOMIC_THREAD_COUNT.times { ready.pop }
      ATOMIC_THREAD_COUNT.times { start << true }

      assert_equal 1, threads.map(&:value).count(true)
      assert_equal 1, adapter.count(model: "user", where: [{field: "id", value: data.fetch(:id)}])
    end
  end

  def test_adapter_contract_increment_one_rejects_non_numeric_and_id_fields
    config = contract_config(user: {additional_fields: {credits: {type: "number", required: false}}})

    with_contract_adapter(config) do |adapter|
      user = adapter.create(model: "user", data: {name: "Increment", email: "invalid-increment@example.com", credits: 1})

      %i[email id emailVerified createdAt missing].each do |field|
        assert_raises(BetterAuth::APIError) do
          adapter.increment_one(model: "user", where: [{field: "id", value: user.fetch("id")}], increment: {field => 1})
        end
      end

      result = adapter.increment_one(model: "user", where: [{field: "id", value: user.fetch("id")}], increment: {credits: 2})
      assert_equal 3, result.fetch("credits")
    end
  end

  def test_adapter_contract_consume_one_deletes_and_returns_at_most_one_row
    config = contract_config

    with_contract_adapter(config) do |adapter|
      first = adapter.create(model: "user", data: {name: "First", email: "first-consume@example.com"})
      second = adapter.create(model: "user", data: {name: "Second", email: "second-consume@example.com"})

      consumed = adapter.consume_one(model: "user", where: [{field: "emailVerified", value: false}])

      assert_includes [first.fetch("id"), second.fetch("id")], consumed.fetch("id")
      assert_equal 1, adapter.count(model: "user")
      assert_nil adapter.consume_one(model: "user", where: [{field: "id", value: "missing"}])
    end
  end

  def test_adapter_contract_consume_one_has_exactly_one_concurrent_winner
    config = contract_config

    with_contract_adapter(config) do |adapter|
      user = adapter.create(model: "user", data: {name: "Consume", email: "consume-race@example.com"})
      ready = Queue.new
      start = Queue.new
      threads = ATOMIC_THREAD_COUNT.times.map do
        Thread.new do
          ready << true
          start.pop
          adapter.consume_one(model: "user", where: [{field: "id", value: user.fetch("id")}])
        end
      end
      ATOMIC_THREAD_COUNT.times { ready.pop }
      ATOMIC_THREAD_COUNT.times { start << true }
      results = threads.map(&:value)

      assert_equal 1, results.compact.length
      assert_equal user.fetch("id"), results.compact.first.fetch("id")
      assert_nil adapter.find_one(model: "user", where: [{field: "id", value: user.fetch("id")}])
    end
  end

  def test_adapter_contract_increment_one_applies_guarded_deltas_atomically
    config = contract_config(user: {additional_fields: {credits: {type: "number", required: false}}})

    with_contract_adapter(config) do |adapter|
      user = adapter.create(model: "user", data: {name: "Increment", email: "increment-race@example.com", credits: 0})
      ready = Queue.new
      start = Queue.new
      threads = ATOMIC_THREAD_COUNT.times.map do
        Thread.new do
          ready << true
          start.pop
          adapter.increment_one(
            model: "user",
            where: [{field: "id", value: user.fetch("id")}],
            increment: {credits: 1}
          )
        end
      end
      ATOMIC_THREAD_COUNT.times { ready.pop }
      ATOMIC_THREAD_COUNT.times { start << true }
      results = threads.map(&:value)

      assert_equal ATOMIC_THREAD_COUNT, results.compact.length
      assert_equal ATOMIC_THREAD_COUNT, adapter.find_one(model: "user", where: [{field: "id", value: user.fetch("id")}]).fetch("credits")

      winner = adapter.increment_one(
        model: "user",
        where: [{field: "id", value: user.fetch("id")}, {field: "credits", value: ATOMIC_THREAD_COUNT + 1, operator: "lt"}],
        increment: {credits: 1},
        set: {image: "winner.png"}
      )
      loser = adapter.increment_one(
        model: "user",
        where: [{field: "id", value: user.fetch("id")}, {field: "credits", value: ATOMIC_THREAD_COUNT + 1, operator: "lt"}],
        increment: {credits: 1}
      )

      assert_equal ATOMIC_THREAD_COUNT + 1, winner.fetch("credits")
      assert_equal "winner.png", winner.fetch("image")
      assert_nil loser
    end
  end

  def test_adapter_contract_rate_limit_guard_allows_exactly_max_concurrent_requests
    config = contract_config(rate_limit: {storage: "database"})

    with_contract_adapter(config) do |adapter|
      now = (Time.now.to_f * 1000).to_i
      adapter.create_if_absent(
        model: "rateLimit",
        data: {key: "atomic-burst", count: 0, lastRequest: now},
        conflict_field: "key"
      )
      ready = Queue.new
      start = Queue.new
      threads = ATOMIC_THREAD_COUNT.times.map do
        Thread.new do
          ready << true
          start.pop
          adapter.increment_one(
            model: "rateLimit",
            where: [
              {field: "key", value: "atomic-burst"},
              {field: "lastRequest", operator: "gte", value: now - 60_000},
              {field: "count", operator: "lt", value: 3}
            ],
            increment: {count: 1},
            set: {lastRequest: now}
          )
        end
      end
      ATOMIC_THREAD_COUNT.times { ready.pop }
      ATOMIC_THREAD_COUNT.times { start << true }

      assert_equal 3, threads.map(&:value).compact.length
      row = adapter.find_one(model: "rateLimit", where: [{field: "key", value: "atomic-burst"}])
      assert_equal 3, row.fetch("count")

      reset = adapter.increment_one(
        model: "rateLimit",
        where: [
          {field: "key", value: "atomic-burst"},
          {field: "lastRequest", operator: "lte", value: now}
        ],
        increment: {},
        set: {count: 1, lastRequest: now + 61_000}
      )
      assert_equal 1, reset.fetch("count")
    end
  end

  def test_adapter_contract_nested_transactions_reuse_the_active_transaction
    config = contract_config

    with_contract_adapter(config) do |adapter|
      adapter.transaction do |outer|
        outer.transaction do |inner|
          assert_same outer, inner
          inner.create(model: "user", data: {name: "Nested", email: "nested-transaction@example.com"})
        end
      end

      assert adapter.find_one(model: "user", where: [{field: "email", value: "nested-transaction@example.com"}])

      assert_raises(RuntimeError) do
        adapter.transaction do |outer|
          outer.transaction do |inner|
            inner.create(model: "user", data: {name: "Rollback", email: "nested-rollback@example.com"})
            raise "rollback"
          end
        end
      end

      assert_nil adapter.find_one(model: "user", where: [{field: "email", value: "nested-rollback@example.com"}])
    end
  end

  def test_adapter_contract_singular_update_fails_closed
    config = contract_config

    with_contract_adapter(config) do |adapter|
      first = adapter.create(model: "user", data: {name: "Ada", email: "ada-update-safety@example.com"})
      second = adapter.create(model: "user", data: {name: "Grace", email: "grace-update-safety@example.com"})

      assert_nil adapter.update(model: "user", where: [], update: {name: "Unsafe"})
      assert_nil adapter.update(model: "user", where: nil, update: {name: "Unsafe"})
      assert_nil adapter.update(model: "user", where: [{field: "id", value: "missing"}], update: {name: "Missing"})
      assert_equal ["Ada", "Grace"], adapter.find_many(model: "user", sort_by: {field: "email", direction: "asc"}).map { |user| user.fetch("name") }

      assert_equal 2, adapter.update_many(model: "user", where: [], update: {image: "bulk.png"})
      assert_equal ["bulk.png", "bulk.png"], adapter.find_many(model: "user", sort_by: {field: "email", direction: "asc"}).map { |user| user.fetch("image") }
      assert adapter.find_one(model: "user", where: [{field: "id", value: first.fetch("id")}])
      assert adapter.find_one(model: "user", where: [{field: "id", value: second.fetch("id")}])
    end
  end

  def test_adapter_contract_groups_and_or_predicates
    config = contract_config(
      user: {
        additional_fields: {
          cohort: {type: "string", required: false}
        }
      }
    )

    with_contract_adapter(config) do |adapter|
      first = adapter.create(model: "user", data: {name: "First", email: "first-group@example.com", cohort: "target"})
      second = adapter.create(model: "user", data: {name: "Second", email: "second-group@example.com", cohort: "other"})
      third = adapter.create(model: "user", data: {name: "Third", email: "third-group@example.com", cohort: "target"})
      adapter.create(model: "session", data: {token: "third-group-session", userId: third.fetch("id"), expiresAt: Time.now + 60}, force_allow_id: true)

      where = [
        {field: "cohort", value: "target"},
        {field: "id", value: second.fetch("id"), connector: "OR"},
        {field: "id", value: third.fetch("id"), connector: "OR"}
      ]

      assert_equal [third.fetch("id")], adapter.find_many(model: "user", where: where).map { |user| user.fetch("id") }
      assert_equal 1, adapter.count(model: "user", where: where)
      joined = adapter.find_many(model: "user", where: where, join: {session: true})
      assert_equal ["third-group-session"], joined.fetch(0).fetch("session").map { |session| session.fetch("token") }

      assert_equal 1, adapter.update_many(model: "user", where: where, update: {image: "grouped.png"})
      assert_nil adapter.find_one(model: "user", where: [{field: "id", value: first.fetch("id")}, {field: "image", value: "grouped.png"}])
      assert_nil adapter.find_one(model: "user", where: [{field: "id", value: second.fetch("id")}, {field: "image", value: "grouped.png"}])
      assert_equal "grouped.png", adapter.find_one(model: "user", where: [{field: "id", value: third.fetch("id")}]).fetch("image")

      assert_equal 1, adapter.delete_many(model: "user", where: where)
      assert_equal [first.fetch("id"), second.fetch("id")].sort, adapter.find_many(model: "user").map { |user| user.fetch("id") }.sort
    end
  end

  def test_adapter_contract_crud_where_update_delete_and_counts
    config = contract_config(
      user: {
        additional_fields: {
          age: {type: "number", required: false},
          nickname: {type: "string", required: false}
        }
      }
    )

    with_contract_adapter(config) do |adapter|
      first = adapter.create(model: "user", data: {name: "Ada Lovelace", email: "ada@example.com", age: 25}, force_allow_id: false)
      second = adapter.create(model: "user", data: {name: "Grace Hopper", email: "grace@example.com", age: 30}, force_allow_id: false)
      adapter.update(model: "user", where: [{field: "id", value: second.fetch("id")}], update: {emailVerified: true})

      assert_kind_of String, first.fetch("id")
      assert_equal false, first.fetch("emailVerified")
      assert_equal ["ada@example.com"], adapter.find_many(model: "user", where: [{field: "emailVerified", value: false}]).map { |user| user.fetch("email") }
      assert_equal ["ada@example.com"], adapter.find_many(model: "user", where: [{field: "email", value: "ADA@EXAMPLE.COM", mode: "insensitive"}]).map { |user| user.fetch("email") }
      assert_equal ["ada@example.com"], adapter.find_many(model: "user", where: [{field: "name", operator: "contains", value: "love", mode: "insensitive"}]).map { |user| user.fetch("email") }
      assert_equal ["ada@example.com"], adapter.find_many(model: "user", where: [{field: "age", value: "25"}]).map { |user| user.fetch("email") }
      assert_equal 2, adapter.count(model: "user", where: [{field: "email", operator: "contains", value: "@example.com"}])

      updated_count = adapter.update_many(model: "user", where: [{field: "email", operator: "contains", value: "@example.com"}], update: {image: "avatar.png"})
      assert_equal 2, updated_count
      assert_equal ["avatar.png", "avatar.png"], adapter.find_many(model: "user", sort_by: {field: "email", direction: "asc"}).map { |user| user.fetch("image") }

      assert_equal 1, adapter.delete_many(model: "user", where: [{field: "id", value: second.fetch("id")}])
      assert_equal 1, adapter.count(model: "user")
      assert_nil adapter.find_one(model: "user", where: [{field: "id", value: second.fetch("id")}])
    end
  end

  def test_adapter_contract_transaction_rolls_back
    config = contract_config

    with_contract_adapter(config) do |adapter|
      user = adapter.create(model: "user", data: {name: "Ada", email: "rollback@example.com"})

      assert_raises(RuntimeError) do
        adapter.transaction do |trx|
          trx.update(model: "user", where: [{field: "id", value: user.fetch("id")}], update: {name: "Rolled Back"})
          raise "rollback"
        end
      end

      assert_equal "Ada", adapter.find_one(model: "user", where: [{field: "id", value: user.fetch("id")}]).fetch("name")
    end
  end

  def test_adapter_contract_json_array_fields_round_trip
    plugin = BetterAuth::Plugin.new(
      id: "typed-contract",
      schema: {
        typedRecord: {
          model_name: "typed_contract_records",
          fields: {
            id: {type: "string", required: true},
            metadata: {type: "json", required: false},
            tags: {type: "string[]", required: false},
            scores: {type: "number[]", required: false}
          }
        }
      }
    )
    config = contract_config(plugins: [plugin])

    with_contract_adapter(config) do |adapter|
      adapter.create(
        model: "typedRecord",
        data: {
          id: "typed-1",
          metadata: {"nested" => {"enabled" => true}},
          tags: ["alpha", "beta"],
          scores: [1, 2, 3]
        },
        force_allow_id: true
      )

      record = adapter.find_one(model: "typedRecord", where: [{field: "id", value: "typed-1"}])
      assert_equal({"nested" => {"enabled" => true}}, record.fetch("metadata"))
      assert_equal ["alpha", "beta"], record.fetch("tags")
      assert_equal [1, 2, 3], record.fetch("scores")
    end
  end

  def test_adapter_contract_join_session_user
    config = contract_config

    with_contract_adapter(config) do |adapter|
      user = adapter.create(model: "user", data: {name: "Join User", email: "join@example.com"})
      session = adapter.create(
        model: "session",
        data: {userId: user.fetch("id"), token: "join-token", expiresAt: Time.now + 3600},
        force_allow_id: true
      )

      found = adapter.find_one(model: "session", where: [{field: "token", value: session.fetch("token")}], join: {user: true})

      assert_equal "join-token", found.fetch("token")
      assert_equal user.fetch("id"), found.fetch("user").fetch("id")
      assert_equal "join@example.com", found.fetch("user").fetch("email")
    end
  end

  def test_adapter_contract_database_rate_limit_persists_throttles_and_resets
    config = contract_config(rate_limit: {storage: "database"})

    with_contract_adapter(config) do |adapter|
      auth = BetterAuth.auth(
        base_url: "http://localhost:3000",
        secret: self.class::SECRET,
        database: adapter,
        rate_limit: {enabled: true, window: 60, max: 1, storage: "database"},
        plugins: [
          {
            id: "contract-rate-limit",
            endpoints: {
              limited: BetterAuth::Endpoint.new(path: "/limited", method: "GET") { {ok: true} }
            }
          }
        ]
      )

      assert_equal 200, auth.call(contract_rack_env("GET", "/api/auth/limited")).first
      stored = adapter.find_one(model: "rateLimit", where: [{field: "key", value: "127.0.0.1|/limited"}])
      assert_equal 1, stored.fetch("count")
      assert_kind_of Integer, stored.fetch("lastRequest")

      status, headers, body = auth.call(contract_rack_env("GET", "/api/auth/limited"))
      assert_equal 429, status
      assert_match(/\A\d+\z/, headers.fetch("x-retry-after"))
      assert_equal({"message" => "Too many requests. Please try again later."}, JSON.parse(body.join))

      adapter.update(
        model: "rateLimit",
        where: [{field: "key", value: "127.0.0.1|/limited"}],
        update: {count: 1, lastRequest: ((Time.now.to_f - 61) * 1000).to_i}
      )
      assert_equal 200, auth.call(contract_rack_env("GET", "/api/auth/limited?nonce=1")).first
      reset = adapter.find_one(model: "rateLimit", where: [{field: "key", value: "127.0.0.1|/limited"}])
      assert_equal 1, reset.fetch("count")
    end
  end

  private

  def contract_config(**options)
    BetterAuth::Configuration.new({secret: self.class::SECRET, database: :memory}.merge(options))
  end

  def contract_rack_env(method, path)
    path_info, query_string = path.split("?", 2)
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path_info,
      "QUERY_STRING" => query_string || "",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "3000",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(""),
      "CONTENT_LENGTH" => "0"
    }
  end
end
