# frozen_string_literal: true

# Soft-load probe shim for `better_auth-telemetry`.
#
# The core package soft-loads `require "better_auth/telemetry"` when building
# `auth.telemetry`. This shim keeps the plugin-style path loadable for callers
# that still require it directly, then delegates to the canonical public entry
# point.
#
# Implements Requirements 16.1 and 16.2.
require "better_auth/telemetry"
