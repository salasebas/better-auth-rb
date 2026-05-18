# frozen_string_literal: true

require "openauth"
require "better_auth/telemetry"

module OpenAuth
  Telemetry = BetterAuth::Telemetry unless const_defined?(:Telemetry, false)
  alias_better_auth_constants!
end
