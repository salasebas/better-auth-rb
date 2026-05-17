# frozen_string_literal: true

require "openauth"
require "better_auth/scim"

module OpenAuth
  SCIM = BetterAuth::SCIM unless const_defined?(:SCIM, false)
  alias_better_auth_constants!
end
