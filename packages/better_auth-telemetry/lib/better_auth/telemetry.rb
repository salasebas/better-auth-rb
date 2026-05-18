# frozen_string_literal: true

# Public entry point for the `better_auth-telemetry` gem.
#
# Requiring this file pulls in every internal component the telemetry
# pipeline depends on so callers only need a single
# `require "better_auth/telemetry"` to access the full public surface:
#
# - {BetterAuth::Telemetry.create} — build a publisher tailored to the
#   host's opt-in state.
# - {BetterAuth::Telemetry.project_id} /
#   {BetterAuth::Telemetry.reset_project_id!} — anonymous project id
#   resolution and the test-only cache reset hook.
# - {BetterAuth::Telemetry::Publisher} /
#   {BetterAuth::Telemetry::NoopPublisher} — the two publisher shapes
#   `create` returns.
# - {BetterAuth::Telemetry::Detectors} — the seven detector modules
#   (`Runtime`, `Environment`, `SystemInfo`, `Database`, `Framework`,
#   `ProjectInfo`, `AuthConfig`).
# - Supporting value objects and helpers
#   ({BetterAuth::Telemetry::NormalizedOptions},
#   {BetterAuth::Telemetry::NormalizedContext},
#   {BetterAuth::Telemetry::CurrentOptions},
#   {BetterAuth::Telemetry::Env},
#   {BetterAuth::Telemetry::HttpClient},
#   {BetterAuth::Telemetry::LoggerAdapter}).
#
# The standard-library requires below are listed once at the entry
# point so individual internal files can rely on them being loaded.
# Every internal file additionally requires what it directly depends
# on, so any single file is independently loadable.

require "better_auth"

require "base64"
require "digest"
require "json"
require "net/http"
require "securerandom"
require "uri"

require_relative "telemetry/version"
require_relative "telemetry/noop_publisher"
require_relative "telemetry/logger_adapter"
require_relative "telemetry/options"
require_relative "telemetry/env"
require_relative "telemetry/http_client"
require_relative "telemetry/project_id"
require_relative "telemetry/publisher"
require_relative "telemetry/create"

require_relative "telemetry/detectors/runtime"
require_relative "telemetry/detectors/environment"
require_relative "telemetry/detectors/system_info"
require_relative "telemetry/detectors/database"
require_relative "telemetry/detectors/framework"
require_relative "telemetry/detectors/project_info"
require_relative "telemetry/detectors/auth_config"

module BetterAuth
  # Top-level namespace for the `better_auth-telemetry` gem.
  #
  # See `BetterAuth::Telemetry.create` for the entry point used by
  # `BetterAuth::Auth#initialize` and by tests that exercise the
  # publisher in isolation.
  module Telemetry
  end
end
