# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../support/stripe_helpers"

class BetterAuthStripeRoutesStripeWebhookTest < Minitest::Test
  include BetterAuthStripeTestHelpers

  def test_endpoint_matches_upstream_path_and_method
    endpoint = BetterAuth::Stripe::Routes::StripeWebhook.endpoint({})

    assert_equal "/stripe/webhook", endpoint.path
    assert_equal ["POST"], endpoint.methods
    assert_equal true, endpoint.metadata.fetch(:hide)
  end

  def test_built_in_handler_failure_is_acknowledged_and_on_event_still_runs
    stripe = BetterAuthStripeTestHelpers::FakeStripeClient.new
    stripe.subscriptions.retrieve_error = RuntimeError.new("Stripe API error")
    stripe.webhooks.async_event = {
      type: "checkout.session.completed",
      data: {object: {mode: "subscription", subscription: "sub_failed"}}
    }
    steps = []
    original_retrieve = stripe.subscriptions.method(:retrieve)
    stripe.subscriptions.define_singleton_method(:retrieve) do |id|
      steps << :built_in
      original_retrieve.call(id)
    end
    events = []
    auth = build_auth(
      stripe_client: stripe,
      stripe_webhook_secret: "whsec_test",
      on_event: lambda do |event|
        steps << :on_event
        events << event.fetch(:type)
      end
    )

    status, _headers, body = auth.call(
      rack_env(
        "POST",
        "/api/auth/stripe/webhook",
        raw_body: JSON.generate(stripe.webhooks.async_event),
        headers: {"HTTP_STRIPE_SIGNATURE" => "valid"}
      )
    )

    assert_equal 200, status
    assert_equal({"success" => true}, JSON.parse(body.join))
    assert_equal [:built_in, :on_event], steps
    assert_equal ["checkout.session.completed"], events
  end
end
