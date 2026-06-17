# frozen_string_literal: true

module BetterAuth
  module Stripe
    module OpenAPI
      STRING = {type: "string"}.freeze
      BOOLEAN = {type: "boolean"}.freeze
      OBJECT = {type: "object", additionalProperties: true}.freeze

      module_function

      def customer_reference_fields
        {
          customerType: STRING,
          referenceId: STRING
        }
      end

      def redirect_fields
        {
          returnUrl: STRING,
          disableRedirect: BOOLEAN
        }
      end

      def upgrade_subscription_metadata
        {
          operationId: "upgradeSubscription",
          requestBody: BetterAuth::OpenAPI.json_request_body(
            BetterAuth::OpenAPI.object_schema(
              {
                plan: STRING,
                annual: BOOLEAN,
                seats: {type: "integer"},
                successUrl: STRING,
                cancelUrl: STRING,
                returnUrl: STRING,
                subscriptionId: STRING,
                scheduleAtPeriodEnd: BOOLEAN,
                metadata: OBJECT,
                locale: STRING,
                disableRedirect: BOOLEAN
              }.merge(customer_reference_fields),
              required: ["plan"]
            )
          ),
          responses: {
            "200" => BetterAuth::OpenAPI.json_response("Subscription upgrade initiated", url_redirect_response_schema)
          }
        }
      end

      def billing_portal_metadata
        {
          operationId: "createBillingPortal",
          requestBody: BetterAuth::OpenAPI.json_request_body(
            BetterAuth::OpenAPI.object_schema(
              redirect_fields.merge(customer_reference_fields).merge(locale: STRING)
            )
          ),
          responses: {
            "200" => BetterAuth::OpenAPI.json_response("Billing portal session created", url_redirect_response_schema)
          }
        }
      end

      def cancel_subscription_metadata
        {
          operationId: "cancelSubscription",
          requestBody: BetterAuth::OpenAPI.json_request_body(
            BetterAuth::OpenAPI.object_schema(
              redirect_fields.merge(customer_reference_fields).merge(subscriptionId: STRING)
            )
          ),
          responses: {
            "200" => BetterAuth::OpenAPI.json_response("Subscription cancellation initiated", url_redirect_response_schema)
          }
        }
      end

      def restore_subscription_metadata
        {
          operationId: "restoreSubscription",
          requestBody: BetterAuth::OpenAPI.json_request_body(
            BetterAuth::OpenAPI.object_schema(
              customer_reference_fields.merge(subscriptionId: STRING)
            )
          ),
          responses: {
            "200" => BetterAuth::OpenAPI.json_response("Subscription restored", OBJECT)
          }
        }
      end

      def subscription_success_metadata
        {
          operationId: "subscriptionSuccess",
          parameters: [
            BetterAuth::OpenAPI.query_parameter("callbackURL", description: "URL to redirect after checkout success"),
            BetterAuth::OpenAPI.query_parameter("checkoutSessionId", description: "Stripe checkout session ID")
          ],
          responses: {
            "302" => {description: "Redirect to callback URL"}
          }
        }
      end

      def cancel_subscription_callback_metadata
        {
          operationId: "cancelSubscriptionCallback",
          parameters: [
            BetterAuth::OpenAPI.query_parameter("callbackURL", description: "URL to redirect after cancellation"),
            BetterAuth::OpenAPI.query_parameter("subscriptionId", description: "Internal subscription ID")
          ],
          responses: {
            "302" => {description: "Redirect to callback URL"}
          }
        }
      end

      def list_active_subscriptions_metadata
        {
          operationId: "listActiveSubscriptions",
          parameters: [
            BetterAuth::OpenAPI.query_parameter("customerType", description: "Customer type (`user` or `organization`)"),
            BetterAuth::OpenAPI.query_parameter("referenceId", description: "User or organization reference ID")
          ],
          responses: {
            "200" => BetterAuth::OpenAPI.json_response("Active subscriptions", BetterAuth::OpenAPI.array_schema(OBJECT))
          }
        }
      end

      def url_redirect_response_schema
        BetterAuth::OpenAPI.object_schema(
          {
            url: STRING,
            redirect: BOOLEAN
          }
        )
      end
    end
  end
end
