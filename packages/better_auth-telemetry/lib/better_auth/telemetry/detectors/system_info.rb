# frozen_string_literal: true

require "etc"
require "rbconfig"
require "rubygems"
require "timeout"

module BetterAuth
  module Telemetry
    module Detectors
      # System info detector. Returns a hash describing the host
      # platform, container/WSL state, deployment vendor, and a few
      # cheap host-level signals (cpu count, memory, isTTY).
      #
      # This is the Ruby-specific replacement for upstream's
      # `detect-system-info.ts` (and the Node-specific block inside
      # `node.ts`). The Ruby port collapses both upstream variants into
      # a single server-side detector that uses `RbConfig`,
      # `Gem::Platform.local`, `Etc`, `IO.popen`, and a few `File.exist?`
      # / `File.read` probes against well-known paths.
      #
      # ## Ruby-specific deviations from upstream
      #
      # - `cpuModel` is always `nil`. There is no portable Ruby stdlib
      #   API for the model string, and exposing a partial detection
      #   (e.g. parsing `/proc/cpuinfo`) would only work on Linux.
      # - `cpuSpeed` (an upstream key) is **omitted entirely** from the
      #   returned hash, rather than emitted as `nil`. Including it
      #   would invite consumers to assume it can ever be populated by
      #   the Ruby implementation. The README documents this.
      # - `memory` is read from `/proc/meminfo` on Linux and from
      #   `sysctl -n hw.memsize` on macOS via {.read_sysctl_memsize}
      #   under a 1s {Timeout.timeout}. On other platforms (and on
      #   read failures) it is `nil`.
      #
      # ## Failure handling (Requirement 9.11)
      #
      # Every probe is invoked through {.safely}, which is just
      # `yield rescue StandardError; nil`. A surprise from any single
      # probe degrades that field to `nil` rather than escaping out of
      # the init payload composition in
      # {BetterAuth::Telemetry.create}.
      #
      # Each helper probe ({.detect_vendor}, {.platform}, {.release},
      # {.architecture}, {.cpu_count}, {.total_memory_bytes}, {.wsl?},
      # {.docker?}, {.tty?}) is exposed as a `module_function` so it
      # can be stubbed with `Minitest::Mock#stub` in the
      # corresponding test, exercising the per-field rescue path.
      module SystemInfo
        # Vendor table. The list and order mirror upstream's
        # `getVendor` short-circuit chain in
        # `upstream/better-auth/1.6.9/packages/telemetry/src/detectors/detect-system-info.ts`.
        # First match wins; a missing match yields `nil`.
        #
        # Each entry is `[vendor_name, [marker_env_var, ...]]`. A
        # vendor matches when any of its marker variables is set to a
        # non-empty value.
        VENDORS = [
          ["cloudflare", %w[CF_PAGES CF_PAGES_URL CF_ACCOUNT_ID]],
          ["vercel", %w[VERCEL VERCEL_URL VERCEL_ENV]],
          ["netlify", %w[NETLIFY NETLIFY_URL]],
          ["render", %w[RENDER RENDER_URL RENDER_INTERNAL_HOSTNAME RENDER_SERVICE_ID]],
          ["aws", %w[AWS_LAMBDA_FUNCTION_NAME AWS_EXECUTION_ENV LAMBDA_TASK_ROOT]],
          ["gcp", %w[GOOGLE_CLOUD_FUNCTION_NAME GOOGLE_CLOUD_PROJECT GCP_PROJECT K_SERVICE]],
          ["azure", %w[AZURE_FUNCTION_NAME FUNCTIONS_WORKER_RUNTIME WEBSITE_INSTANCE_ID WEBSITE_SITE_NAME]],
          ["deno-deploy", %w[DENO_DEPLOYMENT_ID DENO_REGION]],
          ["fly-io", %w[FLY_APP_NAME FLY_REGION FLY_ALLOC_ID]],
          ["railway", %w[RAILWAY_STATIC_URL RAILWAY_ENVIRONMENT_NAME]],
          ["heroku", %w[DYNO HEROKU_APP_NAME]],
          ["digitalocean", %w[DO_DEPLOYMENT_ID DO_APP_NAME DIGITALOCEAN]],
          ["koyeb", %w[KOYEB KOYEB_DEPLOYMENT_ID KOYEB_APP_NAME]]
        ].freeze

        # Cap on the `sysctl` subprocess reading macOS `hw.memsize`. A
        # well-behaved `sysctl` returns essentially instantly; the cap
        # only exists so a hung subprocess cannot block init.
        SYSCTL_TIMEOUT_SECONDS = 1

        module_function

        # Compose the system-info hash emitted as
        # `payload[:systemInfo]` in the init event.
        #
        # @return [Hash{Symbol => Object, nil}] hash with keys
        #   `:deploymentVendor`, `:systemPlatform`, `:systemRelease`,
        #   `:systemArchitecture`, `:cpuCount`, `:cpuModel`, `:memory`,
        #   `:isWSL`, `:isDocker`, `:isTTY`. Any individual field may
        #   be `nil` when the underlying probe is unsupported on the
        #   host or raises. The key `:cpuSpeed` is intentionally
        #   absent.
        def call
          {
            deploymentVendor: safely { detect_vendor },
            systemPlatform: safely { platform },
            systemRelease: safely { release },
            systemArchitecture: safely { architecture },
            cpuCount: safely { cpu_count },
            cpuModel: nil,
            memory: safely { total_memory_bytes },
            isWSL: safely { wsl? },
            isDocker: safely { docker? },
            isTTY: safely { tty? }
          }
        end

        # Run `block` and rescue any `StandardError` to `nil`. The
        # whole detector composes its return hash by calling each
        # probe through this helper, so a raising probe degrades only
        # that field rather than aborting the entire detector.
        #
        # @yield the probe to run.
        # @return [Object, nil] whatever the block returns, or `nil`
        #   if the block raised a `StandardError`.
        def safely
          yield
        rescue
          nil
        end

        # Match the first vendor whose marker variables are present in
        # `ENV`. Mirrors upstream's `getVendor` short-circuit chain.
        #
        # @return [String, nil] the vendor name (`"vercel"`,
        #   `"cloudflare"`, …) or `nil` when no vendor matches.
        def detect_vendor
          VENDORS.each do |(name, keys)|
            return name if keys.any? { |k| has_env_marker?(k) }
          end
          nil
        end

        # @return [Boolean] whether `ENV[key]` is set to a non-empty
        #   string. Mirrors upstream's `Boolean(env[k])`.
        def has_env_marker?(key)
          value = ENV[key]
          !value.nil? && !value.empty?
        end

        # Short platform identifier matching upstream `os.platform()`
        # style.
        #
        # @return [String, nil] one of `"linux"`, `"darwin"`,
        #   `"windows"`, `"freebsd"`, `"openbsd"`, `"netbsd"`,
        #   `"sunos"`, `"aix"`. Falls back to
        #   `Gem::Platform.local.os` (or the raw `host_os`) when the
        #   `host_os` token does not match a known prefix.
        def platform
          host_os = RbConfig::CONFIG["host_os"].to_s.downcase
          case host_os
          when /linux/ then "linux"
          when /darwin/ then "darwin"
          when /mswin|mingw|cygwin/ then "windows"
          when /freebsd/ then "freebsd"
          when /openbsd/ then "openbsd"
          when /netbsd/ then "netbsd"
          when /sunos|solaris/ then "sunos"
          when /aix/ then "aix"
          else
            (Gem::Platform.local.os if defined?(::Gem::Platform)) || host_os
          end
        end

        # Operating-system release string. Prefers `Etc.uname[:release]`
        # (e.g. `"5.15.0-92-generic"` on Linux, `"24.6.0"` on macOS).
        # Falls back to the trailing version digits of
        # `RbConfig::CONFIG["host_os"]` (e.g. `"darwin25"` → `"25"`)
        # when `Etc.uname` is unavailable.
        #
        # @return [String, nil]
        def release
          if defined?(::Etc) && ::Etc.respond_to?(:uname)
            value = ::Etc.uname[:release]
            return value if value.is_a?(String) && !value.empty?
          end
          host_os = RbConfig::CONFIG["host_os"].to_s
          tail = host_os[/\d.*\z/]
          (tail.nil? || tail.empty?) ? nil : tail
        end

        # Short architecture identifier matching upstream `os.arch()`
        # style.
        #
        # @return [String, nil] e.g. `"x64"`, `"arm64"`, `"ia32"`.
        #   Falls back to `Gem::Platform.local.cpu` (or the raw
        #   `host_cpu`) when the value does not match a known token.
        def architecture
          host_cpu = RbConfig::CONFIG["host_cpu"].to_s.downcase
          case host_cpu
          when "x86_64", "amd64", "x64" then "x64"
          when "aarch64", "arm64" then "arm64"
          when "i386", "i686", "x86" then "ia32"
          when /ppc64/ then "ppc64"
          when /ppc/ then "ppc"
          when /arm/ then "arm"
          else
            (Gem::Platform.local.cpu if defined?(::Gem::Platform)) || host_cpu
          end
        end

        # @return [Integer, nil] the value returned by
        #   `Etc.nprocessors`, reported verbatim including `0`. The
        #   outer `safely` wrapper in {.call} maps an `Etc.nprocessors`
        #   raise to `nil`.
        def cpu_count
          ::Etc.nprocessors
        end

        # Total system memory in bytes when reachable on the host
        # platform, otherwise `nil`.
        #
        # @return [Integer, nil]
        def total_memory_bytes
          case platform
          when "linux"
            read_meminfo_bytes
          when "darwin"
            read_sysctl_memsize
          end
        end

        # Read `MemTotal` from `/proc/meminfo`. The field reports
        # kilobytes; we multiply to bytes to match upstream's
        # `os.totalmem()` units.
        #
        # @return [Integer, nil]
        def read_meminfo_bytes
          File.foreach("/proc/meminfo") do |line|
            if (m = line.match(/\AMemTotal:\s+(\d+)\s+kB/i))
              return m[1].to_i * 1024
            end
          end
          nil
        rescue
          nil
        end

        # Run `sysctl -n hw.memsize` under a 1s timeout. The
        # subprocess writes a single integer (bytes) to stdout.
        #
        # @return [Integer, nil]
        def read_sysctl_memsize
          output = Timeout.timeout(SYSCTL_TIMEOUT_SECONDS) do
            IO.popen(["sysctl", "-n", "hw.memsize"], err: File::NULL, &:read)
          end
          return nil if output.nil? || output.strip.empty?
          value = output.strip.to_i
          (value > 0) ? value : nil
        rescue
          nil
        end

        # Detect Docker via well-known sentinels.
        #
        # @return [Boolean] `true` when `/.dockerenv` exists OR
        #   `/proc/self/cgroup` exists and contains the literal
        #   substring `"docker"`; `false` otherwise.
        def docker?
          return true if File.exist?("/.dockerenv")
          if File.exist?("/proc/self/cgroup")
            return true if File.read("/proc/self/cgroup").include?("docker")
          end
          false
        rescue
          false
        end

        # Detect WSL.
        #
        # `true` iff `RUBY_PLATFORM` indicates Linux AND either
        # `Etc.uname[:release]` or `/proc/version` contains the
        # case-insensitive substring `"microsoft"`, AND the host is
        # not detected as inside a non-Docker container (the
        # `/run/.containerenv` sentinel).
        #
        # @return [Boolean]
        def wsl?
          return false unless RUBY_PLATFORM.to_s.include?("linux")

          return false unless microsoft_marker?
          return false if non_docker_container?

          true
        rescue
          false
        end

        # @return [Boolean] whether either `Etc.uname[:release]` or
        #   `/proc/version` contains `"microsoft"` (case-insensitive).
        def microsoft_marker?
          if defined?(::Etc) && ::Etc.respond_to?(:uname)
            release_str = ::Etc.uname[:release].to_s
            return true if release_str.downcase.include?("microsoft")
          end

          if File.exist?("/proc/version")
            return true if File.read("/proc/version").downcase.include?("microsoft")
          end

          false
        rescue
          false
        end

        # @return [Boolean] whether the host is detected as a non-Docker
        #   container — `/run/.containerenv` is present AND
        #   {.docker?} is `false`.
        def non_docker_container?
          File.exist?("/run/.containerenv") && !docker?
        rescue
          false
        end

        # @return [Boolean] `$stdout.tty?`.
        def tty?
          $stdout.tty?
        end
      end
    end
  end
end
