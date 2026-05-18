# frozen_string_literal: true

require "bundler/setup"
require "grape"
require "better_auth"
require "better_auth/grape"

class API < Grape::API
  include BetterAuth::Grape

  format :json

  better_auth at: "/api/auth" do |config|
    config.secret = ENV.fetch("BETTER_AUTH_SECRET", "change-me-grape-secret-12345678901234567890")
    config.base_url = ENV.fetch("BETTER_AUTH_URL", "http://localhost:9292")
    config.database = :memory
    config.email_and_password = {enabled: true}
  end

  get "/" do
    {message: "Hello from Grape + Better Auth"}
  end

  get "/protected" do
    require_authentication
    {email: current_user.fetch("email")}
  end
end

run API
