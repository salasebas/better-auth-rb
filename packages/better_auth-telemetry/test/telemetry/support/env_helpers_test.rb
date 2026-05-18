# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "env_helpers"

class EnvHelpersTest < Minitest::Test
  EnvHelpers = BetterAuth::Telemetry::Test::EnvHelpers

  KEY_PRESENT = "BETTER_AUTH_TELEMETRY_TEST_PRESENT"
  KEY_ABSENT = "BETTER_AUTH_TELEMETRY_TEST_ABSENT"
  KEY_OTHER = "BETTER_AUTH_TELEMETRY_TEST_OTHER"

  def setup
    @prior_present = ENV[KEY_PRESENT]
    @prior_absent = ENV[KEY_ABSENT]
    @prior_other = ENV[KEY_OTHER]

    ENV[KEY_PRESENT] = "original"
    ENV.delete(KEY_ABSENT)
    ENV.delete(KEY_OTHER)
  end

  def teardown
    ENV[KEY_PRESENT] = @prior_present
    ENV[KEY_ABSENT] = @prior_absent
    ENV[KEY_OTHER] = @prior_other
  end

  def test_overrides_apply_inside_block
    EnvHelpers.with_env(KEY_PRESENT => "patched", KEY_ABSENT => "added") do
      assert_equal "patched", ENV[KEY_PRESENT]
      assert_equal "added", ENV[KEY_ABSENT]
    end
  end

  def test_restores_previously_set_value_after_block
    EnvHelpers.with_env(KEY_PRESENT => "patched") {}

    assert_equal "original", ENV[KEY_PRESENT]
  end

  def test_deletes_key_that_was_originally_absent_after_block
    EnvHelpers.with_env(KEY_ABSENT => "added") {}

    assert_nil ENV[KEY_ABSENT]
    refute ENV.key?(KEY_ABSENT)
  end

  def test_nil_override_deletes_key_for_duration_of_block
    EnvHelpers.with_env(KEY_PRESENT => nil) do
      assert_nil ENV[KEY_PRESENT]
      refute ENV.key?(KEY_PRESENT)
    end

    assert_equal "original", ENV[KEY_PRESENT]
  end

  def test_nil_override_on_absent_key_is_noop
    EnvHelpers.with_env(KEY_ABSENT => nil) do
      assert_nil ENV[KEY_ABSENT]
    end

    assert_nil ENV[KEY_ABSENT]
  end

  def test_restores_env_when_block_raises
    boom = Class.new(StandardError)

    assert_raises(boom) do
      EnvHelpers.with_env(KEY_PRESENT => "patched", KEY_ABSENT => "added") do
        assert_equal "patched", ENV[KEY_PRESENT]
        assert_equal "added", ENV[KEY_ABSENT]
        raise boom, "kaboom"
      end
    end

    assert_equal "original", ENV[KEY_PRESENT]
    assert_nil ENV[KEY_ABSENT]
    refute ENV.key?(KEY_ABSENT)
  end

  def test_restores_env_when_block_throws
    catch(:done) do
      EnvHelpers.with_env(KEY_PRESENT => "patched") do
        throw :done
      end
    end

    assert_equal "original", ENV[KEY_PRESENT]
  end

  def test_only_listed_keys_are_touched
    ENV[KEY_OTHER] = "untouched"

    EnvHelpers.with_env(KEY_PRESENT => "patched") do
      assert_equal "untouched", ENV[KEY_OTHER]
    end

    assert_equal "untouched", ENV[KEY_OTHER]
  ensure
    ENV.delete(KEY_OTHER)
  end

  def test_returns_block_value
    result = EnvHelpers.with_env(KEY_PRESENT => "patched") { 42 }

    assert_equal 42, result
  end

  def test_non_string_values_are_coerced_via_to_s
    EnvHelpers.with_env(KEY_PRESENT => 7) do
      assert_equal "7", ENV[KEY_PRESENT]
    end
  end

  def test_can_be_included_as_a_minitest_helper
    test_class = Class.new do
      include EnvHelpers
    end
    instance = test_class.new

    captured = nil
    instance.with_env(KEY_PRESENT => "from-include") { captured = ENV[KEY_PRESENT] }

    assert_equal "from-include", captured
    assert_equal "original", ENV[KEY_PRESENT]
  end

  def test_requires_a_block
    assert_raises(ArgumentError) { EnvHelpers.with_env(KEY_PRESENT => "x") }
  end

  def test_requires_hash_overrides
    assert_raises(ArgumentError) { EnvHelpers.with_env([[KEY_PRESENT, "x"]]) {} }
  end

  def test_rejects_non_string_keys
    assert_raises(ArgumentError) { EnvHelpers.with_env(KEY_PRESENT.to_sym => "x") {} }
  end
end

class TelemetryResetProjectIdTest < Minitest::Test
  def test_reset_project_id_returns_nil
    assert_nil BetterAuth::Telemetry.reset_project_id!
  end

  def test_reset_project_id_clears_instance_variable
    BetterAuth::Telemetry.instance_variable_set(:@project_id_cache, "cached-id")

    BetterAuth::Telemetry.reset_project_id!

    assert_nil BetterAuth::Telemetry.instance_variable_get(:@project_id_cache)
  end

  def test_reset_project_id_is_idempotent
    BetterAuth::Telemetry.reset_project_id!
    BetterAuth::Telemetry.reset_project_id!

    assert_nil BetterAuth::Telemetry.instance_variable_get(:@project_id_cache)
  end
end
