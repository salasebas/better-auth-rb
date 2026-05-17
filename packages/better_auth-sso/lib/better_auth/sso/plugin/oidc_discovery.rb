# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def sso_discover_oidc_config(issuer:, fetch: nil, existing_config: nil, discovery_endpoint: nil, trusted_origin: nil, timeout: nil)
      existing = normalize_hash(existing_config || {})
      discovery_url = discovery_endpoint || existing[:discovery_endpoint] || "#{issuer.to_s.sub(%r{/+\z}, "")}/.well-known/openid-configuration"
      if trusted_origin && !trusted_origin.call(discovery_url)
        raise APIError.new("BAD_REQUEST", message: "OIDC discovery endpoint is not trusted")
      end
      document = if fetch
        fetch.call(discovery_url)
      else
        uri = URI(discovery_url)
        JSON.parse(Net::HTTP.get(uri))
      end
      document = normalize_hash(document)
      valid = document[:issuer].to_s.sub(%r{/+\z}, "") == issuer.to_s.sub(%r{/+\z}, "") &&
        !document[:authorization_endpoint].to_s.empty? &&
        !document[:token_endpoint].to_s.empty? &&
        !document[:jwks_uri].to_s.empty?
      raise APIError.new("BAD_REQUEST", message: "Invalid OIDC discovery document") unless valid

      authorization_endpoint = sso_normalize_discovery_url(document[:authorization_endpoint], issuer, trusted_origin)
      token_endpoint = sso_normalize_discovery_url(document[:token_endpoint], issuer, trusted_origin)
      jwks_endpoint = sso_normalize_discovery_url(document[:jwks_uri], issuer, trusted_origin)
      user_info_endpoint = document[:userinfo_endpoint] && sso_normalize_discovery_url(document[:userinfo_endpoint], issuer, trusted_origin)
      auth_methods = Array(document[:token_endpoint_auth_methods_supported])
      token_endpoint_authentication = if existing[:token_endpoint_authentication]
        existing[:token_endpoint_authentication]
      elsif auth_methods.include?("client_secret_post") && !auth_methods.include?("client_secret_basic")
        "client_secret_post"
      else
        "client_secret_basic"
      end

      {
        issuer: existing[:issuer] || document[:issuer],
        discovery_endpoint: existing[:discovery_endpoint] || discovery_url,
        client_id: existing[:client_id],
        authorization_endpoint: existing[:authorization_endpoint] || authorization_endpoint,
        token_endpoint: existing[:token_endpoint] || token_endpoint,
        jwks_endpoint: existing[:jwks_endpoint] || jwks_endpoint,
        user_info_endpoint: existing[:user_info_endpoint] || user_info_endpoint,
        token_endpoint_authentication: token_endpoint_authentication,
        scopes_supported: existing[:scopes_supported] || document[:scopes_supported]
      }.compact
    rescue APIError
      raise
    rescue
      raise APIError.new("BAD_REQUEST", message: "Invalid OIDC discovery document")
    end

    def sso_normalize_discovery_url(value, issuer, trusted_origin)
      uri = URI(value.to_s)
      normalized = if uri.absolute?
        uri.to_s
      else
        issuer_uri = URI(issuer.to_s)
        issuer_base = issuer_uri.to_s.sub(%r{/+\z}, "")
        endpoint = value.to_s.sub(%r{\A/+}, "")
        "#{issuer_base}/#{endpoint}"
      end
      if trusted_origin && !trusted_origin.call(normalized)
        raise APIError.new("BAD_REQUEST", message: "OIDC discovery endpoint is not trusted")
      end

      normalized
    rescue URI::InvalidURIError
      raise APIError.new("BAD_REQUEST", message: "Invalid OIDC discovery document")
    end
  end
end
