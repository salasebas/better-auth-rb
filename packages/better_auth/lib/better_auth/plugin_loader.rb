# frozen_string_literal: true

module BetterAuth
  module Plugins
    # Maps `BetterAuth::Plugins` factory methods and nested modules to source files.
    PLUGIN_FILES = {
      additional_fields: "plugins/additional_fields",
      custom_session: "plugins/custom_session",
      multi_session: "plugins/multi_session",
      last_login_method: "plugins/last_login_method",
      bearer: "plugins/bearer",
      jwt: "plugins/jwt",
      open_api: "plugins/open_api",
      access: "plugins/access",
      username: "plugins/username",
      anonymous: "plugins/anonymous",
      magic_link: "plugins/magic_link",
      email_otp: "plugins/email_otp",
      phone_number: "plugins/phone_number",
      one_time_token: "plugins/one_time_token",
      one_tap: "plugins/one_tap",
      siwe: "plugins/siwe",
      generic_oauth: "plugins/generic_oauth",
      dub: "plugins/dub",
      oauth_proxy: "plugins/oauth_proxy",
      passkey: "plugins/passkey",
      organization_schema: "plugins/organization/schema",
      organization: "plugins/organization",
      admin_schema: "plugins/admin/schema",
      admin: "plugins/admin",
      oauth_protocol: "plugins/oauth_protocol",
      oidc_provider: "plugins/oidc_provider",
      oauth_provider: "plugins/oauth_provider",
      device_authorization: "plugins/device_authorization",
      mcp: "plugins/mcp",
      two_factor: "plugins/two_factor",
      captcha: "plugins/captcha",
      have_i_been_pwned: "plugins/have_i_been_pwned",
      api_key: "plugins/api_key",
      sso: "plugins/sso",
      scim: "plugins/scim",
      stripe: "plugins/stripe",
      expo: "plugins/expo"
    }.freeze

    PLUGIN_DEPENDENCIES = {
      organization: %i[organization_schema access],
      admin_schema: %i[organization_schema],
      admin: %i[admin_schema access],
      oidc_provider: %i[oauth_protocol],
      mcp: %i[oauth_protocol],
      device_authorization: %i[oauth_protocol]
    }.freeze

    # Core route metadata helpers; loaded at boot because base endpoints reference OpenAPI.
    BOOT_PLUGINS = %i[open_api].freeze

    PLUGIN_ID_TO_LOADER = {
      "additional-fields" => :additional_fields,
      "custom-session" => :custom_session,
      "multi-session" => :multi_session,
      "last-login-method" => :last_login_method,
      "bearer" => :bearer,
      "jwt" => :jwt,
      "open-api" => :open_api,
      "username" => :username,
      "anonymous" => :anonymous,
      "magic-link" => :magic_link,
      "email-otp" => :email_otp,
      "phone-number" => :phone_number,
      "one-time-token" => :one_time_token,
      "one-tap" => :one_tap,
      "siwe" => :siwe,
      "generic-oauth" => :generic_oauth,
      "dub" => :dub,
      "oauth-proxy" => :oauth_proxy,
      "passkey" => :passkey,
      "organization" => :organization,
      "admin" => :admin,
      "oidc-provider" => :oidc_provider,
      "oauth-provider" => :oauth_provider,
      "device-authorization" => :device_authorization,
      "mcp" => :mcp,
      "two-factor" => :two_factor,
      "captcha" => :captcha,
      "have-i-been-pwned" => :have_i_been_pwned,
      "api-key" => :api_key,
      "sso" => :sso,
      "scim" => :scim,
      "stripe" => :stripe,
      "expo" => :expo
    }.freeze

    NESTED_MODULE_LOADERS = {
      OIDCProvider: :oidc_provider,
      OAuthProtocol: :oauth_protocol,
      JWT: :jwt,
      MCP: :mcp,
      OrganizationSchema: :organization_schema,
      AdminSchema: :admin_schema
    }.freeze

    LAZY_PLUGIN_METHODS = PLUGIN_FILES.keys.freeze

    @loaded_plugins = {}

    module_function

    def load_plugin!(name)
      name = name.to_sym
      return true if @loaded_plugins[name]
      if name == :sso && defined?(SSO_PLUGIN_IMPLEMENTATION)
        @loaded_plugins[name] = true
        return true
      end

      Array(PLUGIN_DEPENDENCIES[name]).each { |dependency| load_plugin!(dependency) }

      relative_path = PLUGIN_FILES.fetch(name) do
        raise ArgumentError, "Unknown plugin loader: #{name}"
      end

      absolute_path = File.expand_path(relative_path, __dir__)
      unless File.file?("#{absolute_path}.rb")
        @loaded_plugins[name] = true
        return false
      end

      require_relative relative_path
      @loaded_plugins[name] = true
      true
    end

    def plugin_loaded?(name)
      @loaded_plugins.key?(name.to_sym)
    end

    def ensure_plugin_loaded_for!(plugin)
      return unless plugin.is_a?(BetterAuth::Plugin)

      loader = PLUGIN_ID_TO_LOADER[plugin.id]
      load_plugin!(loader) if loader
    end

    def lazy_plugin_method?(name)
      LAZY_PLUGIN_METHODS.include?(name.to_sym)
    end

    def load_plugin_for_constant!(name)
      if (loader = NESTED_MODULE_LOADERS[name])
        return load_plugin!(loader)
      end

      if name == :OpenAPI
        return load_plugin!(:open_api)
      end

      constant = name.to_s
      if constant.end_with?("_ERROR_CODES")
        plugin_name = constant.delete_suffix("_ERROR_CODES").downcase.to_sym
        return load_plugin!(plugin_name) if PLUGIN_FILES.key?(plugin_name)
      end

      false
    end

    def load_boot_plugins!
      BOOT_PLUGINS.each { |plugin| load_plugin!(plugin) }
    end
  end
end
