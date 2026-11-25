# frozen_string_literal: true

require "base64"
require "json"
require "jwt"
require "openssl"

module BetterAuth
  module Plugins
    module OAuthProtocol
      module_function

      def consume_code!(internal_adapter, code, client_id:, redirect_uri:, code_verifier: nil, store_tokens: "hashed")
        stored_code = get_stored_token(store_tokens, code.to_s, "authorization_code")
        verification = internal_adapter.consume_verification_value(stored_code)
        verification ||= internal_adapter.consume_verification_value(code.to_s) if stored_code != code.to_s
        data = verification && JSON.parse(verification.fetch("value"), symbolize_names: true)
        unless data.is_a?(Hash) && !data[:client_id].to_s.empty? && !data[:redirect_uri].to_s.empty? && data[:session].is_a?(Hash) && data[:scopes].is_a?(Array)
          raise APIError.new("BAD_REQUEST", message: "invalid_grant")
        end
        raise APIError.new("BAD_REQUEST", message: "invalid_grant") unless data[:client_id] == client_id.to_s
        raise APIError.new("BAD_REQUEST", message: "invalid_grant") unless data[:redirect_uri] == redirect_uri.to_s
        if data[:code_challenge]
          verify_pkce!(data, code_verifier)
        elsif !code_verifier.to_s.empty?
          raise APIError.new("BAD_REQUEST", message: "invalid_grant")
        end

        data
      rescue JSON::ParserError, KeyError, TypeError
        raise APIError.new("BAD_REQUEST", message: "invalid_grant")
      end

      def verify_pkce!(code_data, verifier)
        raise APIError.new("BAD_REQUEST", message: "invalid_grant") if verifier.to_s.empty?

        raise APIError.new("BAD_REQUEST", message: "invalid_grant") unless code_data[:code_challenge_method].to_s == "S256"

        challenge = Base64.urlsafe_encode64(OpenSSL::Digest.digest("SHA256", verifier.to_s), padding: false)
        raise APIError.new("BAD_REQUEST", message: "invalid_grant") unless challenge == code_data[:code_challenge]
      end

      def issue_tokens(ctx, store, model:, client:, session:, scopes:, include_refresh: false, issuer: nil, jwt_audience: nil, access_token_expires_in: 3600, refresh_token_expires_in: 2_592_000, id_token_expires_in: 3600, id_token_signer: nil, prefix: {}, audience: nil, grant_type: nil, custom_token_response_fields: nil, custom_access_token_claims: nil, custom_id_token_claims: nil, jwt_access_token: false, use_jwt_plugin: false, pairwise_secret: nil, nonce: nil, auth_time: nil, reference_id: nil, filter_id_token_claims_by_scope: false, store_tokens: "hashed", generate_opaque_access_token: nil, generate_refresh_token: nil, format_refresh_token: nil)
        data = stringify_keys(session || {})
        user = stringify_keys(data["user"] || data[:user] || {})
        session_data = stringify_keys(data["session"] || data[:session] || {})
        raw_client_data = stringify_keys(client)
        provided_client_secret = raw_client_data["__providedClientSecret"]
        client_data = redact_client_secret_fields(raw_client_data)
        subject = subject_identifier(user["id"], client_data, pairwise_secret)
        token_auth_time = auth_time || session_auth_time({"session" => session_data})
        token_reference_id = reference_id || client_data["referenceId"]
        access_token_value = generate_opaque_access_token.respond_to?(:call) ? generate_opaque_access_token.call : Crypto.random_string(32)
        refresh_token_value = if include_refresh
          generate_refresh_token.respond_to?(:call) ? generate_refresh_token.call : Crypto.random_string(32)
        end
        refresh_token = refresh_token_value ? encode_refresh_token(refresh_token_value, prefix: prefix, format_refresh_token: format_refresh_token, session_id: session_data["id"]) : nil
        scope = scope_string(scopes)
        expires_at = Time.now + access_token_expires_in.to_i
        access_token = if jwt_access_token && audience
          build_jwt_access_token(ctx, client_data, user, session_data, scope, audience, issuer || issuer(ctx), expires_at, custom_access_token_claims, reference_id: token_reference_id, use_jwt_plugin: use_jwt_plugin)
        else
          apply_prefix(access_token_value, prefix, :access_token)
        end
        refresh_record = nil
        if refresh_token_value
          refresh_record = {
            "token" => store_token_value(store_tokens, refresh_token_value, "refresh_token"),
            "clientId" => client_data["clientId"],
            "sessionId" => session_data["id"],
            "userId" => user["id"],
            "referenceId" => token_reference_id,
            "authTime" => token_auth_time,
            "expiresAt" => Time.now + refresh_token_expires_in.to_i,
            "createdAt" => Time.now,
            "revoked" => nil,
            "scopes" => parse_scopes(scope),
            "subject" => subject,
            "audience" => audience,
            "issuer" => issuer || issuer(ctx),
            "issuedAt" => Time.now
          }
          created_refresh = schema_model?(ctx, "oauthRefreshToken") ? ctx.context.adapter.create(model: "oauthRefreshToken", data: refresh_record) : nil
          refresh_record = refresh_record.merge("id" => stringify_keys(created_refresh || {})["id"], "token" => refresh_token_value, "user" => user, "session" => session_data, "client" => client_data, "scope" => scope)
          store[:refresh_tokens][refresh_token_value] = refresh_record
          store[:refresh_tokens][refresh_token] = refresh_record
        end
        unless jwt_access_token && audience
          record = {
            "token" => store_token_value(store_tokens, access_token_value, "access_token"),
            "expiresAt" => expires_at,
            "clientId" => client_data["clientId"],
            "userId" => user["id"],
            "subject" => subject,
            "sessionId" => session_data["id"],
            "scopes" => parse_scopes(scope),
            "revoked" => nil,
            "referenceId" => token_reference_id,
            "authTime" => token_auth_time,
            "refreshId" => refresh_record && refresh_record["id"],
            "audience" => audience,
            "issuer" => issuer || issuer(ctx),
            "issuedAt" => Time.now
          }
          created_access = ctx.context.adapter.create(model: model, data: record)
          created = stringify_keys(created_access || {})
          record = record.merge("id" => created["id"]) if created["id"]
          stored_record = record.merge("token" => access_token_value, "user" => user, "session" => session_data, "client" => client_data)
          store[:tokens][access_token_value] = stored_record
          store[:tokens][access_token] = stored_record
        end

        response = {
          access_token: access_token,
          token_type: "Bearer",
          expires_in: access_token_expires_in.to_i,
          expires_at: expires_at.to_i,
          scope: scope
        }
        response[:audience] = audience if audience
        response[:refresh_token] = refresh_token if refresh_token
        issue_id_token = parse_scopes(scope).include?("openid") && (use_jwt_plugin || !provided_client_secret.to_s.empty?)
        response[:id_token] = id_token(user.merge("id" => subject), client_data["clientId"], issuer || issuer(ctx), jwt_audience || client_data["clientId"], ctx: ctx, signer: id_token_signer, session_id: session_data["id"], include_sid: !!client_data["enableEndSession"], nonce: nonce, auth_time: token_auth_time, custom_claims: custom_id_token_claims, scopes: parse_scopes(scope), client: client_data, filter_claims_by_scope: filter_id_token_claims_by_scope, expires_in: id_token_expires_in, use_jwt_plugin: use_jwt_plugin, hs256_secret: provided_client_secret) if issue_id_token
        if custom_token_response_fields.respond_to?(:call)
          extra = custom_token_response_fields.call({grant_type: grant_type, user: user.empty? ? nil : user, scopes: parse_scopes(scope), metadata: stringify_keys(client_data["metadata"] || {})})
          response.merge!(stringify_keys(extra).reject { |key, _value| standard_token_response_field?(key) }.transform_keys(&:to_sym)) if extra.is_a?(Hash)
        end
        response
      end

      def refresh_tokens(ctx, store, model:, client:, refresh_token:, scopes: nil, issuer: nil, access_token_expires_in: 3600, refresh_token_expires_in: 2_592_000, id_token_expires_in: 3600, id_token_signer: nil, prefix: {}, audience: nil, custom_token_response_fields: nil, custom_access_token_claims: nil, custom_id_token_claims: nil, jwt_access_token: false, use_jwt_plugin: false, pairwise_secret: nil, filter_id_token_claims_by_scope: false, store_tokens: "hashed", generate_opaque_access_token: nil, generate_refresh_token: nil, format_refresh_token: nil)
        refresh_token_value = decode_refresh_token(refresh_token, prefix: prefix, format_refresh_token: format_refresh_token)
        raise APIError.new("BAD_REQUEST", message: "invalid_grant") if refresh_token_value.to_s.empty?
        data = store[:refresh_tokens][refresh_token_value]
        raise APIError.new("BAD_REQUEST", message: "invalid_grant") unless data
        scrub_token_record_client!(data)
        if data["revoked"]
          revoke_refresh_family!(ctx, store, data)
          raise APIError.new("BAD_REQUEST", message: "invalid_grant")
        end
        raise APIError.new("BAD_REQUEST", message: "invalid_grant") if data["expiresAt"] && data["expiresAt"] <= Time.now

        client_data = stringify_keys(client)
        unless data["clientId"].to_s == client_data["clientId"].to_s
          raise APIError.new("BAD_REQUEST", message: "invalid_grant")
        end

        requested = scopes ? parse_scopes(scopes) : data["scopes"]
        unless requested.all? { |scope| data["scopes"].include?(scope) }
          raise APIError.new("BAD_REQUEST", message: "invalid_scope")
        end
        data["revoked"] = Time.now
        ctx.context.adapter.update(model: "oauthRefreshToken", where: [{field: "id", value: data["id"]}], update: {revoked: data["revoked"]}) if data["id"] && schema_model?(ctx, "oauthRefreshToken")

        issue_tokens(
          ctx,
          store,
          model: model,
          client: client,
          session: {"user" => data["user"], "session" => data["session"]},
          scopes: requested,
          include_refresh: true,
          issuer: issuer,
          access_token_expires_in: access_token_expires_in,
          refresh_token_expires_in: refresh_token_expires_in,
          id_token_signer: id_token_signer,
          prefix: prefix,
          audience: audience,
          grant_type: REFRESH_GRANT,
          custom_token_response_fields: custom_token_response_fields,
          custom_access_token_claims: custom_access_token_claims,
          custom_id_token_claims: custom_id_token_claims,
          jwt_access_token: jwt_access_token,
          use_jwt_plugin: use_jwt_plugin,
          pairwise_secret: pairwise_secret,
          id_token_expires_in: id_token_expires_in,
          auth_time: data["authTime"],
          reference_id: data["referenceId"],
          filter_id_token_claims_by_scope: filter_id_token_claims_by_scope,
          store_tokens: store_tokens,
          generate_opaque_access_token: generate_opaque_access_token,
          generate_refresh_token: generate_refresh_token,
          format_refresh_token: format_refresh_token
        )
      end

      def build_jwt_access_token(ctx, client, user, session, scope, audience, issuer_value, expires_at, custom_claims, reference_id: nil, use_jwt_plugin: false)
        scopes = parse_scopes(scope)
        extra = if custom_claims.respond_to?(:call)
          custom_claims.call({user: user.empty? ? nil : user, scopes: scopes, resource: audience, reference_id: reference_id, metadata: stringify_keys(client["metadata"] || {})})
        end
        payload = (extra.is_a?(Hash) ? stringify_keys(extra) : {}).merge(
          "sub" => user["id"] || client["clientId"],
          "aud" => audience,
          "azp" => client["clientId"],
          "scope" => scope,
          "sid" => session["id"],
          "name" => user["name"],
          "email" => user["email"],
          "email_verified" => user["emailVerified"],
          "iss" => issuer_value,
          "iat" => Time.now.to_i,
          "exp" => expires_at.to_i
        ).compact
        if use_jwt_plugin
          return sign_oauth_jwt!(ctx, payload, issuer: issuer_value, audience: audience)
        end

        ::JWT.encode(payload, ctx.context.secret, "HS256")
      end

      def revoke_refresh_family!(ctx, store, refresh_record)
        client_id = refresh_record["clientId"]
        user_id = refresh_record["userId"]
        store[:refresh_tokens].delete_if { |_token, record| record["clientId"] == client_id && record["userId"] == user_id }
        store[:tokens].delete_if { |_token, record| record["clientId"] == client_id && record["userId"] == user_id }
        if schema_model?(ctx, "oauthRefreshToken")
          refresh_ids = ctx.context.adapter.find_many(
            model: "oauthRefreshToken",
            where: [
              {field: "clientId", value: client_id},
              {field: "userId", value: user_id}
            ]
          ).map { |entry| stringify_keys(entry)["id"] }

          ctx.context.adapter.delete_many(
            model: "oauthRefreshToken",
            where: [
              {field: "clientId", value: client_id},
              {field: "userId", value: user_id}
            ]
          )

          if schema_model?(ctx, "oauthAccessToken")
            refresh_ids.each do |refresh_id|
              ctx.context.adapter.delete_many(model: "oauthAccessToken", where: [{field: "refreshId", value: refresh_id}])
            end
          end
        end
      end

      def encode_refresh_token(token_value, prefix:, format_refresh_token: nil, session_id: nil)
        formatted = if format_refresh_token.is_a?(Hash) && format_refresh_token[:encrypt].respond_to?(:call)
          format_refresh_token[:encrypt].call(token_value, session_id)
        else
          token_value
        end
        apply_prefix(formatted, prefix, :refresh_token)
      end

      def decode_refresh_token(token, prefix:, format_refresh_token: nil)
        value = strip_prefix(token, prefix, :refresh_token)
        return nil if value.nil?

        if format_refresh_token.is_a?(Hash) && format_refresh_token[:decrypt].respond_to?(:call)
          decrypted = format_refresh_token[:decrypt].call(value)
          if decrypted.is_a?(Hash)
            decrypted[:token] || decrypted["token"]
          else
            decrypted.to_s
          end
        else
          value
        end
      end

      def id_token(user, client_id, issuer_value, audience, ctx: nil, signer: nil, session_id: nil, include_sid: false, nonce: nil, auth_time: nil, custom_claims: nil, scopes: [], client: {}, filter_claims_by_scope: false, expires_in: 3600, use_jwt_plugin: false, hs256_secret: nil)
        requested_scopes = parse_scopes(scopes)
        payload = {
          sub: user["id"],
          iss: issuer_value,
          aud: audience || client_id
        }
        include_profile_claims = !filter_claims_by_scope || requested_scopes.include?("profile")
        include_email_claims = !filter_claims_by_scope || requested_scopes.include?("email")
        payload[:name] = user["name"] if include_profile_claims
        if include_email_claims
          payload[:email] = user["email"]
          payload[:email_verified] = !!user["emailVerified"]
        end
        payload[:sid] = session_id if include_sid && session_id
        payload[:nonce] = nonce if nonce
        payload[:auth_time] = timestamp_seconds(auth_time) if auth_time
        if custom_claims.respond_to?(:call)
          extra = custom_claims.call({user: user, scopes: requested_scopes, client: client})
          if extra.is_a?(Hash)
            pinned = %w[sub iss aud exp iat nonce sid]
            payload.merge!(stringify_keys(extra).except(*pinned).transform_keys(&:to_sym))
          end
        end
        return signer.call(ctx, payload) if signer.respond_to?(:call)

        if use_jwt_plugin && ctx
          return sign_oauth_jwt!(ctx, payload, issuer: issuer_value, audience: audience)
        end

        signing_key = id_token_hs256_key(ctx, client_id, hs256_secret)
        raise Error, "client secret is required for HS256 ID token signing" if signing_key.empty?

        Crypto.sign_jwt(payload, signing_key, expires_in: expires_in)
      end

      def id_token_hs256_key(_ctx, _client_id, client_secret = nil)
        client_secret.to_s
      end

      def sign_oauth_jwt(ctx, payload, issuer:, audience:)
        config = oauth_jwt_config(ctx, issuer: issuer, audience: audience)
        return nil unless config

        BetterAuth::Plugins.sign_jwt_payload(ctx, stringify_keys(payload), config)
      end

      def sign_oauth_jwt!(ctx, payload, issuer:, audience:)
        raise BetterAuth::Error, "jwt_config" unless jwt_plugin_options(ctx)

        signed = sign_oauth_jwt(ctx, payload, issuer: issuer, audience: audience)
        raise BetterAuth::Error, "jwt_config" unless signed

        signed
      end

      def standard_token_response_field?(key)
        %w[access_token token_type expires_in scope refresh_token id_token audience].include?(key.to_s)
      end
    end
  end
end
