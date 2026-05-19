# frozen_string_literal: true

require "time"

module BetterAuth
  module Plugins
    module OIDCProvider
      VALID_PROMPTS = %w[none login consent create select_account].freeze
      DEPRECATION_MESSAGE = 'The "oidc-provider" plugin is deprecated and will be removed in the next major version. Migrate to better_auth-oauth-provider. See: https://www.better-auth.com/docs/plugins/oauth-provider'

      module_function

      def warn_deprecation!(logger = nil)
        return if @deprecation_warned

        Deprecate.warn_once("[Deprecation] #{DEPRECATION_MESSAGE}", logger)
        @deprecation_warned = true
      end

      def reset_deprecation_warning!
        @deprecation_warned = false
      end

      def normalize_issuer(value)
        uri = URI.parse(value.to_s)
        uri.query = nil
        uri.fragment = nil
        if uri.scheme == "http" && !["localhost", "127.0.0.1"].include?(uri.host)
          uri.scheme = "https"
        end
        uri.to_s.sub(%r{/+\z}, "")
      rescue URI::InvalidURIError
        value.to_s.split(/[?#]/).first.sub(%r{/+\z}, "")
      end

      def parse_prompt(value)
        prompts = value.to_s.split(/\s+/).select { |prompt| VALID_PROMPTS.include?(prompt) }
        if prompts.include?("none") && prompts.length > 1
          raise APIError.new("BAD_REQUEST", message: "invalid_request")
        end

        prompts.to_set
      end
    end

    module_function

    def oidc_provider(options = {})
      raw_options = normalize_hash(options)
      OIDCProvider.warn_deprecation!(raw_options[:logger]) unless raw_options[:__skip_deprecation_warning]

      config = {
        code_expires_in: 600,
        consent_page: "/oauth2/authorize",
        login_page: "/login",
        default_scope: "openid",
        access_token_expires_in: 3600,
        refresh_token_expires_in: 604_800,
        allow_plain_code_challenge_method: true,
        store_client_secret: "plain",
        scopes: %w[openid profile email offline_access],
        store: OAuthProtocol.stores
      }.merge(raw_options.except(:logger, :__skip_deprecation_warning))

      Plugin.new(
        id: "oidc-provider",
        endpoints: oidc_provider_endpoints(config),
        hooks: {
          after: [
            {
              matcher: ->(ctx) { ctx.path.start_with?("/sign-in/", "/sign-up/") },
              handler: ->(ctx) { oidc_resume_login_prompt(ctx, config) }
            }
          ]
        },
        schema: oidc_provider_schema,
        options: config
      )
    end

    def oidc_provider_endpoints(config)
      {
        get_open_id_config: oidc_metadata_endpoint(config),
        o_auth2_authorize: oidc_authorize_endpoint(config),
        o_auth_consent: oidc_consent_endpoint(config),
        o_auth2_token: oidc_token_endpoint(config),
        o_auth2_introspect: oidc_introspect_endpoint(config),
        o_auth2_revoke: oidc_revoke_endpoint(config),
        o_auth2_user_info: oidc_userinfo_endpoint(config),
        register_o_auth_application: oidc_register_endpoint(config),
        get_o_auth_client: oidc_get_client_endpoint,
        list_o_auth_applications: oidc_list_clients_endpoint,
        update_o_auth_application: oidc_update_client_endpoint,
        rotate_o_auth_application_secret: oidc_rotate_client_secret_endpoint(config),
        delete_o_auth_application: oidc_delete_client_endpoint,
        end_session: oidc_end_session_endpoint
      }
    end

    def oidc_metadata_endpoint(config)
      Endpoint.new(path: "/.well-known/openid-configuration", method: "GET", metadata: {hide: true}) do |ctx|
        base = OAuthProtocol.endpoint_base(ctx)
        supported_algs = oidc_use_jwt_plugin?(ctx, config) ? ["RS256", "EdDSA", "none"] : ["HS256", "none"]
        ctx.json({
          issuer: OIDCProvider.normalize_issuer(OAuthProtocol.issuer(ctx)),
          authorization_endpoint: "#{base}/oauth2/authorize",
          token_endpoint: "#{base}/oauth2/token",
          userinfo_endpoint: "#{base}/oauth2/userinfo",
          jwks_uri: "#{base}/jwks",
          registration_endpoint: "#{base}/oauth2/register",
          introspection_endpoint: "#{base}/oauth2/introspect",
          revocation_endpoint: "#{base}/oauth2/revoke",
          end_session_endpoint: "#{base}/oauth2/endsession",
          scopes_supported: config[:scopes],
          response_types_supported: ["code"],
          response_modes_supported: ["query"],
          grant_types_supported: ["authorization_code", "refresh_token"],
          acr_values_supported: ["urn:mace:incommon:iap:silver", "urn:mace:incommon:iap:bronze"],
          subject_types_supported: ["public"],
          id_token_signing_alg_values_supported: supported_algs,
          token_endpoint_auth_methods_supported: ["client_secret_basic", "client_secret_post", "none"],
          introspection_endpoint_auth_methods_supported: ["client_secret_basic", "client_secret_post"],
          revocation_endpoint_auth_methods_supported: ["client_secret_basic", "client_secret_post"],
          code_challenge_methods_supported: ["S256"],
          claims_supported: %w[sub iss aud exp nbf iat jti email email_verified name]
        }.merge(config[:metadata] || {}))
      end
    end

    def oidc_register_endpoint(config)
      Endpoint.new(path: "/oauth2/register", method: "POST", metadata: oidc_openapi("registerOAuthApplication", "Register an OAuth2 application", "OAuth2 application registered successfully", oidc_client_schema)) do |ctx|
        session = Routes.current_session(ctx, allow_nil: true)
        unless session || config[:allow_dynamic_client_registration]
          raise APIError.new("UNAUTHORIZED", message: "invalid_token")
        end

        body = OAuthProtocol.stringify_keys(ctx.body)
        grant_types = Array(body["grant_types"] || [OAuthProtocol::AUTH_CODE_GRANT])
        response_types = Array(body["response_types"] || ["code"])
        redirects = Array(body["redirect_uris"]).map(&:to_s)
        if (grant_types.empty? || grant_types.include?(OAuthProtocol::AUTH_CODE_GRANT) || grant_types.include?("implicit")) && redirects.empty?
          raise APIError.new("BAD_REQUEST", message: "invalid_redirect_uri")
        end
        if grant_types.include?(OAuthProtocol::AUTH_CODE_GRANT) && !response_types.include?("code")
          raise APIError.new("BAD_REQUEST", message: "invalid_client_metadata")
        end
        if grant_types.include?("implicit") && !response_types.include?("token")
          raise APIError.new("BAD_REQUEST", message: "invalid_client_metadata")
        end

        client = OAuthProtocol.create_client(
          ctx,
          model: "oauthApplication",
          body: body,
          owner_session: session,
          default_auth_method: "client_secret_basic",
          store_client_secret: config[:store_client_secret]
        )
        ctx.json(client, status: 201, headers: {"Cache-Control" => "no-store", "Pragma" => "no-cache"})
      end
    end

    def oidc_get_client_endpoint
      Endpoint.new(path: "/oauth2/client/:id", method: "GET", metadata: oidc_openapi("getOAuthClient", "Get OAuth2 client details", "OAuth2 client retrieved successfully", oidc_client_schema)) do |ctx|
        client = OAuthProtocol.find_client(ctx, "oauthApplication", ctx.params["id"] || ctx.params[:id])
        raise APIError.new("NOT_FOUND", message: "client not found") unless client

        ctx.json(OAuthProtocol.client_response(client, include_secret: false))
      end
    end

    def oidc_list_clients_endpoint
      Endpoint.new(path: "/oauth2/clients", method: "GET", metadata: oidc_openapi("listOAuthApplications", "List OAuth2 applications", "OAuth2 applications retrieved successfully", {type: "array", items: oidc_client_schema})) do |ctx|
        session = Routes.current_session(ctx)
        clients = ctx.context.adapter.find_many(model: "oauthApplication", where: [{field: "userId", value: session[:user]["id"]}])
        ctx.json(clients.map { |client| OAuthProtocol.client_response(client, include_secret: false) })
      end
    end

    def oidc_update_client_endpoint
      Endpoint.new(path: "/oauth2/client/:id", method: "PATCH", metadata: oidc_openapi("updateOAuthApplication", "Update an OAuth2 application", "OAuth2 application updated successfully", oidc_client_schema)) do |ctx|
        session = Routes.current_session(ctx)
        client = oidc_find_owned_client!(ctx, session)
        body = OAuthProtocol.stringify_keys(ctx.body)
        update_source = OAuthProtocol.stringify_keys(body["update"] || body)
        update = {}
        if update_source.key?("client_name") || update_source.key?("name")
          update["name"] = update_source["client_name"] || update_source["name"]
        end
        update["uri"] = update_source["client_uri"] if update_source.key?("client_uri")
        update["icon"] = update_source["logo_uri"] if update_source.key?("logo_uri")
        if update_source.key?("redirect_uris")
          redirects = Array(update_source["redirect_uris"]).map(&:to_s)
          update["redirectUris"] = redirects
          update["redirectUrls"] = redirects.join(",")
        end
        update["postLogoutRedirectUris"] = Array(update_source["post_logout_redirect_uris"]).map(&:to_s) if update_source.key?("post_logout_redirect_uris")
        update["grantTypes"] = Array(update_source["grant_types"]).map(&:to_s) if update_source.key?("grant_types")
        update["responseTypes"] = Array(update_source["response_types"]).map(&:to_s) if update_source.key?("response_types")
        update["scopes"] = OAuthProtocol.parse_scopes(update_source["scope"] || update_source["scopes"]) if update_source.key?("scope") || update_source.key?("scopes")
        update["metadata"] = update_source["metadata"] if update_source.key?("metadata")
        update["updatedAt"] = Time.now
        updated = update.empty? ? client : ctx.context.adapter.update(model: "oauthApplication", where: [{field: "id", value: client.fetch("id")}], update: update)
        ctx.json(OAuthProtocol.client_response(updated, include_secret: false))
      end
    end

    def oidc_rotate_client_secret_endpoint(config)
      Endpoint.new(path: "/oauth2/client/:id/rotate-secret", method: "POST", metadata: oidc_openapi("rotateOAuthApplicationSecret", "Rotate an OAuth2 application secret", "OAuth2 application secret rotated successfully", oidc_client_schema)) do |ctx|
        session = Routes.current_session(ctx)
        client = oidc_find_owned_client!(ctx, session)
        if OAuthProtocol.stringify_keys(client)["tokenEndpointAuthMethod"] == "none"
          raise APIError.new("BAD_REQUEST", message: "invalid_client")
        end

        client_secret = Crypto.random_string(32)
        updated = ctx.context.adapter.update(
          model: "oauthApplication",
          where: [{field: "id", value: client.fetch("id")}],
          update: {clientSecret: OAuthProtocol.store_client_secret_value(ctx, client_secret, config[:store_client_secret]), updatedAt: Time.now}
        )
        ctx.json(OAuthProtocol.client_response(updated, include_secret: false).merge(client_secret: client_secret))
      end
    end

    def oidc_delete_client_endpoint
      Endpoint.new(path: "/oauth2/client/:id", method: "DELETE", metadata: oidc_openapi("deleteOAuthApplication", "Delete an OAuth2 application", "OAuth2 application deleted successfully", OpenAPI.success_response_schema)) do |ctx|
        session = Routes.current_session(ctx)
        client = oidc_find_owned_client!(ctx, session)
        ctx.context.adapter.delete(model: "oauthApplication", where: [{field: "id", value: client.fetch("id")}])
        ctx.json({success: true})
      end
    end

    def oidc_authorize_endpoint(config)
      Endpoint.new(path: "/oauth2/authorize", method: "GET", metadata: oidc_openapi("oauth2Authorize", "Authorize an OAuth2 request", "Authorization response generated successfully", {type: "object", additionalProperties: true})) do |ctx|
        query = OAuthProtocol.stringify_keys(ctx.query)
        prompts = OIDCProvider.parse_prompt(query["prompt"])
        session = Routes.current_session(ctx, allow_nil: true)
        if !session && prompts.include?("none")
          redirect = OAuthProtocol.redirect_uri_with_params(query["redirect_uri"], error: "login_required", error_description: "Authentication required but prompt is none", state: query["state"], iss: OAuthProtocol.issuer(ctx))
          raise ctx.redirect(redirect)
        end
        unless session
          ctx.set_signed_cookie("oidc_login_prompt", JSON.generate(query), ctx.context.secret, max_age: 600, path: "/", same_site: "lax")
          raise ctx.redirect(OAuthProtocol.redirect_uri_with_params(config[:login_page], query))
        end

        client = OAuthProtocol.find_client(ctx, "oauthApplication", query["client_id"])
        raise APIError.new("BAD_REQUEST", message: "invalid_client") unless client
        OAuthProtocol.validate_redirect_uri!(client, query["redirect_uri"])

        scopes = OAuthProtocol.parse_scopes(query["scope"] || config[:default_scope])
        invalid_scopes = scopes.reject { |scope| config[:scopes].include?(scope) }
        unless invalid_scopes.empty?
          redirect = OAuthProtocol.redirect_uri_with_params(query["redirect_uri"], error: "invalid_scope", error_description: "The following scopes are invalid: #{invalid_scopes.join(", ")}", state: query["state"], iss: OAuthProtocol.issuer(ctx))
          raise ctx.redirect(redirect)
        end
        if config[:require_pkce] && (query["code_challenge"].to_s.empty? || query["code_challenge_method"].to_s.empty?)
          redirect = OAuthProtocol.redirect_uri_with_params(query["redirect_uri"], error: "invalid_request", error_description: "pkce is required", state: query["state"], iss: OAuthProtocol.issuer(ctx))
          raise ctx.redirect(redirect)
        end
        challenge_method = query["code_challenge_method"].to_s
        if !challenge_method.empty? && !valid_code_challenge_method?(challenge_method, config)
          redirect = OAuthProtocol.redirect_uri_with_params(query["redirect_uri"], error: "invalid_request", error_description: "invalid code_challenge method", state: query["state"], iss: OAuthProtocol.issuer(ctx))
          raise ctx.redirect(redirect)
        end

        client_data = OAuthProtocol.stringify_keys(client)
        requires_consent = !client_data["skipConsent"] && (prompts.include?("consent") || !oidc_consent_granted?(ctx, client_data["clientId"], session[:user]["id"], scopes))
        if oidc_requires_login?(session, prompts, query)
          ctx.set_signed_cookie("oidc_login_prompt", JSON.generate(query), ctx.context.secret, max_age: 600, path: "/", same_site: "lax")
          raise ctx.redirect(OAuthProtocol.redirect_uri_with_params(config[:login_page], client_id: client_data["clientId"], state: query["state"]))
        end

        if requires_consent
          if prompts.include?("none")
            redirect = OAuthProtocol.redirect_uri_with_params(query["redirect_uri"], error: "consent_required", error_description: "Consent required but prompt is none", state: query["state"], iss: OAuthProtocol.issuer(ctx))
            raise ctx.redirect(redirect)
          end

          consent_code = Crypto.random_string(32)
          config[:store][:consents][consent_code] = {
            query: query,
            session: session,
            client: client,
            scopes: scopes,
            expires_at: Time.now + config[:code_expires_in].to_i
          }
          unless config[:consent_page]
            renderer = config[:get_consent_html]
            raise APIError.new("INTERNAL_SERVER_ERROR", message: "No consent page provided") unless renderer.respond_to?(:call)

            ctx.set_header("content-type", "text/html")
            next renderer.call(
              scopes: scopes,
              clientMetadata: client_data["metadata"] || {},
              clientIcon: client_data["icon"],
              clientId: client_data["clientId"],
              clientName: client_data["name"],
              code: consent_code
            )
          end

          raise ctx.redirect(OAuthProtocol.redirect_uri_with_params(config[:consent_page], consent_code: consent_code, client_id: client_data["clientId"], scope: OAuthProtocol.scope_string(scopes)))
        end

        code = Crypto.random_string(32)
        OAuthProtocol.store_code(
          config[:store],
          code: code,
          client_id: query["client_id"],
          redirect_uri: query["redirect_uri"],
          session: session,
          scopes: scopes,
          code_challenge: query["code_challenge"],
          code_challenge_method: query["code_challenge_method"]
        )

        redirect = OAuthProtocol.redirect_uri_with_params(query["redirect_uri"], code: code, state: query["state"], iss: OAuthProtocol.issuer(ctx))
        raise ctx.redirect(redirect)
      end
    end

    def oidc_consent_endpoint(config)
      Endpoint.new(path: "/oauth2/consent", method: "POST", metadata: oidc_openapi("oauth2Consent", "Handle OAuth2 consent", "OAuth2 consent handled successfully", oidc_redirect_response_schema)) do |ctx|
        Routes.current_session(ctx)
        body = OAuthProtocol.stringify_keys(ctx.body)
        consent = config[:store][:consents].delete(body["consent_code"].to_s)
        raise APIError.new("BAD_REQUEST", message: "invalid consent_code") unless consent
        raise APIError.new("BAD_REQUEST", message: "expired consent_code") if consent[:expires_at] <= Time.now

        query = consent[:query]
        if body["accept"] == false || body["accept"].to_s == "false"
          redirect = OAuthProtocol.redirect_uri_with_params(query["redirect_uri"], error: "access_denied", state: query["state"], iss: OAuthProtocol.issuer(ctx))
          next ctx.json({redirectURI: redirect})
        end

        oidc_store_consent(ctx, consent[:client], consent[:session], consent[:scopes])
        code = Crypto.random_string(32)
        OAuthProtocol.store_code(
          config[:store],
          code: code,
          client_id: query["client_id"],
          redirect_uri: query["redirect_uri"],
          session: consent[:session],
          scopes: consent[:scopes],
          code_challenge: query["code_challenge"],
          code_challenge_method: query["code_challenge_method"]
        )
        ctx.json({redirectURI: OAuthProtocol.redirect_uri_with_params(query["redirect_uri"], code: code, state: query["state"], iss: OAuthProtocol.issuer(ctx))})
      end
    end

    def oidc_token_endpoint(config)
      Endpoint.new(
        path: "/oauth2/token",
        method: "POST",
        metadata: oidc_openapi("oauth2Token", "Exchange OAuth2 code for tokens", "OAuth2 tokens issued successfully", oidc_token_response_schema).merge(allowed_media_types: ["application/x-www-form-urlencoded", "application/json"])
      ) do |ctx|
        body = OAuthProtocol.stringify_keys(ctx.body)
        client = OAuthProtocol.authenticate_client!(ctx, "oauthApplication", store_client_secret: config[:store_client_secret])
        raise APIError.new("UNAUTHORIZED", message: "invalid_client") unless client

        response = case body["grant_type"]
        when OAuthProtocol::AUTH_CODE_GRANT
          code = OAuthProtocol.consume_code!(
            config[:store],
            body["code"],
            client_id: body["client_id"],
            redirect_uri: body["redirect_uri"],
            code_verifier: body["code_verifier"]
          )
          OAuthProtocol.issue_tokens(
            ctx,
            config[:store],
            model: "oauthAccessToken",
            client: client,
            session: code[:session],
            scopes: code[:scopes],
            include_refresh: code[:scopes].include?("offline_access"),
            issuer: OIDCProvider.normalize_issuer(OAuthProtocol.issuer(ctx)),
            access_token_expires_in: config[:access_token_expires_in],
            id_token_signer: oidc_id_token_signer(ctx, config)
          )
        when OAuthProtocol::REFRESH_GRANT
          OAuthProtocol.refresh_tokens(ctx, config[:store], model: "oauthAccessToken", client: client, refresh_token: body["refresh_token"], scopes: body["scope"], issuer: OIDCProvider.normalize_issuer(OAuthProtocol.issuer(ctx)), access_token_expires_in: config[:access_token_expires_in], id_token_signer: oidc_id_token_signer(ctx, config))
        else
          raise APIError.new("BAD_REQUEST", message: "unsupported_grant_type")
        end
        ctx.json(response)
      end
    end

    def oidc_userinfo_endpoint(config)
      Endpoint.new(path: "/oauth2/userinfo", method: "GET", metadata: oidc_openapi("oauth2Userinfo", "Get OAuth2 user information", "User information retrieved successfully", oidc_userinfo_schema)) do |ctx|
        ctx.json(OAuthProtocol.userinfo(config[:store], ctx.headers["authorization"], additional_claim: config[:get_additional_user_info_claim]))
      end
    end

    def oidc_introspect_endpoint(config)
      Endpoint.new(
        path: "/oauth2/introspect",
        method: "POST",
        metadata: oidc_openapi("oauth2Introspect", "Introspect an OAuth2 token", "OAuth2 token introspection result", oidc_introspection_schema).merge(allowed_media_types: ["application/x-www-form-urlencoded", "application/json"])
      ) do |ctx|
        OAuthProtocol.authenticate_client!(ctx, "oauthApplication", store_client_secret: config[:store_client_secret])
        body = OAuthProtocol.stringify_keys(ctx.body)
        token = config[:store][:tokens][body["token"].to_s] || config[:store][:refresh_tokens][body["token"].to_s]
        active = token && !token["revoked"] && (!token["expiresAt"] || token["expiresAt"] > Time.now)
        ctx.json(active ? {
          active: true,
          client_id: token["clientId"],
          scope: OAuthProtocol.scope_string(token["scope"] || token["scopes"]),
          sub: token.dig("user", "id"),
          exp: token["expiresAt"]&.to_i
        } : {active: false})
      end
    end

    def oidc_revoke_endpoint(config)
      Endpoint.new(
        path: "/oauth2/revoke",
        method: "POST",
        metadata: oidc_openapi("oauth2Revoke", "Revoke an OAuth2 token", "OAuth2 token revoked successfully", OpenAPI.object_schema({revoked: {type: "boolean"}}, required: ["revoked"])).merge(allowed_media_types: ["application/x-www-form-urlencoded", "application/json"])
      ) do |ctx|
        OAuthProtocol.authenticate_client!(ctx, "oauthApplication", store_client_secret: config[:store_client_secret])
        body = OAuthProtocol.stringify_keys(ctx.body)
        if (token = config[:store][:tokens][body["token"].to_s] || config[:store][:refresh_tokens][body["token"].to_s])
          token["revoked"] = Time.now
        end
        ctx.json({revoked: true})
      end
    end

    def oidc_end_session_endpoint
      Endpoint.new(
        path: "/oauth2/endsession",
        method: ["GET", "POST"],
        metadata: {
          openapi: {
            operationId: "oauth2EndSession",
            description: "RP-Initiated Logout endpoint",
            parameters: oidc_end_session_schema[:properties].keys.map { |name| OpenAPI.query_parameter(name.to_s, schema: oidc_end_session_schema[:properties][name]) },
            requestBody: OpenAPI.json_request_body(oidc_end_session_schema, required: false),
            responses: {
              "302" => {description: "Redirects after clearing the session cookie"}
            }
          },
          allowed_media_types: ["application/x-www-form-urlencoded", "application/json"]
        }
      ) do |ctx|
        input_source = (ctx.method == "GET") ? ctx.query : ctx.body
        input = OAuthProtocol.stringify_keys(input_source)
        if input["post_logout_redirect_uri"]
          client = OAuthProtocol.find_client(ctx, "oauthApplication", input["client_id"])
          raise APIError.new("BAD_REQUEST", message: "invalid_client") unless client
          unless OAuthProtocol.client_logout_redirect_uris(client).include?(input["post_logout_redirect_uri"])
            raise APIError.new("BAD_REQUEST", message: "invalid_request")
          end
        end

        Cookies.delete_session_cookie(ctx)
        redirect = input["post_logout_redirect_uri"] || "/"
        redirect = OAuthProtocol.redirect_uri_with_params(redirect, state: input["state"]) if input["state"]
        raise ctx.redirect(redirect)
      end
    end

    def oidc_openapi(operation_id, description, response_description = "Success", response_schema = {type: "object"})
      {
        openapi: {
          operationId: operation_id,
          description: description,
          requestBody: oidc_request_body_for(operation_id),
          responses: {
            "200" => OpenAPI.json_response(response_description, response_schema)
          }
        }
      }
    end

    def oidc_request_body_for(operation_id)
      schema = case operation_id
      when "registerOAuthApplication", "updateOAuthApplication"
        oidc_client_registration_schema
      when "rotateOAuthApplicationSecret"
        OpenAPI.empty_request_body.dig(:content, "application/json", :schema)
      when "oauth2Consent"
        OpenAPI.object_schema({consent_code: {type: "string"}, accept: {type: "boolean"}}, required: ["consent_code"])
      when "oauth2Token"
        OpenAPI.object_schema(
          {
            grant_type: {type: "string", enum: [OAuthProtocol::AUTH_CODE_GRANT, OAuthProtocol::REFRESH_GRANT]},
            code: {type: "string"},
            redirect_uri: {type: "string", format: "uri"},
            code_verifier: {type: "string"},
            client_id: {type: "string"},
            client_secret: {type: "string"},
            refresh_token: {type: "string"},
            scope: {type: "string"}
          },
          required: ["grant_type"]
        )
      when "oauth2Introspect", "oauth2Revoke"
        OpenAPI.object_schema({token: {type: "string"}, token_type_hint: {type: "string", enum: ["access_token", "refresh_token"]}}, required: ["token"])
      end
      schema ? OpenAPI.json_request_body(schema) : nil
    end

    def oidc_client_registration_schema
      OpenAPI.object_schema(
        {
          redirect_uris: {type: "array", items: {type: "string", format: "uri"}},
          post_logout_redirect_uris: {type: "array", items: {type: "string", format: "uri"}},
          client_name: {type: "string"},
          client_uri: {type: "string", format: "uri"},
          logo_uri: {type: "string", format: "uri"},
          grant_types: {type: "array", items: {type: "string"}},
          response_types: {type: "array", items: {type: "string"}},
          scope: {type: "string"},
          scopes: {type: "array", items: {type: "string"}},
          metadata: {type: "object", additionalProperties: true}
        }
      )
    end

    def oidc_end_session_schema
      OpenAPI.object_schema(
        {
          id_token_hint: {type: "string"},
          client_id: {type: "string"},
          post_logout_redirect_uri: {type: "string", format: "uri"},
          state: {type: "string"}
        }
      )
    end

    def oidc_client_schema
      OpenAPI.object_schema(
        {
          clientId: {type: "string"},
          clientSecret: {type: ["string", "null"]},
          name: {type: "string"},
          redirectUris: {type: "array", items: {type: "string"}},
          grantTypes: {type: "array", items: {type: "string"}},
          responseTypes: {type: "array", items: {type: "string"}}
        },
        required: ["clientId", "name"]
      )
    end

    def oidc_redirect_response_schema
      OpenAPI.object_schema(
        {redirectURI: {type: "string", format: "uri"}},
        required: ["redirectURI"]
      )
    end

    def oidc_token_response_schema
      OpenAPI.object_schema(
        {
          access_token: {type: "string"},
          token_type: {type: "string"},
          expires_in: {type: "number"},
          refresh_token: {type: ["string", "null"]},
          id_token: {type: ["string", "null"]},
          scope: {type: ["string", "null"]}
        },
        required: ["access_token", "token_type", "expires_in"]
      )
    end

    def oidc_userinfo_schema
      OpenAPI.object_schema(
        {
          sub: {type: "string"},
          email: {type: ["string", "null"]},
          email_verified: {type: ["boolean", "null"]},
          name: {type: ["string", "null"]},
          picture: {type: ["string", "null"]}
        },
        required: ["sub"]
      )
    end

    def oidc_introspection_schema
      OpenAPI.object_schema(
        {
          active: {type: "boolean"},
          client_id: {type: ["string", "null"]},
          scope: {type: ["string", "null"]},
          sub: {type: ["string", "null"]},
          exp: {type: ["number", "null"]}
        },
        required: ["active"]
      )
    end

    def oidc_provider_schema
      {
        oauthApplication: {
          model_name: "oauth_applications",
          fields: {
            name: {type: "string"},
            icon: {type: "string", required: false},
            uri: {type: "string", required: false},
            metadata: {type: "json", required: false},
            clientId: {type: "string", unique: true},
            clientSecret: {type: "string", required: false},
            redirectUrls: {type: "string"},
            redirectUris: {type: "string[]", required: false},
            postLogoutRedirectUris: {type: "string[]", required: false},
            tokenEndpointAuthMethod: {type: "string", required: false},
            skipConsent: {type: "boolean", required: false},
            grantTypes: {type: "string[]", required: false},
            responseTypes: {type: "string[]", required: false},
            scopes: {type: "string[]", required: false},
            type: {type: "string"},
            disabled: {type: "boolean", required: false, default_value: false},
            userId: {type: "string", required: false, references: {model: "users", field: "id", on_delete: "cascade"}, index: true},
            createdAt: {type: "date", required: true, default_value: -> { Time.now }},
            updatedAt: {type: "date", required: true, default_value: -> { Time.now }, on_update: -> { Time.now }}
          }
        },
        oauthAccessToken: {
          model_name: "oauth_access_tokens",
          fields: {
            accessToken: {type: "string", unique: true, required: false},
            token: {type: "string", unique: true, required: false},
            refreshToken: {type: "string", unique: true, required: false},
            accessTokenExpiresAt: {type: "date", required: false},
            expiresAt: {type: "date", required: false},
            clientId: {type: "string", required: true},
            userId: {type: "string", required: false},
            sessionId: {type: "string", required: false},
            scope: {type: "string", required: false},
            scopes: {type: "string[]", required: false},
            revoked: {type: "date", required: false},
            createdAt: {type: "date", required: true, default_value: -> { Time.now }},
            updatedAt: {type: "date", required: true, default_value: -> { Time.now }, on_update: -> { Time.now }}
          }
        },
        oauthConsent: {
          model_name: "oauth_consents",
          fields: {
            clientId: {type: "string", required: true},
            userId: {type: "string", required: true},
            scopes: {type: "string[]", required: false},
            consentGiven: {type: "boolean", required: false},
            createdAt: {type: "date", required: true, default_value: -> { Time.now }},
            updatedAt: {type: "date", required: true, default_value: -> { Time.now }, on_update: -> { Time.now }}
          }
        }
      }
    end

    def oidc_find_owned_client!(ctx, session)
      client = OAuthProtocol.find_client(ctx, "oauthApplication", ctx.params["id"] || ctx.params[:id])
      raise APIError.new("NOT_FOUND", message: "client not found") unless client
      raise APIError.new("FORBIDDEN", message: "Access denied") unless client["userId"] == session[:user]["id"]

      client
    end

    def valid_code_challenge_method?(method, config)
      normalized = method.to_s.downcase
      return true if normalized == "s256"

      normalized == "plain" && config[:allow_plain_code_challenge_method]
    end

    def oidc_requires_login?(session, prompts, query)
      return true if prompts.include?("login")
      return false unless query.key?("max_age")

      max_age = Integer(query["max_age"])
      return false if max_age.negative?

      created_at = session.dig(:session, "createdAt") || session.dig(:session, :createdAt)
      created_at = Time.parse(created_at.to_s) unless created_at.is_a?(Time)
      (Time.now - created_at) > max_age
    rescue ArgumentError, TypeError
      false
    end

    def oidc_use_jwt_plugin?(ctx, config)
      return false unless config[:use_jwt_plugin]

      oidc_jwt_plugin(ctx)
    end

    def oidc_jwt_plugin(ctx)
      ctx.context.options.plugins.find { |plugin| plugin[:id] == "jwt" }
    end

    def oidc_id_token_signer(ctx, config)
      jwt_plugin = oidc_use_jwt_plugin?(ctx, config)
      return nil unless jwt_plugin

      lambda do |sign_ctx, payload|
        BetterAuth::Plugins.sign_jwt_payload(
          sign_ctx,
          OAuthProtocol.stringify_keys(payload),
          jwt_plugin[:options] || {}
        )
      end
    end

    def oidc_consent_granted?(ctx, client_id, user_id, scopes)
      consent = ctx.context.adapter.find_one(
        model: "oauthConsent",
        where: [
          {field: "clientId", value: client_id},
          {field: "userId", value: user_id}
        ]
      )
      return false unless consent && consent["consentGiven"]

      granted = OAuthProtocol.parse_scopes(consent["scopes"])
      scopes.all? { |scope| granted.include?(scope) }
    end

    def oidc_store_consent(ctx, client, session, scopes)
      client_id = OAuthProtocol.stringify_keys(client)["clientId"]
      user_id = session[:user]["id"]
      existing = ctx.context.adapter.find_one(
        model: "oauthConsent",
        where: [
          {field: "clientId", value: client_id},
          {field: "userId", value: user_id}
        ]
      )
      data = {clientId: client_id, userId: user_id, scopes: scopes, consentGiven: true}
      if existing
        ctx.context.adapter.update(model: "oauthConsent", where: [{field: "id", value: existing.fetch("id")}], update: data)
      else
        ctx.context.adapter.create(model: "oauthConsent", data: data)
      end
    end

    def oidc_resume_login_prompt(ctx, config)
      prompt = ctx.get_signed_cookie("oidc_login_prompt", ctx.context.secret)
      return unless prompt
      return unless ctx.response_headers["set-cookie"].to_s.include?(ctx.context.auth_cookies[:session_token].name)

      ctx.set_cookie("oidc_login_prompt", "", path: "/", max_age: 0)
      query = JSON.parse(prompt)
      prompts = OIDCProvider.parse_prompt(query["prompt"])
      if prompts.include?("login")
        prompts.delete("login")
        query["prompt"] = prompts.to_a.join(" ")
      end
      ctx.query = query
      ctx.context.set_current_session(ctx.context.new_session) if ctx.context.respond_to?(:set_current_session) && ctx.context.new_session
      oidc_authorize_endpoint(config).call(ctx)
    rescue APIError => error
      raise APIError.new(
        error.status,
        message: error.message,
        headers: Endpoint::Result.merge_headers(ctx.response_headers, error.headers),
        code: error.code,
        body: error.body
      )
    rescue JSON::ParserError
      nil
    end
  end
end
