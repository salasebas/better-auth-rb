# frozen_string_literal: true

require_relative "../test_helper"

# Verifies that the soft-load probe shim
# (`packages/better_auth-telemetry/lib/better_auth/plugins/telemetry.rb`)
# is requirable on its own and exposes the public telemetry surface.
#
# `BetterAuth::Auth#initialize` performs a
# `require "better_auth/plugins/telemetry"` to detect whether the
# telemetry gem is bundled, so this file must be reachable on the load
# path and must transitively load `BetterAuth::Telemetry.create`.
#
# Implements Requirements 16.1 and 16.2.
class PluginsShimTest < Minitest::Test
  def test_requiring_the_shim_exposes_create
    require "better_auth/plugins/telemetry"

    assert BetterAuth::Telemetry.respond_to?(:create),
      "BetterAuth::Telemetry must respond to :create after requiring the shim"
  end
end
