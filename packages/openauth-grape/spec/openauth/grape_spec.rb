# frozen_string_literal: true

require "bundler/setup"

RSpec.describe "openauth-grape" do
  it "loads the canonical Better Auth Grape adapter" do
    require "openauth/grape"

    expect(defined?(BetterAuth::Grape)).to eq("constant")
  end
end
