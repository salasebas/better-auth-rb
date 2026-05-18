# frozen_string_literal: true

require "bundler/setup"
require "sinatra/base"
require "better_auth"
require "better_auth/sinatra"
require_relative "../shared/lib/better_auth_examples"

class App < Sinatra::Base
  register BetterAuth::Sinatra

  set :environment, ENV.fetch("RACK_ENV", "development").to_sym
  set :port, ENV.fetch("PORT", 4567).to_i
  set :better_auth_examples_registry, BetterAuthExamples.registry(
    app_name: "Better Auth Sinatra Example",
    base_url: ENV.fetch("BETTER_AUTH_URL", "http://localhost:4567"),
    root_path: __dir__
  )
  set :better_auth_examples_dynamic_auth, BetterAuthExamples::DynamicAuth.new(settings.better_auth_examples_registry)
  set :better_auth_examples_dashboard, BetterAuthExamples::DashboardApp.new(
    settings.better_auth_examples_registry,
    framework_name: "Sinatra"
  )

  better_auth at: "/api/auth", auth: -> { settings.better_auth_examples_dynamic_auth }

  helpers do
    def render_dashboard
      status, headers, body = settings.better_auth_examples_dashboard.call(request.env)
      headers.each { |key, value| response[key] = value }
      status status
      body.each.to_a.join
    end
  end

  get "/" do
    render_dashboard
  end

  get "/example/*" do
    render_dashboard
  end

  post "/example/*" do
    render_dashboard
  end
end

App.run! if __FILE__ == $0
