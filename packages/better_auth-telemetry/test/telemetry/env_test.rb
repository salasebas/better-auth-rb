# frozen_string_literal: true

require_relative "../test_helper"
require "better_auth/telemetry/env"
require_relative "support/env_helpers"

class TelemetryEnvTest < Minitest::Test
  include BetterAuth::Telemetry::Test::EnvHelpers

  Env = BetterAuth::Telemetry::Env

  # ---------------------------------------------------------------------
  # Env.truthy? — covers nil, empty, "0", "false"/"FALSE", "1", and a
  # representative arbitrary non-empty string.
  # ---------------------------------------------------------------------

  def test_truthy_returns_false_for_nil
    refute Env.truthy?(nil)
  end

  def test_truthy_returns_false_for_empty_string
    refute Env.truthy?("")
  end

  def test_truthy_returns_false_for_zero_string
    refute Env.truthy?("0")
  end

  def test_truthy_returns_false_for_lowercase_false
    refute Env.truthy?("false")
  end

  def test_truthy_returns_false_for_uppercase_false
    refute Env.truthy?("FALSE")
  end

  def test_truthy_returns_false_for_mixed_case_false
    refute Env.truthy?("False")
    refute Env.truthy?("FaLsE")
  end

  def test_truthy_returns_true_for_one_string
    assert Env.truthy?("1")
  end

  def test_truthy_returns_true_for_arbitrary_non_empty_string
    assert Env.truthy?("yes")
    assert Env.truthy?("on")
    assert Env.truthy?("true")
  end

  def test_truthy_returns_true_for_string_starting_with_zero_but_longer
    # "00" is non-empty, not the literal "0", and not "false" — truthy.
    assert Env.truthy?("00")
  end

  def test_truthy_coerces_non_string_input_via_to_s
    # Booleans / integers should classify under the same rules once
    # coerced — `true.to_s == "true"` (truthy), `false.to_s == "false"`
    # (falsy via the case-insensitive rule), `0.to_s == "0"` (falsy).
    assert Env.truthy?(true)
    refute Env.truthy?(false)
    refute Env.truthy?(0)
    assert Env.truthy?(1)
  end

  # ---------------------------------------------------------------------
  # Env.get — verifies dual-prefix delegation by setting OPEN_AUTH_* vs
  # BETTER_AUTH_*. The OPEN_AUTH_ variant takes precedence when set and
  # non-empty; otherwise the BETTER_AUTH_ variant is returned.
  # ---------------------------------------------------------------------

  def test_get_returns_nil_when_neither_variant_is_set
    with_env(
      "OPEN_AUTH_TELEMETRY" => nil,
      "BETTER_AUTH_TELEMETRY" => nil
    ) do
      assert_nil Env.get("BETTER_AUTH_TELEMETRY")
    end
  end

  def test_get_falls_back_to_better_auth_when_open_auth_is_unset
    with_env(
      "OPEN_AUTH_TELEMETRY" => nil,
      "BETTER_AUTH_TELEMETRY" => "1"
    ) do
      assert_equal "1", Env.get("BETTER_AUTH_TELEMETRY")
    end
  end

  def test_get_prefers_open_auth_over_better_auth_when_both_set
    with_env(
      "OPEN_AUTH_TELEMETRY" => "from-open-auth",
      "BETTER_AUTH_TELEMETRY" => "from-better-auth"
    ) do
      assert_equal "from-open-auth", Env.get("BETTER_AUTH_TELEMETRY")
    end
  end

  def test_get_returns_open_auth_value_when_only_open_auth_is_set
    with_env(
      "OPEN_AUTH_TELEMETRY" => "open-auth-only",
      "BETTER_AUTH_TELEMETRY" => nil
    ) do
      assert_equal "open-auth-only", Env.get("BETTER_AUTH_TELEMETRY")
    end
  end

  def test_get_treats_empty_open_auth_as_unset_and_falls_back
    # `BetterAuth::Env.get` skips empty values when deciding whether the
    # OPEN_AUTH_* alias is "present"; an empty string in OPEN_AUTH_*
    # therefore falls through to BETTER_AUTH_*.
    with_env(
      "OPEN_AUTH_TELEMETRY" => "",
      "BETTER_AUTH_TELEMETRY" => "from-better-auth"
    ) do
      assert_equal "from-better-auth", Env.get("BETTER_AUTH_TELEMETRY")
    end
  end

  def test_get_works_for_all_three_documented_telemetry_variables
    with_env(
      "OPEN_AUTH_TELEMETRY" => "1",
      "BETTER_AUTH_TELEMETRY" => "0",
      "OPEN_AUTH_TELEMETRY_DEBUG" => nil,
      "BETTER_AUTH_TELEMETRY_DEBUG" => "true",
      "OPEN_AUTH_TELEMETRY_ENDPOINT" => "https://open-auth.example",
      "BETTER_AUTH_TELEMETRY_ENDPOINT" => "https://better-auth.example"
    ) do
      assert_equal "1", Env.get("BETTER_AUTH_TELEMETRY")
      assert_equal "true", Env.get("BETTER_AUTH_TELEMETRY_DEBUG")
      assert_equal "https://open-auth.example", Env.get("BETTER_AUTH_TELEMETRY_ENDPOINT")
    end
  end

  # ---------------------------------------------------------------------
  # Env.get + Env.truthy? — composed behavior matches the upstream
  # `getBooleanEnvVar` semantics that the rest of the pipeline relies on.
  # ---------------------------------------------------------------------

  def test_get_then_truthy_classifies_unset_as_falsy
    with_env(
      "OPEN_AUTH_TELEMETRY" => nil,
      "BETTER_AUTH_TELEMETRY" => nil
    ) do
      refute Env.truthy?(Env.get("BETTER_AUTH_TELEMETRY"))
    end
  end

  def test_get_then_truthy_classifies_zero_as_falsy
    with_env(
      "OPEN_AUTH_TELEMETRY" => nil,
      "BETTER_AUTH_TELEMETRY" => "0"
    ) do
      refute Env.truthy?(Env.get("BETTER_AUTH_TELEMETRY"))
    end
  end

  def test_get_then_truthy_classifies_false_as_falsy
    with_env(
      "OPEN_AUTH_TELEMETRY" => "FALSE",
      "BETTER_AUTH_TELEMETRY" => nil
    ) do
      refute Env.truthy?(Env.get("BETTER_AUTH_TELEMETRY"))
    end
  end

  def test_get_then_truthy_classifies_one_as_truthy
    with_env(
      "OPEN_AUTH_TELEMETRY" => nil,
      "BETTER_AUTH_TELEMETRY" => "1"
    ) do
      assert Env.truthy?(Env.get("BETTER_AUTH_TELEMETRY"))
    end
  end
end
