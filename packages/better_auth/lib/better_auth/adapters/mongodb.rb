# frozen_string_literal: true

begin
  require "better_auth/mongodb"
rescue LoadError => error
  raise if error.path && error.path != "better_auth/mongodb"

  raise LoadError, "BetterAuth::Adapters::MongoDB requires the better_auth-mongodb gem. Add `gem \"better_auth-mongodb\"` and `require \"better_auth/mongodb\"`."
end
