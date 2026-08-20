# frozen_string_literal: true

module BetterAuth
  module APIKey
    module Routes
      module UpdateAPIKey
        UPSTREAM_SOURCE = "reference/upstream-src/1.7.1/repository/packages/api-key/src/routes/update-api-key.ts"

        module_function

        def endpoint(config)
          BetterAuth::Endpoint.new(
            path: "/api-key/update",
            method: "POST",
            body_schema: BetterAuth::APIKey::RequestContract.update_body_schema,
            metadata: Routes.openapi_for(:update_api_key)
          ) do |ctx|
            body = BetterAuth::Plugins.api_key_normalize_body(ctx.body)
            resolved_config = BetterAuth::Plugins.api_key_resolve_config(ctx.context, config, body[:config_id])
            # Updates must not authorize from a stale cookie-cache session.
            session = BetterAuth::Routes.current_session(ctx, allow_nil: true, sensitive: true)
            if !session && BetterAuth::Plugins.api_key_auth_required?(ctx)
              raise BetterAuth::APIKey.error("UNAUTHORIZED", "UNAUTHORIZED_SESSION")
            end
            user_id = session&.dig(:user, "id") || body[:user_id]
            raise BetterAuth::APIKey.error("UNAUTHORIZED", "UNAUTHORIZED_SESSION") unless user_id
            if session && body[:user_id] && body[:user_id] != session[:user]["id"]
              raise BetterAuth::APIKey.error("UNAUTHORIZED", "UNAUTHORIZED_SESSION")
            end

            key_id = body[:key_id]
            record = BetterAuth::Plugins.api_key_find_by_id(ctx, key_id, resolved_config)
            raise BetterAuth::APIKey.error("NOT_FOUND", "KEY_NOT_FOUND") unless record
            unless BetterAuth::Plugins.api_key_config_id_matches?(BetterAuth::Plugins.api_key_record_config_id(record), resolved_config[:config_id])
              raise BetterAuth::APIKey.error("NOT_FOUND", "KEY_NOT_FOUND")
            end

            record_config = BetterAuth::Plugins.api_key_resolve_config(ctx.context, config, BetterAuth::Plugins.api_key_record_config_id(record))
            BetterAuth::Plugins.api_key_authorize_reference!(ctx, record_config, user_id, BetterAuth::Plugins.api_key_record_reference_id(record), "update")

            BetterAuth::Plugins.api_key_validate_create_update!(body, record_config, create: false, client: BetterAuth::Plugins.api_key_auth_required?(ctx))
            update = BetterAuth::Plugins.api_key_update_payload(body, record_config)
            raise BetterAuth::APIKey.error("BAD_REQUEST", "NO_VALUES_TO_UPDATE") if update.empty?

            updated = BetterAuth::Plugins.api_key_update_record(ctx, record, update.merge(updatedAt: Time.now), record_config)
            unless updated
              raise BetterAuth::APIError.new(
                "INTERNAL_SERVER_ERROR",
                message: BetterAuth::Plugins::API_KEY_ERROR_CODES["FAILED_TO_UPDATE_API_KEY"],
                code: "FAILED_TO_UPDATE_API_KEY"
              )
            end
            updated = BetterAuth::Plugins.api_key_migrate_legacy_metadata(ctx, updated, record_config)
            BetterAuth::Plugins.api_key_delete_expired(ctx.context, record_config)
            ctx.json(BetterAuth::Plugins.api_key_public(updated, include_key_field: false))
          end
        end
      end
    end
  end
end
