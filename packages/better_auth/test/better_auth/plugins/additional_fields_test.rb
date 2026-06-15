# frozen_string_literal: true

require_relative "../../test_helper"

class BetterAuthPluginsAdditionalFieldsTest < Minitest::Test
  SECRET = "phase-seven-secret-with-enough-entropy-123"

  def test_additional_fields_plugin_merges_user_and_session_schema
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.additional_fields(
          user: {
            favoriteColor: {type: "string", required: false, default_value: "blue"},
            nickname: {type: "string", required: false}
          },
          session: {
            deviceName: {type: "string", required: false, default_value: "web"}
          }
        )
      ]
    )

    cookie = sign_up_cookie(auth, email: "fields@example.com", favorite_color: "green")
    session = auth.api.get_session(headers: {"cookie" => cookie})

    assert_equal "green", session[:user]["favoriteColor"]
    assert_equal "web", session[:session]["deviceName"]

    auth.api.update_user(headers: {"cookie" => cookie}, body: {nickname: "Fieldy"})
    updated = auth.api.get_session(headers: {"cookie" => cookie}, query: {disableCookieCache: true})

    assert_equal "Fieldy", updated[:user]["nickname"]
  end

  def test_additional_fields_validate_input_and_refresh_user_cookie
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.additional_fields(
          user: {
            requiredField: {type: "string", required: true},
            lockedField: {type: "string", required: false, input: false},
            nickname: {type: "string", required: false}
          }
        )
      ]
    )

    missing = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "missing@example.com", password: "password123", name: "Missing"})
    end
    assert_equal 400, missing.status_code
    assert_equal "requiredField is required", missing.message

    locked = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "locked@example.com", password: "password123", name: "Locked", requiredField: "ok", lockedField: "nope"})
    end
    assert_equal 400, locked.status_code
    assert_equal "lockedField is not allowed to be set", locked.message

    result = auth.api.sign_up_email(
      body: {email: "refresh@example.com", password: "password123", name: "Refresh", requiredField: "ok"},
      return_headers: true
    )
    cookie = cookie_header(result.fetch(:headers).fetch("set-cookie"))
    update = auth.api.update_user(headers: {"cookie" => cookie}, body: {nickname: "Fresh"}, return_headers: true)
    refreshed_cookie = [cookie, cookie_header(update.fetch(:headers).fetch("set-cookie"))].join("; ")

    session = auth.api.get_session(headers: {"cookie" => refreshed_cookie})
    assert_equal "Fresh", session.fetch(:user).fetch("nickname")

    empty = assert_raises(BetterAuth::APIError) do
      auth.api.update_user(headers: {"cookie" => refreshed_cookie}, body: {unknownField: "ignored"})
    end
    assert_equal 400, empty.status_code
    assert_equal "No fields to update", empty.message
  end

  def test_session_additional_fields_update_and_secondary_storage_defaults
    storage = MemoryStorage.new
    auth = build_auth(
      secondary_storage: storage,
      database_hooks: {
        session: {
          create: {
            before: ->(_session, _ctx) { {data: {hookField: "from-hook"}} }
          }
        }
      },
      plugins: [
        BetterAuth::Plugins.additional_fields(
          session: {
            deviceName: {type: "string", required: false, default_value: "web"},
            hookField: {type: "string", required: false},
            lockedSessionField: {type: "string", required: false, input: false}
          }
        )
      ]
    )

    cookie = sign_up_cookie(auth, email: "session-fields@example.com")
    session = auth.api.get_session(headers: {"cookie" => cookie})
    assert_equal "web", session.fetch(:session).fetch("deviceName")
    assert_equal "from-hook", session.fetch(:session).fetch("hookField")

    locked = assert_raises(BetterAuth::APIError) do
      auth.api.update_session(headers: {"cookie" => cookie}, body: {lockedSessionField: "nope"})
    end
    assert_equal 400, locked.status_code

    update = auth.api.update_session(headers: {"cookie" => cookie}, body: {deviceName: "mobile"}, return_headers: true)
    assert_equal "mobile", update.fetch(:response).fetch(:session).fetch("deviceName")
    updated_cookie = [cookie, cookie_header(update.fetch(:headers).fetch("set-cookie"))].join("; ")
    updated = auth.api.get_session(headers: {"cookie" => updated_cookie})
    assert_equal "mobile", updated.fetch(:session).fetch("deviceName")
  end

  def test_returned_false_user_fields_are_stored_but_not_exposed
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.additional_fields(
          user: {
            publicCode: {type: "string", required: false},
            secretCode: {type: "string", required: false, returned: false},
            favoriteColor: {type: "string", required: false, default_value: "blue"}
          }
        )
      ]
    )

    cookie = sign_up_cookie(auth, email: "returned-false@example.com", favorite_color: "green", secret_code: "hidden")
    session = auth.api.get_session(headers: {"cookie" => cookie}, query: {disableCookieCache: true})

    assert_equal "green", session[:user]["favoriteColor"]
    refute session[:user].key?("secretCode")

    stored = auth.context.internal_adapter.find_user_by_email("returned-false@example.com")[:user]
    assert_equal "hidden", stored["secretCode"]
  end

  private

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET, database: :memory}.merge(options).merge(email_and_password: email_and_password))
  end

  def sign_up_cookie(auth, email:, favorite_color: nil, secret_code: nil)
    body = {email: email, password: "password123", name: "Fields User"}
    body[:favoriteColor] = favorite_color if favorite_color
    body[:secretCode] = secret_code if secret_code
    _status, headers, _body = auth.api.sign_up_email(
      body: body,
      as_response: true
    )
    cookie_header(headers.fetch("set-cookie"))
  end

  def cookie_header(set_cookie)
    set_cookie.to_s.lines.map { |line| line.split(";").first }.join("; ")
  end

  class MemoryStorage
    def initialize
      @store = {}
    end

    def set(key, value, _ttl = nil)
      @store[key] = value
    end

    def get(key)
      @store[key]
    end

    def delete(key)
      @store.delete(key)
    end
  end
end
