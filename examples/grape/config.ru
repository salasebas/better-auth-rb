# frozen_string_literal: true

require "bundler/setup"
require "grape"
require "better_auth"
require "better_auth/grape"
require_relative "../shared/lib/better_auth_examples"

REGISTRY = BetterAuthExamples.registry(
  app_name: "Better Auth Grape Example",
  base_url: ENV.fetch("BETTER_AUTH_URL", "http://localhost:9292"),
  root_path: __dir__
)
DYNAMIC_AUTH = BetterAuthExamples::DynamicAuth.new(REGISTRY)
DASHBOARD = BetterAuthExamples::DashboardApp.new(REGISTRY, framework_name: "Grape")

class API < Grape::API
  include BetterAuth::Grape

  format :json

  better_auth at: "/api/auth", auth: DYNAMIC_AUTH

  get "/" do
    {message: "Hello from Grape + Better Auth"}
  end

  get "/protected" do
    require_authentication
    {email: current_user.fetch("email")}
  end
end

run BetterAuthExamples::CompositeApp.new(dashboard: DASHBOARD, auth: API, base_path: "/api/auth")
