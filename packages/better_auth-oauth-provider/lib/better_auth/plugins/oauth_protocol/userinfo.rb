# frozen_string_literal: true

require "jwt"

module BetterAuth
  module Plugins
    module OAuthProtocol
      module_function

      def userinfo(store, authorization, additional_claim: nil, prefix: {}, jwt_secret: nil, ctx: nil, issuer: nil)
        if authorization.to_s.strip.empty?
          raise APIError.new(
            "UNAUTHORIZED",
            message: "authorization header not found",
            body: {error: "invalid_request", error_description: "authorization header not found"}
          )
        end
        token = authorization.to_s.delete_prefix("Bearer ").strip
        record = token_record(store, token, prefix: prefix)
        return jwt_userinfo(token, jwt_secret, additional_claim: additional_claim, ctx: ctx, issuer: issuer) unless record
        scrub_token_record_client!(record)
        user = stringify_keys(record["user"])
        scopes = parse_scopes(record["scopes"])
        raise userinfo_openid_scope_error unless scopes.include?("openid")

        response = {sub: record["subject"] || user["id"]}
        response[:name] = user["name"] if scopes.include?("profile")
        response[:given_name] = user["name"].to_s.split(/\s+/, 2).first if scopes.include?("profile") && user["name"]
        response[:family_name] = user["name"].to_s.split(/\s+/, 2).last if scopes.include?("profile") && user["name"].to_s.include?(" ")
        response[:picture] = user["image"] if scopes.include?("profile") && user["image"]
        if scopes.include?("email")
          response[:email] = user["email"]
          response[:email_verified] = !!user["emailVerified"]
        end
        if additional_claim.respond_to?(:call)
          extra = begin
            additional_claim.call({user: user, scopes: scopes, jwt: record, client: stringify_keys(record["client"] || {})})
          rescue ArgumentError
            additional_claim.call(user, scopes, stringify_keys(record["client"] || {}))
          end
          response.merge!(extra) if extra.is_a?(Hash)
        end
        response
      end

      def jwt_userinfo(token, jwt_secret, additional_claim: nil, ctx: nil, issuer: nil)
        payload = if ctx
          verify_oauth_jwt(ctx, token, issuer: issuer || issuer(ctx), hs256_secret: jwt_secret)
        else
          ::JWT.decode(token, jwt_secret.to_s, true, algorithm: "HS256").first
        end
        scopes = parse_scopes(payload["scope"])
        raise userinfo_openid_scope_error unless scopes.include?("openid")

        response = {sub: payload["sub"]}
        if scopes.include?("profile")
          response[:name] = payload["name"] if payload["name"]
          response[:given_name] = payload["name"].to_s.split(/\s+/, 2).first if payload["name"]
          response[:family_name] = payload["name"].to_s.split(/\s+/, 2).last if payload["name"].to_s.include?(" ")
        end
        if scopes.include?("email")
          response[:email] = payload["email"]
          response[:email_verified] = !!payload["email_verified"]
        end
        if additional_claim.respond_to?(:call)
          extra = additional_claim.call({user: payload, scopes: scopes, jwt: payload, client: {}})
          response.merge!(extra) if extra.is_a?(Hash)
        end
        response
      rescue ::JWT::DecodeError
        raise APIError.new("UNAUTHORIZED", message: "invalid_token")
      end

      def userinfo_openid_scope_error
        APIError.new(
          "BAD_REQUEST",
          message: "openid scope is required",
          body: {error: "invalid_request", error_description: "openid scope is required"}
        )
      end
    end
  end
end
