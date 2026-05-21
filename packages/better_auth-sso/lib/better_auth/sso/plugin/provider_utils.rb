# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def sso_oidc_redirect_uri(context, provider_id)
      redirect_uri = context.options.plugins.find { |plugin| plugin.id == "sso" }&.options&.fetch(:redirect_uri, nil)
      if redirect_uri && !redirect_uri.to_s.strip.empty?
        value = redirect_uri.to_s
        return value if URI(value).absolute?

        path = value.start_with?("/") ? value : "/#{value}"
        return "#{context.base_url}#{path}"
      end

      "#{context.base_url}/sso/callback/#{URI.encode_www_form_component(provider_id.to_s)}"
    rescue URI::InvalidURIError
      "#{context.base_url}/sso/callback/#{URI.encode_www_form_component(provider_id.to_s)}"
    end

    def sso_email_domain_matches?(email_domain, provider_domain)
      email_domain = email_domain.to_s.strip.downcase
      email_domain = email_domain.split("@", 2).last if email_domain.include?("@")
      return false if email_domain.to_s.empty?

      provider_domain.to_s.split(",").map { |value| value.strip.downcase }.reject(&:empty?).any? do |domain|
        email_domain == domain || email_domain.end_with?(".#{domain}")
      end
    end

    def sso_find_provider!(ctx, provider_id)
      provider = ctx.context.adapter.find_one(model: "ssoProvider", where: [{field: "providerId", value: provider_id.to_s}])
      raise APIError.new("NOT_FOUND", message: "Provider not found", code: "PROVIDER_NOT_FOUND") unless provider

      provider
    end

    def sso_find_saml_provider!(ctx, provider_id, config = {})
      if config[:default_sso]
        provider = sso_default_provider(config, provider_id: provider_id.to_s, domain: "")
        return provider if provider && provider["samlConfig"]
      end

      provider = ctx.context.adapter.find_one(model: "ssoProvider", where: [{field: "providerId", value: provider_id.to_s}])
      raise APIError.new("NOT_FOUND", message: "Provider not found", code: "PROVIDER_NOT_FOUND") unless provider && provider["samlConfig"]

      provider
    end

    def sso_provider_access?(provider, user_id, ctx)
      organization_id = provider["organizationId"]
      return provider["userId"] == user_id if organization_id.to_s.empty?
      return provider["userId"] == user_id unless ctx.context.options.plugins.any? { |plugin| plugin.id == "organization" }

      member = ctx.context.adapter.find_one(
        model: "member",
        where: [{field: "userId", value: user_id}, {field: "organizationId", value: organization_id}]
      )
      Array(member&.fetch("role", nil).to_s.split(",")).map(&:strip).any? { |role| %w[owner admin].include?(role) }
    end

    def sso_authorize_domain_verification!(ctx, provider, user_id)
      organization_id = provider["organizationId"]
      is_org_member = true
      if organization_id
        is_org_member = !!ctx.context.adapter.find_one(
          model: "member",
          where: [{field: "userId", value: user_id}, {field: "organizationId", value: organization_id}]
        )
      end
      return if provider["userId"] == user_id && is_org_member

      raise APIError.new("FORBIDDEN", message: "User must be owner of or belong to the SSO provider organization", code: "INSUFFICIENT_ACCESS")
    end

    def sso_txt_record_exact_match?(records, expected)
      Array(records).flatten.any? { |record| record.to_s.strip == expected.to_s }
    end

    def sso_domain_verification_identifier(config, provider_id)
      prefix = config.dig(:domain_verification, :token_prefix) || "better-auth-token"
      "_#{prefix}-#{provider_id}"
    end

    def sso_future_time?(value)
      time = value.is_a?(Time) ? value : Time.parse(value.to_s)
      time > Time.now
    rescue
      false
    end

    def sso_hostname_from_domain(domain)
      value = domain.to_s.strip
      return nil if value.empty?

      uri = URI(value.include?("://") ? value : "https://#{value}")
      uri.host
    rescue URI::InvalidURIError
      nil
    end

    def sso_resolve_txt_records(hostname, config)
      resolver = config.dig(:domain_verification, :dns_txt_resolver)
      return Array(resolver.call(hostname)) if resolver.respond_to?(:call)

      Resolv::DNS.open do |dns|
        dns.getresources(hostname, Resolv::DNS::Resource::IN::TXT).map { |record| record.strings }
      end
    rescue
      []
    end

    def sso_sanitize_provider(provider, context)
      data = provider.dup
      oidc_config = sso_provider_config_hash(data["oidcConfig"])
      saml_config = sso_provider_config_hash(data["samlConfig"])
      data["type"] = saml_config.empty? ? "oidc" : "saml"
      data["organizationId"] ||= nil
      data["domainVerified"] = !!data["domainVerified"]
      data.delete("domainVerified") unless sso_context_domain_verification_enabled?(context)
      data["oidcConfig"] = oidc_config.empty? ? nil : sso_sanitize_oidc_config(oidc_config)
      data["samlConfig"] = saml_config.empty? ? nil : sso_sanitize_saml_config(saml_config)
      data["spMetadataUrl"] = "#{context.base_url}/sso/saml2/sp/metadata?providerId=#{URI.encode_www_form_component(data.fetch("providerId"))}"
      data.compact
    end

    def sso_provider_config_hash(value)
      return normalize_hash(value) if value.is_a?(Hash)
      return {} if value.nil? || value.to_s.strip.empty?

      parsed = JSON.parse(value.to_s)
      normalize_hash(parsed)
    rescue JSON::ParserError, TypeError
      {}
    end

    def sso_context_domain_verification_enabled?(context)
      context.options.plugins.any? do |plugin|
        plugin.id == "sso" && plugin.options.dig(:domain_verification, :enabled)
      end
    end

    def sso_sanitize_config(config)
      data = normalize_hash(config || {})
      data.delete(:client_secret)
      data.each_with_object({}) { |(key, value), result| result[Schema.storage_key(key)] = value unless value.respond_to?(:call) }
    end

    def sso_sanitize_oidc_config(config)
      {
        "clientIdLastFour" => sso_mask_client_id(config[:client_id]),
        "authorizationEndpoint" => config[:authorization_endpoint],
        "tokenEndpoint" => config[:token_endpoint],
        "userInfoEndpoint" => config[:user_info_endpoint],
        "jwksEndpoint" => config[:jwks_endpoint],
        "scopes" => config[:scopes],
        "tokenEndpointAuthentication" => config[:token_endpoint_authentication],
        "pkce" => config[:pkce],
        "discoveryEndpoint" => config[:discovery_endpoint],
        "mapping" => config[:mapping] && sso_sanitize_config(config[:mapping])
      }.compact
    end

    def sso_sanitize_saml_config(config)
      {
        "entryPoint" => config[:entry_point],
        "callbackUrl" => config[:callback_url],
        "audience" => config[:audience],
        "wantAssertionsSigned" => config[:want_assertions_signed],
        "authnRequestsSigned" => config[:authn_requests_signed],
        "identifierFormat" => config[:identifier_format],
        "signatureAlgorithm" => config[:signature_algorithm],
        "digestAlgorithm" => config[:digest_algorithm],
        "certificate" => sso_parse_certificate(config[:cert]),
        "idpMetadata" => sso_sanitize_saml_metadata_config(config[:idp_metadata]),
        "spMetadata" => sso_sanitize_saml_metadata_config(config[:sp_metadata]),
        "mapping" => config[:mapping] && sso_sanitize_config(config[:mapping])
      }.compact
    end

    def sso_sanitize_saml_metadata_config(metadata)
      data = normalize_hash(metadata || {})
      return nil if data.empty?

      data.except(:private_key, :private_key_pass, :enc_private_key, :enc_private_key_pass, :decryption_pvk).each_with_object({}) do |(key, value), result|
        result[(key == :entity_id) ? "entityID" : Schema.storage_key(key)] = value
      end
    end

    def sso_mask_client_id(client_id)
      value = client_id.to_s
      return "****" if value.length <= 4

      "****#{value[-4, 4]}"
    end

    def sso_parse_certificate(cert)
      OpenSSL::X509::Certificate.new(cert.to_s)
      {subject: cert.to_s.lines.first.to_s.strip}
    rescue
      {error: "Failed to parse certificate"}
    end

    def sso_fetch(data, key)
      return nil unless data.respond_to?(:[])

      compact = key.to_s.delete("_").downcase
      direct = data[key] ||
        data[key.to_s] ||
        data[Schema.storage_key(key)] ||
        data[Schema.storage_key(key).to_sym] ||
        data[compact] ||
        data[compact.to_sym]
      return direct unless direct.nil?

      data.each do |candidate, value|
        normalized = candidate.to_s.delete("_").downcase
        return value if normalized == compact
      end
      nil
    end

    def sso_redirect(ctx, location)
      [302, ctx.response_headers.merge("location" => location), [""]]
    end

    def sso_safe_oidc_redirect_url(ctx, url)
      app_origin = ctx.context.base_url
      value = url.to_s
      return app_origin if value.empty?

      return value if value.start_with?("/") && !value.start_with?("//")
      return app_origin unless ctx.context.trusted_origin?(value, allow_relative_paths: false)

      value
    rescue
      app_origin
    end
  end
end
