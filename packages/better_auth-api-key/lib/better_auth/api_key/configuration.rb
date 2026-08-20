# frozen_string_literal: true

module BetterAuth
  module APIKey
    module Configuration
      module_function

      def normalize(configurations, options = nil)
        if configurations.is_a?(Array)
          normalized_configs = configurations.map { |config| single(config) }
          if normalized_configs.any? { |config| js_falsy?(config[:config_id]) }
            raise BetterAuth::Error, "configId is required for each API key configuration in the api-key plugin."
          end
          config_ids = normalized_configs.map { |config| config[:config_id] }
          raise BetterAuth::Error, "configId must be unique for each API key configuration in the api-key plugin." if config_ids.uniq.length != config_ids.length

          plugin_options = BetterAuth::Plugins.normalize_hash(options || {})
          default_config = normalized_configs.find { |config| BetterAuth::APIKey::Routes.default_config_id?(config[:config_id]) }
          selected_config = default_config || normalized_configs.first || single({})
          selected_config.merge(
            configurations: normalized_configs,
            schema: plugin_options[:schema]
          )
        else
          config = single(configurations)
          config[:config_id] ||= "default"
          plugin_options = BetterAuth::Plugins.normalize_hash(options || {})
          schema = options.nil? ? config[:schema] : plugin_options[:schema]
          config.merge(configurations: [config], schema: schema)
        end
      end

      def single(options)
        data = BetterAuth::Plugins.normalize_hash(options || {})
        rate_limit_options = data[:rate_limit] || {}
        key_expiration_options = data[:key_expiration] || {}
        starting_characters_options = data[:starting_characters_config] || {}
        {
          config_id: data[:config_id],
          api_key_headers: nullish_default(data[:api_key_headers], "x-api-key"),
          default_key_length: js_falsy?(data[:default_key_length]) ? 64 : data[:default_key_length],
          default_prefix: data[:default_prefix],
          maximum_prefix_length: nullish_default(data[:maximum_prefix_length], 32),
          minimum_prefix_length: nullish_default(data[:minimum_prefix_length], 1),
          maximum_name_length: nullish_default(data[:maximum_name_length], 32),
          minimum_name_length: nullish_default(data[:minimum_name_length], 1),
          enable_metadata: nullish_default(data[:enable_metadata], false),
          disable_key_hashing: nullish_default(data[:disable_key_hashing], false),
          require_name: nullish_default(data[:require_name], false),
          storage: nullish_default(data[:storage], "database"),
          rate_limit: {
            enabled: rate_limit_options.fetch(:enabled, true),
            time_window: nullish_default(rate_limit_options[:time_window], 86_400_000),
            max_requests: nullish_default(rate_limit_options[:max_requests], 10)
          },
          key_expiration: {
            default_expires_in: key_expiration_options[:default_expires_in],
            disable_custom_expires_time: nullish_default(key_expiration_options[:disable_custom_expires_time], false),
            max_expires_in: nullish_default(key_expiration_options[:max_expires_in], 365),
            min_expires_in: nullish_default(key_expiration_options[:min_expires_in], 1)
          },
          starting_characters_config: {
            should_store: nullish_default(starting_characters_options[:should_store], true),
            characters_length: nullish_default(starting_characters_options[:characters_length], 6)
          },
          enable_session_for_api_keys: nullish_default(data[:enable_session_for_api_keys], false),
          fallback_to_database: nullish_default(data[:fallback_to_database], false),
          custom_storage: data[:custom_storage],
          custom_key_generator: data[:custom_key_generator],
          custom_api_key_getter: data[:custom_api_key_getter],
          custom_api_key_validator: data[:custom_api_key_validator],
          default_permissions: data[:default_permissions],
          permissions: data[:permissions] || {},
          references: data[:references] || "user",
          defer_updates: nullish_default(data[:defer_updates], false),
          schema: data[:schema]
        }
      end

      def nullish_default(value, default)
        value.nil? ? default : value
      end

      def js_falsy?(value)
        value.nil? || value == false || value == 0 || value == "" || (value.respond_to?(:nan?) && value.nan?)
      end
    end
  end
end
