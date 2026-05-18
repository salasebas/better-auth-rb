# frozen_string_literal: true

require "rack/request"

module BetterAuthExamples
  class CompositeApp
    def initialize(dashboard:, auth:, base_path: DEFAULT_BASE_PATH)
      @dashboard = dashboard
      @auth = auth
      @base_path = base_path
    end

    def call(env)
      path = env.fetch("PATH_INFO", "")
      return @auth.call(env) if path == @base_path || path.start_with?("#{@base_path}/")

      @dashboard.call(env)
    end
  end
end
