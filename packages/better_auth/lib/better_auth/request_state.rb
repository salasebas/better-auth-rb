# frozen_string_literal: true

module BetterAuth
  module RequestState
    THREAD_KEY = :better_auth_request_state_stack

    State = Struct.new(:ref, :initializer) do
      def get
        store = RequestState.current_store
        store[ref] = initializer.call unless store.key?(ref)
        store[ref]
      end

      def set(value)
        RequestState.current_store[ref] = value
      end
    end

    module_function

    def run(store = {}, &block)
      stack.push(store)
      block.call
    ensure
      stack.pop
    end

    def present?
      !stack.empty?
    end

    def with_current(&block)
      present? ? block.call : run(&block)
    end

    def current_store
      stack.last || raise("No request state found. Please make sure you are calling this function within a `run` callback.")
    end

    def define(&initializer)
      State.new(Object.new.freeze, initializer || -> {})
    end

    def stack
      Thread.current[THREAD_KEY] ||= []
    end
  end
end
