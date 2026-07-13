# frozen_string_literal: true

require "json"
require "stringio"
require_relative "../../test_helper"

class BetterAuthRoutesSignUpTest < Minitest::Test
  SECRET = "phase-five-secret-with-enough-entropy-123"

  def test_sign_up_email_creates_user_account_and_session
    auth = build_auth

    result = auth.api.sign_up_email(body: {
      email: "Ada@Example.COM",
      password: "password123",
      name: "Ada Lovelace",
      image: "https://example.com/ada.png"
    })

    assert_match(/\A[0-9a-f]{32}\z/, result[:token])
    assert_equal "ada@example.com", result[:user]["email"]
    assert_equal "Ada Lovelace", result[:user]["name"]
    assert_equal false, result[:user]["emailVerified"]

    account = auth.context.adapter.find_one(model: "account", where: [{field: "userId", value: result[:user]["id"]}])
    assert_equal "credential", account["providerId"]
    assert_equal result[:user]["id"], account["accountId"]
    assert_match(/\A[0-9a-f]{32}:[0-9a-f]{128}\z/, account["password"])
    assert BetterAuth::Password.verify(password: "password123", hash: account["password"])
  end

  def test_sign_up_email_requires_email_password_to_be_enabled
    auth = BetterAuth.auth(base_url: "http://localhost:3000", secret: SECRET)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "default-disabled@example.com", password: "password123", name: "Disabled"})
    end

    assert_equal 400, error.status_code
    assert_equal "EMAIL_PASSWORD_SIGN_UP_DISABLED", error.code
    assert_equal "Email and password sign up is not enabled", error.message
  end

  def test_sign_up_email_uses_configured_bcrypt_hasher
    auth = build_auth(password_hasher: :bcrypt)

    result = auth.api.sign_up_email(body: {
      email: "bcrypt@example.com",
      password: "password123",
      name: "BCrypt"
    })

    account = auth.context.adapter.find_one(model: "account", where: [{field: "userId", value: result[:user]["id"]}])
    assert_match(/\Abcrypt_sha256\$/, account["password"])
    assert BetterAuth::Password.verify(password: "password123", hash: account["password"])
  end

  def test_sign_up_email_returns_declared_additional_user_fields
    auth = build_auth(
      user: {
        additional_fields: {
          plan: {type: "string", required: false},
          isAdmin: {type: "boolean", default_value: true, input: false}
        }
      }
    )

    result = auth.api.sign_up_email(body: {
      email: "additional-sign-up@example.com",
      password: "password123",
      name: "Additional",
      plan: "pro"
    })

    assert_equal "pro", result[:user]["plan"]
    assert_equal true, result[:user]["isAdmin"]
  end

  def test_sign_up_email_rejects_input_false_additional_user_fields
    auth = build_auth(
      user: {
        additional_fields: {
          role: {type: "string", required: false, input: false}
        }
      }
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {
        email: "input-false-sign-up@example.com",
        password: "password123",
        name: "Input False",
        role: "admin"
      })
    end

    assert_equal 400, error.status_code
    assert_equal "role is not allowed to be set", error.message
  end

  def test_sign_up_email_rolls_back_user_and_account_when_session_creation_fails
    auth = build_auth
    auth.context.internal_adapter.define_singleton_method(:create_session) do |*_args|
      nil
    end

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {
        email: "rollback@example.com",
        password: "password123",
        name: "Rollback"
      })
    end

    assert_equal 400, error.status_code
    assert_nil auth.context.adapter.find_one(model: "user", where: [{field: "email", value: "rollback@example.com"}])
    assert_empty auth.context.adapter.find_many(model: "account")
  end

  def test_sign_up_and_sign_in_email_use_custom_password_callbacks
    auth = build_auth(
      email_and_password: {
        password: {
          hash: ->(password) { "custom:#{password.reverse}" },
          verify: ->(data) { data[:hash] == "custom:#{data[:password].reverse}" }
        }
      }
    )

    auth.api.sign_up_email(body: {email: "custom@example.com", password: "password123", name: "Custom"})
    account = auth.context.adapter.find_one(model: "account", where: [{field: "providerId", value: "credential"}])

    assert_equal "custom:321drowssap", account["password"]
    assert auth.api.sign_in_email(body: {email: "custom@example.com", password: "password123"})[:token]
  end

  def test_sign_up_email_allows_empty_name_without_trusting_raw_forwarded_header
    auth = build_auth

    result = auth.api.sign_up_email(
      body: {email: "headers@example.com", password: "password123", name: ""},
      headers: {"x-forwarded-for" => "127.0.0.1", "user-agent" => "SignUpTest"}
    )
    session = auth.context.internal_adapter.find_session(result[:token])

    assert_equal "", result[:user]["name"]
    assert_equal "", session[:session]["ipAddress"]
    assert_equal "SignUpTest", session[:session]["userAgent"]
  end

  def test_sign_up_session_uses_advanced_ip_address_headers
    auth = build_auth(
      advanced: {
        ip_address: {
          ip_address_headers: ["x-client-ip", "x-forwarded-for"]
        }
      }
    )

    _status, headers, _body = auth.api.sign_up_email(
      body: {email: "ip-header@example.com", password: "password123", name: "IP Header"},
      headers: {"x-client-ip" => "203.0.113.10", "x-forwarded-for" => "198.51.100.20", "user-agent" => "SignUpTest"},
      as_response: true
    )
    session = auth.api.get_session(headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))})

    assert_equal "203.0.113.10", session[:session]["ipAddress"]
  end

  def test_sign_up_email_sets_session_cookie_for_rack_requests
    auth = build_auth

    status, headers, body = auth.call(
      rack_env(
        "POST",
        "/api/auth/sign-up/email",
        body: JSON.generate(email: "cookie@example.com", password: "password123", name: "Cookie User")
      )
    )

    data = JSON.parse(body.join)
    assert_equal 200, status
    assert_match(/\A[0-9a-f]{32}\z/, data.fetch("token"))
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
  end

  def test_sign_up_email_accepts_form_urlencoded_rack_requests
    auth = build_auth
    form = "email=form-sign-up%40example.com&password=password123&name=Form+User"

    status, _headers, body = auth.call(
      rack_env(
        "POST",
        "/api/auth/sign-up/email",
        body: form,
        content_type: "application/x-www-form-urlencoded"
      )
    )
    data = JSON.parse(body.join)

    assert_equal 200, status
    assert_match(/\A[0-9a-f]{32}\z/, data.fetch("token"))
    assert_equal "form-sign-up@example.com", data.fetch("user").fetch("email")
  end

  def test_sign_up_email_blocks_cross_site_navigation
    auth = build_auth

    status, _headers, body = auth.call(
      rack_env(
        "POST",
        "/api/auth/sign-up/email",
        body: JSON.generate(email: "csrf@example.com", password: "password123", name: "CSRF"),
        extra_headers: {
          "HTTP_SEC_FETCH_SITE" => "cross-site",
          "HTTP_SEC_FETCH_MODE" => "navigate",
          "HTTP_SEC_FETCH_DEST" => "document",
          "HTTP_ORIGIN" => "https://evil.example"
        }
      )
    )
    data = JSON.parse(body.join)

    assert_equal 403, status
    assert_equal BetterAuth::BASE_ERROR_CODES["CROSS_SITE_NAVIGATION_LOGIN_BLOCKED"], data.fetch("message")
  end

  def test_sign_up_email_rejects_invalid_email_and_short_password
    auth = build_auth

    invalid_email = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "invalid", password: "password123", name: "Bad Email"})
    end
    assert_equal 400, invalid_email.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES["INVALID_EMAIL"], invalid_email.message

    short_password = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "short@example.com", password: "short", name: "Short Password"})
    end
    assert_equal 400, short_password.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES["PASSWORD_TOO_SHORT"], short_password.message
  end

  def test_sign_up_email_rejects_missing_required_body_fields_before_creating_user
    auth = build_auth

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "missing-name@example.com", password: "password123"})
    end

    assert_equal 400, error.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES["VALIDATION_ERROR"], error.message
    assert_nil auth.context.internal_adapter.find_user_by_email("missing-name@example.com")
  end

  def test_sign_up_email_rejects_duplicate_email
    auth = build_auth

    auth.api.sign_up_email(body: {email: "duplicate@example.com", password: "password123", name: "First"})
    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "DUPLICATE@example.com", password: "password123", name: "Second"})
    end

    assert_equal 422, error.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES["USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL"], error.message
  end

  def test_sign_up_email_with_required_verification_returns_synthetic_user_for_existing_email
    callbacks = []
    auth = build_auth(
      email_and_password: {
        require_email_verification: true,
        on_existing_user_sign_up: ->(data) { callbacks << data }
      },
      email_verification: {
        send_on_sign_up: false
      }
    )

    original = auth.api.sign_up_email(body: {email: "existing-verify@example.com", password: "password123", name: "Original"})
    duplicate = auth.api.sign_up_email(body: {email: "EXISTING-VERIFY@example.com", password: "password123", name: "Duplicate"})

    assert_nil original[:token]
    assert_nil duplicate[:token]
    assert_equal "existing-verify@example.com", duplicate[:user]["email"]
    refute_equal original[:user]["id"], duplicate[:user]["id"]
    assert_equal 1, callbacks.length
    assert_equal "existing-verify@example.com", callbacks.first[:user]["email"]
  end

  def test_sign_up_duplicate_with_required_verification_returns_same_user_keys_in_same_order
    auth = build_auth(
      email_and_password: {require_email_verification: true},
      email_verification: {send_on_sign_up: false},
      user: {
        additional_fields: {
          displayName: {type: "string", required: false},
          isAdmin: {type: "boolean", default_value: false, input: false}
        }
      }
    )

    first = auth.api.sign_up_email(body: {
      email: "indistinguishable@example.com",
      password: "password123",
      name: "First User",
      displayName: "FirstDisplay"
    })
    second = auth.api.sign_up_email(body: {
      email: "indistinguishable@example.com",
      password: "password456",
      name: "Second Attempt",
      displayName: "SecondDisplay"
    })

    assert_equal first.keys, second.keys
    assert_equal first[:user].keys, second[:user].keys
    assert_nil second[:token]
    assert_equal "Second Attempt", second[:user]["name"]
    assert_equal "SecondDisplay", second[:user]["displayName"]
    assert_equal false, second[:user]["isAdmin"]
    refute_equal first[:user]["id"], second[:user]["id"]
  end

  def test_sign_up_duplicate_custom_synthetic_user_can_return_admin_plugin_fields
    auth = build_auth(
      email_and_password: {
        require_email_verification: true,
        customSyntheticUser: lambda do |data|
          core_fields = data[:coreFields]
          additional_fields = data[:additionalFields]
          core_fields.merge(
            "role" => "user",
            "banned" => false,
            "banReason" => nil,
            "banExpires" => nil
          ).merge(additional_fields).merge("id" => data[:id])
        end
      },
      email_verification: {send_on_sign_up: false},
      plugins: [BetterAuth::Plugins.admin]
    )

    first = auth.api.sign_up_email(body: {email: "admin-enum@example.com", password: "password123", name: "First"})
    second = auth.api.sign_up_email(body: {email: "admin-enum@example.com", password: "password456", name: "Second"})

    assert_equal first[:user].keys, second[:user].keys
    assert_equal "user", second[:user]["role"]
    assert_equal false, second[:user]["banned"]
    assert_nil second[:user]["banReason"]
    assert_nil second[:user]["banExpires"]
  end

  def test_sign_up_existing_email_with_auto_sign_in_false_returns_indistinguishable_synthetic_response
    callbacks = []
    hashed_passwords = []
    auth = build_auth(
      email_and_password: {
        auto_sign_in: false,
        on_existing_user_sign_up: ->(data) { callbacks << data },
        password: {
          hash: lambda do |password|
            hashed_passwords << password
            "observed:#{password}"
          end,
          verify: ->(password:, hash:) { hash == "observed:#{password}" }
        }
      },
      user: {
        additional_fields: {
          displayName: {type: "string", required: false},
          isAdmin: {type: "boolean", default_value: false, input: false}
        }
      }
    )

    first_status, _first_headers, first_body = auth.api.sign_up_email(body: {
      email: "auto-disabled-existing@example.com",
      password: "password123",
      name: "First",
      displayName: "First Display",
      isAdmin: true
    }, as_response: true)
    first = JSON.parse(first_body.join)
    assert_nil first["token"]
    assert_equal false, first.dig("user", "isAdmin")

    second_status, _second_headers, second_body = auth.api.sign_up_email(body: {
      email: "auto-disabled-existing@example.com",
      password: "password456",
      name: "Second",
      displayName: "Second Display",
      isAdmin: true
    }, as_response: true)
    second = JSON.parse(second_body.join)

    assert_equal first_status, second_status
    assert_equal first.keys, second.keys
    assert_equal first.fetch("user").keys, second.fetch("user").keys
    assert_nil second["token"]
    assert_equal "Second", second.dig("user", "name")
    assert_equal "Second Display", second.dig("user", "displayName")
    assert_equal false, second.dig("user", "isAdmin")
    refute_equal first.dig("user", "id"), second.dig("user", "id")
    assert_equal ["password123", "password456"], hashed_passwords
    assert_equal 1, callbacks.length
    assert_equal first.dig("user", "id"), callbacks.first[:user]["id"]
  end

  def test_sign_up_protected_duplicate_validates_input_false_without_default_before_lookup
    auth = build_auth(
      email_and_password: {auto_sign_in: false},
      user: {
        additional_fields: {
          role: {type: "string", required: false, input: false}
        }
      }
    )
    auth.api.sign_up_email(body: {
      email: "protected-input-known@example.com",
      password: "password123",
      name: "Known"
    })

    errors = ["protected-input-known@example.com", "protected-input-new@example.com"].map do |email|
      assert_raises(BetterAuth::APIError) do
        auth.api.sign_up_email(body: {
          email: email,
          password: "password456",
          name: "Attempt",
          role: "admin"
        })
      end
    end

    assert_equal [400, 400], errors.map(&:status_code)
    assert_equal ["role is not allowed to be set"] * 2, errors.map(&:message)
  end

  def test_sign_up_protected_duplicate_ignores_js_falsy_input_false_values_before_lookup
    auth = build_auth(
      email_and_password: {auto_sign_in: false},
      user: {
        additional_fields: {
          lockedField: {type: "string", required: false, input: false}
        }
      }
    )
    auth.api.sign_up_email(body: {
      email: "falsy-input-known@example.com",
      password: "password123",
      name: "Known"
    })

    ["", 0].each_with_index do |value, index|
      known = auth.api.sign_up_email(body: {
        email: "falsy-input-known@example.com",
        password: "password456",
        name: "Known Attempt",
        lockedField: value
      })
      new_email = "falsy-input-new-#{index}@example.com"
      created = auth.api.sign_up_email(body: {
        email: new_email,
        password: "password456",
        name: "New Attempt",
        lockedField: value
      })

      assert_nil known[:token]
      assert_nil created[:token]
      refute known[:user].key?("lockedField")
      refute created[:user].key?("lockedField")
      refute auth.context.internal_adapter.find_user_by_email(new_email).fetch(:user).key?("lockedField")
    end
  end

  def test_sign_up_protected_duplicate_validates_required_additional_fields_before_lookup
    auth = build_auth(
      email_and_password: {auto_sign_in: false},
      user: {
        additional_fields: {
          tenantId: {type: "string", required: true}
        }
      }
    )
    auth.api.sign_up_email(body: {
      email: "required-known@example.com",
      password: "password123",
      name: "Known",
      tenantId: "tenant-1"
    })

    errors = ["required-known@example.com", "required-new@example.com"].map do |email|
      assert_raises(BetterAuth::APIError) do
        auth.api.sign_up_email(body: {
          email: email,
          password: "password456",
          name: "Attempt"
        })
      end
    end

    assert_equal [400, 400], errors.map(&:status_code)
    assert_equal ["tenantId is required"] * 2, errors.map(&:message)
  end

  def test_sign_up_existing_callback_runs_only_for_protected_duplicate_branch
    callbacks = []
    auth = build_auth(
      email_and_password: {
        auto_sign_in: false,
        on_existing_user_sign_up: ->(data) { callbacks << data }
      }
    )

    auth.api.sign_up_email(body: {email: "callback-duplicate@example.com", password: "password123", name: "First"})
    assert_empty callbacks

    auth.api.sign_up_email(body: {email: "callback-duplicate@example.com", password: "password456", name: "Second"})
    assert_equal 1, callbacks.length
  end

  def test_sign_up_new_user_with_auto_sign_in_false_returns_null_token
    auth = build_auth(email_and_password: {auto_sign_in: false})

    result = auth.api.sign_up_email(body: {
      email: "auto-disabled-new@example.com",
      password: "password123",
      name: "No Session"
    })

    assert_nil result[:token]
    assert_equal "auto-disabled-new@example.com", result[:user]["email"]
    assert_nil auth.context.adapter.find_one(model: "session", where: [{field: "userId", value: result[:user]["id"]}])
  end

  def test_sign_up_email_can_be_disabled
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      email_and_password: {enabled: true, disable_sign_up: true}
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "disabled@example.com", password: "password123", name: "Disabled"})
    end

    assert_equal 400, error.status_code
    assert_equal "Email and password sign up is not enabled", error.message
  end

  def test_sign_up_email_requires_verification_without_auto_session
    sent = []
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      email_and_password: {enabled: true, require_email_verification: true},
      email_verification: {
        send_verification_email: ->(data, _request = nil) { sent << data }
      }
    )

    result = auth.api.sign_up_email(body: {
      email: "verify@example.com",
      password: "password123",
      name: "Verify Me",
      callbackURL: "/dashboard"
    })

    assert_nil result[:token]
    assert_equal "verify@example.com", result[:user]["email"]
    assert_equal 1, sent.length
    assert_equal "verify@example.com", sent.first[:user]["email"]
    assert_includes sent.first[:url], "/verify-email?token="
    assert_includes sent.first[:url], "callbackURL=%2Fdashboard"
  end

  def test_sign_up_email_does_not_send_verification_when_send_on_sign_up_is_false
    sent = []
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      email_and_password: {enabled: true, require_email_verification: true},
      email_verification: {
        send_on_sign_up: false,
        send_verification_email: ->(data, _request = nil) { sent << data }
      }
    )

    result = auth.api.sign_up_email(body: {
      email: "no-send@example.com",
      password: "password123",
      name: "No Send"
    })

    assert_nil result[:token]
    assert_empty sent
  end

  def test_sign_up_email_rejects_untrusted_callback_url
    auth = build_auth(email_and_password: {require_email_verification: true})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {
        email: "bad-callback-sign-up@example.com",
        password: "password123",
        name: "Bad Callback",
        callbackURL: "https://evil.example/callback"
      })
    end

    assert_equal 403, error.status_code
    assert_equal "Invalid callbackURL", error.message
  end

  def test_sign_up_email_sends_verification_by_default_when_required
    sent = []
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      email_and_password: {enabled: true, require_email_verification: true},
      email_verification: {send_verification_email: ->(data, _request = nil) { sent << data }}
    )

    auth.api.sign_up_email(body: {email: "default-send@example.com", password: "password123", name: "Default Send"})

    assert_equal 1, sent.length
    assert_equal "default-send@example.com", sent.first[:user]["email"]
  end

  def test_sign_up_email_rejects_unsupported_content_type_for_rack_requests
    auth = build_auth

    status, _headers, body = auth.call(
      rack_env(
        "POST",
        "/api/auth/sign-up/email",
        body: "email=test%40example.com&password=password123&name=Test",
        content_type: "text/plain"
      )
    )

    assert_equal 415, status
    assert_equal({"error" => "Unsupported Media Type"}, JSON.parse(body.join))
  end

  private

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET}.merge(options).merge(email_and_password: email_and_password))
  end

  def rack_env(method, path, body: "", content_type: "application/json", extra_headers: {})
    base = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "3000",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(body),
      "CONTENT_TYPE" => content_type,
      "CONTENT_LENGTH" => body.bytesize.to_s,
      "HTTP_ORIGIN" => "http://localhost:3000"
    }
    base.merge(extra_headers)
  end

  def cookie_header(set_cookie)
    set_cookie.lines.map { |line| line.split(";").first }.join("; ")
  end
end
