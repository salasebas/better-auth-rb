# frozen_string_literal: true

module BetterAuth
  module Plugins
    module OAuthProvider
      module_function

      def validate_issuer_url(value)
        uri = URI.parse(value.to_s)
        uri.query = nil
        uri.fragment = nil
        if uri.scheme == "http" && !["localhost", "127.0.0.1", "::1"].include?(uri.hostname || uri.host)
          uri.scheme = "https"
        end
        uri.to_s.sub(%r{/+\z}, "")
      rescue URI::InvalidURIError
        value.to_s.split(/[?#]/).first.sub(%r{/+\z}, "")
      end
    end

    module_function

    def oauth_authorize_endpoint(config)
      Endpoint.new(path: "/oauth2/authorize", method: "GET") do |ctx|
        oauth_authorize_flow(ctx, config, OAuthProtocol.stringify_keys(ctx.query))
      end
    end

    def oauth_authorize_flow(ctx, config, query)
      query = oauth_resolve_request_uri!(ctx, config, query)
      response_type = query["response_type"].to_s

      client = OAuthProtocol.find_client(ctx, "oauthClient", query["client_id"])
      raise APIError.new("BAD_REQUEST", message: "invalid_client") unless client
      OAuthProtocol.validate_redirect_uri!(client, query["redirect_uri"])
      client_data = OAuthProtocol.stringify_keys(client)
      if client_data["disabled"]
        raise ctx.redirect(oauth_authorize_error_redirect(ctx, query, "invalid_client", "client is disabled"))
      end
      unless oauth_client_allows_grant?(client, OAuthProtocol::AUTH_CODE_GRANT)
        raise ctx.redirect(oauth_authorize_error_redirect(ctx, query, "unauthorized_client", "client is not authorized to use the authorization_code grant"))
      end
      unless oauth_provider_allows_grant?(config, OAuthProtocol::AUTH_CODE_GRANT)
        raise ctx.redirect(oauth_authorize_error_redirect(ctx, query, "unsupported_grant_type", "authorization_code grant is disabled"))
      end
      if response_type != "code"
        raise ctx.redirect(oauth_authorize_error_redirect(ctx, query, "unsupported_response_type", "response_type must be code"))
      end

      scopes = OAuthProtocol.parse_scopes(query["scope"])
      scopes = OAuthProtocol.parse_scopes(OAuthProtocol.stringify_keys(client)["scopes"] || config[:scopes]) if scopes.empty?
      prompts = OAuthProtocol.parse_scopes(query["prompt"])
      if prompts.include?("none") && (prompts - ["none"]).any?
        raise ctx.redirect(oauth_authorize_error_redirect(ctx, query, "invalid_request", "prompt none cannot be combined with other prompts"))
      end
      allowed_scopes = OAuthProtocol.parse_scopes(client_data["scopes"])
      allowed_scopes = OAuthProtocol.parse_scopes(config[:scopes]) if allowed_scopes.empty?
      unless scopes.all? { |scope| allowed_scopes.include?(scope) }
        raise ctx.redirect(oauth_authorize_error_redirect(ctx, query, "invalid_scope", "invalid scope"))
      end
      if scopes.include?("offline_access") && (!oauth_provider_allows_grant?(config, OAuthProtocol::REFRESH_GRANT) || !oauth_client_allows_grant?(client, OAuthProtocol::REFRESH_GRANT))
        raise ctx.redirect(oauth_authorize_error_redirect(ctx, query, "invalid_scope", "offline_access requires refresh_token support"))
      end
      pkce_error = OAuthProtocol.validate_authorize_pkce(client_data, scopes, query["code_challenge"], query["code_challenge_method"])
      raise ctx.redirect(oauth_authorize_error_redirect(ctx, query, "invalid_request", pkce_error)) if pkce_error

      session = Routes.current_session(ctx, allow_nil: true)
      unless session
        if prompts.include?("none")
          raise ctx.redirect(OAuthProtocol.redirect_uri_with_params(query["redirect_uri"], error: "login_required", state: query["state"], iss: OAuthProvider.validate_issuer_url(OAuthProtocol.issuer(ctx))))
        end

        if prompts.include?("create")
          raise ctx.redirect(oauth_prompt_redirect(ctx, config, query, "create"))
        end

        raise ctx.redirect(oauth_prompt_redirect(ctx, config, query, "login"))
      end

      if oauth_requires_login?(session, prompts, query)
        raise ctx.redirect(oauth_prompt_redirect(ctx, config, query, "login"))
      end

      if prompts.include?("select_account")
        if prompts.include?("none")
          raise ctx.redirect(OAuthProtocol.redirect_uri_with_params(query["redirect_uri"], error: "account_selection_required", state: query["state"], iss: OAuthProvider.validate_issuer_url(OAuthProtocol.issuer(ctx))))
        end

        raise ctx.redirect(oauth_prompt_redirect(ctx, config, query, "select_account"))
      end

      if config.dig(:post_login, :should_redirect).respond_to?(:call)
        should_redirect = config.dig(:post_login, :should_redirect).call({user: session[:user], session: session[:session], client: client_data, scopes: scopes})
        if should_redirect
          if prompts.include?("none")
            raise ctx.redirect(OAuthProtocol.redirect_uri_with_params(query["redirect_uri"], error: "interaction_required", state: query["state"], iss: OAuthProvider.validate_issuer_url(OAuthProtocol.issuer(ctx))))
          end

          raise ctx.redirect(oauth_prompt_redirect(ctx, config, query, "post_login", page: should_redirect.is_a?(String) ? should_redirect : nil, session: session))
        end
      end

      consent_reference_id = oauth_consent_reference(config, session, scopes)
      requires_consent = !client_data["skipConsent"] && (prompts.include?("consent") || !oauth_consent_granted?(ctx, client_data["clientId"], session[:user]["id"], scopes, consent_reference_id))

      if requires_consent
        if prompts.include?("none")
          raise ctx.redirect(OAuthProtocol.redirect_uri_with_params(query["redirect_uri"], error: "consent_required", state: query["state"], iss: OAuthProvider.validate_issuer_url(OAuthProtocol.issuer(ctx))))
        end

        consent_code = Crypto.random_string(32)
        config[:store][:consents][consent_code] = {
          query: query,
          session: session,
          client: client,
          scopes: scopes,
          reference_id: consent_reference_id,
          expires_at: Time.now + 600
        }
        raise ctx.redirect(OAuthProtocol.redirect_uri_with_params(config[:consent_page], consent_code: consent_code, client_id: client_data["clientId"], scope: OAuthProtocol.scope_string(scopes)))
      end

      oauth_redirect_with_code(ctx, config, query, session, client, scopes, reference_id: consent_reference_id)
    end

    def oauth_requires_login?(session, prompts, query)
      return true if prompts.include?("login")
      return false unless query.key?("max_age")

      max_age = Integer(query["max_age"])
      return false if max_age.negative?

      auth_time = OAuthProvider::Utils.resolve_session_auth_time(session)
      return false unless auth_time

      (Time.now - auth_time) > max_age
    rescue ArgumentError, TypeError
      false
    end

    def oauth_prompt_redirect(ctx, config, query, type, page: nil, session: nil)
      target = page || oauth_prompt_page(config, type)
      post_login_marker = oauth_store_post_login_marker(ctx, query, session) if type == "post_login"

      "#{target}?#{oauth_signed_query(ctx, query, post_login_marker: post_login_marker)}"
    end

    def oauth_prompt_page(config, type)
      case type
      when "create"
        config.dig(:signup, :page) || config[:login_page]
      when "select_account"
        config.dig(:select_account, :page) || config[:login_page]
      when "post_login"
        config.dig(:post_login, :page) || config[:login_page]
      when "consent"
        config[:consent_page]
      else
        config[:login_page]
      end
    end

    def oauth_signed_query(ctx, query, post_login_marker: nil)
      data = OAuthProtocol.stringify_keys(query).compact
      %w[sig ba_param ba_iat exp ba_pl].each { |key| data.delete(key) }
      data["ba_pl"] = post_login_marker if post_login_marker
      data["exp"] = (Time.now.to_i + 600).to_s
      data["ba_iat"] = (Time.now.to_f * 1000).to_i.to_s
      pairs = oauth_query_pairs(data)
      signed_names = (pairs.map(&:first) + ["ba_param"]).uniq.sort
      signed_names.each { |name| pairs << ["ba_param", name] }
      unsigned = oauth_canonical_query(pairs)
      signature = Crypto.hmac_signature(unsigned, ctx.context.secret, encoding: :base64url)
      "#{unsigned}&#{URI.encode_www_form("sig" => signature)}"
    end

    def oauth_verified_query!(ctx, oauth_query)
      raise APIError.new("BAD_REQUEST", message: "missing oauth query") if oauth_query.to_s.empty?
      raise APIError.new("BAD_REQUEST", message: "invalid oauth query") if oauth_query.to_s.include?("#")

      pairs = URI.decode_www_form(oauth_query.to_s)
      signatures = oauth_pairs_matching(pairs, "sig").map(&:last)
      unsigned_pairs = oauth_pairs_excluding(pairs, "sig")
      signed_names = oauth_pairs_matching(unsigned_pairs, "ba_param").map(&:last)
      payload_pairs = oauth_pairs_excluding(unsigned_pairs, "ba_param")
      exp_values = oauth_pairs_matching(payload_pairs, "exp").map(&:last)
      duplicate_reserved_names = payload_pairs.group_by(&:first).any? do |key, entries|
        %w[exp ba_iat ba_pl].include?(key) && entries.length != 1
      end
      names_valid = signed_names.any? && signed_names.uniq.length == signed_names.length &&
        signed_names.sort == (payload_pairs.map(&:first) + ["ba_param"]).uniq.sort &&
        payload_pairs.all? { |key, _value| signed_names.include?(key) }
      unsigned = oauth_canonical_query(unsigned_pairs)
      exp = exp_values.first.to_i
      unless signatures.length == 1 && exp_values.length == 1 && !duplicate_reserved_names && names_valid && exp >= Time.now.to_i && Crypto.verify_hmac_signature(unsigned, signatures.first, ctx.context.secret, encoding: :base64url)
        raise APIError.new("BAD_REQUEST", message: "invalid oauth query")
      end

      payload_pairs.each_with_object({}) do |(key, value), result|
        next if key == "exp" || key == "ba_iat"

        result[key] = result.key?(key) ? Array(result[key]) << value : value
      end
    rescue ArgumentError
      raise APIError.new("BAD_REQUEST", message: "invalid oauth query")
    end

    def oauth_query_pairs(data)
      data.flat_map do |key, value|
        Array(value).map { |entry| [key.to_s, entry.to_s] }
      end
    end

    def oauth_pairs_matching(pairs, name)
      pairs.each_with_object([]) { |pair, result| result << pair if pair.first == name }
    end

    def oauth_pairs_excluding(pairs, name)
      pairs.each_with_object([]) { |pair, result| result << pair unless pair.first == name }
    end

    def oauth_canonical_query(pairs)
      URI.encode_www_form(pairs.sort_by { |key, value| [key, value] })
    end

    # A pre-gate marker proves only that this authorization request may resume
    # once. It is deliberately not used to skip post_login; the live callback
    # still decides whether the session has completed the gate.
    def oauth_store_post_login_marker(ctx, query, session)
      raise APIError.new("INTERNAL_SERVER_ERROR", message: "post-login session missing") unless session

      marker = Crypto.random_string(32)
      data = OAuthProtocol.stringify_keys(query)
      %w[sig ba_param ba_iat exp ba_pl].each { |key| data.delete(key) }
      session_id = OAuthProtocol.stringify_keys(session).dig("session", "id")
      ctx.context.internal_adapter.create_verification_value(
        identifier: "oauth_post_login:#{marker}",
        value: JSON.generate(
          session_id: session_id,
          client_id: data["client_id"],
          request: oauth_canonical_query(oauth_query_pairs(data))
        ),
        expiresAt: Time.now + 600
      )
      marker
    end

    def oauth_consume_post_login_marker!(ctx, query, session)
      marker = query.delete("ba_pl").to_s
      verification = ctx.context.internal_adapter.consume_verification_value("oauth_post_login:#{marker}") unless marker.empty?
      data = verification && JSON.parse(verification.fetch("value"), symbolize_names: true)
      session_id = OAuthProtocol.stringify_keys(session || {}).dig("session", "id")
      request = oauth_canonical_query(oauth_query_pairs(query))
      unless data.is_a?(Hash) && data[:session_id].to_s == session_id.to_s && data[:client_id].to_s == query["client_id"].to_s && data[:request] == request
        raise APIError.new("BAD_REQUEST", message: "invalid post-login continuation")
      end
    rescue JSON::ParserError, KeyError, TypeError
      raise APIError.new("BAD_REQUEST", message: "invalid post-login continuation")
    end

    def oauth_client_allows_grant?(client, grant)
      grants = OAuthProtocol.stringify_keys(client)["grantTypes"]
      grants = OAuthProtocol.parse_scopes(grants)
      grants = [OAuthProtocol::AUTH_CODE_GRANT] if grants.empty?
      return true if grant == OAuthProtocol::REFRESH_GRANT && grants.include?(OAuthProtocol::AUTH_CODE_GRANT)

      grants.include?(grant)
    end

    def oauth_provider_allows_grant?(config, grant)
      OAuthProtocol.parse_scopes(config[:grant_types]).include?(grant)
    end

    def oauth_dispatch_authorize(ctx, config, query)
      endpoint = config.fetch(:endpoints).fetch(:oauth2_authorize)
      resumed = Endpoint::Context.new(
        path: endpoint.path,
        method: "GET",
        query: query,
        body: {},
        params: {},
        headers: ctx.headers,
        context: ctx.context,
        request: ctx.request
      )
      result = API.new(ctx.context, config.fetch(:endpoints)).execute(endpoint, resumed)
      error = result.response
      location = result.headers["location"]
      raise error if error.is_a?(APIError) && !location

      result
    end

    def oauth_delete_prompt!(query, prompt)
      prompts = OAuthProtocol.parse_scopes(query["prompt"])
      prompts.delete(prompt)
      if prompts.empty?
        query.delete("prompt")
      else
        query["prompt"] = OAuthProtocol.scope_string(prompts)
      end
    end

    def oauth_authorize_error_redirect(ctx, query, error, description)
      OAuthProtocol.redirect_uri_with_params(
        query["redirect_uri"],
        error: error,
        error_description: description,
        state: query["state"],
        iss: OAuthProvider.validate_issuer_url(OAuthProtocol.issuer(ctx))
      )
    end

    def oauth_resolve_request_uri!(ctx, config, query)
      query = OAuthProtocol.stringify_keys(query)
      return query if query["request_uri"].to_s.empty?

      resolver = config[:request_uri_resolver]
      unless resolver.respond_to?(:call)
        return oauth_invalid_request_uri!(ctx, query, "request_uri not supported")
      end

      resolved = resolver.call({request_uri: query["request_uri"], client_id: query["client_id"], context: ctx})
      return oauth_invalid_request_uri!(ctx, query, "request_uri is invalid or expired") unless resolved

      resolved_query = OAuthProtocol.stringify_keys(resolved)
      resolved_query["client_id"] = query["client_id"] if query["client_id"]
      resolved_query
    end

    def oauth_invalid_request_uri!(ctx, query, description)
      redirect_uri = query["redirect_uri"]
      raise APIError.new("BAD_REQUEST", message: "invalid_request_uri") if redirect_uri.to_s.empty?

      raise ctx.redirect(oauth_authorize_error_redirect(ctx, query, "invalid_request_uri", description))
    end
  end
end
