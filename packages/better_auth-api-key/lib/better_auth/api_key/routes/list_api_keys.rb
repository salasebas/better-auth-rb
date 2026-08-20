# frozen_string_literal: true

module BetterAuth
  module APIKey
    module Routes
      module ListAPIKeys
        UPSTREAM_SOURCE = "reference/upstream-src/1.7.1/repository/packages/api-key/src/routes/list-api-keys.ts"
        STORAGE_GROUP_CONCURRENCY = 10

        module_function

        def endpoint(config)
          BetterAuth::Endpoint.new(path: "/api-key/list", method: "GET", metadata: Routes.openapi_for(:list_api_keys)) do |ctx|
            session = BetterAuth::Routes.current_session(ctx)
            query = BetterAuth::Plugins.normalize_hash(ctx.query)
            BetterAuth::Plugins.api_key_validate_list_query!(query)
            config_id = query[:config_id]
            filter_by_config = !config_id.to_s.empty?
            configs = filter_by_config ? [BetterAuth::Plugins.api_key_resolve_config(ctx.context, config, config_id)] : storage_groups(config.fetch(:configurations, [config]))
            organization_id = query[:organization_id]
            organization_scope = !organization_id.to_s.empty?
            reference_id = organization_id.nil? ? session[:user]["id"] : organization_id
            expected_reference = organization_scope ? "organization" : "user"
            BetterAuth::Plugins.api_key_check_org_permission!(ctx, session[:user]["id"], reference_id, "read") if organization_scope
            offset = query.key?(:offset) ? query[:offset].to_i : nil
            limit = query.key?(:limit) ? query[:limit].to_i : nil
            pushed = filter_by_config ? database_paginated_records(ctx, configs.first, reference_id, expected_reference, query, limit, offset) : nil
            if pushed
              records = pushed.fetch(:records)
              total = pushed.fetch(:total)
            else
              group_records = BetterAuth::Async.map_concurrent(configs, concurrency: STORAGE_GROUP_CONCURRENCY) do |entry|
                records = BetterAuth::Plugins.api_key_list_for_reference(ctx, reference_id, entry)
                BetterAuth::Plugins.api_key_sort_records(records, query[:sort_by], query[:sort_direction])
              end
              records = group_records.flatten.uniq { |record| record["id"] }
              records = records.select do |record|
                record_config = configuration_for_record(config, BetterAuth::Plugins.api_key_record_config_id(record))
                references = record_config ? record_config[:references].to_s : "user"
                references == expected_reference &&
                  BetterAuth::Plugins.api_key_record_reference_id(record) == reference_id &&
                  (!filter_by_config || BetterAuth::Plugins.api_key_config_id_matches?(BetterAuth::Plugins.api_key_record_config_id(record), config_id))
              end
              total = records.length
              records = records.drop(offset) if offset
              records = records.first(limit) if limit
            end
            cleanup_config = filter_by_config ? configs.first : config
            BetterAuth::Plugins.api_key_delete_expired(ctx.context, cleanup_config)
            migration_records = records.select { |record| BetterAuth::APIKey::Adapter.legacy_metadata_migration_needed?(record) }
            if migration_records.any?
              BetterAuth::APIKey::Utils.run_background_task(
                ctx,
                "API key metadata migration",
                lambda do
                  migration_records.each do |record|
                    record_config = BetterAuth::Plugins.api_key_resolve_config(ctx.context, config, BetterAuth::Plugins.api_key_record_config_id(record))
                    BetterAuth::APIKey::Adapter.batch_migrate_legacy_metadata(ctx, [record], record_config)
                  end
                end
              )
            end
            api_keys = records.map do |record|
              BetterAuth::Plugins.api_key_public(record, include_key_field: false)
            end
            ctx.json({apiKeys: api_keys, total: total, limit: limit, offset: offset})
          end
        end

        def storage_groups(configurations)
          seen = {}
          configurations.each_with_object([]) do |entry, groups|
            key = storage_identifier(entry)
            next if seen[key]

            seen[key] = true
            groups << entry
          end
        end

        def configuration_for_record(config, config_id)
          configurations = config.fetch(:configurations, [config])
          if BetterAuth::APIKey::Routes.default_config_id?(config_id)
            configurations.find { |entry| BetterAuth::APIKey::Routes.default_config_id?(entry[:config_id]) }
          else
            configurations.find { |entry| entry[:config_id].to_s == config_id.to_s }
          end
        end

        def storage_identifier(config)
          return "database" if config[:storage].to_s == "database"
          return "custom:#{config[:config_id] || "default"}" if config[:custom_storage]

          config[:fallback_to_database] ? "secondary-storage-with-fallback" : "secondary-storage"
        end

        def database_paginated_records(ctx, config, reference_id, expected_reference, query, limit, offset)
          return nil unless query[:config_id] && config
          return nil unless config[:storage].to_s == "database"
          return nil if BetterAuth::APIKey::Routes.default_config_id?(query[:config_id])
          return nil unless config[:references].to_s == expected_reference
          return nil if expected_reference == "user" && legacy_user_id_records?(ctx, reference_id, query[:config_id])

          where = [
            {field: "referenceId", value: reference_id},
            {field: "configId", value: query[:config_id]}
          ]
          sort_by = query[:sort_by] ? {field: query[:sort_by].to_s, direction: (query[:sort_direction] || "asc").to_s} : nil
          {
            records: ctx.context.adapter.find_many(
              model: BetterAuth::Plugins::API_KEY_TABLE_NAME,
              where: where,
              sort_by: sort_by,
              limit: limit,
              offset: offset
            ),
            total: ctx.context.adapter.count(model: BetterAuth::Plugins::API_KEY_TABLE_NAME, where: where)
          }
        end

        def legacy_user_id_records?(ctx, reference_id, config_id)
          where = [
            {field: "userId", value: reference_id},
            {field: "configId", value: config_id}
          ]
          ctx.context.adapter.count(model: BetterAuth::Plugins::API_KEY_TABLE_NAME, where: where).positive?
        rescue KeyError, NoMethodError
          false
        rescue BetterAuth::Error => error
          raise unless error.message.include?("Field userId not found")

          false
        end
      end
    end
  end
end
