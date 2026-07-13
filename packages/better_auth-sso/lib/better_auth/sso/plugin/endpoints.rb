# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def sso_saml_callback_endpoint(config)
      Endpoint.new(path: "/sso/saml2/callback/:providerId", method: ["GET", "POST"], metadata: sso_openapi_for(:saml_callback).merge(allowed_media_types: ["application/json", "application/x-www-form-urlencoded"])) do |ctx|
        sso_handle_saml_response(ctx, config)
      end
    end

    def sso_saml_acs_endpoint(config)
      Endpoint.new(path: "/sso/saml2/sp/acs/:providerId", method: "POST", metadata: sso_openapi_for(:saml_acs).merge(allowed_media_types: ["application/json", "application/x-www-form-urlencoded"])) do |ctx|
        sso_handle_saml_response(ctx, config)
      end
    end

    def sso_sp_metadata_endpoint(config = {})
      Endpoint.new(path: "/sso/saml2/sp/metadata", method: "GET") do |ctx|
        provider = sso_find_saml_provider!(ctx, sso_fetch(ctx.query, :provider_id), config)
        metadata = sso_sp_metadata_xml(ctx, provider, config)
        if (ctx.query[:format] || ctx.query["format"]) == "json"
          ctx.json({providerId: provider.fetch("providerId"), metadata: metadata})
        else
          ctx.set_header("content-type", "application/samlmetadata+xml")
          ctx.json(metadata)
        end
      end
    end

    def sso_saml_slo_endpoint(config = {})
      Endpoint.new(path: "/sso/saml2/sp/slo/:providerId", method: ["GET", "POST"], metadata: sso_openapi_for(:saml_slo).merge(allowed_media_types: ["application/json", "application/x-www-form-urlencoded"])) do |ctx|
        raise APIError.new("BAD_REQUEST", message: "Single Logout is not enabled") unless config.dig(:saml, :enable_single_logout)

        provider = sso_find_saml_provider!(ctx, sso_fetch(ctx.params, :provider_id), config)
        relay_state = sso_fetch(ctx.body, :relay_state) || sso_fetch(ctx.query, :relay_state)
        if sso_fetch(ctx.body, :saml_response) || sso_fetch(ctx.query, :saml_response)
          raw_response = sso_fetch(ctx.body, :saml_response) || sso_fetch(ctx.query, :saml_response)
          sso_validate_saml_slo_signature!(ctx, provider, raw_response, "LogoutResponse", "Invalid LogoutResponse") if config.dig(:saml, :want_logout_response_signed)
          sso_process_saml_logout_response(ctx, raw_response)
          Cookies.delete_session_cookie(ctx)
          next sso_redirect(ctx, sso_safe_slo_redirect_url(ctx, relay_state, provider.fetch("providerId")))
        end

        raw_request = sso_fetch(ctx.body, :saml_request) || sso_fetch(ctx.query, :saml_request)
        raise APIError.new("BAD_REQUEST", message: "Invalid LogoutRequest") if raw_request.to_s.empty?

        sso_validate_saml_slo_signature!(ctx, provider, raw_request, "LogoutRequest", "Invalid LogoutRequest") if config.dig(:saml, :want_logout_request_signed)
        logout_request_data = sso_process_saml_logout_request(ctx, provider, raw_request)
        in_response_to = logout_request_data[:id].to_s.empty? ? "" : " InResponseTo=\"#{CGI.escapeHTML(logout_request_data[:id].to_s)}\""
        response = Base64.strict_encode64("<samlp:LogoutResponse xmlns:samlp=\"urn:oasis:names:tc:SAML:2.0:protocol\" ID=\"_#{BetterAuth::Crypto.random_string(32)}\"#{in_response_to} Version=\"2.0\" IssueInstant=\"#{Time.now.utc.iso8601}\" Destination=\"#{sso_saml_logout_destination(provider)}\"><samlp:Status><samlp:StatusCode Value=\"urn:oasis:names:tc:SAML:2.0:status:Success\"/></samlp:Status></samlp:LogoutResponse>")
        if sso_fetch(ctx.body, :saml_request)
          next sso_saml_post_form(sso_saml_logout_destination(provider), "SAMLResponse", response, relay_state)
        end

        query = {SAMLResponse: response, RelayState: relay_state}
        query = sso_signed_saml_redirect_query(provider, query) if config.dig(:saml, :want_logout_response_signed)
        sso_redirect(ctx, "#{sso_saml_logout_destination(provider)}?#{URI.encode_www_form(query)}")
      end
    end

    def sso_initiate_slo_endpoint(config = {})
      Endpoint.new(path: "/sso/saml2/logout/:providerId", method: "POST", metadata: sso_openapi_for(:initiate_slo)) do |ctx|
        raise APIError.new("BAD_REQUEST", message: "Single Logout is not enabled") unless config.dig(:saml, :enable_single_logout)

        session = Routes.current_session(ctx)
        provider = sso_find_saml_provider!(ctx, sso_fetch(ctx.params, :provider_id), config)
        destination = sso_saml_logout_destination(provider)
        if destination.to_s.empty?
          raise APIError.new("BAD_REQUEST", message: "IdP does not support Single Logout Service")
        end

        relay_state = sso_fetch(ctx.body, :callback_url) || ctx.context.base_url
        session_token = session.fetch(:session).fetch("token")
        user_email = session.fetch(:user).fetch("email")
        saml_session_key = ctx.context.internal_adapter.find_verification_value("#{SSO_SAML_SESSION_BY_ID_KEY_PREFIX}#{session_token}")&.fetch("value")
        saml_session = saml_session_key && ctx.context.internal_adapter.find_verification_value(saml_session_key)
        saml_record = saml_session ? JSON.parse(saml_session.fetch("value")) : {}
        name_id = saml_record["nameId"] || user_email
        session_index = saml_record["sessionIndex"]

        request_id = "_#{BetterAuth::Crypto.random_string(32)}"
        session_index_xml = session_index.to_s.empty? ? "" : "<samlp:SessionIndex>#{CGI.escapeHTML(session_index.to_s)}</samlp:SessionIndex>"
        request = Base64.strict_encode64("<samlp:LogoutRequest xmlns:samlp=\"urn:oasis:names:tc:SAML:2.0:protocol\" xmlns:saml=\"urn:oasis:names:tc:SAML:2.0:assertion\" ID=\"#{request_id}\" Version=\"2.0\" IssueInstant=\"#{Time.now.utc.iso8601}\" Destination=\"#{CGI.escapeHTML(destination.to_s)}\"><saml:NameID>#{CGI.escapeHTML(name_id.to_s)}</saml:NameID>#{session_index_xml}</samlp:LogoutRequest>")
        sso_store_saml_logout_request(ctx, provider, request_id, config)
        ctx.context.internal_adapter.delete_verification_by_identifier(saml_session_key) if saml_session_key
        ctx.context.internal_adapter.delete_verification_by_identifier("#{SSO_SAML_SESSION_BY_ID_KEY_PREFIX}#{session_token}")
        ctx.context.internal_adapter.delete_session(session_token)
        Cookies.delete_session_cookie(ctx)
        query = {SAMLRequest: request, RelayState: relay_state}
        query = sso_signed_saml_redirect_query(provider, query) if config.dig(:saml, :want_logout_request_signed)
        sso_redirect(ctx, "#{destination}?#{URI.encode_www_form(query)}")
      end
    end

    def sso_request_domain_verification_endpoint(config)
      Endpoint.new(path: "/sso/request-domain-verification", method: "POST") do |ctx|
        session = Routes.current_session(ctx)
        provider = sso_find_provider!(ctx, normalize_hash(ctx.body)[:provider_id])
        sso_authorize_domain_verification!(ctx, provider, session.fetch(:user).fetch("id"))
        if provider.key?("domainVerified") && provider["domainVerified"]
          raise APIError.new("CONFLICT", message: "Domain has already been verified", code: "DOMAIN_VERIFIED")
        end

        identifier = sso_domain_verification_identifier(config, provider.fetch("providerId"))
        active = ctx.context.internal_adapter.find_verification_value(identifier)
        if active && sso_future_time?(active.fetch("expiresAt"))
          next ctx.json({domainVerificationToken: active.fetch("value")}, status: 201)
        end

        token = BetterAuth::Crypto.random_string(24)
        ctx.context.internal_adapter.create_verification_value(identifier: identifier, value: token, expiresAt: Time.now + (7 * 24 * 60 * 60))
        config.dig(:domain_verification, :request)&.call(provider: provider, token: token, context: ctx)
        ctx.json({domainVerificationToken: token}, status: 201)
      end
    end

    def sso_verify_domain_endpoint(config)
      Endpoint.new(path: "/sso/verify-domain", method: "POST") do |ctx|
        session = Routes.current_session(ctx)
        provider = sso_find_provider!(ctx, normalize_hash(ctx.body)[:provider_id])
        sso_authorize_domain_verification!(ctx, provider, session.fetch(:user).fetch("id"))
        if provider.key?("domainVerified") && provider["domainVerified"]
          raise APIError.new("CONFLICT", message: "Domain has already been verified", code: "DOMAIN_VERIFIED")
        end

        identifier = sso_domain_verification_identifier(config, provider.fetch("providerId"))
        if identifier.length > 63
          raise APIError.new("BAD_REQUEST", message: "Verification identifier exceeds the DNS label limit of 63 characters", code: "IDENTIFIER_TOO_LONG")
        end
        active = ctx.context.internal_adapter.find_verification_value(identifier)
        if !active || !sso_future_time?(active.fetch("expiresAt"))
          raise APIError.new("NOT_FOUND", message: "No pending domain verification exists", code: "NO_PENDING_VERIFICATION")
        end

        hostnames = sso_hostnames_from_domains(provider.fetch("domain"))
        raise APIError.new("BAD_REQUEST", message: "Invalid domain", code: "INVALID_DOMAIN") if hostnames.to_a.empty?

        hostnames.each do |hostname|
          records = sso_resolve_txt_records("#{identifier}.#{hostname}", config)
          unless sso_txt_record_exact_match?(records, identifier, active.fetch("value"))
            raise APIError.new("BAD_GATEWAY", message: "Unable to verify domain ownership for #{hostname}. Try again later", code: "DOMAIN_VERIFICATION_FAILED")
          end
        end

        ctx.context.adapter.update(model: "ssoProvider", where: [{field: "id", value: provider.fetch("id")}], update: {domainVerified: true})
        ctx.context.internal_adapter.delete_verification_by_identifier(identifier)
        ctx.set_status(204)
        nil
      end
    end
  end
end
