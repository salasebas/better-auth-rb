# frozen_string_literal: true

module BetterAuth
  module Stripe
    module PluginFactory
      module_function

      def build(options = {})
        config = BetterAuth::Plugins.normalize_hash(options)
        BetterAuth::Plugin.new(
          id: "stripe",
          version: BetterAuth::Stripe::VERSION,
          init: ->(ctx) { {context: {schema: BetterAuth::Schema.auth_tables(ctx.options)}} },
          schema: BetterAuth::Stripe::Schema.schema(config),
          endpoints: BetterAuth::Stripe::Routes.endpoints(config),
          error_codes: BetterAuth::Stripe::ERROR_CODES,
          options: config.merge(database_hooks: database_hooks(config), organization_hooks: BetterAuth::Stripe::OrganizationHooks.hooks(config))
        )
      end

      def database_hooks(config)
        {
          user: {
            create: {
              after: lambda do |user, hook_ctx|
                next unless hook_ctx && config[:create_customer_on_sign_up] && user["email"] && !user["stripeCustomerId"]

                BetterAuth::Plugins.stripe_create_customer(config, hook_ctx, user)
              rescue
                nil
              end
            },
            update: {
              after: lambda do |user, _ctx|
                next unless user && user["stripeCustomerId"]

                customer = BetterAuth::Stripe::Utils.client(config).customers.retrieve(user["stripeCustomerId"])
                next if BetterAuth::Stripe::Utils.fetch(customer, "deleted")
                next if BetterAuth::Stripe::Utils.fetch(customer, "email") == user["email"]

                BetterAuth::Stripe::Utils.client(config).customers.update(user["stripeCustomerId"], email: user["email"])
              rescue
                nil
              end
            }
          }
        }
      end
    end
  end
end
