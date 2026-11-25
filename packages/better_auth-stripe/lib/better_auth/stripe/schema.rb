# frozen_string_literal: true

module BetterAuth
  module Stripe
    module Schema
      module_function

      def schema(config)
        custom_schema = custom_schema(config)
        config = BetterAuth::Plugins.normalize_hash((config || {}).reject { |key, _| key.to_s == "schema" })
        base_schema = {
          user: {
            fields: {
              stripeCustomerId: {type: "string", required: false}
            }
          }
        }

        if config.dig(:subscription, :enabled)
          base_schema[:subscription] = {
            fields: {
              plan: {type: "string", required: true},
              referenceId: {type: "string", required: true},
              stripeCustomerId: {type: "string", required: false},
              stripeSubscriptionId: {type: "string", required: false},
              status: {type: "string", required: false, default_value: "incomplete"},
              periodStart: {type: "date", required: false},
              periodEnd: {type: "date", required: false},
              trialStart: {type: "date", required: false},
              trialEnd: {type: "date", required: false},
              cancelAtPeriodEnd: {type: "boolean", required: false, default_value: false},
              cancelAt: {type: "date", required: false},
              canceledAt: {type: "date", required: false},
              endedAt: {type: "date", required: false},
              seats: {type: "number", required: false},
              billingInterval: {type: "string", required: false},
              stripeScheduleId: {type: "string", required: false},
              limits: {type: "json", required: false}
            }
          }
        end

        if config.dig(:organization, :enabled)
          base_schema[:organization] = {fields: {stripeCustomerId: {type: "string", required: false}}}
        end

        custom_schema = custom_schema.except(:subscription) unless config.dig(:subscription, :enabled)
        BetterAuth::Plugins.merge_schema(base_schema, custom_schema)
      end

      def custom_schema(config)
        raw = config && (config[:schema] || config["schema"])
        return {} unless raw.is_a?(Hash)

        raw.transform_keys { |model| BetterAuth::Plugins.normalize_key(model) }
      end
    end
  end
end
