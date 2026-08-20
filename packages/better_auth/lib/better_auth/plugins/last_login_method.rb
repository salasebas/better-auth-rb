# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def last_login_method(options = {})
      config = {
        cookie_name: "better-auth.last_used_login_method",
        max_age: 60 * 60 * 24 * 30
      }.merge(normalize_hash(options))

      Plugin.new(
        id: "last-login-method",
        schema: last_login_method_schema(config),
        init: ->(_context) {
          {
            options: {
              database_hooks: last_login_method_database_hooks(config)
            }
          }
        },
        hooks: {
          after: [
            {
              matcher: ->(_ctx) { true },
              handler: ->(ctx) { apply_last_login_method(ctx, config) }
            }
          ]
        },
        options: config
      )
    end

    def last_login_method_schema(config)
      return {} unless config[:store_in_database]

      field_name = config.dig(:schema, :user, :last_login_method) || "lastLoginMethod"
      {
        user: {
          fields: {
            lastLoginMethod: {
              type: "string",
              input: false,
              required: false,
              field_name: field_name
            }
          }
        }
      }
    end

    def last_login_method_database_hooks(config)
      {
        user: {
          create: {
            before: ->(user, ctx) { apply_last_login_method_to_new_user(user, ctx, config) }
          }
        },
        session: {
          create: {
            after: ->(session, ctx) { persist_last_login_method(session, ctx, config) }
          }
        }
      }
    end

    def apply_last_login_method_to_new_user(user, ctx, config)
      return unless config[:store_in_database] && ctx

      method = resolve_login_method(ctx, config)
      return unless method && method != ""

      {data: user.merge("lastLoginMethod" => method)}
    end

    def persist_last_login_method(session, ctx, config)
      return unless config[:store_in_database] && ctx

      method = resolve_login_method(ctx, config)
      user_id = fetch_value(session, "userId")
      return unless method && method != "" && user_id

      begin
        ctx.context.internal_adapter.update_user(user_id, lastLoginMethod: method)
      rescue => error
        log_last_login_method_update_error(ctx, error)
      end
      nil
    end

    def log_last_login_method_update_error(ctx, error)
      logger = ctx.context.logger
      if logger.respond_to?(:call)
        logger.call(:error, "Failed to update lastLoginMethod", error)
      elsif logger.respond_to?(:error)
        logger.error("Failed to update lastLoginMethod", error)
      end
    rescue
      nil
    end

    def apply_last_login_method(ctx, config)
      method = resolve_login_method(ctx, config)
      return unless method

      set_cookie = ctx.response_headers["set-cookie"].to_s
      return unless set_cookie.include?(ctx.context.auth_cookies[:session_token].name)

      attributes = ctx.context.auth_cookies[:session_token].attributes.merge(max_age: config[:max_age], http_only: false)
      ctx.set_cookie(config[:cookie_name], method, attributes)
      nil
    end

    def resolve_login_method(ctx, config)
      custom = config[:custom_resolve_method]
      resolve_context = ctx
      unless ctx.path
        resolve_context = ctx.dup
        resolve_context.path = ""
      end
      resolved = custom.call(resolve_context) if custom.respond_to?(:call)
      return resolved if resolved

      path = resolve_context.path.to_s
      case path
      when "/sign-in/email", "/sign-up/email"
        "email"
      when "/callback/:id"
        fetch_value(ctx.params, "id") || fetch_value(ctx.params, "providerId")
      when "/oauth2/callback/:providerId"
        fetch_value(ctx.params, "providerId")
      else
        return Regexp.last_match(1) if path =~ %r{\A/callback/([^/]+)\z}
        return Regexp.last_match(1) if path =~ %r{\A/oauth2/callback/([^/]+)\z}
        return "siwe" if path.include?("siwe")
        return "passkey" if path.include?("/passkey/verify-authentication")
        return "magic-link" if path.start_with?("/magic-link/verify")

        nil
      end
    end
  end
end
