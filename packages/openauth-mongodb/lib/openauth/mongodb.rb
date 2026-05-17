# frozen_string_literal: true

require "openauth"
require "better_auth/mongodb"

module OpenAuth
  MongoDB = BetterAuth::MongoDB unless const_defined?(:MongoDB, false)
  MongoAdapter = BetterAuth::MongoDB unless const_defined?(:MongoAdapter, false)
  alias_better_auth_constants!
end
