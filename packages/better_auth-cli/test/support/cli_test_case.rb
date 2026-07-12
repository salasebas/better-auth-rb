# frozen_string_literal: true

ENV["BETTER_AUTH_URL"] ||= "http://localhost:3000"

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../../better_auth/lib", __dir__)

require "better_auth/cli"
require "json"
require "minitest/autorun"
require_relative "cli_helpers"

class BetterAuthCLITestCase < Minitest::Test
  include BetterAuthCLITestHelpers

  SECRET = BetterAuthCLITestHelpers::SECRET
  HARDENED_SECRET = BetterAuthCLITestHelpers::HARDENED_SECRET

  def teardown
    BetterAuth::CLI.configure(nil)
  end
end
