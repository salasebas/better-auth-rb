# frozen_string_literal: true

require "rack/request"

module BetterAuthExamples
  class DynamicAuth
    attr_reader :registry

    def initialize(registry)
      @registry = registry
    end

    def call(env)
      request = Rack::Request.new(env)
      registry.auth_for(Settings.from_request(request)).call(env)
    end
  end
end
