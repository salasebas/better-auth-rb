# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def one_time_token(options = {})
      config = {
        expires_in: 3,
        store_token: "plain"
      }.merge(normalize_hash(options))

      Plugin.new(
        id: "one-time-token",
        endpoints: {
          generate_one_time_token: generate_one_time_token_endpoint(config),
          verify_one_time_token: verify_one_time_token_endpoint(config)
        },
        hooks: {
          after: [
            {
              matcher: ->(_ctx) { true },
              handler: ->(ctx) { one_time_token_after_response(ctx, config) }
            }
          ]
        },
        options: config
      )
    end

    def generate_one_time_token_endpoint(config)
      Endpoint.new(
        path: "/one-time-token/generate",
        method: "GET",
        metadata: {
          openapi: {
            operationId: "generateOneTimeToken",
            description: "Generate a one-time token for the current session",
            responses: {
              "200" => OpenAPI.json_response(
                "One-time token",
                OpenAPI.object_schema(
                  {
                    token: {type: "string"}
                  },
                  required: ["token"]
                )
              )
            }
          }
        }
      ) do |ctx|
        if config[:disable_client_request] && ctx.request
          raise APIError.new("BAD_REQUEST", message: "Client requests are disabled")
        end

        session = Routes.current_session(ctx)
        token = one_time_token_create(ctx, config, session)
        ctx.json({token: token})
      end
    end

    def verify_one_time_token_endpoint(config)
      Endpoint.new(
        path: "/one-time-token/verify",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "verifyOneTimeToken",
            description: "Verify a one-time token and restore its session",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  token: {type: "string"}
                },
                required: ["token"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response("Session restored", OpenAPI.session_response_schema_pair)
            }
          }
        }
      ) do |ctx|
        body = normalize_hash(ctx.body)
        token = body[:token].to_s
        stored_token = one_time_token_stored_value(config, token)
        verification = ctx.context.internal_adapter.consume_verification_value("one-time-token:#{stored_token}")
        raise APIError.new("BAD_REQUEST", message: "Invalid token") unless verification

        session = ctx.context.internal_adapter.find_session(verification["value"])
        raise APIError.new("BAD_REQUEST", message: "Session not found") unless session
        raise APIError.new("BAD_REQUEST", message: "Session expired") if Routes.expired_time?(session[:session]["expiresAt"])

        Cookies.set_session_cookie(ctx, session) unless config[:disable_set_session_cookie]
        ctx.json(session)
      end
    end

    def one_time_token_after_response(ctx, config)
      return unless config[:set_ott_header_on_new_session]

      session = ctx.context.new_session
      return unless session && session[:session] && session[:user]

      token = one_time_token_create(ctx, config, session)
      existing = ctx.response_headers["access-control-expose-headers"].to_s
      exposed = existing.split(",").map(&:strip).reject(&:empty?)
      exposed << "set-ott"
      ctx.set_header("set-ott", token)
      ctx.set_header("access-control-expose-headers", exposed.uniq.join(", "))
      nil
    end

    def one_time_token_create(ctx, config, session)
      generator = config[:generate_token]
      token = if generator.respond_to?(:call)
        generator.call(session, ctx)
      else
        Crypto.random_string(32)
      end.to_s
      stored_token = one_time_token_stored_value(config, token)
      ctx.context.internal_adapter.create_verification_value(
        identifier: "one-time-token:#{stored_token}",
        value: session[:session]["token"],
        expiresAt: Time.now + config[:expires_in].to_i * 60
      )
      token
    end

    def one_time_token_stored_value(config, token)
      storage = config[:store_token]
      return Crypto.sha256(token, encoding: :base64url) if storage.to_s == "hashed"

      if storage.is_a?(Hash) && storage[:type].to_s.tr("_", "-") == "custom-hasher"
        hasher = storage[:hash]
        return hasher.call(token) if hasher.respond_to?(:call)
      end

      token
    end
  end
end
