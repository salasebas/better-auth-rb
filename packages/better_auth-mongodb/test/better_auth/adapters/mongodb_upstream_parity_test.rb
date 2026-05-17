# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require_relative "../../test_helper"
require_relative "../../support/fake_mongo"

class BetterAuthMongoDBUpstreamParityTest < Minitest::Test
  include BetterAuthMongoAdapterTestSupport

  SECRET = "test-secret-that-is-long-enough-for-validation"
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  def setup
    reset_adapter
  end

  def test_upstream_mongo_specific_create_adapter
    assert_instance_of BetterAuth::Adapters::MongoDB, adapter
  end

  def test_upstream_mongo_specific_uuid_ids_are_stored_as_bson_uuid
    reset_adapter(advanced: {database: {generate_id: "uuid"}})

    user = adapter.create(model: "user", data: user_data(id: nil))
    stored = collection("user").documents.first

    assert_instance_of BSON::Binary, stored.fetch("_id")
    assert_equal :uuid, stored.fetch("_id").type
    assert_match UUID_PATTERN, user.fetch("id")
    assert_equal stored.fetch("_id").to_uuid, user.fetch("id")
  end

  def test_upstream_mongo_specific_uuid_foreign_keys_are_stored_as_bson_uuid
    reset_adapter(advanced: {database: {generate_id: "uuid"}})
    user_id = SecureRandom.uuid

    session = adapter.create(model: "session", data: session_data(user_id: user_id, id: nil))
    stored = collection("session").documents.first

    assert_instance_of BSON::Binary, stored.fetch("_id")
    assert_instance_of BSON::Binary, stored.fetch("user_id")
    assert_equal user_id, stored.fetch("user_id").to_uuid
    assert_equal user_id, session.fetch("userId")
  end

  def test_upstream_mongo_specific_default_ids_are_stored_as_object_ids
    user = adapter.create(model: "user", data: user_data(id: nil))
    stored = collection("user").documents.first

    assert_instance_of BSON::ObjectId, stored.fetch("_id")
    assert_equal stored.fetch("_id").to_s, user.fetch("id")
  end

  def test_upstream_mongo_specific_bson_uuid_outputs_are_strings
    reset_adapter(advanced: {database: {generate_id: "uuid"}})
    user_id = SecureRandom.uuid
    collection("user").insert_one("_id" => BSON::Binary.from_uuid(user_id), "email" => "uuid@example.com", "name" => "UUID")

    found = adapter.find_one(model: "user", where: [{field: "id", value: user_id}])

    assert_equal user_id, found.fetch("id")
    assert_equal "uuid@example.com", found.fetch("email")
  end

  def test_upstream_mongo_specific_update_keeps_object_id_foreign_keys
    user = adapter.create(model: "user", data: user_data(id: nil))
    session = adapter.create(model: "session", data: session_data(user_id: user.fetch("id"), id: nil))

    before_update = collection("session").documents.first
    assert_instance_of BSON::ObjectId, before_update.fetch("user_id")

    updated = adapter.update(
      model: "session",
      where: [{field: "id", value: session.fetch("id")}],
      update: session.merge("expiresAt" => Time.now + 120, "id" => nil)
    )
    after_update = collection("session").documents.first

    assert_equal session.fetch("id"), updated.fetch("id")
    assert_instance_of BSON::ObjectId, after_update.fetch("user_id")
  end

  def test_normal_create_model_create_id_and_custom_generate_id
    data = user_data
    user = adapter.create(model: "user", data: data, force_allow_id: true)
    assert_equal data.fetch(:id), user.fetch("id")
    assert_equal data.fetch(:email), user.fetch("email")

    generated = adapter.create(model: "user", data: user_data(id: nil, email: "generated@example.com"))
    assert_kind_of String, generated.fetch("id")

    reset_adapter(advanced: {database: {generate_id: -> { "HARD-CODED-ID" }}})
    custom = adapter.create(model: "user", data: user_data(id: nil, email: "custom@example.com"))
    assert_equal "HARD-CODED-ID", custom.fetch("id")
    assert_equal custom, adapter.find_one(model: "user", where: [{field: "id", value: custom.fetch("id")}])
  end

  def test_normal_create_nullable_foreign_key_and_default_values
    reset_adapter(
      plugins: [{
        id: "defaults-test",
        schema: {
          testModel: {
            fields: {
              nullableReference: {type: "string", required: false, references: {model: "user", field: "id"}},
              testField: {type: "string", defaultValue: "test-value"},
              cbDefaultValueField: {type: "string", defaultValue: -> { "advanced-test-value" }}
            }
          }
        }
      }],
      user: {
        additional_fields: {
          testField: {type: "string", default_value: "test-value"},
          cbDefaultValueField: {type: "string", default_value: -> { "advanced-test-value" }}
        }
      }
    )

    model = adapter.create(model: "testModel", data: {nullableReference: nil})
    user = adapter.create(model: "user", data: user_data)

    assert_nil model.fetch("nullableReference")
    assert_equal "test-value", model.fetch("testField")
    assert_equal "advanced-test-value", model.fetch("cbDefaultValueField")
    assert_equal "test-value", user.fetch("testField")
    assert_equal "advanced-test-value", user.fetch("cbDefaultValueField")
  end

  def test_normal_find_one_core_lookup_variants
    user = create_user
    session = create_session(user)

    assert_equal user, adapter.find_one(model: "user", where: [{field: "id", value: user.fetch("id")}])
    assert_equal session, adapter.find_one(model: "session", where: [{field: "userId", value: user.fetch("id")}])
    assert_nil adapter.find_one(model: "user", where: [{field: "id", value: next_id}])
    assert_equal user, adapter.find_one(model: "user", where: [{field: "email", value: user.fetch("email")}])
    assert_equal user, adapter.find_one(model: "user", where: [{field: "createdAt", operator: "eq", value: user.fetch("createdAt")}])
  end

  def test_normal_find_one_modified_model_field_and_additional_fields
    reset_adapter(
      user: {
        model_name: "user_custom",
        fields: {email: "email_address"},
        additional_fields: {
          customField: {type: "string", input: false, required: true, default_value: "default-value"}
        }
      }
    )
    user = create_user

    found = adapter.find_one(model: "user", where: [{field: "customField", value: "default-value"}])
    stored = collection("user_custom").documents.first

    assert_equal user, found
    assert_equal user.fetch("email"), stored.fetch("email_address")
    assert_nil collection("user").documents.first
  end

  def test_normal_find_one_select_fields_and_select_with_joins
    user = create_user
    session = create_session(user)
    account = create_account(user)

    selected = adapter.find_one(model: "user", where: [{field: "id", value: user.fetch("id")}], select: ["email", "name"])
    with_session = adapter.find_one(model: "user", where: [{field: "id", value: user.fetch("id")}], select: ["email", "name"], join: {session: true})
    with_account = adapter.find_one(model: "user", where: [{field: "id", value: user.fetch("id")}], select: ["email", "name"], join: {session: true, account: true})

    assert_equal({"email" => user.fetch("email"), "name" => user.fetch("name")}, selected)
    assert_equal session.fetch("id"), with_session.fetch("session").first.fetch("id")
    assert_equal account.fetch("id"), with_account.fetch("account").first.fetch("id")
  end

  def test_normal_select_fields_with_one_to_one_join
    configure_one_to_one
    user = create_user
    one_to_one = adapter.create(model: "oneToOneTable", data: {oneToOne: user.fetch("id")})

    result = adapter.find_one(
      model: "user",
      where: [{field: "id", value: user.fetch("id")}],
      select: ["email", "name"],
      join: {oneToOneTable: true}
    )

    assert_equal user.fetch("email"), result.fetch("email")
    assert_equal user.fetch("name"), result.fetch("name")
    assert_equal one_to_one.fetch("id"), result.fetch("oneToOneTable").fetch("id")
    refute result.key?("id")
  end

  def test_normal_one_to_one_joins_return_object_or_nil
    configure_one_to_one
    user = create_user
    joined = adapter.create(model: "oneToOneTable", data: {oneToOne: user.fetch("id")})
    missing_user = create_user(email: "missing-join@example.com")

    found = adapter.find_one(model: "user", where: [{field: "id", value: user.fetch("id")}], join: {oneToOneTable: true})
    missing = adapter.find_one(model: "user", where: [{field: "id", value: missing_user.fetch("id")}], join: {oneToOneTable: true})

    assert_equal joined.fetch("id"), found.fetch("oneToOneTable").fetch("id")
    assert_nil missing.fetch("oneToOneTable")
  end

  def test_normal_one_to_many_and_backwards_joins
    user = create_user
    session = create_session(user)
    account = create_account(user)

    user_with_joins = adapter.find_one(model: "user", where: [{field: "id", value: user.fetch("id")}], join: {session: true, account: true})
    session_with_user = adapter.find_one(model: "session", where: [{field: "token", value: session.fetch("token")}], join: {user: true})

    assert_equal [session.fetch("id")], user_with_joins.fetch("session").map { |entry| entry.fetch("id") }
    assert_equal [account.fetch("id")], user_with_joins.fetch("account").map { |entry| entry.fetch("id") }
    assert_equal user.fetch("id"), session_with_user.fetch("user").fetch("id")
    refute_kind_of Array, session_with_user.fetch("user")
  end

  def test_normal_missing_base_records_with_joins_return_nil_or_empty_array
    configure_one_to_one

    assert_nil adapter.find_one(model: "user", where: [{field: "id", value: next_id}], join: {session: true, account: true, oneToOneTable: true})
    assert_equal [], adapter.find_many(model: "user", where: [{field: "id", value: next_id}], join: {session: true, account: true, oneToOneTable: true})
  end

  def test_normal_mixed_join_results_keep_base_records_when_some_joins_are_missing
    configure_one_to_one
    user_with_both = create_user(email: "both@example.com")
    one_to_one = adapter.create(model: "oneToOneTable", data: {oneToOne: user_with_both.fetch("id")})
    session = create_session(user_with_both)
    user_with_one_to_one = create_user(email: "one-to-one@example.com")
    adapter.create(model: "oneToOneTable", data: {oneToOne: user_with_one_to_one.fetch("id")})
    user_with_session = create_user(email: "session@example.com")
    create_session(user_with_session)
    user_without_joins = create_user(email: "empty@example.com")

    results = adapter.find_many(
      model: "user",
      where: [
        {field: "id", value: user_with_both.fetch("id"), connector: "OR"},
        {field: "id", value: user_with_one_to_one.fetch("id"), connector: "OR"},
        {field: "id", value: user_with_session.fetch("id"), connector: "OR"},
        {field: "id", value: user_without_joins.fetch("id"), connector: "OR"}
      ],
      join: {oneToOneTable: true, session: true}
    )

    by_id = results.to_h { |user| [user.fetch("id"), user] }
    assert_equal one_to_one.fetch("id"), by_id.fetch(user_with_both.fetch("id")).fetch("oneToOneTable").fetch("id")
    assert_equal [session.fetch("id")], by_id.fetch(user_with_both.fetch("id")).fetch("session").map { |entry| entry.fetch("id") }
    assert by_id.fetch(user_with_one_to_one.fetch("id")).fetch("oneToOneTable")
    assert_empty by_id.fetch(user_with_one_to_one.fetch("id")).fetch("session")
    assert_nil by_id.fetch(user_with_session.fetch("id")).fetch("oneToOneTable")
    refute_empty by_id.fetch(user_with_session.fetch("id")).fetch("session")
    assert_nil by_id.fetch(user_without_joins.fetch("id")).fetch("oneToOneTable")
    assert_empty by_id.fetch(user_without_joins.fetch("id")).fetch("session")
  end

  def test_normal_limited_joins
    user = create_user
    5.times { |index| create_session(user, token: "limited-#{index}") }
    5.times { |index| create_account(user, provider_id: "provider-#{index}") }

    found = adapter.find_one(model: "user", where: [{field: "id", value: user.fetch("id")}], join: {session: {limit: 2}, account: {limit: 3}})
    many = adapter.find_many(model: "user", join: {session: {limit: 2}, account: {limit: 3}}, limit: 1)

    assert_equal 2, found.fetch("session").length
    assert_equal 3, found.fetch("account").length
    assert_equal 2, many.first.fetch("session").length
    assert_equal 3, many.first.fetch("account").length
  end

  def test_normal_find_many_core_filters_and_string_operators
    users = [
      create_user(name: "john doe", email: "john@example.com"),
      create_user(name: "jane smith", email: "jane@gmail.com"),
      create_user(name: "prefix-.*-suffix", email: "regex@sample.net")
    ]

    assert_ids users, adapter.find_many(model: "user")
    assert_ids [users.first], adapter.find_many(model: "user", where: [{field: "name", value: "john", operator: "starts_with"}])
    assert_ids [users.first], adapter.find_many(model: "user", where: [{field: "email", value: "example.com", operator: "ends_with"}])
    assert_ids [users.last], adapter.find_many(model: "user", where: [{field: "name", value: "-.*-", operator: "contains"}])
    assert_ids [users.first], adapter.find_many(model: "user", where: [
      {field: "email", value: "john@example.com", operator: "eq", connector: "AND"},
      {field: "name", value: "john", operator: "contains", connector: "AND"}
    ])
  end

  def test_normal_find_many_comparison_and_membership_operators
    older = create_user(created_at: Time.now - 300)
    middle = create_user(email: "middle@example.com", created_at: Time.now - 200)
    newer = create_user(email: "newer@example.com", created_at: Time.now - 100)

    assert_ids [middle, newer], adapter.find_many(model: "user", where: [{field: "createdAt", value: older.fetch("createdAt"), operator: "gt"}])
    assert_ids [older, middle], adapter.find_many(model: "user", where: [{field: "createdAt", value: middle.fetch("createdAt"), operator: "lte"}])
    assert_ids [older, newer], adapter.find_many(model: "user", where: [{field: "id", value: [older.fetch("id"), newer.fetch("id")], operator: "in"}])
    assert_ids [newer], adapter.find_many(model: "user", where: [{field: "id", value: [older.fetch("id"), middle.fetch("id")], operator: "not_in"}])
  end

  def test_normal_find_many_sort_limit_offset_and_where_order
    configure_numeric_field
    users = 5.times.map { |index| create_user(name: "sort-#{index}", email: "sort-#{index}@example.com", numeric_field: index) }

    sorted = adapter.find_many(model: "user", sort_by: {field: "numericField", direction: "asc"})
    paged = adapter.find_many(model: "user", sort_by: {field: "numericField", direction: "asc"}, limit: 2, offset: 2)
    filtered = adapter.find_many(model: "user", where: [{field: "name", value: "sort", operator: "starts_with"}], sort_by: {field: "numericField", direction: "desc"}, limit: 2, offset: 1)

    assert_equal users.map { |user| user.fetch("numericField") }, sorted.map { |user| user.fetch("numericField") }
    assert_equal [2, 3], paged.map { |user| user.fetch("numericField") }
    assert_equal [3, 2], filtered.map { |user| user.fetch("numericField") }
  end

  def test_normal_find_many_with_joins_limit_offset_sort_and_where
    configure_numeric_field
    users = 5.times.map do |index|
      create_user(name: "join-user-#{index}", email: "join-#{index}@example.com", numeric_field: index).tap do |user|
        2.times { |session_index| create_session(user, token: "join-#{index}-#{session_index}") }
      end
    end

    result = adapter.find_many(
      model: "user",
      where: [{field: "name", value: "join-user", operator: "starts_with"}],
      join: {session: true},
      sort_by: {field: "numericField", direction: "asc"},
      limit: 2,
      offset: 2
    )

    assert_equal users[2, 2].map { |user| user.fetch("id") }, result.map { |user| user.fetch("id") }
    assert result.all? { |user| user.fetch("session").length == 2 }
  end

  def test_normal_update_update_many_delete_delete_many_and_count
    users = 3.times.map { |index| create_user(email: "crud-#{index}@example.com") }

    updated = adapter.update(model: "user", where: [{field: "email", value: users.first.fetch("email")}], update: {email: "updated@example.com", name: "Updated", emailVerified: true})
    update_all_count = adapter.update_many(model: "user", where: [], update: {name: "Updated All"})
    update_some_count = adapter.update_many(model: "user", where: [{field: "id", value: users[1].fetch("id")}], update: {name: "Updated Some"})
    deleted = adapter.delete(model: "user", where: [{field: "email", value: "updated@example.com"}])
    delete_count = adapter.delete_many(model: "user", where: [{field: "id", value: [users[1].fetch("id"), users[2].fetch("id")], operator: "in"}])

    assert_equal "updated@example.com", updated.fetch("email")
    assert_equal true, updated.fetch("emailVerified")
    assert_equal 3, update_all_count
    assert_equal 1, update_some_count
    assert_nil deleted
    assert_equal 2, delete_count
    assert_equal 0, adapter.count(model: "user")
  end

  def test_normal_delete_non_unique_field_numeric_boolean_and_regex_literals
    configure_numeric_field
    verification = adapter.create(model: "verification", data: {identifier: "email", value: "token", expiresAt: Time.now + 60})
    numeric_zero = create_user(email: "numeric-0@example.com", numeric_field: 0)
    create_user(email: "numeric-1@example.com", numeric_field: 1)
    keep_false = create_user(email: "false@example.com")
    delete_true = create_user(email: "true@example.com")
    regex_user = create_user(name: "prefix-.*-suffix", email: "regex-delete@example.com")
    adapter.update(model: "user", where: [{field: "id", value: delete_true.fetch("id")}], update: {emailVerified: true})

    adapter.delete(model: "verification", where: [{field: "identifier", value: verification.fetch("identifier")}])
    adapter.delete_many(model: "user", where: [{field: "numericField", value: 0, operator: "gt"}])
    adapter.delete_many(model: "user", where: [{field: "emailVerified", value: true}])
    adapter.delete_many(model: "user", where: [{field: "name", value: "-.*-", operator: "contains"}])

    assert_nil adapter.find_one(model: "verification", where: [{field: "id", value: verification.fetch("id")}])
    assert adapter.find_one(model: "user", where: [{field: "id", value: numeric_zero.fetch("id")}])
    assert adapter.find_one(model: "user", where: [{field: "id", value: keep_false.fetch("id")}])
    assert_nil adapter.find_one(model: "user", where: [{field: "id", value: delete_true.fetch("id")}])
    assert_nil adapter.find_one(model: "user", where: [{field: "id", value: regex_user.fetch("id")}])
  end

  def test_normal_delete_many_does_not_treat_starts_or_ends_with_values_as_regex
    starts = create_user(name: ".*danger", email: "starts-regex@example.com")
    ends = create_user(name: "danger.*", email: "ends-regex@example.com")
    normal = create_user(name: "ordinary", email: "ordinary-regex@example.com")

    adapter.delete_many(model: "user", where: [{field: "name", value: ".*", operator: "starts_with"}])
    adapter.delete_many(model: "user", where: [{field: "name", value: ".*", operator: "ends_with"}])

    assert_nil adapter.find_one(model: "user", where: [{field: "id", value: starts.fetch("id")}])
    assert_nil adapter.find_one(model: "user", where: [{field: "id", value: ends.fetch("id")}])
    assert adapter.find_one(model: "user", where: [{field: "id", value: normal.fetch("id")}])
  end

  def test_normal_arrays_json_and_null_where_behavior
    reset_adapter(
      plugins: [{
        id: "typed-test",
        schema: {
          testModel: {
            fields: {
              stringArray: {type: "string[]", required: true},
              numberArray: {type: "number[]", required: true},
              json: {type: "json", required: true}
            }
          }
        }
      }]
    )
    record = adapter.create(model: "testModel", data: {stringArray: ["1", "2"], numberArray: [1, 2], json: {foo: "bar"}})
    with_null = create_user(image: nil)
    with_image = create_user(email: "image@example.com", image: "https://example.com/avatar.png")
    updated = adapter.update(model: "user", where: [{field: "id", value: with_null.fetch("id")}, {field: "image", operator: "eq", value: nil}], update: {name: "null-updated"})

    assert_equal record, adapter.find_one(model: "testModel", where: [{field: "id", value: record.fetch("id")}])
    assert_ids [with_null], adapter.find_many(model: "user", where: [{field: "image", operator: "eq", value: nil}])
    assert_ids [with_image], adapter.find_many(model: "user", where: [{field: "image", operator: "ne", value: nil}])
    assert_equal "null-updated", updated.fetch("name")
  end

  def test_normal_null_where_and_or_groups
    null_verified = create_user(email: "null-verified@example.com", image: nil)
    adapter.update(model: "user", where: [{field: "id", value: null_verified.fetch("id")}], update: {emailVerified: true})
    null_unverified = create_user(email: "null-unverified@example.com", image: nil)
    image_verified = create_user(email: "image-verified@example.com", image: "https://example.com/avatar.png")
    adapter.update(model: "user", where: [{field: "id", value: image_verified.fetch("id")}], update: {emailVerified: true})
    other_image = create_user(email: "other-image@example.com", image: "https://example.com/other.png")

    and_null = adapter.find_many(model: "user", where: [
      {field: "image", operator: "eq", value: nil, connector: "AND"},
      {field: "emailVerified", value: true, connector: "AND"}
    ])
    and_not_null = adapter.find_many(model: "user", where: [
      {field: "image", operator: "ne", value: nil, connector: "AND"},
      {field: "emailVerified", value: true, connector: "AND"}
    ])
    or_null = adapter.find_many(model: "user", where: [
      {field: "image", operator: "eq", value: nil, connector: "OR"},
      {field: "email", value: image_verified.fetch("email"), connector: "OR"}
    ])
    or_not_null = adapter.find_many(model: "user", where: [
      {field: "image", operator: "ne", value: nil, connector: "OR"},
      {field: "email", value: null_unverified.fetch("email"), connector: "OR"}
    ])

    assert_ids [null_verified], and_null
    assert_ids [image_verified], and_not_null
    assert_ids [null_verified, null_unverified, image_verified], or_null
    assert_ids [null_unverified, image_verified, other_image], or_not_null
  end

  def test_normal_update_supports_multiple_and_conditions_with_unique_field
    user = create_user(email: "and-update@example.com")

    updated = adapter.update(
      model: "user",
      where: [
        {field: "email", value: user.fetch("email")},
        {field: "id", value: user.fetch("id")}
      ],
      update: {name: "Updated Name"}
    )

    assert_equal user.fetch("id"), updated.fetch("id")
    assert_equal "Updated Name", updated.fetch("name")
  end

  def test_normal_missing_and_ambiguous_schema_joins_raise
    reset_adapter(
      plugins: [{
        id: "ambiguous-join-parity",
        schema: {
          ambiguousProfile: {
            fields: {
              primaryUserId: {type: "string", required: true, references: {model: "user", field: "id"}},
              secondaryUserId: {type: "string", required: true, references: {model: "user", field: "id"}}
            }
          },
          unrelatedProfile: {
            fields: {label: {type: "string", required: false}}
          }
        }
      }]
    )

    assert_raises(BetterAuth::Error) { adapter.find_one(model: "user", where: [{field: "id", value: next_id}], join: {unrelatedProfile: true}) }
    assert_raises(BetterAuth::Error) { adapter.find_one(model: "user", where: [{field: "id", value: next_id}], join: {ambiguousProfile: true}) }
  end

  def test_case_insensitive_suite
    keep = create_user(email: "Keep@Example.com")
    target = create_user(email: "TestUser@Example.COM", name: "prefixCONTAINSsuffix")

    assert_equal target.fetch("id"), adapter.find_one(model: "user", where: [{field: "email", value: "testuser@example.com", operator: "eq", mode: "insensitive"}]).fetch("id")
    assert_nil adapter.find_one(model: "user", where: [{field: "email", value: "testuser@example.com", operator: "eq", mode: "sensitive"}])
    assert_ids [keep], adapter.find_many(model: "user", where: [{field: "email", value: "testuser@example.com", operator: "ne", mode: "insensitive"}])
    assert_ids [target], adapter.find_many(model: "user", where: [{field: "email", value: ["other@test.com", "testuser@example.com"], operator: "in", mode: "insensitive"}])
    assert_ids [keep], adapter.find_many(model: "user", where: [{field: "email", value: ["testuser@example.com"], operator: "not_in", mode: "insensitive"}])
    assert_ids [target], adapter.find_many(model: "user", where: [{field: "name", value: "containssuffix", operator: "contains", mode: "insensitive"}])
    assert_ids [target], adapter.find_many(model: "user", where: [{field: "name", value: "prefix", operator: "starts_with", mode: "insensitive"}])
    assert_ids [target], adapter.find_many(model: "user", where: [{field: "name", value: "suffix", operator: "ends_with", mode: "insensitive"}])
    assert_equal 1, adapter.count(model: "user", where: [{field: "email", value: "testuser@example.com", operator: "eq", mode: "insensitive"}])

    updated = adapter.update(model: "user", where: [{field: "email", value: "testuser@example.com", operator: "eq", mode: "insensitive"}], update: {name: "AfterUpdate"})
    adapter.delete_many(model: "user", where: [{field: "email", value: "keep@example.com", operator: "eq", mode: "insensitive"}])

    assert_equal "AfterUpdate", updated.fetch("name")
    assert_nil adapter.find_one(model: "user", where: [{field: "id", value: keep.fetch("id")}])
  end

  def test_auth_flow_suite_with_fake_mongo_database
    auth = auth_with_database
    date_field = Time.now

    status, headers, body = auth.api.sign_up_email(
      body: {email: "auth-flow-parity@example.com", password: "password123", name: "Auth Flow", dateField: date_field.iso8601},
      as_response: true
    )
    payload = JSON.parse(body.join)
    sign_in = auth.api.sign_in_email(body: {email: "auth-flow-parity@example.com", password: "password123"})

    assert_equal 200, status
    assert_equal "auth-flow-parity@example.com", payload.fetch("user").fetch("email")
    assert_equal payload.fetch("user").fetch("id"), sign_in.fetch(:user).fetch("id")
    assert_raises(BetterAuth::APIError) { auth.api.sign_in_email(body: {email: "missing@example.com", password: "password123"}) }

    original_tz = ENV["TZ"]
    ENV["TZ"] = "Europe/London"
    london_session = auth.api.get_session(headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))})
    ENV["TZ"] = "America/Los_Angeles"
    pacific_session = auth.api.get_session(headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))})

    assert_equal london_session[:user]["createdAt"].iso8601, pacific_session[:user]["createdAt"].iso8601
    assert_equal date_field.to_i, london_session[:user]["dateField"].to_i
  ensure
    ENV["TZ"] = original_tz
  end

  def test_uuid_suite_init_create_find_and_normal_behavior
    reset_adapter(advanced: {database: {generate_id: "uuid"}})
    user = adapter.create(model: "user", data: user_data(id: nil, email: "uuid-suite@example.com"))
    session = adapter.create(model: "session", data: session_data(user_id: user.fetch("id"), id: nil))

    assert_match UUID_PATTERN, user.fetch("id")
    assert_equal user, adapter.find_one(model: "user", where: [{field: "id", value: user.fetch("id")}])
    assert_match UUID_PATTERN, session.fetch("id")
    assert_equal user.fetch("id"), session.fetch("userId")
  end

  def test_transaction_suite_rolls_back_failing_real_mongo_transaction
    client = FakeMongoClient.new
    transactional_adapter = BetterAuth::Adapters::MongoDB.new(configuration, database: database, client: client, transaction: true)

    assert_raises(RuntimeError) do
      transactional_adapter.transaction do |transaction_adapter|
        transaction_adapter.create(model: "user", data: user_data, force_allow_id: true)
        assert_equal 1, transaction_adapter.find_many(model: "user").length
        raise "Simulated failure"
      end
    end
    assert_equal 0, transactional_adapter.count(model: "user")
    assert_equal true, client.sessions.first.aborted
    assert_equal true, client.sessions.first.ended
  end

  private

  attr_reader :database, :adapter, :configuration

  def reset_adapter(**options)
    @database = FakeMongoDatabase.new
    @configuration = BetterAuth::Configuration.new({secret: SECRET, database: :memory}.merge(options))
    @adapter = BetterAuth::Adapters::MongoDB.new(configuration, database: database)
  end

  def auth_with_database
    database = @database
    BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: ->(options) { BetterAuth::Adapters::MongoDB.new(options, database: database, transaction: false) },
      email_and_password: {
        enabled: true,
        password: {
          hash: ->(password) { password },
          verify: ->(data) { data[:hash] == data[:password] || data["hash"] == data["password"] }
        }
      },
      user: {
        additional_fields: {
          dateField: {type: "date", required: false}
        }
      },
      session: {cookie_cache: {enabled: false}}
    )
  end

  def configure_one_to_one
    reset_adapter(
      plugins: [{
        id: "one-to-one-test",
        schema: {
          oneToOneTable: {
            fields: {
              oneToOne: {type: "string", required: true, references: {model: "user", field: "id"}, unique: true}
            }
          }
        }
      }]
    )
  end

  def configure_numeric_field
    reset_adapter(
      user: {
        additional_fields: {
          numericField: {type: "number", required: false}
        }
      }
    )
  end

  def collection(name)
    database.collection(name)
  end

  def create_user(email: nil, name: nil, created_at: nil, image: "image", numeric_field: nil)
    adapter.create(
      model: "user",
      data: user_data(email: email, name: name, created_at: created_at, image: image, numeric_field: numeric_field),
      force_allow_id: true
    )
  end

  def create_session(user, token: nil)
    adapter.create(model: "session", data: session_data(user_id: user.fetch("id"), token: token), force_allow_id: true)
  end

  def create_account(user, provider_id: "github")
    adapter.create(
      model: "account",
      data: {
        id: next_id,
        userId: user.fetch("id"),
        providerId: provider_id,
        accountId: "#{provider_id}-#{next_id}",
        createdAt: Time.now,
        updatedAt: Time.now
      },
      force_allow_id: true
    )
  end

  def user_data(id: next_id, email: nil, name: nil, created_at: nil, image: "image", numeric_field: nil)
    data = {
      id: id,
      name: name || "User #{id || "generated"}",
      email: email || "user-#{id || SecureRandom.hex(4)}@email.com",
      emailVerified: false,
      image: image,
      createdAt: created_at || Time.now,
      updatedAt: Time.now
    }
    data[:numericField] = numeric_field unless numeric_field.nil?
    data
  end

  def session_data(user_id:, id: next_id, token: nil)
    {
      id: id,
      userId: user_id,
      token: token || "token-#{id || SecureRandom.hex(4)}",
      expiresAt: Time.now + 3600,
      createdAt: Time.now,
      updatedAt: Time.now
    }
  end

  def next_id
    BSON::ObjectId.new.to_s
  end

  def assert_ids(expected, actual)
    assert_equal expected.map { |entry| entry.fetch("id") }.sort, actual.map { |entry| entry.fetch("id") }.sort
  end

  def cookie_header(set_cookie)
    set_cookie.lines.map { |line| line.split(";").first }.join("; ")
  end
end
