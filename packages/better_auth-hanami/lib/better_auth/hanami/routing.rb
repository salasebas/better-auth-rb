# frozen_string_literal: true

module BetterAuth
  module Hanami
    module Routing
      HTTP_METHODS = %i[get post put patch delete options].freeze

      def self.included(base)
        base.extend(self)
      end

      def better_auth(auth: nil, at: BetterAuth::Configuration::DEFAULT_BASE_PATH)
        mount_path = normalize_better_auth_mount_path(at)
        auth ||= auth_for_better_auth_mount(mount_path)
        app = BetterAuth::Hanami::MountedApp.new(auth, mount_path: mount_path)

        HTTP_METHODS.each do |method_name|
          public_send(method_name, mount_path, to: app)
          public_send(method_name, "#{mount_path}/*path", to: app)
        end
      end

      private

      def normalize_better_auth_mount_path(path)
        normalized = path.to_s
        normalized = "/#{normalized}" unless normalized.start_with?("/")
        normalized = normalized.squeeze("/")
        normalized = normalized.delete_suffix("/") unless normalized == "/"
        normalized.empty? ? "/" : normalized
      end

      def auth_for_better_auth_mount(mount_path)
        configured_path = normalize_better_auth_mount_path(BetterAuth::Hanami.configuration.base_path)
        return BetterAuth::Hanami.auth if mount_path == configured_path

        BetterAuth::Hanami.auth(base_path: mount_path)
      end
    end
  end
end
