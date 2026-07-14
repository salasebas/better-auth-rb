# frozen_string_literal: true

require "better_auth"
require_relative "passkey/version"
require_relative "passkey/error_codes"
require_relative "passkey/schema"
require_relative "passkey/authenticator_metadata"
require_relative "passkey/utils"
require_relative "passkey/challenges"
require_relative "passkey/credentials"
require_relative "passkey/routes"
require_relative "plugins/passkey"

module BetterAuth
  module Passkey
  end
end
