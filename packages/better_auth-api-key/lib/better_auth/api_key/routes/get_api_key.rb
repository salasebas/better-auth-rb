# frozen_string_literal: true

module BetterAuth
  module APIKey
    module Routes
      module GetAPIKey
        UPSTREAM_SOURCE = "reference/upstream-src/1.7.1/repository/packages/api-key/src/routes/get-api-key.ts"

        module_function

        def endpoint(config)
          BetterAuth::Endpoint.new(
            path: "/api-key/get",
            method: "GET",
            query_schema: BetterAuth::APIKey::RequestContract.get_query_schema,
            metadata: Routes.openapi_for(:get_api_key)
          ) do |ctx|
            session = BetterAuth::Routes.current_session(ctx)
            query = BetterAuth::Plugins.normalize_hash(ctx.query)
            resolved_config = BetterAuth::Plugins.api_key_resolve_config(ctx.context, config, query[:config_id])
            id = query[:id]
            record = BetterAuth::Plugins.api_key_find_by_id(ctx, id, resolved_config)
            unless record && BetterAuth::Plugins.api_key_config_id_matches?(BetterAuth::Plugins.api_key_record_config_id(record), resolved_config[:config_id])
              raise BetterAuth::APIKey.error("NOT_FOUND", "KEY_NOT_FOUND")
            end

            record_config = BetterAuth::Plugins.api_key_resolve_config(ctx.context, config, BetterAuth::Plugins.api_key_record_config_id(record))
            BetterAuth::Plugins.api_key_authorize_reference!(ctx, record_config, session[:user]["id"], BetterAuth::Plugins.api_key_record_reference_id(record), "read")

            record = BetterAuth::Plugins.api_key_migrate_legacy_metadata(ctx, record, record_config)
            BetterAuth::Plugins.api_key_delete_expired(ctx.context, record_config)
            ctx.json(BetterAuth::Plugins.api_key_public(record, include_key_field: false))
          end
        end
      end
    end
  end
end
