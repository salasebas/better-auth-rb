# frozen_string_literal: true

require_relative "request_ip"

module BetterAuth
  module Core
    def self.base_endpoints
      {
        ok: Routes.ok,
        error: Routes.error,
        sign_up_email: Routes.sign_up_email,
        sign_in_email: Routes.sign_in_email,
        sign_in_social: Routes.sign_in_social,
        callback_oauth: Routes.callback_oauth,
        sign_out: Routes.sign_out,
        get_session: Routes.get_session,
        list_sessions: Routes.list_sessions,
        update_session: Routes.update_session,
        revoke_session: Routes.revoke_session,
        revoke_sessions: Routes.revoke_sessions,
        revoke_other_sessions: Routes.revoke_other_sessions,
        request_password_reset: Routes.request_password_reset,
        request_password_reset_callback: Routes.request_password_reset_callback,
        reset_password: Routes.reset_password,
        verify_password: Routes.verify_password,
        send_verification_email: Routes.send_verification_email,
        verify_email: Routes.verify_email,
        update_user: Routes.update_user,
        change_email: Routes.change_email,
        change_password: Routes.change_password,
        set_password: Routes.set_password,
        delete_user: Routes.delete_user,
        delete_user_callback: Routes.delete_user_callback,
        list_accounts: Routes.list_accounts,
        link_social: Routes.link_social,
        unlink_account: Routes.unlink_account,
        get_access_token: Routes.get_access_token,
        refresh_token: Routes.refresh_token,
        account_info: Routes.account_info
      }
    end
  end
end
