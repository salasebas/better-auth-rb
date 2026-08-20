# frozen_string_literal: true

module BetterAuth
  module StoreCapabilities
    module_function

    def has_server_session_store?(options)
      !!options.database || !!options.secondary_storage
    end

    def should_bind_account_cookie_to_session_user?(options)
      !!options.database
    end
  end
end
