# frozen_string_literal: true

module BetterAuth
  module Stripe
    module OrganizationHooks
      module_function

      def hooks(config)
        return {} unless config.dig(:organization, :enabled)

        {
          after_update_organization: lambda do |data, _ctx|
            organization = data[:organization] || data["organization"]
            next unless organization && organization["stripeCustomerId"]

            customer = BetterAuth::Stripe::Utils.client(config).customers.retrieve(organization["stripeCustomerId"])
            next if BetterAuth::Stripe::Utils.fetch(customer, "deleted")
            next if BetterAuth::Stripe::Utils.fetch(customer, "name") == organization["name"]

            BetterAuth::Stripe::Utils.client(config).customers.update(organization["stripeCustomerId"], name: organization["name"])
          rescue
            nil
          end,
          before_delete_organization: lambda do |data, _ctx|
            organization = data[:organization] || data["organization"]
            next unless organization && organization["stripeCustomerId"]

            active = BetterAuth::Plugins.stripe_each_subscription(config, organization["stripeCustomerId"], status: "all") do |subscription|
              !%w[canceled incomplete incomplete_expired].include?(BetterAuth::Stripe::Utils.fetch(subscription, "status").to_s)
            end
            raise APIError.new("BAD_REQUEST", message: BetterAuth::Stripe::ERROR_CODES.fetch("ORGANIZATION_HAS_ACTIVE_SUBSCRIPTION")) if active
          end,
          after_add_member: ->(data, ctx) { sync_seats(config, data, ctx) },
          after_remove_member: ->(data, ctx) { sync_seats(config, data, ctx) },
          after_accept_invitation: ->(data, ctx) { sync_seats(config, data, ctx) }
        }
      end

      def sync_seats(config, data, ctx)
        organization = data[:organization] || data["organization"]
        return unless config.dig(:subscription, :enabled) && organization && organization["stripeCustomerId"]

        member_count = ctx.context.adapter.count(model: "member", where: [{field: "organizationId", value: organization.fetch("id")}])
        seat_plans = BetterAuth::Stripe::Utils.plans(config).select { |plan| plan[:seat_price_id] }
        return if seat_plans.empty?

        subscription = ctx.context.adapter.find_many(model: "subscription", where: [{field: "referenceId", value: organization.fetch("id")}]).find { |entry| BetterAuth::Stripe::Utils.active_or_trialing?(entry) }
        return unless subscription && subscription["stripeSubscriptionId"]

        plan = seat_plans.find { |entry| entry[:name].to_s.downcase == subscription["plan"].to_s.downcase }
        return unless plan

        stripe_subscription = BetterAuth::Stripe::Utils.client(config).subscriptions.retrieve(subscription["stripeSubscriptionId"])
        return unless BetterAuth::Stripe::Utils.active_or_trialing?(stripe_subscription)

        items = Array(BetterAuth::Stripe::Utils.fetch(BetterAuth::Stripe::Utils.fetch(stripe_subscription, "items") || {}, "data"))
        seat_item = items.find { |item| BetterAuth::Stripe::Utils.fetch(BetterAuth::Stripe::Utils.fetch(item, "price") || {}, "id") == plan[:seat_price_id] }
        return if seat_item && BetterAuth::Stripe::Utils.fetch(seat_item, "quantity").to_i == member_count.to_i

        update_items = if seat_item
          [{id: BetterAuth::Stripe::Utils.fetch(seat_item, "id"), quantity: member_count}]
        else
          [{price: plan[:seat_price_id], quantity: member_count}]
        end
        BetterAuth::Stripe::Utils.client(config).subscriptions.update(subscription["stripeSubscriptionId"], items: update_items, proration_behavior: plan[:proration_behavior] || "create_prorations")
        ctx.context.adapter.update(model: "subscription", where: [{field: "id", value: subscription.fetch("id")}], update: {seats: member_count})
      rescue
        nil
      end
    end
  end
end
