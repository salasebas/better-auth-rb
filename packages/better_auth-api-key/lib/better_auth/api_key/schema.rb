# frozen_string_literal: true

module BetterAuth
  module APIKey
    module SchemaDefinition
      module_function

      def schema(config, custom_schema = nil)
        base = {
          apikey: {
            model_name: "api_keys",
            fields: {
              configId: {type: "string", required: true, default_value: "default", index: true},
              name: {type: "string", required: false},
              start: {type: "string", required: false},
              prefix: {type: "string", required: false},
              key: {type: "string", required: true, index: true},
              referenceId: {type: "string", required: true, index: true},
              refillInterval: {type: "number", required: false},
              refillAmount: {type: "number", required: false},
              lastRefillAt: {type: "date", required: false},
              enabled: {type: "boolean", required: false, default_value: true},
              rateLimitEnabled: {type: "boolean", required: false, default_value: true},
              rateLimitTimeWindow: {type: "number", required: false, default_value: config[:rate_limit][:time_window]},
              rateLimitMax: {type: "number", required: false, default_value: config[:rate_limit][:max_requests]},
              requestCount: {type: "number", required: false, default_value: 0},
              remaining: {type: "number", required: false},
              lastRequest: {type: "date", required: false},
              expiresAt: {type: "date", required: false},
              createdAt: {type: "date", required: true},
              updatedAt: {type: "date", required: true},
              permissions: {type: "string", required: false},
              metadata: {type: "string", required: false}
            }
          }
        }
        BetterAuth::Plugins.deep_merge_hashes(base, BetterAuth::Plugins.normalize_hash(custom_schema || {}))
      end
    end
  end
end
