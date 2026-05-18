# frozen_string_literal: true

require "test_helper"

class OpenAuthTelemetryTest < Minitest::Test
  def test_alias_constant_points_to_canonical_module
    assert_equal BetterAuth::Telemetry, OpenAuth::Telemetry
  end

  def test_alias_exposes_create_method
    assert_respond_to OpenAuth::Telemetry, :create
  end
end
