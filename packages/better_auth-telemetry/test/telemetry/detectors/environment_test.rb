# frozen_string_literal: true

require_relative "../../test_helper"
require "better_auth/telemetry/detectors/environment"
require_relative "../support/env_helpers"

class EnvironmentDetectorTest < Minitest::Test
  include BetterAuth::Telemetry::Test::EnvHelpers

  Environment = BetterAuth::Telemetry::Detectors::Environment

  # All env variables the classifier inspects. Tests that need a clean
  # slate snapshot every one of these so a CI build (which exports `CI`
  # and friends) cannot bleed into the assertion.
  ALL_VARS = (Environment::TEST_VARS + Environment::CI_VARS).freeze

  def clean_env_overrides(extra = {})
    base = ALL_VARS.each_with_object({}) { |key, acc| acc[key] = nil }
    base.merge(extra.transform_keys(&:to_s))
  end

  # ---------------------------------------------------------------------
  # Precedence: production > ci > test > development.
  # ---------------------------------------------------------------------

  def test_returns_development_when_no_marker_is_set
    with_env(clean_env_overrides) do
      assert_equal "development", Environment.call
    end
  end

  def test_returns_test_when_only_rack_env_is_test
    with_env(clean_env_overrides("RACK_ENV" => "test")) do
      assert_equal "test", Environment.call
    end
  end

  def test_returns_test_when_only_rails_env_is_test
    with_env(clean_env_overrides("RAILS_ENV" => "test")) do
      assert_equal "test", Environment.call
    end
  end

  def test_returns_test_when_only_app_env_is_test
    with_env(clean_env_overrides("APP_ENV" => "test")) do
      assert_equal "test", Environment.call
    end
  end

  def test_ci_wins_over_test
    with_env(clean_env_overrides("RAILS_ENV" => "test", "CI" => "true")) do
      assert_equal "ci", Environment.call
    end
  end

  def test_production_wins_over_ci_and_test
    with_env(clean_env_overrides(
      "RAILS_ENV" => "production",
      "CI" => "true",
      "RACK_ENV" => "test"
    )) do
      assert_equal "production", Environment.call
    end
  end

  def test_production_wins_when_only_app_env_is_production
    with_env(clean_env_overrides("APP_ENV" => "production")) do
      assert_equal "production", Environment.call
    end
  end

  # ---------------------------------------------------------------------
  # CI marker handling: empty + case-insensitive "false" are treated as
  # unset.
  # ---------------------------------------------------------------------

  def test_empty_ci_marker_is_treated_as_unset
    with_env(clean_env_overrides("CI" => "")) do
      assert_equal "development", Environment.call
    end
  end

  def test_lowercase_false_ci_marker_is_treated_as_unset
    with_env(clean_env_overrides("CI" => "false")) do
      assert_equal "development", Environment.call
    end
  end

  def test_uppercase_false_ci_marker_is_treated_as_unset
    with_env(clean_env_overrides("CI" => "FALSE")) do
      assert_equal "development", Environment.call
    end
  end

  def test_mixed_case_false_ci_marker_is_treated_as_unset
    with_env(clean_env_overrides("CI" => "False")) do
      assert_equal "development", Environment.call
    end
  end

  def test_explicit_false_ci_marker_does_not_outrank_test_env
    with_env(clean_env_overrides("CI" => "false", "RAILS_ENV" => "test")) do
      assert_equal "test", Environment.call
    end
  end

  def test_any_ci_marker_flips_to_ci
    Environment::CI_VARS.each do |marker|
      with_env(clean_env_overrides(marker => "1")) do
        assert_equal "ci", Environment.call, "expected #{marker}=1 to classify as ci"
      end
    end
  end

  def test_arbitrary_non_false_value_flips_to_ci
    with_env(clean_env_overrides("BUILD_ID" => "1234")) do
      assert_equal "ci", Environment.call
    end
  end
end
