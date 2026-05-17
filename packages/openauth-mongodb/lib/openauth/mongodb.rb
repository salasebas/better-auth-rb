# frozen_string_literal: true

require "openauth"
require "better_auth/mongo_adapter"
require "better_auth/mongo_adapter/version"

module OpenAuth
  MongoAdapter = BetterAuth::MongoAdapter unless const_defined?(:MongoAdapter, false)
  MongoDB = BetterAuth::MongoAdapter unless const_defined?(:MongoDB, false)
  alias_better_auth_constants!
end
