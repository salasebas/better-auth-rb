# frozen_string_literal: true

module BetterAuth
  module Logger
    LEVELS = [:debug, :info, :success, :warn, :error].freeze

    Internal = Struct.new(:level, :disabled, :handler) do
      LEVELS.each do |log_level|
        define_method(log_level) do |message, *args|
          return if disabled || !Logger.should_publish?(level, log_level)

          if handler
            handler.call((log_level == :success) ? :info : log_level, message, *args)
          else
            Kernel.warn("#{log_level.upcase} [Better Auth]: #{message}")
          end
        end
      end
    end

    module_function

    def should_publish?(current_log_level, log_level)
      LEVELS.index(log_level.to_sym).to_i >= LEVELS.index(current_log_level.to_sym).to_i
    end

    def create(level: :warn, disabled: false, log: nil, **)
      Internal.new(level: level.to_sym, disabled: disabled, handler: log)
    end
  end
end
