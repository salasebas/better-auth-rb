# frozen_string_literal: true

require_relative "../../test_helper"

class BetterAuthStripeSchemaTest < Minitest::Test
  def test_base_schema_includes_user_stripe_customer_id
    schema = BetterAuth::Stripe::Schema.schema({})

    assert_equal({type: "string", required: false}, schema.fetch(:user).fetch(:fields).fetch(:stripeCustomerId))
    refute schema.key?(:subscription)
  end

  def test_subscription_schema_includes_upstream_fields
    schema = BetterAuth::Stripe::Schema.schema(subscription: {enabled: true, plans: []})
    fields = schema.fetch(:subscription).fetch(:fields)

    assert_equal({type: "string", required: false}, fields.fetch(:billingInterval))
    assert_equal({type: "string", required: false}, fields.fetch(:stripeScheduleId))
  end

  def test_organization_schema_is_conditional
    schema = BetterAuth::Stripe::Schema.schema(organization: {enabled: true})

    assert_equal({type: "string", required: false}, schema.fetch(:organization).fetch(:fields).fetch(:stripeCustomerId))
  end

  def test_conditional_fields_reach_migration_projection
    config = BetterAuth::Configuration.new(
      secret: "stripe-schema-secret-with-enough-entropy",
      database: :memory,
      plugins: [BetterAuth::Plugins.stripe(subscription: {enabled: true, plans: []}, organization: {enabled: true})]
    )
    tables = BetterAuth::Schema.migration_tables(config)

    assert_includes tables.fetch("subscriptions").fetch(:fields), "stripe_subscription_id"
    assert_includes tables.fetch("organizations").fetch(:fields), "stripe_customer_id"
    assert_includes tables.fetch("users").fetch(:fields), "stripe_customer_id"
  end

  def test_custom_subscription_schema_is_ignored_when_subscriptions_are_disabled
    schema = BetterAuth::Stripe::Schema.schema(
      schema: {
        user: {fields: {role: {type: "string", required: false}}},
        subscription: {fields: {custom: {type: "string", required: false}}}
      }
    )

    assert_equal({type: "string", required: false}, schema.fetch(:user).fetch(:fields).fetch(:role))
    refute schema.key?(:subscription)
  end

  def test_custom_user_schema_merges_with_stripe_customer_field
    schema = BetterAuth::Stripe::Schema.schema(
      schema: {
        user: {
          fields: {
            role: {type: "string", required: false}
          }
        }
      }
    )

    fields = schema.fetch(:user).fetch(:fields)
    assert_equal({type: "string", required: false}, fields.fetch(:stripeCustomerId))
    assert_equal({type: "string", required: false}, fields.fetch(:role))
  end

  def test_custom_organization_schema_merges_when_organization_enabled
    schema = BetterAuth::Stripe::Schema.schema(
      organization: {enabled: true},
      schema: {
        organization: {
          fields: {
            billingEmail: {type: "string", required: false}
          }
        }
      }
    )

    fields = schema.fetch(:organization).fetch(:fields)
    assert_equal({type: "string", required: false}, fields.fetch(:stripeCustomerId))
    assert_equal({type: "string", required: false}, fields.fetch(:billingEmail))
  end

  def test_custom_subscription_schema_merges_when_subscription_enabled
    schema = BetterAuth::Stripe::Schema.schema(
      subscription: {enabled: true, plans: []},
      schema: {
        subscription: {
          fields: {
            entitlement: {type: "string", required: false}
          }
        }
      }
    )

    fields = schema.fetch(:subscription).fetch(:fields)
    assert_equal({type: "string", required: true}, fields.fetch(:plan))
    assert_equal({type: "string", required: false}, fields.fetch(:entitlement))
  end
end
