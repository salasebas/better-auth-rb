# frozen_string_literal: true

module BetterAuthExamples
  module RateLimitSettings
    module_function

    def config(settings)
      settings = Settings.normalize(settings)
      {
        enabled: true,
        storage: storage_name(settings),
        window: settings[:rate_window],
        max: settings[:rate_max],
        custom_rules: {
          "*" => {
            window: settings[:rate_window],
            max: settings[:rate_max]
          }
        }
      }
    end

    def secondary_storage(settings)
      return nil unless Settings.normalize(settings)[:rate_adapter] == "redis"

      require "redis"
      require "better_auth/redis_storage"

      client = Redis.new(url: ENV.fetch("BETTER_AUTH_EXAMPLE_REDIS_URL", "redis://127.0.0.1:16379/0"))
      BetterAuth.redis_storage(client: client, key_prefix: "better-auth-example:")
    end

    def storage_name(settings)
      (Settings.normalize(settings)[:rate_adapter] == "redis") ? "secondary-storage" : "memory"
    end
  end
end
