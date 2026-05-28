# frozen_string_literal: true

require_relative "better_auth/version"
require_relative "better_auth/core"
require_relative "better_auth/error"
require_relative "better_auth/api_error"
require_relative "better_auth/env"
require_relative "better_auth/secret_config"
require_relative "better_auth/crypto"
require_relative "better_auth/host"
require_relative "better_auth/url_helpers"
require_relative "better_auth/request_state"
require_relative "better_auth/response"
require_relative "better_auth/async"
require_relative "better_auth/deprecate"
require_relative "better_auth/logger"
require_relative "better_auth/instrumentation"
require_relative "better_auth/http_client"
require_relative "better_auth/oauth2"
require_relative "better_auth/password"
require_relative "better_auth/plugin"
require_relative "better_auth/configuration"
require_relative "better_auth/schema"
require_relative "better_auth/schema/sql"
require_relative "better_auth/migration_plan"
require_relative "better_auth/doctor"
require_relative "better_auth/adapters/base"
require_relative "better_auth/adapters/join_support"
require_relative "better_auth/adapters/memory"
require_relative "better_auth/adapters/sql"
require_relative "better_auth/adapters/postgres"
require_relative "better_auth/adapters/mysql"
require_relative "better_auth/adapters/sqlite"
require_relative "better_auth/adapters/mssql"
require_relative "better_auth/database_hooks"
require_relative "better_auth/adapters/internal_adapter"
require_relative "better_auth/context"
require_relative "better_auth/plugin_context"
require_relative "better_auth/plugin_registry"
require_relative "better_auth/plugins"
BetterAuth::Plugins.load_boot_plugins!
require_relative "better_auth/social_providers"
require_relative "better_auth/session_store"
require_relative "better_auth/cookies"
require_relative "better_auth/session"
require_relative "better_auth/endpoint"
require_relative "better_auth/routes/validation"
require_relative "better_auth/routes/ok"
require_relative "better_auth/routes/error"
require_relative "better_auth/routes/sign_up"
require_relative "better_auth/routes/sign_in"
require_relative "better_auth/routes/sign_out"
require_relative "better_auth/routes/session"
require_relative "better_auth/routes/password"
require_relative "better_auth/routes/email_verification"
require_relative "better_auth/routes/user"
require_relative "better_auth/routes/account"
require_relative "better_auth/routes/social"
require_relative "better_auth/api"
require_relative "better_auth/rate_limiter"
require_relative "better_auth/request_ip"
require_relative "better_auth/middleware/origin_check"
require_relative "better_auth/router"
require_relative "better_auth/auth"

module BetterAuth
  def self.auth(options = {})
    Auth.new(options)
  end

  def self.const_missing(name)
    if name == :OpenAPI
      Plugins.load_plugin!(:open_api)
      return const_get(:OpenAPI) if const_defined?(:OpenAPI, false)
    end

    super
  end
end
