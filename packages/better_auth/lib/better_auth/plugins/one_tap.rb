# frozen_string_literal: true

require "net/http"
require "uri"

module BetterAuth
  module Plugins
    module_function

    def one_tap(options = {})
      config = normalize_hash(options)

      Plugin.new(
        id: "one-tap",
        endpoints: {
          one_tap_callback: one_tap_callback_endpoint(config)
        },
        options: config
      )
    end

    def one_tap_callback_endpoint(config)
      Endpoint.new(
        path: "/one-tap/callback",
        method: "POST",
        body_schema: ->(body) {
          data = normalize_hash(body)
          data[:id_token].to_s.empty? ? false : data
        },
        metadata: {
          openapi: {
            operationId: "oneTapCallback",
            summary: "One tap callback",
            description: "Use this endpoint to authenticate with Google One Tap",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  id_token: {type: "string", description: "Google One Tap ID token"}
                },
                required: ["id_token"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response("Success", OpenAPI.session_response_schema_pair)
            }
          }
        }
      ) do |ctx|
        body = normalize_hash(ctx.body)
        id_token = body[:id_token].to_s
        payload = one_tap_verify_id_token(ctx, config, id_token)
        email = fetch_value(payload, "email").to_s.downcase
        raise APIError.new("BAD_REQUEST", message: "invalid id token") if Routes.blank_remote_id?(fetch_value(payload, "sub"))

        if email.empty?
          next ctx.json({error: "Email not available in token"})
        end

        sub = fetch_value(payload, "sub").to_s
        session_data = Routes.persist_social_user(
          ctx,
          "google",
          {
            id: sub,
            email: email,
            emailVerified: one_tap_boolean_value(fetch_value(payload, "email_verified")),
            name: fetch_value(payload, "name").to_s,
            image: fetch_value(payload, "picture")
          },
          {
            providerId: "google",
            accountId: sub,
            idToken: id_token,
            scope: "openid,profile,email"
          },
          disable_sign_up: config[:disable_signup]
        )
        one_tap_raise_persistence_error!(session_data[:error]) if session_data[:error]

        Cookies.set_session_cookie(ctx, session_data)
        ctx.json({
          token: session_data[:session]["token"],
          user: Schema.parse_output(ctx.context.options, "user", session_data[:user])
        })
      end
    end

    def one_tap_verify_id_token(ctx, config, id_token)
      google_provider = ctx.context.options.social_providers[:google] || {}
      google_options = fetch_value(google_provider, "options") || {}
      audience = config[:client_id]
      audience = fetch_value(google_provider, "client_id") if one_tap_blank_audience?(audience)
      if one_tap_blank_audience?(audience)
        raise APIError.new(
          "BAD_REQUEST",
          message: "Google client ID is required for One Tap. Set it on the one_tap plugin (client_id) or on social_providers.google."
        )
      end

      begin
        verifier = config[:verify_id_token]
        payload = if verifier.respond_to?(:call)
          verifier.call(id_token, ctx, audience: audience)
        else
          one_tap_verify_google_id_token(id_token, audience)
        end
        payload = one_tap_stringify_payload(payload)
        hosted_domain = fetch_value(google_provider, "hd")
        hosted_domain = fetch_value(google_options, "hd") if hosted_domain.nil?
        unless SocialProviders.google_hosted_domain_allowed?(hosted_domain, payload["hd"])
          raise "Invalid Google hosted domain"
        end

        payload
      rescue
        raise APIError.new("BAD_REQUEST", message: "invalid id token")
      end
    end

    def one_tap_verify_google_id_token(id_token, audience)
      jwks = one_tap_google_jwks
      options = {
        algorithms: ["RS256"],
        iss: ["https://accounts.google.com", "accounts.google.com"],
        verify_iss: true
      }
      options[:aud] = audience
      options[:verify_aud] = true
      payload, = ::JWT.decode(id_token, nil, true, options.merge(jwks: jwks))
      payload
    end

    def one_tap_google_jwks
      cached = @one_tap_google_jwks_cache
      return cached[:jwks] if cached && cached[:expires_at] > Time.now

      payload = HTTPClient.get_json("https://www.googleapis.com/oauth2/v3/certs")
      raise "Unable to fetch Google JWKS" unless payload

      jwks = ::JWT::JWK::Set.new(payload)
      @one_tap_google_jwks_cache = {jwks: jwks, expires_at: Time.now + 300}
      jwks
    end

    def one_tap_blank_audience?(audience)
      Array(audience).empty? || Array(audience).all? { |value| value.to_s.strip.empty? }
    end

    def one_tap_raise_persistence_error!(error)
      case error
      when "signup disabled"
        raise APIError.new("BAD_GATEWAY", message: "User not found")
      when "account not linked", "banned"
        raise APIError.new("UNAUTHORIZED", message: "Google sub doesn't match")
      else
        raise APIError.new("INTERNAL_SERVER_ERROR", message: "Could not create user")
      end
    end

    def one_tap_stringify_payload(payload)
      raise "Invalid payload" unless payload.is_a?(Hash)

      payload.each_with_object({}) do |(key, value), result|
        result[key.to_s] = value
      end
    end

    def one_tap_boolean_value(value)
      value == true || value.to_s.downcase == "true"
    end
  end
end
