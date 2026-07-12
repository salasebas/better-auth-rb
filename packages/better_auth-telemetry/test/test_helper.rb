# frozen_string_literal: true

ENV["BETTER_AUTH_URL"] ||= "http://localhost:3000"

require "minitest/autorun"
require "better_auth/telemetry"

require "prop_check/minitest" if Gem.loaded_specs["prop_check"]
