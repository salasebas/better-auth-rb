# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    MULTI_SESSION_ERROR_CODES = {
      "INVALID_SESSION_TOKEN" => "Invalid session token"
    }.freeze

    def multi_session(options = {})
      config = {maximum_sessions: 5}.merge(normalize_hash(options))

      Plugin.new(
        id: "multi-session",
        endpoints: {
          list_device_sessions: list_device_sessions_endpoint,
          set_active_session: set_active_session_endpoint,
          revoke_device_session: revoke_device_session_endpoint
        },
        hooks: {
          after: [
            {
              matcher: ->(_ctx) { true },
              handler: ->(ctx) { set_multi_session_cookie(ctx, config) }
            },
            {
              matcher: ->(ctx) { ctx.path == "/sign-out" },
              handler: ->(ctx) { clear_multi_session_cookies(ctx) }
            }
          ]
        },
        error_codes: MULTI_SESSION_ERROR_CODES,
        options: config
      )
    end

    def list_device_sessions_endpoint
      Endpoint.new(
        path: "/multi-session/list-device-sessions",
        method: "GET",
        metadata: {
          openapi: {
            operationId: "listDeviceSessions",
            description: "List device sessions",
            responses: {
              "200" => OpenAPI.json_response(
                "Device sessions",
                {
                  type: "array",
                  items: OpenAPI.session_response_schema_pair
                }
              )
            }
          }
        }
      ) do |ctx|
        tokens = verified_multi_session_tokens(ctx)
        sessions = ctx.context.internal_adapter.find_sessions(tokens)
          .reject { |entry| entry[:session]["expiresAt"] && entry[:session]["expiresAt"] <= Time.now }
        unique = sessions.each_with_object({}) { |entry, by_user| by_user[entry[:user]["id"]] ||= entry }.values

        ctx.json(unique.map { |entry| parsed_session(ctx, entry) })
      end
    end

    def set_active_session_endpoint
      Endpoint.new(
        path: "/multi-session/set-active",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "setActiveSession",
            description: "Set the active session",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  sessionToken: {type: "string", description: "The session token"}
                },
                required: ["sessionToken"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response("Active session", OpenAPI.session_response_schema_pair)
            }
          }
        }
      ) do |ctx|
        token = fetch_value(ctx.body, "sessionToken").to_s
        cookie_name = multi_session_cookie_name(ctx, token)
        verified_token = ctx.get_signed_cookie(cookie_name, ctx.context.secret) unless token.empty?
        unless verified_token
          raise APIError.new("UNAUTHORIZED", message: MULTI_SESSION_ERROR_CODES["INVALID_SESSION_TOKEN"])
        end

        session = ctx.context.internal_adapter.find_session(verified_token)
        unless session && session[:session]["expiresAt"] > Time.now
          expire_cookie(ctx, cookie_name)
          raise APIError.new("UNAUTHORIZED", message: MULTI_SESSION_ERROR_CODES["INVALID_SESSION_TOKEN"])
        end

        Cookies.set_session_cookie(ctx, session)
        ctx.json(parsed_session(ctx, session))
      end
    end

    def revoke_device_session_endpoint
      Endpoint.new(
        path: "/multi-session/revoke",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "revokeDeviceSession",
            description: "Revoke a device session",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  sessionToken: {type: "string", description: "The session token"}
                },
                required: ["sessionToken"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response("Device session revoked", OpenAPI.status_response_schema)
            }
          }
        }
      ) do |ctx|
        current = Routes.current_session(ctx)
        token = fetch_value(ctx.body, "sessionToken").to_s
        cookie_name = multi_session_cookie_name(ctx, token)
        verified_token = ctx.get_signed_cookie(cookie_name, ctx.context.secret) unless token.empty?
        unless verified_token
          raise APIError.new("UNAUTHORIZED", message: MULTI_SESSION_ERROR_CODES["INVALID_SESSION_TOKEN"])
        end

        ctx.context.internal_adapter.delete_session(verified_token)
        expire_cookie(ctx, cookie_name)

        if current && current[:session]["token"] == verified_token
          next_session = ctx.context.internal_adapter
            .find_sessions(verified_multi_session_tokens(ctx).reject { |entry| entry == verified_token })
            .find { |entry| !entry[:session]["expiresAt"] || entry[:session]["expiresAt"] > Time.now }
          if next_session
            Cookies.set_session_cookie(ctx, next_session)
          else
            Cookies.delete_session_cookie(ctx)
          end
        end

        ctx.json({status: true})
      end
    end

    def set_multi_session_cookie(ctx, config)
      new_session = ctx.context.new_session
      return unless new_session && new_session[:session]
      set_cookie = ctx.response_headers["set-cookie"].to_s

      token = new_session[:session]["token"]
      cookie_config = ctx.context.auth_cookies[:session_token]
      cookie_name = multi_session_cookie_name(ctx, token)
      cookies = ctx.cookies
      return unless set_cookie.include?(cookie_config.name)
      return if cookies.key?(cookie_name)

      deleted_count = 0
      existing_multi_cookie_names = multi_cookie_names(ctx)
      existing_multi_cookie_names.each do |name|
        existing_token = ctx.get_signed_cookie(name, ctx.context.secret)
        next unless existing_token

        existing_session = ctx.context.internal_adapter.find_session(existing_token)
        next unless existing_session && existing_session[:user]["id"] == new_session[:user]["id"]

        ctx.context.internal_adapter.delete_session(existing_token)
        expire_cookie(ctx, name)
        deleted_count += 1
      end

      current_count = existing_multi_cookie_names.length - deleted_count + 1
      return if current_count > config[:maximum_sessions].to_i

      ctx.set_signed_cookie(cookie_name, token, ctx.context.secret, cookie_config.attributes)
      nil
    end

    def clear_multi_session_cookies(ctx)
      tokens = []
      multi_cookie_names(ctx).each do |name|
        token = ctx.get_signed_cookie(name, ctx.context.secret)
        next unless token

        tokens << token if token
        expire_cookie(ctx, canonical_multi_session_cookie_name(name))
      end
      ctx.context.internal_adapter.delete_sessions(tokens) unless tokens.empty?
      nil
    end

    def verified_multi_session_tokens(ctx)
      multi_cookie_names(ctx).filter_map { |name| ctx.get_signed_cookie(name, ctx.context.secret) }
    end

    def multi_cookie_names(ctx)
      ctx.cookies.keys.select { |name| multi_session_cookie?(name) }
    end

    def multi_session_cookie?(name)
      name.to_s.include?("_multi-")
    end

    def multi_session_cookie_name(ctx, token)
      "#{ctx.context.auth_cookies[:session_token].name}_multi-#{token.to_s.downcase}"
    end

    def parsed_session(ctx, entry)
      {
        session: Schema.parse_output(ctx.context.options, "session", entry[:session]),
        user: Schema.parse_output(ctx.context.options, "user", entry[:user])
      }
    end

    def expire_cookie(ctx, name)
      ctx.set_cookie(name, "", ctx.context.auth_cookies[:session_token].attributes.merge(max_age: 0))
    end

    def canonical_multi_session_cookie_name(name)
      prefix = "__Secure-"
      name.to_s.sub(/\A#{Regexp.escape(prefix)}/i, prefix)
    end
  end
end
