# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe BetterAuth::Hanami do
  after do
    described_class.instance_variable_set(:@auth, nil)
    described_class.instance_variable_set(:@configuration, nil)
  end

  it "builds a core auth instance from Hanami configuration" do
    described_class.configure do |config|
      config.secret = secret
      config.database = :memory
      config.base_url = "http://localhost:2300"
      config.trusted_origins = ["http://localhost:2300"]
      config.email_and_password = {enabled: true}
      config.password_hasher = :bcrypt
    end

    auth = described_class.auth

    expect(auth).to be_a(BetterAuth::Auth)
    expect(auth.context.options.base_path).to eq("/api/auth")
    expect(auth.context.options.base_url).to eq("http://localhost:2300")
    expect(auth.context.options.trusted_origins).to eq(["http://localhost:2300"])
    expect(auth.context.options.password_hasher).to eq(:bcrypt)
  end

  it "returns a fresh auth instance when overrides are provided" do
    described_class.configure do |config|
      config.secret = secret
      config.database = :memory
      config.base_path = "/api/auth"
    end

    default_auth = described_class.auth
    override_auth = described_class.auth(base_path: "/auth")

    expect(default_auth.context.options.base_path).to eq("/api/auth")
    expect(override_auth.context.options.base_path).to eq("/auth")
    expect(override_auth).not_to equal(default_auth)
  end

  it "builds the default auth instance only once under concurrent access" do
    build_count = 0
    mutex = Mutex.new

    described_class.configure do |config|
      config.secret = secret
      config.database = ->(_options) {
        sleep 0.01
        mutex.synchronize { build_count += 1 }
        BetterAuth::Adapters::Memory.new(BetterAuth::Configuration.new(secret: secret, database: :memory))
      }
    end

    auths = 8.times.map { Thread.new { described_class.auth } }.map(&:value)

    expect(auths.uniq.length).to eq(1)
    expect(build_count).to eq(1)
  end

  def secret
    "test-secret-that-is-long-enough-for-validation"
  end
end
