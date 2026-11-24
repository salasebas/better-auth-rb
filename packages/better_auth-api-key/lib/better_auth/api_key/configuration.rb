# frozen_string_literal: true

module BetterAuth
  module APIKey
    module Configuration
      module_function

      def normalize(configurations, options = nil)
        if configurations.is_a?(Array)
          normalized_configs = configurations.map { |config| single(config) }
          if normalized_configs.any? { |config| config[:config_id].to_s.empty? }
            raise BetterAuth::Error, "configId is required for each API key configuration in the api-key plugin."
          end
          config_ids = normalized_configs.map { |config| config[:config_id] }
          raise BetterAuth::Error, "configId must be unique for each API key configuration in the api-key plugin." if config_ids.uniq.length != config_ids.length

          plugin_options = BetterAuth::Plugins.normalize_hash(options || {})
          default_config = normalized_configs.find { |config| BetterAuth::APIKey::Routes.default_config_id?(config[:config_id]) }
          default_config ||= normalized_configs.first
          default_config.merge(
            configurations: normalized_configs,
            schema: plugin_options[:schema] || default_config[:schema]
          )
        else
          config = single(configurations)
          config[:config_id] ||= "default"
          config.merge(configurations: [config])
        end
      end

      def single(options)
        data = BetterAuth::Plugins.normalize_hash(options || {})
        rate_limit_options = data[:rate_limit] || {}
        starting_characters_options = data[:starting_characters_config] || {}
        {
          config_id: data[:config_id],
          api_key_headers: data[:api_key_headers] || "x-api-key",
          default_key_length: data[:default_key_length] || 64,
          default_prefix: data[:default_prefix],
          maximum_prefix_length: data.key?(:maximum_prefix_length) ? data[:maximum_prefix_length] : 32,
          minimum_prefix_length: data.key?(:minimum_prefix_length) ? data[:minimum_prefix_length] : 1,
          maximum_name_length: data.key?(:maximum_name_length) ? data[:maximum_name_length] : 32,
          minimum_name_length: data.key?(:minimum_name_length) ? data[:minimum_name_length] : 1,
          enable_metadata: data[:enable_metadata] || false,
          disable_key_hashing: data[:disable_key_hashing] || false,
          require_name: data[:require_name] || false,
          storage: data[:storage] || "database",
          rate_limit: {
            enabled: rate_limit_options.fetch(:enabled, true),
            time_window: rate_limit_options[:time_window] || 86_400_000,
            max_requests: rate_limit_options[:max_requests] || 10
          },
          key_expiration: {
            default_expires_in: data.dig(:key_expiration, :default_expires_in),
            disable_custom_expires_time: data.dig(:key_expiration, :disable_custom_expires_time) || false,
            max_expires_in: data.dig(:key_expiration, :max_expires_in) || 365,
            min_expires_in: data.dig(:key_expiration, :min_expires_in) || 1
          },
          starting_characters_config: {
            should_store: starting_characters_options.fetch(:should_store, true),
            characters_length: starting_characters_options[:characters_length] || 6
          },
          enable_session_for_api_keys: data[:enable_session_for_api_keys] || false,
          fallback_to_database: data[:fallback_to_database] || false,
          custom_storage: data[:custom_storage],
          custom_key_generator: data[:custom_key_generator],
          custom_api_key_getter: data[:custom_api_key_getter],
          custom_api_key_validator: data[:custom_api_key_validator],
          default_permissions: data[:default_permissions],
          permissions: data[:permissions] || {},
          references: data[:references] || "user",
          defer_updates: data[:defer_updates] || false,
          schema: data[:schema]
        }
      end
    end
  end
end
