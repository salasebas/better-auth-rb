# frozen_string_literal: true

require "test_helper"

class BetterAuthCookiesTest < Minitest::Test
  SECRET = "phase-four-secret-with-enough-entropy-123"

  def test_cookie_definitions_follow_upstream_defaults_and_secure_prefix
    auth = BetterAuth.auth(
      secret: SECRET,
      base_url: "https://example.com",
      advanced: {
        use_secure_cookies: true,
        cookie_prefix: "custom",
        cross_subdomain_cookies: {enabled: true}
      }
    )

    cookie = auth.context.auth_cookies[:session_token]

    assert_equal "__Secure-custom.session_token", cookie.name
    assert_equal true, cookie.attributes[:secure]
    assert_equal "lax", cookie.attributes[:same_site]
    assert_equal "/", cookie.attributes[:path]
    assert_equal true, cookie.attributes[:http_only]
    assert_equal "example.com", cookie.attributes[:domain]
    assert_equal 60 * 60 * 24 * 7, cookie.attributes[:max_age]
  end

  def test_advanced_cookie_overrides_name_and_attributes
    auth = BetterAuth.auth(
      secret: SECRET,
      advanced: {
        cookie_prefix: "custom",
        cookies: {
          session_token: {
            name: "sid",
            attributes: {same_site: "none", path: "/auth"}
          }
        }
      }
    )

    cookie = auth.context.auth_cookies[:session_token]

    assert_equal "sid", cookie.name
    assert_equal "none", cookie.attributes[:same_site]
    assert_equal "/auth", cookie.attributes[:path]
  end

  def test_session_cookie_parser_accepts_secure_and_legacy_names
    secure = "__Secure-better-auth.session_token=signed"
    legacy = "better-auth-session_token=legacy"

    assert_equal "signed", BetterAuth::Cookies.get_session_cookie(secure)
    assert_equal "legacy", BetterAuth::Cookies.get_session_cookie(legacy)
  end

  def test_session_cookie_parser_prefers_secure_cookie_over_legacy_cookie
    header = "better-auth.session_token=legacy; __Secure-better-auth.session_token=secure"

    assert_equal "secure", BetterAuth::Cookies.get_session_cookie(header)
  end

  def test_set_cookie_splitter_accepts_rack_header_forms_without_splitting_expires
    first = "first=one; Path=/; Expires=Wed, 09 Jun 2027 10:18:14 GMT"
    second = "second=two; Path=/; HttpOnly"

    assert_equal [first], BetterAuth::Cookies.split_set_cookie_header(first)
    assert_equal [first, second], BetterAuth::Cookies.split_set_cookie_header("#{first}\n#{second}")
    assert_equal [first, second], BetterAuth::Cookies.split_set_cookie_header([first, second])
    assert_equal [first, second], BetterAuth::Cookies.split_set_cookie_header("#{first}, #{second}")
    assert_empty BetterAuth::Cookies.split_set_cookie_header(nil)
  end

  def test_set_cookie_parser_preserves_duplicate_names_in_header_order
    lines = BetterAuth::Cookies.split_set_cookie_header("session=first; Path=/\nsession=second; Path=/")
    parsed = lines.map { |line| BetterAuth::Cookies.parse_set_cookie(line) }

    assert_equal ["first", "second"], parsed.map { |cookie| cookie.fetch(:value) }
    assert_equal({"path" => "/"}, parsed.first.fetch(:attributes))
  end

  def test_expiring_cookie_scrubs_prior_same_name_and_chunked_set_cookie_entries
    auth = BetterAuth.auth(secret: SECRET, session: {cookie_cache: {enabled: true}})
    ctx = endpoint_context(auth)
    cookie = auth.context.auth_cookies[:session_data]
    ctx.set_cookie(cookie.name, "still-valid", cookie.attributes)
    ctx.set_cookie("#{cookie.name}.0", "chunk-valid", cookie.attributes)
    ctx.set_cookie("unrelated", "keep", path: "/")

    BetterAuth::Cookies.expire_cookie(ctx, cookie)

    lines = ctx.response_headers.fetch("set-cookie").lines
    assert lines.any? { |line| line.start_with?("unrelated=keep") }
    assert lines.any? { |line| line.start_with?("#{cookie.name}=") && line.include?("Max-Age=0") }
    refute lines.any? { |line| line.start_with?("#{cookie.name}=still-valid") }
    refute lines.any? { |line| line.start_with?("#{cookie.name}.0=chunk-valid") }
  end

  def test_signed_cookie_round_trip_and_rejects_tampering
    ctx = endpoint_context(BetterAuth.auth(secret: SECRET))

    ctx.set_signed_cookie("better-auth.session_token", "token-1", SECRET)
    cookie = ctx.response_headers.fetch("set-cookie")
    request_ctx = endpoint_context(BetterAuth.auth(secret: SECRET), cookie: cookie.split(";").first)

    assert_equal "token-1", request_ctx.get_signed_cookie("better-auth.session_token", SECRET)
    tampered = cookie.sub("token-1", "token-2")
    tampered_ctx = endpoint_context(BetterAuth.auth(secret: SECRET), cookie: tampered.split(";").first)
    assert_nil tampered_ctx.get_signed_cookie("better-auth.session_token", SECRET)
  end

  def test_parse_cookies_decodes_percent_encoded_values_without_rejecting_legacy_raw_values
    cookies = BetterAuth::Cookies.parse_cookies("json=%7B%22prompt%22%3A%22login%3Bstrict%22%7D; legacy=raw%ZZvalue; byte=%FF; pair=%C3%28")

    assert_equal "{\"prompt\":\"login;strict\"}", cookies.fetch("json")
    assert_equal "raw%ZZvalue", cookies.fetch("legacy")
    assert_equal "%FF", cookies.fetch("byte")
    assert_equal "%C3%28", cookies.fetch("pair")
  end

  def test_set_request_cookie_matches_upstream_parse_mutate_serialize_semantics
    assert_equal "better-auth.session_token=abc", BetterAuth::Cookies.set_request_cookie("", "better-auth.session_token", "abc")
    assert_equal(
      "preference=dark; locale=en; better-auth.session_token=abc",
      BetterAuth::Cookies.set_request_cookie("preference=dark; locale=en", "better-auth.session_token", "abc")
    )
    assert_equal(
      "better-auth.session_token=fresh; locale=en",
      BetterAuth::Cookies.set_request_cookie("better-auth.session_token=stale; locale=en", "better-auth.session_token", "fresh")
    )
    assert_equal(
      "valid=1; locale=en; better-auth.session_token=abc",
      BetterAuth::Cookies.set_request_cookie("valid=1; ; =orphan; locale=en", "better-auth.session_token", "abc")
    )
    assert_equal "locale=en; session=foo%3Bbar%3Dbaz", BetterAuth::Cookies.set_request_cookie("locale=en", "session", "foo;bar=baz")
    assert_equal "token=%22abc%22", BetterAuth::Cookies.set_request_cookie("", "token", '"abc"')
    assert_equal "x=%25C3%2528", BetterAuth::Cookies.set_request_cookie("x=%C3%28", "x", "%C3%28")
  end

  def test_set_request_cookie_validates_names_values_and_only_trims_ows
    header = "\tquoted = \"hello%20world\"\t; bad name=value; bad-value=has\\slash; ctl=bad\rvalue; plus=a+b"

    assert_equal(
      "quoted=hello%20world; plus=a%2Bb; fresh=value",
      BetterAuth::Cookies.set_request_cookie(header, "fresh", "value")
    )
    assert_equal "valid=1", BetterAuth::Cookies.set_request_cookie("valid=1", "bad name", "ignored")
    assert_equal "valid=1; token=line%0Abreak", BetterAuth::Cookies.set_request_cookie("valid=1", "token", "line\nbreak")
  end

  def test_cookie_cache_compact_strategy_round_trips_and_validates_version
    auth = BetterAuth.auth(
      secret: SECRET,
      session: {cookie_cache: {enabled: true, strategy: "compact", version: "2"}}
    )
    ctx = endpoint_context(auth)
    data = {
      session: {"id" => "session-1", "token" => "token-1", "userId" => "user-1"},
      user: {"id" => "user-1", "email" => "ada@example.com"}
    }

    BetterAuth::Cookies.set_cookie_cache(ctx, data, false)
    cookie = ctx.response_headers.fetch("set-cookie").lines.find { |line| line.include?("session_data") }.split(";").first

    parsed = BetterAuth::Cookies.get_cookie_cache(cookie, secret: SECRET, strategy: "compact", version: "2")
    assert_equal "session-1", parsed["session"]["id"]
    assert_nil BetterAuth::Cookies.get_cookie_cache(cookie, secret: SECRET, strategy: "compact", version: "3")
  end

  def test_cookie_cache_uses_custom_session_data_cookie_name
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      email_and_password: {enabled: true},
      session: {cookie_cache: {enabled: true, max_age: 120}},
      advanced: {cookies: {session_data: {name: "custom.session_payload"}}}
    )

    status, headers, = auth.api.sign_up_email(
      body: {email: "custom-cache@example.com", password: "password123", name: "Cached"},
      as_response: true
    )
    assert_equal 200, status

    cookie = headers.fetch("set-cookie").to_s.lines(chomp: true).map { |line| line.split(";").first }.join("; ")
    session = auth.api.get_session(headers: {"cookie" => cookie})
    user_id = session.fetch(:user).fetch("id")
    auth.context.adapter.update(model: "user", where: [{field: "id", value: user_id}], update: {name: "Database"})

    cached = auth.api.get_session(headers: {"cookie" => cookie})

    assert_equal "Cached", cached.fetch(:user).fetch("name")
  end

  def test_cookie_cache_supports_compact_jwt_and_jwe_strategies
    %w[compact jwt jwe].each do |strategy|
      auth = BetterAuth.auth(
        secret: SECRET,
        session: {cookie_cache: {enabled: true, strategy: strategy, version: "1"}}
      )
      ctx = endpoint_context(auth)

      BetterAuth::Cookies.set_cookie_cache(ctx, {
        session: {"id" => "session-1", "token" => "token-1", "userId" => "user-1"},
        user: {"id" => "user-1", "email" => "ada@example.com"}
      }, false)

      cookie = ctx.response_headers.fetch("set-cookie").lines.find { |line| line.include?("session_data") }.split(";").first
      payload = BetterAuth::Cookies.get_cookie_cache(cookie, secret: SECRET, strategy: strategy, version: "1")

      assert_equal "token-1", payload.fetch("session").fetch("token")
      assert_equal "ada@example.com", payload.fetch("user").fetch("email")
    end
  end

  def test_jwe_cookie_cache_and_account_cookie_survive_secret_rotation
    old_auth = BetterAuth.auth(
      secret: "legacy-secret-that-is-long-enough-for-cookies",
      secrets: [{version: 1, value: "old-secret-that-is-long-enough-for-cookies"}],
      session: {cookie_cache: {enabled: true, strategy: "jwe"}},
      account: {store_account_cookie: true}
    )
    old_ctx = endpoint_context(old_auth)

    BetterAuth::Cookies.set_cookie_cache(old_ctx, {
      session: {"id" => "session-1", "token" => "token-1", "userId" => "user-1"},
      user: {"id" => "user-1", "email" => "ada@example.com"}
    }, false)
    BetterAuth::Cookies.set_account_cookie(old_ctx, {"providerId" => "github", "accountId" => "account-1"})

    header = old_ctx.response_headers.fetch("set-cookie").to_s.lines(chomp: true).map { |line| line.split(";").first }.join("; ")
    new_auth = BetterAuth.auth(
      secret: "legacy-secret-that-is-long-enough-for-cookies",
      secrets: [
        {version: 2, value: "new-secret-that-is-long-enough-for-cookies"},
        {version: 1, value: "old-secret-that-is-long-enough-for-cookies"}
      ],
      session: {cookie_cache: {enabled: true, strategy: "jwe"}},
      account: {store_account_cookie: true}
    )
    new_ctx = endpoint_context(new_auth, cookie: header)

    session_cookie = BetterAuth::SessionStore.get_chunked_cookie(new_ctx, new_auth.context.auth_cookies[:session_data].name)
    session_payload = BetterAuth::Cookies.decode_cookie_cache(session_cookie, new_auth.context.secret_config, strategy: "jwe")

    assert_equal "token-1", session_payload.fetch("session").fetch("token")
    assert_equal "account-1", BetterAuth::Cookies.get_account_cookie(new_ctx).fetch("accountId")
  end

  def test_cookie_cache_filters_fields_marked_returned_false
    auth = BetterAuth.auth(
      secret: SECRET,
      session: {cookie_cache: {enabled: true, strategy: "jwt"}},
      plugins: [
        {
          id: "private-cache-field",
          schema: {
            user: {
              fields: {
                secretNote: {type: "string", returned: false}
              }
            },
            session: {
              fields: {
                serverOnly: {type: "string", returned: false}
              }
            }
          }
        }
      ]
    )
    ctx = endpoint_context(auth)

    BetterAuth::Cookies.set_cookie_cache(ctx, {
      session: {
        "id" => "session-1",
        "token" => "token-1",
        "userId" => "user-1",
        "serverOnly" => "do-not-cache"
      },
      user: {
        "id" => "user-1",
        "email" => "ada@example.com",
        "secretNote" => "do-not-cache"
      }
    }, false)

    cookie = ctx.response_headers.fetch("set-cookie").lines.find { |line| line.include?("session_data") }.split(";").first
    payload = BetterAuth::Cookies.get_cookie_cache(cookie, secret: SECRET, strategy: "jwt")

    refute payload.fetch("session").key?("serverOnly")
    refute payload.fetch("user").key?("secretNote")
  end

  def test_session_store_chunks_and_reassembles_large_values
    auth = BetterAuth.auth(secret: SECRET)
    ctx = endpoint_context(auth)
    store = BetterAuth::SessionStore.new("better-auth.session_data", {}, ctx)
    cookies = store.chunk("x" * 8_000)

    assert_operator cookies.length, :>, 1
    store.set_cookies(cookies)

    header = ctx.response_headers.fetch("set-cookie").to_s.lines(chomp: true).map { |line| line.split(";").first }.join("; ")
    request_ctx = endpoint_context(auth, cookie: header)
    assert_equal "x" * 8_000, BetterAuth::SessionStore.get_chunked_cookie(request_ctx, "better-auth.session_data")
  end

  def test_production_environment_enables_secure_cookies_from_rack_rails_and_app_env
    %w[RACK_ENV RAILS_ENV APP_ENV].each do |env_key|
      with_env("RACK_ENV" => nil, "RAILS_ENV" => nil, "APP_ENV" => nil, env_key => "production") do
        config = BetterAuth::Configuration.new(secret: SECRET, base_url: "http://example.com", database: :memory)
        cookie = BetterAuth::Cookies.create_cookie(config, "session_token")

        assert_equal true, cookie.attributes[:secure], "expected secure cookies for #{env_key}=production"
      end
    end
  end

  def test_use_secure_cookies_false_overrides_production_and_https_defaults
    with_env("RACK_ENV" => "production", "RAILS_ENV" => nil, "APP_ENV" => nil) do
      config = BetterAuth::Configuration.new(
        secret: SECRET,
        base_url: "https://example.com",
        database: :memory,
        advanced: {use_secure_cookies: false}
      )
      cookie = BetterAuth::Cookies.create_cookie(config, "session_token")

      assert_equal false, cookie.attributes[:secure]
      refute cookie.name.start_with?(BetterAuth::Cookies::SECURE_COOKIE_PREFIX)
    end
  end

  def test_cross_subdomain_cookies_derive_domain_from_base_url_and_require_base_url
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      base_url: "https://app.example.com",
      database: :memory,
      advanced: {cross_subdomain_cookies: {enabled: true}}
    )
    cookie = BetterAuth::Cookies.create_cookie(config, "session_token")

    assert_equal "app.example.com", cookie.attributes[:domain]

    with_env("BETTER_AUTH_URL" => nil, "OPEN_AUTH_URL" => nil, "BASE_URL" => nil) do
      assert_raises(BetterAuth::Error, "base_url is required") do
        BetterAuth::Configuration.new(
          secret: SECRET,
          database: :memory,
          advanced: {cross_subdomain_cookies: {enabled: true}}
        )
      end
    end

    assert_raises(BetterAuth::Error, "dynamic base_url is unsupported") do
      BetterAuth::Configuration.new(
        secret: SECRET,
        database: :memory,
        base_url: {allowed_hosts: ["example.com"], fallback: "https://example.com"},
        advanced: {cross_subdomain_cookies: {enabled: true}}
      )
    end
  end

  def test_default_cookie_attributes_merge_before_per_cookie_overrides
    config = BetterAuth::Configuration.new(
      secret: SECRET,
      base_url: "https://example.com",
      database: :memory,
      advanced: {
        default_cookie_attributes: {same_site: "none", path: "/app"},
        cookies: {
          session_token: {attributes: {path: "/auth", same_site: "strict"}}
        }
      }
    )
    cookie = BetterAuth::Cookies.create_cookie(config, "session_token")

    assert_equal "/auth", cookie.attributes[:path]
    assert_equal "strict", cookie.attributes[:same_site]
    assert_equal true, cookie.attributes[:http_only]
  end

  def test_strip_secure_cookie_prefix_removes_secure_and_host_prefixes
    assert_equal "better-auth.session_token", BetterAuth::Cookies.strip_secure_cookie_prefix("__Secure-better-auth.session_token")
    assert_equal "better-auth.session_token", BetterAuth::Cookies.strip_secure_cookie_prefix("__Host-better-auth.session_token")
    assert_equal "", BetterAuth::Cookies.strip_secure_cookie_prefix("")
    assert_equal "", BetterAuth::Cookies.strip_secure_cookie_prefix(BetterAuth::Cookies::SECURE_COOKIE_PREFIX)
    assert_equal "", BetterAuth::Cookies.strip_secure_cookie_prefix(BetterAuth::Cookies::HOST_COOKIE_PREFIX)
  end

  def test_parse_cookies_handles_empty_headers_duplicate_keys_and_padding
    assert_empty BetterAuth::Cookies.parse_cookies("")
    assert_empty BetterAuth::Cookies.parse_cookies(nil)

    parsed = BetterAuth::Cookies.parse_cookies("first=1; second=2; first=last")
    assert_equal "last", parsed.fetch("first")
    assert_equal "2", parsed.fetch("second")

    padded = BetterAuth::Cookies.parse_cookies("better-auth.session_token=token.signature=; better-auth.session_data=data.signature=")
    assert_equal "token.signature=", padded.fetch("better-auth.session_token")
    assert_equal "data.signature=", padded.fetch("better-auth.session_data")
  end

  def test_expire_cookie_emits_max_age_zero_and_preserves_attributes
    auth = BetterAuth.auth(secret: SECRET)
    ctx = endpoint_context(auth)
    cookie = BetterAuth::Cookies::Cookie.new(
      name: "better-auth.session_token",
      attributes: {path: "/custom", domain: "example.com", http_only: true}
    )

    BetterAuth::Cookies.expire_cookie(ctx, cookie)
    set_cookie = ctx.response_headers.fetch("set-cookie")

    assert_includes set_cookie, "Max-Age=0"
    assert_includes set_cookie, "Path=/custom"
    assert_includes set_cookie, "Domain=example.com"
    assert_includes set_cookie, "HttpOnly"
  end

  def test_endpoint_context_emits_multiline_set_cookie_headers
    auth = BetterAuth.auth(secret: SECRET)
    ctx = endpoint_context(auth)
    ctx.set_cookie("better-auth.session_token", "token", path: "/")
    ctx.set_cookie("better-auth.session_data", "cache", path: "/")

    lines = ctx.response_headers.fetch("set-cookie").to_s.lines(chomp: true).map { |line| line.split(";").first }

    assert_equal ["better-auth.session_token=token", "better-auth.session_data=cache"], lines
  end

  def test_compact_cookie_cache_rejects_expired_and_tampered_payloads
    data = {
      "session" => {"id" => "session-1", "token" => "token-1", "userId" => "user-1"},
      "user" => {"id" => "user-1", "email" => "ada@example.com"}
    }
    expired = BetterAuth::Cookies.encode_cookie_cache(data, SECRET, strategy: "compact", max_age: -60)
    valid = BetterAuth::Cookies.encode_cookie_cache(data, SECRET, strategy: "compact", max_age: 300)
    payload = JSON.parse(BetterAuth::Crypto.base64url_decode(valid))
    payload["signature"] = "bad-signature"
    tampered = BetterAuth::Crypto.base64url_encode(JSON.generate(payload))

    assert_nil BetterAuth::Cookies.decode_cookie_cache(expired, SECRET, strategy: "compact")
    assert_nil BetterAuth::Cookies.decode_cookie_cache(tampered, SECRET, strategy: "compact")
  end

  def test_jwt_and_jwe_cookie_cache_reject_wrong_secrets
    data = {
      "session" => {"id" => "session-1", "token" => "token-1", "userId" => "user-1"},
      "user" => {"id" => "user-1", "email" => "ada@example.com"}
    }
    signing_secret = "signing-secret-that-is-long-enough-123456"
    other_secret = "other-secret-that-is-long-enough-1234567"
    jwt_value = BetterAuth::Cookies.encode_cookie_cache(data, signing_secret, strategy: "jwt", max_age: 300)
    jwe_value = BetterAuth::Cookies.encode_cookie_cache(
      data,
      [{version: 1, value: signing_secret}],
      strategy: "jwe",
      max_age: 300
    )

    assert_nil BetterAuth::Cookies.decode_cookie_cache(jwt_value, other_secret, strategy: "jwt")
    assert_nil BetterAuth::Cookies.decode_cookie_cache(jwe_value, [{version: 1, value: other_secret}], strategy: "jwe")
  end

  def test_get_cookie_cache_supports_cookie_full_name_and_is_secure_options
    auth = BetterAuth.auth(secret: SECRET, session: {cookie_cache: {enabled: true, strategy: "compact", version: "1"}})
    ctx = endpoint_context(auth)
    BetterAuth::Cookies.set_cookie_cache(ctx, {
      session: {"id" => "session-1", "token" => "token-1", "userId" => "user-1"},
      user: {"id" => "user-1", "email" => "ada@example.com"}
    }, false)
    cookie = ctx.response_headers.fetch("set-cookie").lines.find { |line| line.include?("session_data") }.split(";").first

    parsed = BetterAuth::Cookies.get_cookie_cache(
      cookie,
      secret: SECRET,
      strategy: "compact",
      version: "1",
      cookie_full_name: "better-auth.session_data"
    )
    secure_parsed = BetterAuth::Cookies.get_cookie_cache(
      cookie,
      secret: SECRET,
      strategy: "compact",
      version: "1",
      is_secure: false
    )

    assert_equal "token-1", parsed.fetch("session").fetch("token")
    assert_equal "token-1", secure_parsed.fetch("session").fetch("token")
    assert_nil BetterAuth::Cookies.get_cookie_cache(
      cookie,
      secret: SECRET,
      strategy: "compact",
      version: "1",
      is_secure: true
    )
  end

  def test_cookie_cache_version_callback_receives_session_and_user
    version = ->(session, user) { "#{session.fetch("token")}-#{user.fetch("id")}" }
    auth = BetterAuth.auth(secret: SECRET, session: {cookie_cache: {enabled: true, strategy: "compact", version: version}})
    ctx = endpoint_context(auth)
    BetterAuth::Cookies.set_cookie_cache(ctx, {
      session: {"id" => "session-1", "token" => "token-1", "userId" => "user-1"},
      user: {"id" => "user-1", "email" => "ada@example.com"}
    }, false)
    cookie = ctx.response_headers.fetch("set-cookie").lines.find { |line| line.include?("session_data") }.split(";").first

    parsed = BetterAuth::Cookies.get_cookie_cache(cookie, secret: SECRET, strategy: "compact", version: version)
    mismatched = ->(_session, _user) { "other-version" }

    assert_equal "token-1", parsed.fetch("session").fetch("token")
    assert_nil BetterAuth::Cookies.get_cookie_cache(cookie, secret: SECRET, strategy: "compact", version: mismatched)
  end

  def test_cookie_cache_chunk_cleanup_and_numeric_ordering
    auth = BetterAuth.auth(secret: SECRET, session: {cookie_cache: {enabled: true, strategy: "compact"}})
    large_ctx = endpoint_context(auth)
    BetterAuth::Cookies.set_cookie_cache(large_ctx, {
      session: {"id" => "session-1", "token" => "token-1", "userId" => "user-1", "note" => "x" * 8_000},
      user: {"id" => "user-1", "email" => "chunked@example.com"}
    }, false)
    chunked_header = large_ctx.response_headers.fetch("set-cookie").to_s.lines(chomp: true).map { |line| line.split(";").first }.join("; ")
    refute_includes chunked_header, "better-auth.session_data="

    request_ctx = endpoint_context(auth, cookie: chunked_header)
    BetterAuth::Cookies.set_cookie_cache(request_ctx, {
      session: {"id" => "session-1", "token" => "token-1", "userId" => "user-1"},
      user: {"id" => "user-1", "email" => "chunked@example.com"}
    }, false)
    cleanup_header = request_ctx.response_headers.fetch("set-cookie")

    assert cleanup_header.lines.any? { |line| line.include?("better-auth.session_data.") && line.include?("Max-Age=0") }
    assert_includes cleanup_header, "better-auth.session_data="

    ordered = BetterAuth::SessionStore.join_chunks({
      "better-auth.session_data.10" => "bbb",
      "better-auth.session_data.0" => "aaa",
      "better-auth.session_data.1" => "ccc"
    })
    assert_equal "aaacccbbb", ordered
  end

  def test_account_cookie_chunking_mirrors_session_data_chunking
    auth = BetterAuth.auth(secret: SECRET, account: {store_account_cookie: true})
    ctx = endpoint_context(auth)
    BetterAuth::Cookies.set_account_cookie(ctx, {"providerId" => "github", "accountId" => "a" * 8_000})

    set_cookie = ctx.response_headers.fetch("set-cookie")
    assert set_cookie.lines.count { |line| line.start_with?("better-auth.account_data.") } > 1

    header = set_cookie.to_s.lines(chomp: true).map { |line| line.split(";").first }.join("; ")
    request_ctx = endpoint_context(auth, cookie: header)
    account = BetterAuth::Cookies.get_account_cookie(request_ctx)

    assert_equal "github", account.fetch("providerId")
    assert_equal "a" * 8_000, account.fetch("accountId")
  end

  private

  def with_env(overrides)
    overrides = overrides.transform_keys(&:to_s)
    original = overrides.each_key.to_h { |key| [key, ENV.key?(key) ? ENV.fetch(key) : :__missing__] }
    overrides.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    yield
  ensure
    original&.each do |key, value|
      if value == :__missing__
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  def endpoint_context(auth, cookie: nil)
    headers = {}
    headers["cookie"] = cookie if cookie
    BetterAuth::Endpoint::Context.new(
      path: "/test",
      method: "GET",
      query: {},
      body: {},
      params: {},
      headers: headers,
      context: auth.context
    )
  end
end
