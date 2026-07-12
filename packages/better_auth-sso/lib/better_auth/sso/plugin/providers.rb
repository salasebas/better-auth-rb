# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def sso_register_provider_endpoint(config = {})
      Endpoint.new(path: "/sso/register", method: "POST", metadata: sso_openapi_for(:register_provider)) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        provider_id = body[:provider_id].to_s
        raise APIError.new("BAD_REQUEST", message: "providerId is required") if provider_id.empty?

        limit = sso_provider_limit(session.fetch(:user), config)
        if limit.to_i.zero?
          raise APIError.new("FORBIDDEN", message: "SSO provider registration is disabled")
        end
        providers = ctx.context.adapter.find_many(model: "ssoProvider", where: [{field: "userId", value: session.fetch(:user).fetch("id")}])
        if providers.length >= limit.to_i
          raise APIError.new("FORBIDDEN", message: "You have reached the maximum number of SSO providers")
        end

        sso_validate_url!(body[:issuer], "Invalid issuer. Must be a valid URL")
        sso_validate_organization_membership!(ctx, session.fetch(:user).fetch("id"), body[:organization_id]) if body[:organization_id]
        if ctx.context.adapter.find_one(model: "ssoProvider", where: [{field: "providerId", value: provider_id}])
          raise APIError.new("UNPROCESSABLE_ENTITY", message: "SSO provider with this providerId already exists")
        end

        oidc_config = normalize_hash(body[:oidc_config] || {})
        sso_validate_oidc_endpoint_origins!(ctx, oidc_config) if oidc_config.any?
        oidc_config = sso_hydrate_oidc_config(body[:issuer], oidc_config, ctx) if oidc_config.any? && !oidc_config[:skip_discovery]
        sso_validate_oidc_endpoint_origins!(ctx, oidc_config) if oidc_config.any?
        oidc_config[:override_user_info] = !!(body[:override_user_info] || config[:default_override_user_info]) if oidc_config.any?
        saml_config = normalize_hash(body[:saml_config] || {})
        sso_validate_saml_config!(saml_config, config) unless saml_config.empty?

        provider = ctx.context.adapter.create(
          model: "ssoProvider",
          data: {
            providerId: provider_id,
            issuer: body[:issuer].to_s,
            domain: body[:domain].to_s.downcase,
            oidcConfig: oidc_config.empty? ? nil : oidc_config,
            samlConfig: saml_config.empty? ? nil : saml_config,
            userId: session.fetch(:user).fetch("id"),
            organizationId: body[:organization_id],
            domainVerified: false
          }
        )
        domain_verification_token = nil
        if config.dig(:domain_verification, :enabled)
          domain_verification_token = BetterAuth::Crypto.random_string(24)
          ctx.context.internal_adapter.create_verification_value(
            identifier: sso_domain_verification_identifier(config, provider.fetch("providerId")),
            value: domain_verification_token,
            expiresAt: Time.now + (7 * 24 * 60 * 60)
          )
        end
        response = sso_sanitize_provider(provider, ctx.context)
        response[:redirectURI] = sso_oidc_redirect_uri(ctx.context, provider.fetch("providerId"))
        response[:domainVerificationToken] = domain_verification_token if domain_verification_token
        ctx.json(response)
      end
    end

    def sso_list_providers_endpoint
      Endpoint.new(path: "/sso/providers", method: "GET") do |ctx|
        session = Routes.current_session(ctx)
        providers = ctx.context.adapter.find_many(model: "ssoProvider")
          .select { |provider| sso_provider_access?(provider, session.fetch(:user).fetch("id"), ctx) }
          .map { |provider| sso_sanitize_provider(provider, ctx.context) }
        ctx.json({providers: providers})
      end
    end

    def sso_get_provider_endpoint
      Endpoint.new(path: "/sso/get-provider", method: "GET") do |ctx|
        session = Routes.current_session(ctx)
        provider = sso_find_provider!(ctx, sso_fetch(ctx.query, :provider_id) || sso_fetch(ctx.params, :provider_id))
        raise APIError.new("FORBIDDEN", message: "You don't have access to this provider") unless sso_provider_access?(provider, session.fetch(:user).fetch("id"), ctx)

        ctx.json(sso_sanitize_provider(provider, ctx.context))
      end
    end

    def sso_update_provider_endpoint(config = {})
      Endpoint.new(path: "/sso/update-provider", method: "POST", metadata: sso_openapi_for(:update_provider)) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        provider = sso_find_provider!(ctx, sso_fetch(body, :provider_id) || sso_fetch(ctx.params, :provider_id))
        raise APIError.new("FORBIDDEN", message: "You don't have access to this provider") unless sso_provider_access?(provider, session.fetch(:user).fetch("id"), ctx)

        if !body.key?(:issuer) && !body.key?(:domain) && !body.key?(:oidc_config) && !body.key?(:saml_config)
          raise APIError.new("BAD_REQUEST", message: "No fields provided for update")
        end
        sso_validate_url!(body[:issuer], "Invalid issuer. Must be a valid URL") if body.key?(:issuer)
        update = {}
        update[:issuer] = body[:issuer] if body.key?(:issuer)
        update[:domain] = body[:domain].to_s.downcase if body.key?(:domain)
        update[:domainVerified] = false if body.key?(:domain) && body[:domain].to_s.downcase != provider["domain"].to_s
        if body.key?(:oidc_config)
          current = sso_provider_config_hash(provider["oidcConfig"])
          raise APIError.new("BAD_REQUEST", message: "Cannot update OIDC config for a provider that doesn't have OIDC configured") if current.empty?

          resolved_issuer = update[:issuer] || current[:issuer] || provider["issuer"]
          update[:oidcConfig] = current.merge(normalize_hash(body[:oidc_config])).merge(issuer: resolved_issuer).compact
          sso_validate_oidc_endpoint_origins!(ctx, update[:oidcConfig])
        end
        if body.key?(:saml_config)
          current = sso_provider_config_hash(provider["samlConfig"])
          raise APIError.new("BAD_REQUEST", message: "Cannot update SAML config for a provider that doesn't have SAML configured") if current.empty?

          resolved_issuer = update[:issuer] || current[:issuer] || provider["issuer"]
          merged_saml_config = current.merge(normalize_hash(body[:saml_config])).merge(issuer: resolved_issuer).compact
          sso_validate_saml_config!(merged_saml_config, config)
          update[:samlConfig] = merged_saml_config
        end
        updated = ctx.context.adapter.update(model: "ssoProvider", where: [{field: "id", value: provider.fetch("id")}], update: update)
        ctx.json(sso_sanitize_provider(updated, ctx.context))
      end
    end

    def sso_delete_provider_endpoint
      Endpoint.new(path: "/sso/delete-provider", method: "POST", metadata: sso_openapi_for(:delete_provider)) do |ctx|
        session = Routes.current_session(ctx)
        provider = sso_find_provider!(ctx, sso_fetch(ctx.body, :provider_id) || sso_fetch(ctx.params, :provider_id))
        raise APIError.new("FORBIDDEN", message: "You don't have access to this provider") unless sso_provider_access?(provider, session.fetch(:user).fetch("id"), ctx)

        ctx.context.adapter.delete(model: "ssoProvider", where: [{field: "id", value: provider.fetch("id")}])
        ctx.json({success: true})
      end
    end
  end
end
