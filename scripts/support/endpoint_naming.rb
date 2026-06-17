# frozen_string_literal: true

module EndpointNaming
  ACRONYM_REPLACEMENTS = [
    [/\AoAuth2(?=[A-Z]|$)/, "oauth2"],
    [/(?<=[a-z])OAuth2(?=[A-Z]|$)/, "oauth2"],
    [/\AoAuth(?=[A-Z]|$)/, "oauth"],
    [/(?<=[a-z])OAuth(?=[A-Z]|$)/, "oauth"],
    [/OpenAPI(?=[A-Z]|$)/, "openapi"],
    [/OpenId(?=[A-Z]|$)/, "openid"],
    [/OIDC(?=[A-Z]|$)/, "oidc"],
    [/SCIM(?=[A-Z]|$)/, "scim"],
    [/SSO(?=[A-Z]|$)/, "sso"],
    [/OTP(?=[A-Z]|$)/, "otp"],
    [/JWT(?=[A-Z]|$)/, "jwt"],
    [/URL(?=[A-Z]|$)/, "url"],
    [/API(?=[A-Z]|$)/, "api"],
    [/SIWE(?=[A-Z]|$)/, "siwe"]
  ].freeze

  APPROVED_RUBY_REGISTRY_KEYS = {
    "listUserAccounts" => "list_accounts",
    "linkSocialAccount" => "link_social",
    "registerOAuthApplication" => "register_oauth_client",
    "rotateClientSecret" => "rotate_oauth_client_secret",
    "oAuthConsent" => "oauth2_consent",
    "oAuthProxy" => "oauth_proxy",
    "getOAuthServerConfig" => "get_oauth_server_config"
  }.freeze

  module_function

  def upstream_registry_key_to_ruby(key)
    approved = APPROVED_RUBY_REGISTRY_KEYS[key.to_s]
    return approved if approved

    normalized = key.to_s.dup
    placeholders = {}
    ACRONYM_REPLACEMENTS.each_with_index do |(pattern, replacement), index|
      token = "__ACR#{index}__"
      placeholders[token] = replacement
      normalized.gsub!(pattern) { token }
    end

    ruby_key = normalized
      .gsub(/([a-z\d])([A-Z])/, '\1_\2')
      .tr("-", "_")
      .downcase

    placeholders.each { |token, replacement| ruby_key.gsub!(token.downcase, "_#{replacement}_") }
    ruby_key
      .squeeze("_")
      .gsub(/\A_|_\z/, "")
      .gsub(/\bo_auth2\b/, "oauth2")
      .gsub(/\bo_auth\b/, "oauth")
  end

  def normalize_api_name(name)
    return nil if name.nil? || name.to_s.strip.empty?

    upstream_registry_key_to_ruby(name)
  end

  def registry_keys_equivalent?(upstream_registry_key, ruby_endpoint_key)
    expected = upstream_registry_key_to_ruby(upstream_registry_key)
    actual = ruby_endpoint_key.to_s
    expected == actual || APPROVED_RUBY_REGISTRY_KEYS[upstream_registry_key.to_s] == actual
  end

  def upstream_api_call(registry_key)
    "auth.api.#{registry_key}"
  end

  def ruby_api_call(ruby_registry_key)
    "auth.api.#{ruby_registry_key}"
  end
end
