# frozen_string_literal: true

require "better_auth"
require_relative "api_key/version"
require_relative "api_key/error_codes"
require_relative "api_key/request_contract"
require_relative "api_key/types"
require_relative "api_key/utils"
require_relative "api_key/rate_limit"
require_relative "api_key/keys"
require_relative "api_key/adapter"
require_relative "api_key/schema"
require_relative "api_key/org_authorization"
require_relative "api_key/validation"
require_relative "api_key/configuration"
require_relative "api_key/session"
require_relative "api_key/plugin_factory"
require_relative "api_key/routes/index"
require_relative "api_key/routes/create_api_key"
require_relative "api_key/routes/verify_api_key"
require_relative "api_key/routes/get_api_key"
require_relative "api_key/routes/update_api_key"
require_relative "api_key/routes/delete_api_key"
require_relative "api_key/routes/list_api_keys"
require_relative "api_key/routes/delete_all_expired_api_keys"
require_relative "plugins/api_key"

module BetterAuth
  module APIKey
    module_function

    def default_key_hasher(key)
      Plugins.default_api_key_hasher(key)
    end
  end
end
