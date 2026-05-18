# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"

require_relative "version"

module BetterAuth
  module Telemetry
    # Thread-local registry that lets {ProjectId.resolve_project_name}
    # discover the host's `app_name` without changing the public method
    # signature `BetterAuth::Telemetry.project_id(base_url)` (Requirement
    # 14.1).
    #
    # `BetterAuth::Telemetry.create` sets `app_name` for the duration of
    # an init flow via {.with_app_name}; outside of that scope the reader
    # returns `nil` and the project-name resolver falls through to the
    # Bundler root directory name.
    #
    # The store is per-thread so concurrent `create` calls in different
    # threads don't clobber each other.
    module CurrentOptions
      KEY = :better_auth_telemetry_current_options_app_name

      module_function

      # @return [String, nil] the app name set by the most recent
      #   {.with_app_name} block on the current thread, or `nil`.
      def app_name
        Thread.current[KEY]
      end

      # @param value [String, nil]
      # @return [String, nil] the value just stored.
      def app_name=(value)
        Thread.current[KEY] = value
      end

      # Run `block` with `app_name` set to `value`, restoring the prior
      # value (typically `nil`) on the way out — even when the block
      # raises.
      #
      # @param value [String, nil]
      # @yield with the thread-local app name temporarily set.
      # @return [Object] whatever the block returns.
      def with_app_name(value)
        prior = Thread.current[KEY]
        Thread.current[KEY] = value
        yield
      ensure
        Thread.current[KEY] = prior
      end
    end

    # Project-name resolver used by {BetterAuth::Telemetry.project_id}.
    #
    # The chain (Requirement 14.7) is:
    #
    # 1. {CurrentOptions.app_name} — when set and not the default
    #    `"Better Auth"`.
    # 2. `File.basename(Bundler.root)` — the directory name of the
    #    Gemfile root.
    #
    # Every fallback is wrapped in `rescue StandardError; nil` so that a
    # missing Bundler load, an unreadable lockfile, or any unrelated
    # error in one rule degrades to the next rule rather than escaping
    # to the caller (Requirement 14.8).
    module ProjectId
      # Upstream sentinel: the `Better Auth` literal is treated as "not
      # configured" so the chain falls through to the Bundler signals.
      DEFAULT_APP_NAME = "Better Auth"

      module_function

      # @return [String, nil] the resolved project name, or `nil` when
      #   no rule produced a non-empty string.
      def resolve_project_name
        from_app_name || from_bundler_root
      rescue
        nil
      end

      # Read the host's `app_name` from {CurrentOptions}. Treats the
      # literal `"Better Auth"` (the upstream default) as "not
      # configured" so it never wins over the Bundler-derived rules.
      #
      # @return [String, nil]
      def from_app_name
        name = CurrentOptions.app_name
        return nil if name.nil?
        return nil unless name.is_a?(String)
        return nil if name.empty?
        return nil if name == DEFAULT_APP_NAME

        name
      rescue
        nil
      end

      # Legacy helper retained as a test seam for older specs. The
      # resolver no longer uses the first locked dependency as project
      # identity because that can collide across unrelated apps.
      #
      # @return [String, nil]
      def from_locked_gems
        return nil unless defined?(::Bundler)

        locked = ::Bundler.locked_gems
        return nil if locked.nil?

        spec = locked.specs&.first
        return nil if spec.nil?

        name = spec.name
        return nil if name.nil? || name.empty?

        name
      rescue
        nil
      end

      # Directory name of `Bundler.root`. The closest Ruby analog to
      # upstream's "directory containing package.json" fallback.
      #
      # @return [String, nil]
      def from_bundler_root
        return nil unless defined?(::Bundler)

        root = ::Bundler.root
        return nil if root.nil?

        name = File.basename(root.to_s)
        return nil if name.nil? || name.empty?

        name
      rescue
        nil
      end
    end

    @project_id_cache = {}
    @project_id_mutex = Mutex.new

    # Resolve a stable, anonymous project id for telemetry.
    #
    # The id is memoized by normalized `(base_url, project_name)` input
    # so multi-app Ruby processes do not collapse every auth instance
    # into the first derived anonymous id.
    #
    # ## Derivation chain (Requirements 14.2 – 14.5)
    #
    # 1. Project name resolvable AND `base_url` non-empty:
    #    `Base64(SHA-256(base_url + name))`.
    # 2. Project name resolvable AND `base_url` nil/empty:
    #    `Base64(SHA-256(name))`.
    # 3. No project name AND `base_url` non-empty:
    #    `Base64(SHA-256(base_url))`.
    # 4. Otherwise: a random 32-character `[a-zA-Z0-9]` id from
    #    `SecureRandom`, matching upstream `generateId(32)`.
    #
    # The Bundler probe inside {ProjectId.resolve_project_name} never
    # raises out of this method; a failed probe collapses to "no project
    # name" and the chain continues at rule 3 or rule 4.
    #
    # @param base_url [String, nil] the host's configured base URL.
    # @return [String] the memoized anonymous project id.
    def self.project_id(base_url)
      url = normalize_base_url(base_url)
      name = ProjectId.resolve_project_name
      name = nil if name.is_a?(String) && name.empty?
      cache_key = [url, name]

      cached = @project_id_cache[cache_key]
      return cached if cached

      @project_id_mutex.synchronize do
        cached = @project_id_cache[cache_key]
        return cached if cached

        @project_id_cache[cache_key] = derive_project_id(url, name)
      end
    end

    # Test-only hook that clears the memoized project id cache.
    #
    # Wired here in task 3.6 to clear the `@project_id_cache` ivar that
    # backs {.project_id}. Tests use this between cases that exercise
    # different derivation rules (e.g. with vs. without a project name)
    # so each call goes through the full chain again.
    #
    # @return [nil]
    def self.reset_project_id!
      @project_id_mutex.synchronize do
        @project_id_cache = {}
      end
      nil
    end

    # @api private
    def self.derive_project_id(url, name)
      if name && url
        hash_to_base64(url + name)
      elsif name
        hash_to_base64(name)
      elsif url
        hash_to_base64(url)
      else
        random_id_32
      end
    end

    # @api private
    def self.normalize_base_url(base_url)
      url = base_url.is_a?(String) ? base_url : nil
      (url && url.empty?) ? nil : url
    end

    # @api private
    def self.hash_to_base64(input)
      Base64.strict_encode64(Digest::SHA256.digest(input.to_s))
    end

    # @api private
    PROJECT_ID_ALPHABET = (
      ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a
    ).freeze

    # @api private
    def self.random_id_32
      Array.new(32) { PROJECT_ID_ALPHABET[SecureRandom.random_number(PROJECT_ID_ALPHABET.length)] }.join
    end
  end
end
