# frozen_string_literal: true

require "bundler/setup"
require "better_auth"
require_relative "../shared/lib/better_auth_examples"

registry = BetterAuthExamples.registry(
  app_name: "Better Auth Vanilla Example",
  base_url: ENV.fetch("BETTER_AUTH_URL", "http://localhost:9292"),
  root_path: __dir__
)
dynamic_auth = BetterAuthExamples::DynamicAuth.new(registry)
dashboard = BetterAuthExamples::DashboardApp.new(registry, framework_name: "Vanilla Rack")

run BetterAuthExamples::CompositeApp.new(dashboard: dashboard, auth: dynamic_auth)
