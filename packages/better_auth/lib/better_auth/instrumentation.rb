# frozen_string_literal: true

module BetterAuth
  module Instrumentation
    module SpanStatusCode
      UNSET = 0
      OK = 1
      ERROR = 2
    end

    class NoopSpan
      def set_attribute(_key, _value)
        self
      end

      def set_attributes(_attributes)
        self
      end

      def record_exception(_error)
        self
      end

      def set_status(_status)
        self
      end

      def add_event(_name, _attributes = nil)
        self
      end

      def end
        self
      end
    end

    class NoopTracer
      def start_active_span(_name, attributes: {}, &block)
        span = NoopSpan.new
        return span unless block

        block.call(span)
      ensure
        span&.end
      end
    end

    class Trace
      def get_tracer(_name = "better-auth")
        NoopTracer.new
      end

      def get_active_span
        NoopSpan.new
      end
    end

    module_function

    def trace
      @trace ||= Trace.new
    end

    def with_span(name, attributes: {}, options: nil, &block)
      if !defined?(::OpenTelemetry::Trace::Status) || options&.experimental&.dig(:instrumentation, :enabled) == false
        return block.call(NoopSpan.new)
      end

      tracer = ::OpenTelemetry.tracer_provider.tracer("better-auth", BetterAuth::VERSION)
      span = tracer.start_span(name, attributes: attributes)
      ::OpenTelemetry::Trace.with_span(span) do
        block.call(span)
      rescue => error
        if error.is_a?(APIError) && (300...400).cover?(error.status_code)
          span.set_attribute("http.response.status_code", error.status_code)
          span.status = ::OpenTelemetry::Trace::Status.ok
        else
          span.record_exception(error)
          span.status = ::OpenTelemetry::Trace::Status.error(error.message)
        end
        raise
      end
    ensure
      span&.finish
    end
  end
end
