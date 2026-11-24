# frozen_string_literal: true

require_relative "test_support"

class BetterAuthAPIKeyConfigurationTest < Minitest::Test
  def test_single_configuration_applies_upstream_defaults
    config = BetterAuth::APIKey::Configuration.normalize({})

    assert_equal "default", config[:config_id]
    assert_equal "x-api-key", config[:api_key_headers]
    assert_equal 64, config[:default_key_length]
    assert_equal true, config[:rate_limit][:enabled]
    assert_equal 86_400_000, config[:rate_limit][:time_window]
    assert_equal 10, config[:rate_limit][:max_requests]
    assert_equal "user", config[:references]
  end

  def test_multiple_configuration_validation_matches_upstream
    assert_raises(BetterAuth::Error) do
      BetterAuth::APIKey::Configuration.normalize([{config_id: "duplicate"}, {config_id: "duplicate"}])
    end

    assert_raises(BetterAuth::Error) do
      BetterAuth::APIKey::Configuration.normalize([{config_id: "valid"}, {}])
    end
  end
end
