# frozen_string_literal: true

require_relative "../../test_helper"
require "better_auth"
require "better_auth/telemetry/detectors/auth_config"

class AuthConfigHelpersTest < Minitest::Test
  AuthConfig = BetterAuth::Telemetry::Detectors::AuthConfig

  # The matrix of representative inputs the task lists explicitly for
  # the redaction primitive helpers. Each entry is `[label, value]`
  # so test failures point at the input shape, not the value.
  PRIMITIVE_INPUTS = [
    ["nil", nil],
    ["empty string", ""],
    ["non-empty string", "x"],
    ["true", true],
    ["false", false],
    ["zero integer", 0]
  ].freeze

  # Build a {BetterAuth::Configuration} with the minimum keys needed
  # for instantiation plus any optional overrides. Used by the
  # `fetch_path` Configuration tests below.
  def configuration_with(extra = {})
    BetterAuth::Configuration.new({secret: "0" * 40}.merge(extra))
  end

  # ---------------------------------------------------------------------
  # bool
  # ---------------------------------------------------------------------

  def test_bool_returns_strict_boolean_for_each_listed_input
    expectations = {
      nil => false,
      "" => true,
      "x" => true,
      true => true,
      false => false,
      0 => true # only nil and false are falsey in Ruby
    }

    expectations.each do |input, expected|
      result = AuthConfig.bool(input)
      assert_equal expected, result, "bool(#{input.inspect}) should be #{expected.inspect}"
      assert_includes [true, false], result, "bool(#{input.inspect}) must be a Boolean"
    end
  end

  # ---------------------------------------------------------------------
  # raw
  # ---------------------------------------------------------------------

  def test_raw_returns_the_input_verbatim
    PRIMITIVE_INPUTS.each do |label, value|
      result = AuthConfig.raw(value)
      if value.nil?
        assert_nil result, "raw(#{label}) should pass through nil verbatim"
      else
        assert_equal value, result, "raw(#{label}) should pass through the value verbatim"
      end
      assert_same value, AuthConfig.raw(value) unless value.nil? || value == false || value == true || value.is_a?(Integer)
    end
  end

  def test_raw_returns_complex_objects_without_copying
    array = [1, 2, 3]
    hash = {a: 1}

    assert_same array, AuthConfig.raw(array)
    assert_same hash, AuthConfig.raw(hash)
  end

  # ---------------------------------------------------------------------
  # bool_present
  # ---------------------------------------------------------------------

  def test_bool_present_returns_false_for_nil_empty_string_and_false
    [nil, "", false].each do |input|
      refute AuthConfig.bool_present(input), "bool_present(#{input.inspect}) should be false"
    end
  end

  def test_bool_present_returns_true_for_truthy_or_present_inputs
    ["x", true, 0].each do |input|
      assert AuthConfig.bool_present(input), "bool_present(#{input.inspect}) should be true"
    end
  end

  def test_bool_present_always_returns_a_boolean
    PRIMITIVE_INPUTS.each do |label, value|
      result = AuthConfig.bool_present(value)
      assert_includes [true, false], result, "bool_present(#{label}) must be a Boolean"
    end
  end

  # ---------------------------------------------------------------------
  # count
  # ---------------------------------------------------------------------

  def test_count_returns_zero_for_nil
    assert_equal 0, AuthConfig.count(nil)
  end

  def test_count_returns_zero_for_empty_array
    assert_equal 0, AuthConfig.count([])
  end

  def test_count_returns_length_for_populated_array
    assert_equal 3, AuthConfig.count([1, 2, 3])
  end

  def test_count_counts_nils_inside_an_array
    # Array#length includes nil entries; we don't compact here.
    assert_equal 1, AuthConfig.count([nil])
  end

  # ---------------------------------------------------------------------
  # fetch_path: raw hash
  # ---------------------------------------------------------------------

  def test_fetch_path_descends_into_a_hash_with_symbol_keys
    opts = {email_verification: {send_verification_email: :sentinel}}

    assert_equal :sentinel, AuthConfig.fetch_path(opts, [:email_verification, :send_verification_email])
  end

  def test_fetch_path_descends_into_a_hash_with_string_keys
    opts = {"email_verification" => {"send_verification_email" => :sentinel}}

    assert_equal :sentinel, AuthConfig.fetch_path(opts, [:email_verification, :send_verification_email])
  end

  def test_fetch_path_descends_into_a_hash_with_mixed_symbol_and_string_keys
    opts = {"email_verification" => {send_verification_email: :sentinel}}

    assert_equal :sentinel, AuthConfig.fetch_path(opts, [:email_verification, :send_verification_email])
  end

  def test_fetch_path_returns_nil_for_a_missing_root_key
    assert_nil AuthConfig.fetch_path({}, [:email_verification, :send_verification_email])
  end

  def test_fetch_path_returns_nil_for_a_missing_leaf_key
    opts = {email_verification: {}}

    assert_nil AuthConfig.fetch_path(opts, [:email_verification, :send_verification_email])
  end

  def test_fetch_path_returns_nil_when_intermediate_value_is_not_a_hash
    opts = {email_verification: "scalar"}

    assert_nil AuthConfig.fetch_path(opts, [:email_verification, :send_verification_email])
  end

  def test_fetch_path_returns_nil_for_a_nil_source
    assert_nil AuthConfig.fetch_path(nil, [:email_verification])
  end

  def test_fetch_path_returns_nil_for_an_empty_path
    assert_nil AuthConfig.fetch_path({a: 1}, [])
  end

  def test_fetch_path_returns_root_value_when_path_has_one_segment
    opts = {database: :memory}

    assert_equal :memory, AuthConfig.fetch_path(opts, [:database])
  end

  # ---------------------------------------------------------------------
  # fetch_path: BetterAuth::Configuration instance
  # ---------------------------------------------------------------------

  def test_fetch_path_calls_snake_case_reader_on_configuration
    configuration = configuration_with(database: :memory)

    assert_equal :memory, AuthConfig.fetch_path(configuration, [:database])
  end

  def test_fetch_path_descends_into_nested_configuration_hash
    configuration = configuration_with(email_verification: {expires_in: 3600})

    assert_equal 3600, AuthConfig.fetch_path(configuration, [:email_verification, :expires_in])
  end

  def test_fetch_path_descends_into_nested_configuration_hash_with_callable_leaf
    callable = -> {}
    configuration = configuration_with(email_verification: {send_verification_email: callable})

    assert_same callable, AuthConfig.fetch_path(configuration, [:email_verification, :send_verification_email])
  end

  def test_fetch_path_returns_nil_when_configuration_does_not_respond_to_root_segment
    configuration = configuration_with

    assert_nil AuthConfig.fetch_path(configuration, [:not_a_real_reader])
  end

  def test_fetch_path_returns_nil_when_nested_key_missing_on_configuration
    configuration = configuration_with(email_verification: {})

    assert_nil AuthConfig.fetch_path(configuration, [:email_verification, :send_verification_email])
  end

  def test_fetch_path_returns_nil_when_configuration_reader_value_is_not_a_hash
    # `password_hasher` is a symbol on Configuration, not a hash; descending past it should yield nil.
    configuration = configuration_with

    assert_nil AuthConfig.fetch_path(configuration, [:password_hasher, :anything])
  end

  def test_fetch_path_does_not_propagate_errors_from_a_misbehaving_source
    bad_source = Object.new
    def bad_source.is_a?(_klass)
      raise "boom"
    end

    assert_nil AuthConfig.fetch_path(bad_source, [:database])
  end
end
