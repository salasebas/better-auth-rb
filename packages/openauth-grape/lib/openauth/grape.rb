# frozen_string_literal: true

require "openauth"
require "better_auth/grape"

module OpenAuth
  Grape = BetterAuth::Grape unless const_defined?(:Grape, false)
  alias_better_auth_constants!
end
