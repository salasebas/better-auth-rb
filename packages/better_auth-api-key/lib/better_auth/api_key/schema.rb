# frozen_string_literal: true

require "json"

module BetterAuth
  module APIKey
    module SchemaDefinition
      module_function

      def schema(config, custom_schema = nil)
        configurations = config.fetch(:configurations, [config])
        rate_limit = (configurations.length == 1) ? configurations.first[:rate_limit] : nil
        rate_limit ||= {}
        base = {
          apikey: {
            model_name: "api_keys",
            fields: {
              configId: {type: "string", required: true, default_value: "default", input: false, index: true},
              name: {type: "string", required: false, input: false},
              start: {type: "string", required: false, input: false},
              referenceId: {type: "string", required: true, input: false, index: true},
              prefix: {type: "string", required: false, input: false},
              key: {type: "string", required: true, input: false, index: true},
              refillInterval: {type: "number", required: false, input: false},
              refillAmount: {type: "number", required: false, input: false},
              lastRefillAt: {type: "date", required: false, input: false},
              enabled: {type: "boolean", required: false, input: false, default_value: true},
              rateLimitEnabled: {type: "boolean", required: false, input: false, default_value: true},
              rateLimitTimeWindow: {type: "number", required: false, input: false, default_value: nullish_default(rate_limit[:time_window], 86_400_000)},
              rateLimitMax: {type: "number", required: false, input: false, default_value: nullish_default(rate_limit[:max_requests], 10)},
              requestCount: {type: "number", required: false, input: false, default_value: 0},
              remaining: {type: "number", required: false, input: false},
              lastRequest: {type: "date", required: false, input: false},
              expiresAt: {type: "date", required: false, input: false},
              createdAt: {type: "date", required: true, input: false},
              updatedAt: {type: "date", required: true, input: false},
              permissions: {type: "string", required: false, input: false},
              metadata: {
                type: "string",
                required: false,
                input: true,
                transform: {
                  input: ->(value) { JSON.generate(value) },
                  output: ->(value) { metadata_output(value) }
                }
              }
            }
          }
        }
        merge_schema(base, custom_schema)
      end

      def merge_schema(base, custom_schema)
        BetterAuth::Plugins.normalize_hash(custom_schema || {}).each do |table_name, override|
          table = base.fetch(table_name)
          model_name = override[:model_name]
          table[:model_name] = model_name if js_truthy?(model_name)

          fields = override[:fields]
          next unless fields.is_a?(Hash)

          table[:fields].each do |logical_name, attributes|
            field_name = fields[BetterAuth::Plugins.normalize_key(logical_name)]
            attributes[:field_name] = field_name if js_truthy?(field_name)
          end
        end
        base
      end

      def metadata_output(value)
        return nil unless js_truthy?(value)
        return value unless value.is_a?(String)

        JSON.parse(value)
      end

      def nullish_default(value, default)
        value.nil? ? default : value
      end

      def js_truthy?(value)
        !(value.nil? || value == false || value == 0 || value == "" || (value.respond_to?(:nan?) && value.nan?))
      end
    end
  end
end
