# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def oauth_end_session_endpoint
      Endpoint.new(path: "/oauth2/end-session", method: ["GET", "POST"], metadata: oauth_openapi_for(:end_session).merge(allowed_media_types: ["application/x-www-form-urlencoded", "application/json"])) do |ctx|
        input = OAuthProtocol.stringify_keys((ctx.method == "GET") ? ctx.query : ctx.body)
        id_token_hint = input["id_token_hint"].to_s
        raise APIError.new("UNAUTHORIZED", message: "invalid id token") if id_token_hint.empty?

        decoded = ::JWT.decode(id_token_hint, nil, false).first
        client_id = input["client_id"] || decoded["aud"]
        client = OAuthProtocol.find_client(ctx, "oauthClient", client_id)
        raise APIError.new("BAD_REQUEST", message: "invalid_client") unless client

        client_data = OAuthProtocol.stringify_keys(client)
        raise APIError.new("BAD_REQUEST", message: "invalid_client") if client_data["disabled"]
        raise APIError.new("UNAUTHORIZED", message: "client unable to logout") unless client_data["enableEndSession"]

        payload = OAuthProtocol.verify_oauth_jwt(
          ctx,
          id_token_hint,
          issuer: OAuthProvider.validate_issuer_url(OAuthProtocol.issuer(ctx)),
          hs256_secret: OAuthProtocol.id_token_hs256_key(ctx, client_data["clientId"], client_data["clientSecret"])
        )
        raise APIError.new("UNAUTHORIZED", message: "invalid id token") unless payload
        raise APIError.new("BAD_REQUEST", message: "audience mismatch") if input["client_id"] && payload["aud"] != input["client_id"]

        if payload["sid"]
          ctx.context.adapter.delete(model: "session", where: [{field: "id", value: payload["sid"]}])
        end

        if input["post_logout_redirect_uri"]
          unless OAuthProtocol.client_logout_redirect_uris(client_data).include?(input["post_logout_redirect_uri"])
            raise APIError.new("BAD_REQUEST", message: "invalid post_logout_redirect_uri")
          end

          redirect = OAuthProtocol.redirect_uri_with_params(input["post_logout_redirect_uri"], state: input["state"])
          raise ctx.redirect(redirect)
        end

        ctx.json({status: true})
      rescue ::JWT::DecodeError
        raise APIError.new("UNAUTHORIZED", message: "invalid id token")
      end
    end
  end
end
