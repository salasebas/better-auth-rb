# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require_relative "../api_key/error_codes"
require_relative "../api_key/types"
require_relative "../api_key/utils"
require_relative "../api_key/rate_limit"
require_relative "../api_key/keys"
require_relative "../api_key/adapter"
require_relative "../api_key/schema"
require_relative "../api_key/org_authorization"
require_relative "../api_key/validation"
require_relative "../api_key/configuration"
require_relative "../api_key/session"
require_relative "../api_key/plugin_factory"
require_relative "../api_key/routes/index"
require_relative "../api_key/routes/create_api_key"
require_relative "../api_key/routes/verify_api_key"
require_relative "../api_key/routes/get_api_key"
require_relative "../api_key/routes/update_api_key"
require_relative "../api_key/routes/delete_api_key"
require_relative "../api_key/routes/list_api_keys"
require_relative "../api_key/routes/delete_all_expired_api_keys"

module BetterAuth
  module Plugins
    singleton_class.remove_method(:api_key) if singleton_class.method_defined?(:api_key)
    remove_method(:api_key) if method_defined?(:api_key) || private_method_defined?(:api_key)

    API_KEY_ERROR_CODES = BetterAuth::APIKey::ERROR_CODES

    API_KEY_TABLE_NAME = BetterAuth::APIKey::Types::API_KEY_TABLE_NAME

    module_function

    def default_api_key_hasher(key)
      BetterAuth::APIKey::Keys.default_hasher(key)
    end

    def api_key(configurations = {}, options = nil)
      BetterAuth::APIKey::PluginFactory.build(configurations, options)
    end

    API_KEY_PLUGIN_IMPLEMENTATION = true

    def api_key_config(configurations, options = nil)
      BetterAuth::APIKey::Configuration.normalize(configurations, options)
    end

    def api_key_single_config(options)
      BetterAuth::APIKey::Configuration.single(options)
    end

    def api_key_schema(config, custom_schema = nil)
      BetterAuth::APIKey::SchemaDefinition.schema(config, custom_schema)
    end

    def api_key_create_endpoint(config)
      BetterAuth::APIKey::Routes::CreateAPIKey.endpoint(config)
    end

    def api_key_verify_endpoint(config)
      BetterAuth::APIKey::Routes::VerifyAPIKey.endpoint(config)
    end

    def api_key_get_endpoint(config)
      BetterAuth::APIKey::Routes::GetAPIKey.endpoint(config)
    end

    def api_key_update_endpoint(config)
      BetterAuth::APIKey::Routes::UpdateAPIKey.endpoint(config)
    end

    def api_key_delete_endpoint(config)
      BetterAuth::APIKey::Routes::DeleteAPIKey.endpoint(config)
    end

    def api_key_list_endpoint(config)
      BetterAuth::APIKey::Routes::ListAPIKeys.endpoint(config)
    end

    def api_key_delete_expired_endpoint(config)
      BetterAuth::APIKey::Routes::DeleteAllExpiredAPIKeys.endpoint(config)
    end

    def api_key_resolve_config(context, config, config_id = nil)
      BetterAuth::APIKey::Routes.resolve_config(context, config, config_id)
    end

    def api_key_default_config_id?(value)
      BetterAuth::APIKey::Routes.default_config_id?(value)
    end

    def api_key_config_id_matches?(record_config_id, expected_config_id)
      BetterAuth::APIKey::Routes.config_id_matches?(record_config_id, expected_config_id)
    end

    def api_key_create_reference_id!(ctx, body, session, config)
      BetterAuth::APIKey::OrgAuthorization.create_reference_id!(ctx, body, session, config)
    end

    def api_key_record_reference_id(record)
      BetterAuth::APIKey::Types.record_reference_id(record)
    end

    def api_key_record_user_id(record)
      BetterAuth::APIKey::Types.record_user_id(record)
    end

    def api_key_record_config_id(record)
      BetterAuth::APIKey::Types.record_config_id(record)
    end

    def api_key_default_permissions(config, reference_id, ctx)
      BetterAuth::APIKey::Types.default_permissions(config, reference_id, ctx)
    end

    def api_key_authorize_reference!(ctx, config, user_id, reference_id, action)
      BetterAuth::APIKey::OrgAuthorization.authorize_reference!(ctx, config, user_id, reference_id, action)
    end

    def api_key_check_org_permission!(ctx, user_id, organization_id, action)
      BetterAuth::APIKey::OrgAuthorization.check_permission!(ctx, user_id, organization_id, action)
    end

    def api_key_sort_records(records, sort_by, direction)
      BetterAuth::APIKey::Utils.sort_records(records, sort_by, direction)
    end

    def api_key_validate_list_query!(query)
      BetterAuth::APIKey::Utils.validate_list_query!(query)
    end

    def api_key_error_code(error)
      BetterAuth::APIKey::Utils.error_code(error)
    end

    def api_key_error_payload(error)
      BetterAuth::APIKey::Utils.error_payload(error)
    end

    def api_key_session_header_config(ctx, config)
      BetterAuth::APIKey::Session.header_config(ctx, config)
    end

    def api_key_session_hook(ctx, config)
      BetterAuth::APIKey::Session.hook(ctx, config)
    end

    def api_key_validate!(ctx, key, config, permissions: nil)
      BetterAuth::APIKey::Validation.validate_api_key!(ctx, key, config, permissions: permissions)
    end

    def api_key_usage_update(record, config)
      BetterAuth::APIKey::Validation.usage_update(record, config)
    end

    def api_key_rate_limit_try_again_in(record, config, now)
      BetterAuth::APIKey::RateLimit.try_again_in(record, config, now)
    end

    def api_key_rate_limit_counts_requests?(record, config)
      BetterAuth::APIKey::RateLimit.counts_requests?(record, config)
    end

    def api_key_next_request_count(record, now)
      BetterAuth::APIKey::RateLimit.next_request_count(record, now)
    end

    def api_key_validate_create_update!(body, config, create:, client:)
      BetterAuth::APIKey::Validation.validate_create_update!(body, config, create: create, client: client)
    end

    def api_key_update_payload(body, config)
      BetterAuth::APIKey::Validation.update_payload(body, config)
    end

    def api_key_generate_key(config, prefix)
      BetterAuth::APIKey::Keys.generate(config, prefix)
    end

    def api_key_hash(key, config)
      BetterAuth::APIKey::Keys.hash(key, config)
    end

    def api_key_normalize_body(raw)
      BetterAuth::APIKey::Keys.normalize_body(raw)
    end

    def api_key_expires_at(body, config)
      BetterAuth::APIKey::Keys.expires_at(body, config)
    end

    def api_key_store(ctx, data, config)
      BetterAuth::APIKey::Adapter.store(ctx, data, config)
    end

    def api_key_find_by_hash(ctx, hashed, config)
      BetterAuth::APIKey::Adapter.find_by_hash(ctx, hashed, config)
    end

    def api_key_find_by_id(ctx, id, config)
      BetterAuth::APIKey::Adapter.find_by_id(ctx, id, config)
    end

    def api_key_list_for_user(ctx, user_id, config)
      api_key_list_for_reference(ctx, user_id, config)
    end

    def api_key_list_for_reference(ctx, reference_id, config)
      BetterAuth::APIKey::Adapter.list_for_reference(ctx, reference_id, config)
    end

    def api_key_update_record(ctx, record, update, config, defer: false)
      BetterAuth::APIKey::Adapter.update_record(ctx, record, update, config, defer: defer)
    end

    def api_key_delete_record(ctx, record, config)
      BetterAuth::APIKey::Adapter.delete_record(ctx, record, config)
    end

    def api_key_schedule_record_delete(ctx, record, config)
      BetterAuth::APIKey::Adapter.schedule_record_delete(ctx, record, config)
    end

    def api_key_schedule_cleanup(ctx, config)
      BetterAuth::APIKey::Routes.schedule_cleanup(ctx, config)
    end

    def api_key_delete_expired(context, config, bypass_last_check: false)
      BetterAuth::APIKey::Routes.delete_expired(context, config, bypass_last_check: bypass_last_check)
    end

    def api_key_storage(config, context = nil)
      BetterAuth::APIKey::Adapter.storage(config, context)
    end

    def api_key_storage_get(ctx, key, config)
      BetterAuth::APIKey::Adapter.get(ctx, key, config)
    end

    def api_key_storage_set(ctx, record, config)
      BetterAuth::APIKey::Adapter.set(ctx, record, config)
    end

    def api_key_storage_delete(ctx, record, config)
      BetterAuth::APIKey::Adapter.delete(ctx, record, config)
    end

    def api_key_ref_list_add(storage, user_key, id)
      BetterAuth::APIKey::Adapter.ref_list_add(storage, user_key, id)
    end

    def api_key_ref_list_remove(storage, user_key, id)
      BetterAuth::APIKey::Adapter.ref_list_remove(storage, user_key, id)
    end

    def api_key_safe_parse_id_list(raw)
      BetterAuth::APIKey::Adapter.safe_parse_id_list(raw)
    end

    def api_key_storage_batch(storage, &block)
      BetterAuth::APIKey::Adapter.batch(storage, &block)
    end

    def api_key_storage_populate_reference(ctx, reference_id, records, config)
      BetterAuth::APIKey::Adapter.populate_reference(ctx, reference_id, records, config)
    end

    def api_key_storage_record(record)
      BetterAuth::APIKey::Adapter.storage_record(record)
    end

    def api_key_deserialize_storage_record(record)
      BetterAuth::APIKey::Adapter.deserialize_record(record)
    end

    def api_key_public(record, reveal_key: nil, include_key_field: false)
      BetterAuth::APIKey::Utils.public_record(record, reveal_key: reveal_key, include_key_field: include_key_field)
    end

    def api_key_migrate_legacy_metadata(ctx, record, config)
      BetterAuth::APIKey::Adapter.migrate_legacy_metadata(ctx, record, config)
    end

    def api_key_background_tasks?(ctx)
      BetterAuth::APIKey::Utils.background_tasks?(ctx)
    end

    def api_key_auth_required?(ctx)
      BetterAuth::APIKey::Utils.auth_required?(ctx)
    end

    def api_key_get_from_headers(ctx, config)
      BetterAuth::APIKey::Keys.from_headers(ctx, config)
    end

    def api_key_check_permissions!(record, required)
      BetterAuth::APIKey::Validation.check_permissions!(record, required)
    end

    def api_key_encode_json(value)
      BetterAuth::APIKey::Utils.encode_json(value)
    end

    def api_key_decode_json(value)
      BetterAuth::APIKey::Utils.decode_json(value)
    end

    def api_key_normalize_time(value)
      BetterAuth::APIKey::Utils.normalize_time(value)
    end
  end
end
