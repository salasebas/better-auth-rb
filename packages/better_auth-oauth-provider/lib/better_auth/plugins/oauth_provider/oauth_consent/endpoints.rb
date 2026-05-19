# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def oauth_list_consents_endpoint
      Endpoint.new(path: "/oauth2/get-consents", method: "GET") do |ctx|
        session = Routes.current_session(ctx)
        consents = ctx.context.adapter.find_many(model: "oauthConsent", where: [{field: "userId", value: session[:user]["id"]}])
        ctx.json(consents.map { |consent| oauth_consent_response(consent) })
      end
    end

    def oauth_get_consent_endpoint
      Endpoint.new(path: "/oauth2/get-consent", method: "GET") do |ctx|
        session = Routes.current_session(ctx)
        query = OAuthProtocol.stringify_keys(ctx.query)
        consent = if query["id"].to_s.empty?
          oauth_find_user_consent(ctx, session, query["client_id"])
        else
          ctx.context.adapter.find_one(model: "oauthConsent", where: [{field: "id", value: query["id"]}])
        end
        raise APIError.new("NOT_FOUND", message: "missing id") unless query["id"] || query["client_id"]
        raise APIError.new("NOT_FOUND", message: "consent not found") unless consent
        raise APIError.new("UNAUTHORIZED") unless OAuthProtocol.stringify_keys(consent)["userId"] == session[:user]["id"]

        ctx.json(oauth_consent_response(consent))
      end
    end

    def oauth_update_consent_endpoint
      Endpoint.new(path: "/oauth2/update-consent", method: "POST", metadata: oauth_openapi_for(:update_consent)) do |ctx|
        session = Routes.current_session(ctx)
        body = OAuthProtocol.stringify_keys(ctx.body)
        id = body["id"]
        consent = if id.to_s.empty?
          oauth_find_user_consent(ctx, session, body["client_id"])
        else
          ctx.context.adapter.find_one(model: "oauthConsent", where: [{field: "id", value: id}])
        end
        raise APIError.new("NOT_FOUND", message: "missing id") if id.to_s.empty? && body["client_id"].to_s.empty?
        raise APIError.new("NOT_FOUND", message: "consent not found") unless consent
        consent_data = OAuthProtocol.stringify_keys(consent)
        raise APIError.new("UNAUTHORIZED") unless consent_data["userId"] == session[:user]["id"]

        client = OAuthProtocol.find_client(ctx, "oauthClient", consent_data["clientId"])
        allowed = OAuthProtocol.parse_scopes(OAuthProtocol.stringify_keys(client || {})["scopes"])
        scopes = OAuthProtocol.parse_scopes(OAuthProtocol.stringify_keys(body["update"] || {})["scopes"] || body["scope"] || body["scopes"])
        unless scopes.all? { |scope| allowed.include?(scope) }
          raise APIError.new("BAD_REQUEST", message: "invalid_scope")
        end

        updated = ctx.context.adapter.update(
          model: "oauthConsent",
          where: [{field: "id", value: consent_data["id"]}],
          update: {scopes: scopes, updatedAt: Time.now}
        )
        ctx.json(oauth_consent_response(updated))
      end
    end

    def oauth_delete_consent_endpoint
      Endpoint.new(path: "/oauth2/delete-consent", method: "POST", metadata: oauth_openapi_for(:delete_consent)) do |ctx|
        session = Routes.current_session(ctx)
        body = OAuthProtocol.stringify_keys(ctx.body)
        id = body["id"]
        consent = if id.to_s.empty?
          oauth_find_user_consent(ctx, session, body["client_id"])
        else
          ctx.context.adapter.find_one(model: "oauthConsent", where: [{field: "id", value: id}])
        end
        raise APIError.new("NOT_FOUND", message: "missing id") if id.to_s.empty? && body["client_id"].to_s.empty?
        raise APIError.new("NOT_FOUND", message: "consent not found") unless consent
        raise APIError.new("UNAUTHORIZED") unless OAuthProtocol.stringify_keys(consent)["userId"] == session[:user]["id"]

        ctx.context.adapter.delete(model: "oauthConsent", where: [{field: "id", value: OAuthProtocol.stringify_keys(consent)["id"]}])
        ctx.json({deleted: true})
      end
    end

    def oauth_legacy_list_consents_endpoint
      Endpoint.new(path: "/oauth2/consents", method: "GET") do |ctx|
        session = Routes.current_session(ctx)
        consents = ctx.context.adapter.find_many(model: "oauthConsent", where: [{field: "userId", value: session[:user]["id"]}])
        ctx.json(consents.map { |consent| oauth_consent_response(consent) })
      end
    end

    def oauth_legacy_get_consent_endpoint
      Endpoint.new(path: "/oauth2/consent", method: "GET") do |ctx|
        session = Routes.current_session(ctx)
        query = OAuthProtocol.stringify_keys(ctx.query)
        consent = oauth_find_user_consent(ctx, session, query["client_id"])
        raise APIError.new("NOT_FOUND", message: "consent not found") unless consent
        ctx.json(oauth_consent_response(consent))
      end
    end

    def oauth_legacy_update_consent_endpoint
      Endpoint.new(path: "/oauth2/consent", method: "PATCH", metadata: oauth_openapi_for(:update_consent)) do |ctx|
        session = Routes.current_session(ctx)
        body = OAuthProtocol.stringify_keys(ctx.body)
        consent = oauth_find_user_consent(ctx, session, body["client_id"])
        raise APIError.new("NOT_FOUND", message: "consent not found") unless consent
        scopes = OAuthProtocol.parse_scopes(body["scope"] || body["scopes"])
        existing = OAuthProtocol.parse_scopes(OAuthProtocol.stringify_keys(consent)["scopes"])
        raise APIError.new("BAD_REQUEST", message: "invalid_scope") unless scopes.all? { |scope| existing.include?(scope) }

        updated = ctx.context.adapter.update(
          model: "oauthConsent",
          where: [{field: "id", value: OAuthProtocol.stringify_keys(consent)["id"]}],
          update: {scopes: scopes, updatedAt: Time.now}
        )
        ctx.json(oauth_consent_response(updated))
      end
    end

    def oauth_legacy_delete_consent_endpoint
      Endpoint.new(path: "/oauth2/consent", method: "DELETE") do |ctx|
        session = Routes.current_session(ctx)
        body = OAuthProtocol.stringify_keys(ctx.body)
        consent = oauth_find_user_consent(ctx, session, body["client_id"])
        raise APIError.new("NOT_FOUND", message: "consent not found") unless consent
        ctx.context.adapter.delete(model: "oauthConsent", where: [{field: "id", value: OAuthProtocol.stringify_keys(consent)["id"]}])
        ctx.json({deleted: true})
      end
    end
  end
end
