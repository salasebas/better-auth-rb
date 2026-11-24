# frozen_string_literal: true

require_relative "../../test_helper"

class BetterAuthRoutesAccountCookieTest < Minitest::Test
  include BetterAuthTestHelpers

  def test_database_requires_cookie_owner_to_match_session
    auth = build_auth(account: {store_account_cookie: true})
    account = {"providerId" => "github", "accountId" => "account-1"}
    [account.merge("userId" => "other"), account].each do |record|
      ctx = endpoint_context(auth, account_cookie_header(auth, record))
      assert_nil BetterAuth::Routes.account_cookie(ctx, "github", nil, "user-1")
    end
  end

  def test_secondary_storage_account_info_uses_account_cookie_without_user_binding
    auth = account_info_auth(database: nil, secondary_storage: AccountCookieStorage.new)
    session_cookie = sign_up_cookie(auth, email: "secondary-account-cookie@example.com")
    account_cookie = account_cookie_header(auth, userId: "different-user", providerId: "github", accountId: "account-1", accessToken: "account-token")

    info = auth.api.account_info(headers: {"cookie" => "#{session_cookie}; #{account_cookie}"})

    assert_equal "account-token", info[:data][:accessToken]
  end

  def test_account_cookie_selection_uses_the_provider_account_id
    auth = build_auth(database: nil)
    cookie = account_cookie_header(auth, id: "row-id", providerId: "github", accountId: "provider-id")
    ctx = endpoint_context(auth, cookie)

    assert_equal "provider-id", BetterAuth::Routes.account_cookie(ctx, "github", "provider-id", "user-1").fetch("accountId")
    assert_nil BetterAuth::Routes.account_cookie(ctx, "github", "row-id", "user-1")
  end

  def test_account_info_uses_the_token_from_the_explicitly_selected_account
    auth = account_info_auth
    session_cookie = sign_up_cookie(auth, email: "selected-account@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => session_cookie}).fetch(:user).fetch("id")
    account = {userId: user_id, providerId: "github", accountId: "account-1"}
    account_cookie = account_cookie_header(auth, account.merge(accessToken: "older-token"))
    auth.context.internal_adapter.create_account(account.merge(accessToken: "current-token"))

    info = auth.api.account_info(query: {accountId: "account-1"}, headers: {"cookie" => "#{session_cookie}; #{account_cookie}"})

    assert_equal "current-token", info[:data][:accessToken]
  end

  private

  def account_info_auth(**options)
    provider = {id: "github", get_user_info: ->(tokens) { {user: {id: "provider-user"}, data: {accessToken: tokens[:accessToken]}} }}
    build_auth(**options, account: {store_account_cookie: true}, social_providers: {github: provider})
  end

  def account_cookie_header(auth, record)
    ctx = endpoint_context(auth)
    BetterAuth::Cookies.set_account_cookie(ctx, record)
    cookie_header(ctx.response_headers.fetch("set-cookie"))
  end

  def endpoint_context(auth, cookie = nil)
    BetterAuth::Endpoint::Context.new(path: "/account-info", method: "GET", query: {}, body: {}, params: {}, headers: {"cookie" => cookie}, context: auth.context)
  end

  class AccountCookieStorage
    def initialize
      @data = {}
    end

    def set(key, value, _ttl = nil)
      @data[key] = value
    end

    def get(key)
      @data[key]
    end

    def delete(key)
      @data.delete(key)
    end
  end
end
