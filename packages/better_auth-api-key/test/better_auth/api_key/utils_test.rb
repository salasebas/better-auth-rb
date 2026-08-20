# frozen_string_literal: true

require_relative "test_support"

class BetterAuthAPIKeyUtilsTest < Minitest::Test
  def test_json_helpers_preserve_object_metadata_contract
    encoded = BetterAuth::APIKey::Utils.encode_json({plan: "pro"})

    assert_equal({"plan" => "pro"}, BetterAuth::APIKey::Utils.decode_json(encoded))
    assert_nil BetterAuth::APIKey::Utils.decode_json(nil)
    assert_nil BetterAuth::APIKey::Utils.decode_json("not json")
  end

  def test_normalize_time_accepts_time_and_parseable_strings
    now = Time.now

    assert_same now, BetterAuth::APIKey::Utils.normalize_time(now)
    assert_instance_of Time, BetterAuth::APIKey::Utils.normalize_time(now.iso8601)
    assert_nil BetterAuth::APIKey::Utils.normalize_time("not a time")
  end

  def test_public_record_hides_secret_key_and_decodes_json_fields
    now = Time.now
    record = {
      "id" => "key-id",
      "configId" => "default",
      "name" => nil,
      "start" => "test_",
      "prefix" => "test_",
      "key" => "hashed-secret",
      "userId" => "user-id",
      "refillInterval" => nil,
      "refillAmount" => nil,
      "lastRefillAt" => nil,
      "enabled" => true,
      "rateLimitEnabled" => true,
      "rateLimitTimeWindow" => 60_000,
      "rateLimitMax" => 10,
      "requestCount" => 0,
      "remaining" => nil,
      "lastRequest" => nil,
      "expiresAt" => nil,
      "createdAt" => now,
      "updatedAt" => now,
      "metadata" => JSON.generate({"tier" => "pro"}),
      "permissions" => JSON.generate({"repo" => ["read"]})
    }

    hidden = BetterAuth::APIKey::Utils.public_record(record)
    revealed = BetterAuth::APIKey::Utils.public_record(record, reveal_key: "raw-secret", include_key_field: true)

    refute hidden.key?(:key)
    refute hidden.key?(:userId)
    refute revealed.key?(:userId)
    assert_equal "raw-secret", revealed.fetch(:key)
    assert_equal({"tier" => "pro"}, hidden.fetch(:metadata))
    assert_equal({"repo" => ["read"]}, hidden.fetch(:permissions))
    assert_equal "user-id", hidden.fetch(:referenceId)
    assert_equal "default", hidden.fetch(:configId)
    assert_equal %i[
      configId
      createdAt
      enabled
      expiresAt
      id
      lastRefillAt
      lastRequest
      metadata
      name
      permissions
      prefix
      rateLimitEnabled
      rateLimitMax
      rateLimitTimeWindow
      referenceId
      refillAmount
      refillInterval
      remaining
      requestCount
      start
      updatedAt
    ].sort, hidden.keys.sort
  end

  def test_sort_records_supports_camel_case_and_descending_direction
    records = [
      {"name" => "second", "createdAt" => Time.now + 1},
      {"name" => "first", "createdAt" => Time.now}
    ]

    by_name = BetterAuth::APIKey::Utils.sort_records(records, "name", "asc")
    by_created_desc = BetterAuth::APIKey::Utils.sort_records(records, "createdAt", "desc")

    assert_equal %w[first second], by_name.map { |record| record.fetch("name") }
    assert_equal %w[second first], by_created_desc.map { |record| record.fetch("name") }
  end

  def test_validate_list_query_accepts_numeric_strings_and_rejects_invalid_values
    BetterAuth::APIKey::Utils.validate_list_query!(limit: "10", offset: "0", sort_direction: "desc")

    assert_raises(BetterAuth::APIError) do
      BetterAuth::APIKey::Utils.validate_list_query!(limit: "-1")
    end
    assert_raises(BetterAuth::APIError) do
      BetterAuth::APIKey::Utils.validate_list_query!(sort_direction: "sideways")
    end
  end

  def test_error_payload_preserves_details_and_maps_error_codes
    detailed = BetterAuth::APIError.new(
      "UNAUTHORIZED",
      message: BetterAuth::APIKey::ERROR_CODES.fetch("RATE_LIMIT_EXCEEDED"),
      code: "RATE_LIMITED",
      body: {
        message: BetterAuth::APIKey::ERROR_CODES.fetch("RATE_LIMIT_EXCEEDED"),
        code: "RATE_LIMITED",
        details: {tryAgainIn: 1000}
      }
    )
    simple = BetterAuth::APIError.new("UNAUTHORIZED", message: BetterAuth::APIKey::ERROR_CODES.fetch("INVALID_API_KEY"))

    assert_equal({message: BetterAuth::APIKey::ERROR_CODES.fetch("RATE_LIMIT_EXCEEDED"), code: "RATE_LIMITED", details: {tryAgainIn: 1000}},
      BetterAuth::APIKey::Utils.error_payload(detailed))
    assert_equal({message: BetterAuth::APIKey::ERROR_CODES.fetch("INVALID_API_KEY"), code: "INVALID_API_KEY"},
      BetterAuth::APIKey::Utils.error_payload(simple))
  end
end
