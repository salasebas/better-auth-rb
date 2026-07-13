# frozen_string_literal: true

module BetterAuth
  module Routes
    def self.get_session
      Endpoint.new(
        path: "/get-session",
        method: ["GET", "POST"],
        metadata: {
          openapi: {
            operationId: "getSession",
            description: "Get the current session",
            responses: {
              "200" => OpenAPI.json_response("Current session or null", OpenAPI.session_response_schema_pair.merge(type: ["object", "null"]))
            }
          }
        }
      ) do |ctx|
        defer_refresh = ctx.context.session_config[:defer_session_refresh]
        if ctx.method == "POST" && !defer_refresh
          raise APIError.new(
            "METHOD_NOT_ALLOWED",
            code: "METHOD_NOT_ALLOWED_DEFER_SESSION_REQUIRED",
            message: BASE_ERROR_CODES["METHOD_NOT_ALLOWED_DEFER_SESSION_REQUIRED"]
          )
        end

        session = current_session(ctx, allow_nil: true, disable_refresh: defer_refresh && ctx.method == "GET")
        next ctx.json(nil) unless session

        response = parsed_session_response(ctx, session)
        response[:needsRefresh] = session_needs_refresh?(ctx, session[:session]) if defer_refresh && ctx.method == "GET"
        ctx.json(response)
      rescue APIError
        raise
      rescue => error
        log(ctx.context, :error, "FAILED_TO_GET_SESSION #{error.message}")
        raise APIError.new("INTERNAL_SERVER_ERROR", message: BASE_ERROR_CODES["FAILED_TO_GET_SESSION"])
      end
    end

    def self.list_sessions
      Endpoint.new(
        path: "/list-sessions",
        method: "GET",
        metadata: {
          openapi: {
            operationId: "listSessions",
            description: "List active sessions for the current user",
            responses: {
              "200" => OpenAPI.json_response(
                "Active sessions",
                {type: "array", items: {type: "object", "$ref": "#/components/schemas/Session"}}
              )
            }
          }
        }
      ) do |ctx|
        session = current_session(ctx)
        sessions = ctx.context.internal_adapter.list_sessions(session[:user]["id"])
        active = sessions
          .map { |entry| stringify_keys(entry) }
          .select { |entry| !Session.expired?(entry) }
          .map { |entry| Schema.parse_output(ctx.context.options, "session", entry) }
        ctx.json(active)
      end
    end

    def self.update_session
      Endpoint.new(
        path: "/update-session",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "updateSession",
            description: "Update the current session",
            responses: {
              "200" => OpenAPI.json_response("Updated session", OpenAPI.session_response_schema_pair)
            }
          }
        }
      ) do |ctx|
        session = current_session(ctx)
        raise APIError.new("BAD_REQUEST", code: "BODY_MUST_BE_AN_OBJECT", message: BASE_ERROR_CODES["BODY_MUST_BE_AN_OBJECT"]) unless ctx.body.is_a?(Hash)

        body = Routes.parse_declared_input(ctx, "session", ctx.body, allowed_base: [])
        raise APIError.new("BAD_REQUEST", message: "No fields to update") if body.empty?

        update = body.merge("updatedAt" => Time.now)
        updated = ctx.context.internal_adapter.update_session(session[:session]["token"], update)
        if !updated && Session.stateful?(ctx)
          Cookies.delete_session_cookie(ctx)
          raise APIError.new("UNAUTHORIZED", message: BASE_ERROR_CODES["FAILED_TO_GET_SESSION"])
        end

        merged = session[:session].merge(updated || update)
        Cookies.set_session_cookie(ctx, {session: merged, user: session[:user]}, Cookies.dont_remember?(ctx))
        ctx.json({session: Schema.parse_output(ctx.context.options, "session", merged)})
      end
    end

    def self.revoke_session
      Endpoint.new(
        path: "/revoke-session",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "revokeSession",
            description: "Revoke a session by token",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  token: {type: "string", description: "The session token to revoke"}
                },
                required: ["token"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response("Session revoked", OpenAPI.status_response_schema)
            }
          }
        }
      ) do |ctx|
        session = current_session(ctx, sensitive: true)
        body = normalize_hash(ctx.body)
        token = body["token"].to_s
        found = ctx.context.internal_adapter.find_session(token)

        if found && stringify_keys(found[:session] || found["session"])["userId"] == session[:user]["id"]
          ctx.context.internal_adapter.delete_session(token)
        end

        ctx.json({status: true})
      end
    end

    def self.revoke_sessions
      Endpoint.new(
        path: "/revoke-sessions",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "revokeSessions",
            description: "Revoke all sessions for the current user",
            responses: {
              "200" => OpenAPI.json_response("Sessions revoked", OpenAPI.status_response_schema)
            }
          }
        }
      ) do |ctx|
        session = current_session(ctx, sensitive: true)
        ctx.context.internal_adapter.delete_user_sessions(session[:user]["id"])
        Cookies.delete_session_cookie(ctx)
        ctx.json({status: true})
      end
    end

    def self.revoke_other_sessions
      Endpoint.new(
        path: "/revoke-other-sessions",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "revokeOtherSessions",
            description: "Revoke all sessions except the current one",
            responses: {
              "200" => OpenAPI.json_response("Other sessions revoked", OpenAPI.status_response_schema)
            }
          }
        }
      ) do |ctx|
        session = current_session(ctx, sensitive: true)
        current_token = session[:session]["token"]
        sessions = ctx.context.internal_adapter.list_sessions(session[:user]["id"])
        sessions.each do |entry|
          data = stringify_keys(entry)
          next if Session.expired?(data) || data["token"] == current_token

          ctx.context.internal_adapter.delete_session(data["token"])
        end
        ctx.json({status: true})
      end
    end

    def self.current_session(ctx, allow_nil: false, sensitive: false, fresh: false, disable_refresh: false)
      data = Session.find_current(
        ctx,
        disable_cookie_cache: truthy_query?(ctx.query, "disableCookieCache"),
        disable_refresh: disable_refresh || truthy_query?(ctx.query, "disableRefresh"),
        sensitive: sensitive
      )
      return nil if allow_nil && data.nil?

      raise APIError.new("UNAUTHORIZED") unless data

      session = stringify_keys(data[:session] || data["session"])
      ensure_fresh_session!(ctx, session) if fresh

      {
        session: session,
        user: stringify_keys(data[:user] || data["user"])
      }
    end

    def self.request_only_session(ctx)
      session = current_session(ctx, allow_nil: true)
      if !session && (ctx.request || !ctx.headers.empty?)
        raise APIError.new("UNAUTHORIZED", code: "UNAUTHORIZED", message: "Unauthorized")
      end

      session
    end

    def self.ensure_fresh_session!(ctx, session)
      fresh_age = ctx.context.session_config[:fresh_age].to_i
      return if fresh_age.zero?

      created_at = normalize_time(session["createdAt"])
      return unless created_at && Time.now - created_at >= fresh_age

      raise APIError.new("FORBIDDEN", code: "SESSION_NOT_FRESH", message: BASE_ERROR_CODES.fetch("SESSION_NOT_FRESH"))
    end

    def self.session_needs_refresh?(ctx, session)
      return false if truthy_query?(ctx.query, "disableRefresh") || ctx.context.session_config[:disable_session_refresh]

      update_age = ctx.context.session_config[:update_age].to_i
      return true if update_age.zero?

      updated_at = normalize_time(session["updatedAt"])
      updated_at && updated_at + update_age <= Time.now
    end

    def self.normalize_time(value)
      return value if value.is_a?(Time)
      return nil if value.nil? || value.to_s.empty?

      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def self.parsed_session_response(ctx, session)
      {
        session: Schema.parse_output(ctx.context.options, "session", session[:session]),
        user: Schema.parse_output(ctx.context.options, "user", session[:user])
      }
    end

    def self.truthy_query?(query, key)
      snake_key = key.to_s
        .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
        .tr("-", "_")
        .downcase
      value = query[key] ||
        query[key.to_sym] ||
        query[Schema.storage_key(key)] ||
        query[Schema.storage_key(key).to_sym] ||
        query[snake_key] ||
        query[snake_key.to_sym]
      value == true || value.to_s == "true"
    end

    def self.stringify_keys(value)
      return value.each_with_object({}) { |(key, object_value), result| result[key.to_s] = stringify_keys(object_value) } if value.is_a?(Hash)
      return value.map { |entry| stringify_keys(entry) } if value.is_a?(Array)

      value
    end

    def self.log(context, level, message)
      logger = context.logger
      if logger.respond_to?(:call)
        logger.call(level, message)
      elsif logger.respond_to?(level)
        logger.public_send(level, message)
      end
    end
  end
end
