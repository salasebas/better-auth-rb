# frozen_string_literal: true

require "bundler/setup"
require "roda"
require "better_auth"
require "better_auth/roda"
require_relative "../shared/lib/better_auth_examples"

REGISTRY = BetterAuthExamples.registry(
  app_name: "Better Auth Roda Example",
  base_url: ENV.fetch("BETTER_AUTH_URL", "http://localhost:9293"),
  root_path: __dir__
)
DYNAMIC_AUTH = BetterAuthExamples::DynamicAuth.new(REGISTRY)
DASHBOARD = BetterAuthExamples::DashboardApp.new(REGISTRY, framework_name: "Roda")

class App < Roda
  plugin :better_auth

  opts[:better_auth_examples_dashboard] = DASHBOARD

  better_auth at: "/api/auth", auth: DYNAMIC_AUTH

  route do |r|
    r.better_auth

    r.root do
      r.halt opts[:better_auth_examples_dashboard].call(r.env)
    end

    r.on "example" do
      r.halt opts[:better_auth_examples_dashboard].call(r.env)
    end

    r.get "health" do
      "OK"
    end
  end
end

run App.freeze.app
