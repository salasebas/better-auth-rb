# frozen_string_literal: true

require "uri"

module BetterAuth
  module Plugins
    module OAuthProtocol
      module_function

      def client_redirect_uris(client)
        value = client["redirectUris"] || client["redirectUrls"] || client[:redirect_uris] || client[:redirectUrls]
        return value if value.is_a?(Array)

        value.to_s.split(",").map(&:strip).reject(&:empty?)
      end

      def client_logout_redirect_uris(client)
        value = client["postLogoutRedirectUris"] || client[:post_logout_redirect_uris]
        return value if value.is_a?(Array)

        value.to_s.split(",").map(&:strip).reject(&:empty?)
      end

      def create_client(ctx, model:, body:, owner_session: nil, default_auth_method: "client_secret_basic", store_client_secret: "plain", unauthenticated: false, default_scopes: nil, allowed_scopes: nil, prefix: {}, dynamic_registration: false, admin: false, pairwise_secret: nil, strip_client_metadata: false, reference_id: nil, generate_client_id: nil, generate_client_secret: nil, client_registration_client_secret_expiration: nil)
        body = request_body!(body || {})
        requested_auth_method = body["token_endpoint_auth_method"] || default_auth_method
        validate_client_metadata_enums!(requested_auth_method, body)
        validate_admin_only_fields!(body, admin: admin)
        auth_method = unauthenticated ? "none" : requested_auth_method
        public_client = auth_method == "none"
        client_id = generate_client_id.respond_to?(:call) ? generate_client_id.call : Crypto.random_string(32)
        client_secret = if public_client
          nil
        else
          generate_client_secret.respond_to?(:call) ? generate_client_secret.call : Crypto.random_string(32)
        end
        redirects = Array(body["redirect_uris"]).map(&:to_s)
        raise APIError.new("BAD_REQUEST", message: "redirect_uris is required") if redirects.empty?
        redirects.each { |uri| validate_safe_url!(uri, field: "redirect_uris") }
        Array(body["post_logout_redirect_uris"]).map(&:to_s).each { |uri| validate_safe_url!(uri, field: "post_logout_redirect_uris") }

        grant_types = Array(body["grant_types"] || [AUTH_CODE_GRANT]).map(&:to_s)
        response_types = Array(body["response_types"] || ["code"]).map(&:to_s)
        validate_client_registration!(auth_method, grant_types, response_types, body, unauthenticated: unauthenticated, dynamic_registration: dynamic_registration)
        validate_redirect_scheme_for_client!(auth_method, body, redirects)
        validate_pairwise_client!(body, redirects, pairwise_secret)

        scope_configured = body.key?("scope") || body.key?("scopes")
        scopes = parse_scopes(body["scope"] || body["scopes"])
        scopes = parse_scopes(default_scopes) if scopes.empty? && default_scopes
        allowed = parse_scopes(allowed_scopes)
        unless allowed.empty? || scopes.all? { |scope| allowed.include?(scope) }
          raise APIError.new("BAD_REQUEST", message: "invalid_scope")
        end

        metadata = client_metadata(body, strip_unknown: strip_client_metadata)
        metadata["software_id"] = body["software_id"] if body["software_id"]
        metadata["software_version"] = body["software_version"] if body["software_version"]
        metadata["software_statement"] = body["software_statement"] if body["software_statement"]
        metadata["tos_uri"] = body["tos_uri"] if body["tos_uri"]
        metadata["policy_uri"] = body["policy_uri"] if body["policy_uri"]
        require_pkce = body.key?("require_pkce") ? body["require_pkce"] : body["requirePKCE"]
        require_pkce = true if dynamic_registration && require_pkce.nil?

        client_type = if unauthenticated && public_client && body["type"] == "web"
          nil
        else
          body["type"] || (public_client ? nil : "web")
        end
        issued_at = Time.now.to_i
        secret_expires_at = if client_secret && dynamic_registration && !client_registration_client_secret_expiration.nil?
          resolve_client_secret_expires_at(client_registration_client_secret_expiration, issued_at)
        elsif admin
          body["client_secret_expires_at"] || 0
        end
        data = {
          "clientId" => client_id,
          "clientSecret" => client_secret ? store_client_secret_value(ctx, client_secret, store_client_secret) : nil,
          "public" => public_client,
          "type" => client_type,
          "name" => body["client_name"] || body["name"] || "OAuth Client",
          "icon" => body["logo_uri"],
          "uri" => body["client_uri"],
          "contacts" => Array(body["contacts"]).map(&:to_s),
          "tos" => body["tos_uri"],
          "policy" => body["policy_uri"],
          "softwareId" => body["software_id"] || metadata["software_id"],
          "softwareVersion" => body["software_version"] || metadata["software_version"],
          "softwareStatement" => body["software_statement"] || metadata["software_statement"],
          "redirectUris" => redirects,
          "redirectUrls" => redirects.join(","),
          "postLogoutRedirectUris" => Array(body["post_logout_redirect_uris"]).map(&:to_s),
          "clientSecretExpiresAt" => secret_expires_at,
          "tokenEndpointAuthMethod" => auth_method,
          "grantTypes" => grant_types,
          "responseTypes" => response_types,
          "scopes" => (scopes if scope_configured || default_scopes),
          "skipConsent" => unauthenticated ? false : !!(body["skip_consent"] || body["skipConsent"]),
          "enableEndSession" => !!(body["enable_end_session"] || body["enableEndSession"]),
          "requirePKCE" => require_pkce,
          "subjectType" => body["subject_type"] || body["subjectType"],
          "metadata" => metadata,
          "disabled" => false
        }
        data["referenceId"] = reference_id if reference_id
        data["userId"] = owner_session[:user]["id"] if owner_session && !reference_id
        created = ctx.context.adapter.create(model: model, data: data)
        response = client_response(created).merge(
          client_secret: client_secret ? apply_prefix(client_secret, prefix, :client_secret) : nil,
          client_id_issued_at: Time.now.to_i
        ).compact
        response[:require_pkce] = require_pkce unless require_pkce.nil?
        if client_secret
          expires = stringify_keys(created || {})["clientSecretExpiresAt"] || secret_expires_at
          response[:client_secret_expires_at] = timestamp_seconds(expires) || 0
        end
        response
      end

      def client_response(client, include_secret: true)
        data = stringify_keys(client || {})
        metadata = stringify_keys(data["metadata"] || {})
        response = {
          client_id: data["clientId"],
          client_name: data["name"],
          client_uri: data["uri"],
          logo_uri: data["icon"],
          redirect_uris: client_redirect_uris(data),
          post_logout_redirect_uris: client_logout_redirect_uris(data),
          token_endpoint_auth_method: data["tokenEndpointAuthMethod"] || "client_secret_basic",
          grant_types: data["grantTypes"] || [],
          response_types: data["responseTypes"] || [],
          scope: (scope_string(data["scopes"]) unless data["scopes"].nil?),
          public: !!data["public"],
          type: data["type"],
          user_id: data["userId"],
          reference_id: data["referenceId"],
          require_pkce: client_require_pkce(data),
          subject_type: data["subjectType"],
          metadata: metadata,
          contacts: data["contacts"] || [],
          tos_uri: data["tos"],
          policy_uri: data["policy"],
          software_id: data["softwareId"],
          software_version: data["softwareVersion"],
          software_statement: data["softwareStatement"],
          client_secret_expires_at: data["clientSecretExpiresAt"]
        }
        response[:skip_consent] = true if data["skipConsent"]
        metadata.each { |key, value| response[key.to_sym] = value }
        response[:client_secret] = data["clientSecret"] if include_secret && data["clientSecret"]
        response.compact
      end

      def validate_client_registration!(auth_method, grant_types, response_types, body, unauthenticated:, dynamic_registration:)
        public_client = auth_method == "none"
        if dynamic_registration && (body["require_pkce"] == false || body["requirePKCE"] == false)
          raise APIError.new("BAD_REQUEST", message: "pkce is required for registered clients")
        end
        if dynamic_registration && (body["enable_end_session"] || body["enableEndSession"])
          raise APIError.new("BAD_REQUEST", message: "enable_end_session is not allowed during dynamic client registration")
        end
        if public_client && grant_types.include?(CLIENT_CREDENTIALS_GRANT)
          raise APIError.new("BAD_REQUEST", message: "public clients cannot use client_credentials")
        end
        if grant_types.include?(AUTH_CODE_GRANT) && !response_types.include?("code")
          raise APIError.new("BAD_REQUEST", message: "authorization_code clients must support code response_type")
        end
        if auth_method != "none" && ["native", "user-agent-based"].include?(body["type"])
          raise APIError.new("BAD_REQUEST", message: "public client types must use token_endpoint_auth_method none")
        end
        if !unauthenticated && auth_method == "none" && body["type"] == "web"
          raise APIError.new("BAD_REQUEST", message: "web clients must be confidential")
        end
      end

      def validate_redirect_scheme_for_client!(auth_method, body, redirects)
        return if auth_method == "none" && body["type"] != "web"

        redirects.each do |value|
          uri = URI.parse(value.to_s)
          next if uri.scheme == "https"
          next if uri.scheme == "http" && loopback_host?(uri.hostname || uri.host)

          raise APIError.new("BAD_REQUEST", message: "redirect_uris is invalid")
        end
      rescue URI::InvalidURIError
        raise APIError.new("BAD_REQUEST", message: "redirect_uris is invalid")
      end

      def validate_pairwise_client!(body, redirects, pairwise_secret)
        subject_type = body["subject_type"] || body["subjectType"]
        return unless subject_type == "pairwise"

        raise APIError.new("BAD_REQUEST", message: "pairwise subject_type requires pairwise_secret") if pairwise_secret.to_s.empty?

        hosts = redirects.map { |uri| URI.parse(uri).host }.uniq
        if hosts.length > 1
          raise APIError.new(
            "BAD_REQUEST",
            message: "pairwise clients with redirect_uris on different hosts require a sector_identifier_uri, which is not yet supported. All redirect_uris must share the same host."
          )
        end
      rescue URI::InvalidURIError
        raise APIError.new("BAD_REQUEST", message: "invalid redirect_uris")
      end

      def validate_safe_url!(value, field:)
        raise APIError.new("BAD_REQUEST", message: "#{field} is invalid") if value.to_s.empty?

        uri = URI.parse(value.to_s)
        scheme = uri.scheme.to_s.downcase
        raise APIError.new("BAD_REQUEST", message: "#{field} is invalid") if scheme.empty?
        raise APIError.new("BAD_REQUEST", message: "#{field} is invalid") if %w[javascript data vbscript].include?(scheme)

        if scheme == "http"
          raise APIError.new("BAD_REQUEST", message: "#{field} is invalid") unless ["localhost", "127.0.0.1", "::1"].include?(uri.hostname || uri.host)
        end
        true
      rescue URI::InvalidURIError
        raise APIError.new("BAD_REQUEST", message: "#{field} is invalid")
      end

      def client_metadata(body, strip_unknown: false)
        raw_metadata = body["metadata"]
        unless raw_metadata.nil? || raw_metadata.is_a?(Hash)
          raise APIError.new("BAD_REQUEST", message: "metadata must be an object")
        end
        metadata = stringify_keys(raw_metadata || {})
        metadata = metadata.slice("software_id", "software_version", "software_statement", "tos_uri", "policy_uri") if strip_unknown
        metadata["software_id"] = body["software_id"] if body["software_id"]
        metadata["software_version"] = body["software_version"] if body["software_version"]
        metadata["software_statement"] = body["software_statement"] if body["software_statement"]
        metadata["tos_uri"] = body["tos_uri"] if body["tos_uri"]
        metadata["policy_uri"] = body["policy_uri"] if body["policy_uri"]
        metadata
      end

      def validate_client_metadata_enums!(auth_method, body)
        unless ["client_secret_basic", "client_secret_post", "none"].include?(auth_method)
          raise APIError.new("BAD_REQUEST", message: "invalid token_endpoint_auth_method")
        end

        invalid_grant = Array(body["grant_types"]).map(&:to_s) - [AUTH_CODE_GRANT, CLIENT_CREDENTIALS_GRANT, REFRESH_GRANT]
        raise APIError.new("BAD_REQUEST", message: "invalid grant_types") unless invalid_grant.empty?

        invalid_response = Array(body["response_types"]).map(&:to_s) - ["code"]
        raise APIError.new("BAD_REQUEST", message: "invalid response_types") unless invalid_response.empty?

        client_type = body["type"]
        if client_type && !["web", "native", "user-agent-based"].include?(client_type)
          raise APIError.new("BAD_REQUEST", message: "invalid type")
        end
      end

      def validate_admin_only_fields!(body, admin:)
        return if admin

        %w[client_secret_expires_at clientSecretExpiresAt].each do |key|
          raise APIError.new("BAD_REQUEST", message: "field #{key} is server-only") if body.key?(key)
        end
      end

      def resolve_client_secret_expires_at(value, issued_at)
        return value.to_i if value.is_a?(Numeric)
        return value.to_i if value.is_a?(Time)

        seconds = timestamp_seconds(value)
        return seconds if seconds && !value.is_a?(String)

        issued_at.to_i + parse_duration(value.to_s)
      rescue TypeError
        0
      end

      def parse_duration(value)
        match = value.strip.match(/\A(-?\d+)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|week|weeks|y|yr|yrs|year|years)(?:\s+from now|\s+ago)?\z/i)
        raise TypeError, "Invalid time string" unless match

        amount = match[1].to_i
        amount = -amount if value.include?("ago")
        unit = match[2].downcase
        multiplier = case unit
        when "s", "sec", "secs", "second", "seconds" then 1
        when "m", "min", "mins", "minute", "minutes" then 60
        when "h", "hr", "hrs", "hour", "hours" then 3600
        when "d", "day", "days" then 86_400
        when "w", "week", "weeks" then 604_800
        else 31_557_600
        end
        amount * multiplier
      end
    end
  end
end
