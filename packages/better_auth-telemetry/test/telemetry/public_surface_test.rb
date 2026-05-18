# frozen_string_literal: true

require_relative "../test_helper"

# Verifies that requiring the canonical entry point
# (`require "better_auth/telemetry"`) is sufficient to expose every
# documented constant and method on the public surface
# (Requirements 1.5, 15.1, 15.2, 15.3).
#
# The test deliberately re-requires the entry point so it remains
# self-contained even though `test_helper.rb` already loads it.
class PublicSurfaceTest < Minitest::Test
  def setup
    require "better_auth/telemetry"
  end

  def test_version_constant_is_defined_and_a_string
    assert defined?(BetterAuth::Telemetry::VERSION), "BetterAuth::Telemetry::VERSION must be defined"
    assert_kind_of String, BetterAuth::Telemetry::VERSION
    refute_empty BetterAuth::Telemetry::VERSION
  end

  def test_create_module_method_is_exposed
    assert_respond_to BetterAuth::Telemetry, :create
  end

  def test_project_id_module_method_is_exposed
    assert_respond_to BetterAuth::Telemetry, :project_id
  end

  def test_reset_project_id_bang_module_method_is_exposed
    assert_respond_to BetterAuth::Telemetry, :reset_project_id!
  end

  def test_publisher_class_is_defined
    assert defined?(BetterAuth::Telemetry::Publisher), "BetterAuth::Telemetry::Publisher must be defined"
    assert_kind_of Class, BetterAuth::Telemetry::Publisher
  end

  def test_noop_publisher_class_is_defined
    assert defined?(BetterAuth::Telemetry::NoopPublisher), "BetterAuth::Telemetry::NoopPublisher must be defined"
    assert_kind_of Class, BetterAuth::Telemetry::NoopPublisher
  end

  def test_detector_modules_are_defined
    %i[Runtime Environment SystemInfo Database Framework ProjectInfo AuthConfig].each do |name|
      assert BetterAuth::Telemetry::Detectors.const_defined?(name),
        "BetterAuth::Telemetry::Detectors::#{name} must be defined"
      detector = BetterAuth::Telemetry::Detectors.const_get(name)
      assert_kind_of Module, detector
    end
  end

  def test_supporting_constants_are_defined
    assert defined?(BetterAuth::Telemetry::CurrentOptions),
      "BetterAuth::Telemetry::CurrentOptions must be defined"
    assert_kind_of Module, BetterAuth::Telemetry::CurrentOptions

    assert defined?(BetterAuth::Telemetry::HttpClient),
      "BetterAuth::Telemetry::HttpClient must be defined"
    assert_kind_of Module, BetterAuth::Telemetry::HttpClient

    assert defined?(BetterAuth::Telemetry::LoggerAdapter),
      "BetterAuth::Telemetry::LoggerAdapter must be defined"
    assert_kind_of Class, BetterAuth::Telemetry::LoggerAdapter

    assert defined?(BetterAuth::Telemetry::NormalizedOptions),
      "BetterAuth::Telemetry::NormalizedOptions must be defined"
    assert_kind_of Class, BetterAuth::Telemetry::NormalizedOptions

    assert defined?(BetterAuth::Telemetry::NormalizedContext),
      "BetterAuth::Telemetry::NormalizedContext must be defined"
    assert_kind_of Class, BetterAuth::Telemetry::NormalizedContext

    assert defined?(BetterAuth::Telemetry::Env),
      "BetterAuth::Telemetry::Env must be defined"
    assert_kind_of Module, BetterAuth::Telemetry::Env
  end
end
