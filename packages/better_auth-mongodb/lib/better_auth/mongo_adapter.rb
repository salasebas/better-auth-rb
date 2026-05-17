# frozen_string_literal: true

warn "better_auth/mongo_adapter is deprecated; use better_auth/mongodb instead.", uplevel: 1

require_relative "mongodb"

module BetterAuth
  MongoAdapter = MongoDB unless const_defined?(:MongoAdapter, false)
end
