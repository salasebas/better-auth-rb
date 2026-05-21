# frozen_string_literal: true

warn "The better_auth-mongo-adapter gem is deprecated; use better_auth-mongodb and require \"better_auth/mongodb\" instead.", uplevel: 1

require "better_auth/mongodb"

module BetterAuth
  remove_const(:MongoAdapter) if const_defined?(:MongoAdapter, false) && const_get(:MongoAdapter) != MongoDB
  MongoAdapter = MongoDB unless const_defined?(:MongoAdapter, false)
end
