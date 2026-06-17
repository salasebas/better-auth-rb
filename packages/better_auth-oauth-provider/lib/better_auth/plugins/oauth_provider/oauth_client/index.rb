# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def oauth_assert_owned_client!(client, session, config = nil)
      data = OAuthProtocol.stringify_keys(client)
      return if data["userId"] && data["userId"] == session[:user]["id"]

      if data["referenceId"] && config && config[:client_reference].respond_to?(:call)
        reference_id = config[:client_reference].call({user: session[:user], session: session[:session]})
        return if data["referenceId"] == reference_id
      end

      raise APIError.new("NOT_FOUND", message: "client not found")
    end

    def oauth_assert_client_privilege!(ctx, config, session, action)
      callback = config[:client_privileges]
      return unless callback.respond_to?(:call)

      allowed = callback.call({
        headers: ctx.headers,
        action: action,
        session: session[:session],
        user: session[:user]
      })
      raise APIError.new("UNAUTHORIZED") unless allowed
    end

    def oauth_assert_trusted_client_mutable!(client_id, config)
      trusted = config[:cached_trusted_clients]
      return unless trusted.is_a?(Set) && trusted.include?(client_id.to_s)

      raise APIError.new(
        "INTERNAL_SERVER_ERROR",
        message: "trusted clients must be updated manually",
        body: {error: "invalid_client", error_description: "trusted clients must be updated manually"}
      )
    end

    def oauth_find_client(ctx, config, client_id)
      OAuthProtocol.find_client(ctx, "oauthClient", client_id, cached_trusted_clients: config[:cached_trusted_clients])
    end

    def oauth_client_create_options(config)
      {
        generate_client_id: config[:generate_client_id] || config[:generateClientId],
        generate_client_secret: config[:generate_client_secret] || config[:generateClientSecret],
        client_registration_client_secret_expiration: config[:client_registration_client_secret_expiration] || config[:clientRegistrationClientSecretExpiration]
      }.compact
    end

    def oauth_token_options(config)
      {
        prefix: config[:prefix],
        format_refresh_token: config[:format_refresh_token] || config[:formatRefreshToken],
        generate_opaque_access_token: config[:generate_opaque_access_token] || config[:generateOpaqueAccessToken],
        generate_refresh_token: config[:generate_refresh_token] || config[:generateRefreshToken],
        store_tokens: config[:store_tokens]
      }
    end

    def oauth_client_reference(config, session)
      return nil unless session && config[:client_reference].respond_to?(:call)

      config[:client_reference].call({user: session[:user], session: session[:session]})
    end

    def oauth_client_update_data(source, admin: false)
      update = {}
      update["name"] = source["client_name"] || source["name"] if source.key?("client_name") || source.key?("name")
      update["uri"] = source["client_uri"] if source.key?("client_uri")
      update["icon"] = source["logo_uri"] if source.key?("logo_uri")
      if source.key?("redirect_uris")
        redirects = Array(source["redirect_uris"]).map(&:to_s)
        update["redirectUris"] = redirects
        update["redirectUrls"] = redirects.join(",")
      end
      update["postLogoutRedirectUris"] = Array(source["post_logout_redirect_uris"]).map(&:to_s) if source.key?("post_logout_redirect_uris")
      update["tokenEndpointAuthMethod"] = source["token_endpoint_auth_method"] || source["tokenEndpointAuthMethod"] if admin && (source.key?("token_endpoint_auth_method") || source.key?("tokenEndpointAuthMethod"))
      update["grantTypes"] = Array(source["grant_types"]).map(&:to_s) if source.key?("grant_types")
      update["responseTypes"] = Array(source["response_types"]).map(&:to_s) if source.key?("response_types")
      update["scopes"] = OAuthProtocol.parse_scopes(source["scope"] || source["scopes"]) if source.key?("scope") || source.key?("scopes")
      update["type"] = source["type"] if admin && source.key?("type")
      update["public"] = !!source["public"] if admin && source.key?("public")
      update["enableEndSession"] = !!(source["enable_end_session"] || source["enableEndSession"]) if source.key?("enable_end_session") || source.key?("enableEndSession")
      update["skipConsent"] = !!(source["skip_consent"] || source["skipConsent"]) if admin && (source.key?("skip_consent") || source.key?("skipConsent"))
      update["clientSecretExpiresAt"] = source["client_secret_expires_at"] if admin && source.key?("client_secret_expires_at")
      update["subjectType"] = source["subject_type"] || source["subjectType"] if admin && (source.key?("subject_type") || source.key?("subjectType"))
      update["metadata"] = source["metadata"] if source.key?("metadata")
      update
    end

    def oauth_validate_client_update!(client, source, config, admin:)
      return if source.empty?

      current = OAuthProtocol.stringify_keys(client)
      source = source.except("public", "token_endpoint_auth_method", "tokenEndpointAuthMethod", "client_secret", "clientSecret", "type") unless admin
      return if source.empty?

      redirects = source.key?("redirect_uris") ? Array(source["redirect_uris"]).map(&:to_s) : OAuthProtocol.client_redirect_uris(current)
      redirects.each { |uri| OAuthProtocol.validate_safe_url!(uri, field: "redirect_uris") }
      if source.key?("post_logout_redirect_uris")
        Array(source["post_logout_redirect_uris"]).map(&:to_s).each { |uri| OAuthProtocol.validate_safe_url!(uri, field: "post_logout_redirect_uris") }
      end

      auth_method = source["token_endpoint_auth_method"] || source["tokenEndpointAuthMethod"] || current["tokenEndpointAuthMethod"] || "client_secret_basic"
      body = {
        "token_endpoint_auth_method" => auth_method,
        "grant_types" => source.key?("grant_types") ? Array(source["grant_types"]).map(&:to_s) : Array(current["grantTypes"]).map(&:to_s),
        "response_types" => source.key?("response_types") ? Array(source["response_types"]).map(&:to_s) : Array(current["responseTypes"]).map(&:to_s),
        "type" => source.key?("type") ? source["type"] : current["type"],
        "subject_type" => source["subject_type"] || source["subjectType"] || current["subjectType"]
      }.compact
      OAuthProtocol.validate_client_metadata_enums!(auth_method, body)
      OAuthProtocol.validate_admin_only_fields!(source, admin: admin)
      OAuthProtocol.validate_client_registration!(auth_method, body["grant_types"], body["response_types"], body, unauthenticated: false, dynamic_registration: false)
      OAuthProtocol.validate_pairwise_client!(body, redirects, config[:pairwise_secret])

      return unless source.key?("scope") || source.key?("scopes")

      scopes = OAuthProtocol.parse_scopes(source["scope"] || source["scopes"])
      allowed = OAuthProtocol.parse_scopes(config[:client_registration_allowed_scopes] || config[:scopes])
      unless allowed.empty? || scopes.all? { |scope| allowed.include?(scope) }
        raise APIError.new("BAD_REQUEST", message: "invalid_scope")
      end
    end

    def oauth_public_client_response(client)
      data = OAuthProtocol.stringify_keys(client)
      {
        client_id: data["clientId"],
        client_name: data["name"],
        client_uri: data["uri"],
        logo_uri: data["icon"],
        contacts: data["contacts"] || [],
        tos_uri: data["tos"],
        policy_uri: data["policy"]
      }.compact
    end
  end
end
