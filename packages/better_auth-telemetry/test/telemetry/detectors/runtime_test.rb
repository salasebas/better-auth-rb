# frozen_string_literal: true

require_relative "../../test_helper"
require "better_auth/telemetry/detectors/runtime"

class RuntimeDetectorTest < Minitest::Test
  Runtime = BetterAuth::Telemetry::Detectors::Runtime

  def test_returns_exact_key_set
    result = Runtime.call

    assert_kind_of Hash, result
    assert_equal [:engine, :name, :version], result.keys.sort
  end

  def test_name_is_literal_ruby_string
    assert_equal "ruby", Runtime.call[:name]
  end

  def test_version_matches_ruby_version_constant
    assert_equal RUBY_VERSION, Runtime.call[:version]
  end

  def test_engine_matches_ruby_engine_constant_on_host
    expected = defined?(RUBY_ENGINE) ? RUBY_ENGINE : "ruby"

    assert_equal expected, Runtime.call[:engine]
  end

  def test_engine_is_a_string
    assert_kind_of String, Runtime.call[:engine]
  end
end
