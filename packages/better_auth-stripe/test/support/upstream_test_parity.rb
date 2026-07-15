# frozen_string_literal: true

require_relative "../../../../test/support/upstream_test_inventory"

module BetterAuthStripeUpstreamParity
  ROOT = File.expand_path("../../../..", __dir__)
  TEST_ROOT = File.expand_path("..", __dir__)
  LEDGER = UpstreamPackageTestLedger.new(
    repository_root: ROOT,
    upstream_subpath: "packages/stripe",
    test_root: TEST_ROOT,
    entries: {
      "test/checkout.test.ts" => {
        owner: "better_auth/plugins/stripe_test.rb",
        status: :covered,
        evidence: {"better_auth/plugins/stripe_test.rb" => "test_checkout_session_params_merge_options_metadata_and_lookup_keys"},
        notes: "Checkout parameters, lookup keys, intervals, trials, and redirect validation"
      },
      "test/customer.test.ts" => {
        owner: "better_auth/plugins/stripe_test.rb",
        status: :covered,
        evidence: {"better_auth/plugins/stripe_test.rb" => "test_customer_create_params_and_callback_receive_upstream_shape"},
        notes: "Customer creation, lookup, metadata, and callback behavior"
      },
      "test/metadata.test.ts" => {
        owner: "better_auth/stripe/metadata_test.rb",
        status: :covered,
        evidence: {"better_auth/stripe/metadata_test.rb" => "test_subscription_metadata_preserves_internal_fields_and_custom_values"},
        notes: "Internal metadata protection and custom values"
      },
      "test/middleware.test.ts" => {
        owner: "better_auth/stripe/middleware_test.rb",
        status: :covered,
        evidence: {"better_auth/stripe/middleware_test.rb" => "test_explicit_other_user_reference_requires_authorize_reference"},
        notes: "Reference resolution and authorization"
      },
      "test/plugin.test.ts" => {
        owner: "better_auth/stripe/plugin_factory_test.rb",
        status: :covered,
        evidence: {"better_auth/stripe/plugin_factory_test.rb" => "test_build_returns_stripe_plugin_with_schema_endpoints_and_error_codes"},
        notes: "Plugin factory surface, endpoints, schema, errors, and version"
      },
      "test/seat-based-billing.test.ts" => {
        owner: "better_auth/plugins/stripe_organization_test.rb",
        status: :covered,
        evidence: {"better_auth/plugins/stripe_organization_test.rb" => "test_metered_seat_upgrade_keeps_quantity_only_for_seat_item"},
        notes: "Seat quantities, metered items, invitations, and organization membership changes"
      },
      "test/stripe-organization.test.ts" => {
        owner: "better_auth/plugins/stripe_organization_test.rb",
        status: :covered,
        evidence: {"better_auth/plugins/stripe_organization_test.rb" => "test_organization_subscription_flow_uses_active_org_and_authorize_reference"},
        notes: "Organization customer and subscription ownership"
      },
      "test/subscription.test.ts" => {
        owner: "better_auth/plugins/stripe_test.rb",
        status: :covered,
        evidence: {"better_auth/plugins/stripe_test.rb" => "test_subscription_success_cancel_callback_restore_and_webhook_errors"},
        notes: "Upgrade, list, cancel, restore, success, portal, and schedule behavior"
      },
      "test/utils.test.ts" => {
        owner: "better_auth/stripe/utils_test.rb",
        status: :covered,
        evidence: {"better_auth/stripe/utils_test.rb" => "test_resolve_plan_item_matches_multi_item_by_lookup_key"},
        notes: "Search escaping, status, plan-item, and value helpers"
      },
      "test/webhook.test.ts" => {
        owner: "better_auth/plugins/stripe_test.rb",
        status: :covered,
        evidence: {"better_auth/plugins/stripe_test.rb" => "test_webhook_event_matrix_and_callbacks"},
        notes: "Signature verification, lifecycle synchronization, callbacks, and defensive failures"
      }
    }
  )
end
