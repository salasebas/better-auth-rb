# frozen_string_literal: true

require "better_auth/logger"

module BetterAuth
  module Telemetry
    # Thin wrapper that normalizes any logger-shaped object into the two-method
    # surface the telemetry pipeline depends on: `#info(message)` and
    # `#error(message)`. Every dispatch is wrapped in a `rescue StandardError`
    # so a misbehaving logger can never propagate out of telemetry code paths
    # (Requirements 5.5, 21.1, 21.2, 21.3).
    #
    # ## Per-dispatch selection rule
    #
    # On every `#info` / `#error` call, in order:
    #
    # 1. If the wrapped logger responds to the requested level
    #    (`:info` or `:error`), call it.
    # 2. Otherwise, if the wrapped logger responds to `:call`, invoke
    #    `logger.call(level, message)`.
    # 3. Otherwise, fall back to `Kernel.warn(message)`.
    #
    # Any `StandardError` raised by the chosen step is swallowed and the call
    # returns `nil`. Non-`StandardError` exceptions (`Interrupt`,
    # `SystemExit`, `SignalException`, `NoMemoryError`) are intentionally
    # allowed to propagate.
    #
    # ## Construction
    #
    # Use {LoggerAdapter.from} to build an adapter from a host-supplied
    # `options.logger`. When no logger is configured, the factory falls back
    # to `BetterAuth::Logger.create` so callers always get a usable adapter
    # that responds to `info` and `error`.
    #
    # @example wrap a Ruby stdlib `Logger`
    #   adapter = BetterAuth::Telemetry::LoggerAdapter.from(Logger.new($stderr))
    #   adapter.info("opted-in")
    #
    # @example wrap a callable logger
    #   adapter = BetterAuth::Telemetry::LoggerAdapter.from(->(level, msg) { puts "[#{level}] #{msg}" })
    #
    # @example default fallback
    #   adapter = BetterAuth::Telemetry::LoggerAdapter.from(nil)
    #   adapter.error("boom") # routed through BetterAuth::Logger.create
    class LoggerAdapter
      # Build a {LoggerAdapter} from the host-supplied logger, falling back to
      # the default {BetterAuth::Logger} when none is configured.
      #
      # Selection rules:
      #
      # - If `options_logger` is non-`nil` and responds to both `:info` and
      #   `:error`, wrap it as-is.
      # - Else if `options_logger` is non-`nil` and responds to `:call`, wrap
      #   the callable.
      # - Else fall back to `BetterAuth::Logger.create`.
      #
      # @param options_logger [Object, nil] the logger to wrap; may be a
      #   `Logger`-shaped object, a callable (`#call(level, message)`), or
      #   `nil`.
      # @return [LoggerAdapter] a fresh adapter with `#info` and `#error`.
      def self.from(options_logger)
        return new(options_logger) if logger_shape?(options_logger)
        return new(options_logger) if callable_shape?(options_logger)

        new(::BetterAuth::Logger.create)
      end

      # @api private
      def self.logger_shape?(logger)
        !logger.nil? && logger.respond_to?(:info) && logger.respond_to?(:error)
      end

      # @api private
      def self.callable_shape?(logger)
        !logger.nil? && logger.respond_to?(:call)
      end

      # @param logger [Object] any object that responds to `:info`/`:error`,
      #   or that responds to `:call`, or that responds to neither (in which
      #   case dispatch falls back to `Kernel.warn`).
      def initialize(logger)
        @logger = logger
      end

      # Dispatch an info-level log entry through the wrapped logger.
      #
      # @param message [String] the message to log.
      # @return [nil]
      def info(message)
        log(:info, message)
      end

      # Dispatch an error-level log entry through the wrapped logger.
      #
      # @param message [String] the message to log.
      # @return [nil]
      def error(message)
        log(:error, message)
      end

      private

      def log(level, message)
        if @logger.respond_to?(level)
          @logger.public_send(level, message)
        elsif @logger.respond_to?(:call)
          @logger.call(level, message)
        else
          Kernel.warn(message)
        end
        nil
      rescue
        # Requirement 21.3: logger errors must not propagate.
        nil
      end
    end
  end
end
