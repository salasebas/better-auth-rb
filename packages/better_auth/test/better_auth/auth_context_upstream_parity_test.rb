# frozen_string_literal: true

require "json"
require "stringio"
require_relative "../test_helper"

class BetterAuthAuthContextUpstreamParityTest < Minitest::Test
  SECRET = "test-secret-that-is-long-enough-for-validation"

  def test_plugin_init_trusted_origins_merge_with_user_config
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      trusted_origins: ->(_request) { ["https://user-dynamic.com"] },
      plugins: [
        {
          id: "trusted-origin-static",
          init: ->(_context) { {options: {trusted_origins: ["https://plugin-static.com"]}} }
        },
        {
          id: "trusted-origin-dynamic",
          init: ->(_context) { {options: {trusted_origins: ->(_request) { ["https://plugin-fn.com"] }}} }
        },
        {
          id: "trusted-origin-test",
          endpoints: {
            trusted_origin: BetterAuth::Endpoint.new(path: "/trusted-origin", method: "GET") do |ctx|
              ctx.json({trusted: ctx.context.trusted_origin?(ctx.query["url"])})
            end
          }
        }
      ]
    )

    assert_trusted_origin auth, "https://user-dynamic.com"
    assert_trusted_origin auth, "https://plugin-static.com"
    assert_trusted_origin auth, "https://plugin-fn.com"
    refute_trusted_origin auth, "https://unknown.com"
  end

  def test_empty_secret_falls_back_to_test_default_secret
    with_env("RACK_ENV" => "test", "BETTER_AUTH_SECRET" => nil, "AUTH_SECRET" => nil) do
      auth = BetterAuth.auth(base_url: "http://localhost:3000", secret: "")

      assert_equal BetterAuth::Configuration::DEFAULT_SECRET, auth.context.secret
    end
  end

  def test_default_secret_is_rejected_in_production
    with_env("RACK_ENV" => "production", "BETTER_AUTH_SECRET" => nil, "AUTH_SECRET" => nil) do
      error = assert_raises(BetterAuth::Error) do
        BetterAuth.auth(
          base_url: "http://localhost:3000",
          secret: BetterAuth::Configuration::DEFAULT_SECRET
        )
      end

      assert_includes error.message, "default secret"
    end
  end

  def test_stateless_cookie_cache_max_age_matches_session_expiry
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: nil,
      session: {expires_in: 1234}
    )

    assert_equal 1234, auth.options.session.dig(:cookie_cache, :max_age)
  end

  def test_cookie_cache_refresh_true_uses_twenty_percent_of_max_age
    payload = {"updatedAt" => ((Time.now.to_f - 201) * 1000).to_i}

    assert BetterAuth::Session.send(
      :should_refresh_cookie_cache?,
      {refresh_cache: true, max_age: 1000},
      payload
    )
  end

  def test_context_exposes_password_utilities_and_custom_callbacks
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      email_and_password: {
        enabled: true,
        min_password_length: 12,
        max_password_length: 256,
        password: {
          hash: ->(password) { "custom:#{password}" },
          verify: ->(password, digest) { digest == "custom:#{password}" }
        }
      }
    )

    password = auth.context.password

    assert_equal 12, password.fetch(:config).fetch(:min_password_length)
    assert_equal 256, password.fetch(:config).fetch(:max_password_length)
    assert_equal "custom:password123", password.fetch(:hash).call("password123")
    assert_equal true, password.fetch(:verify).call(password: "password123", hash: "custom:password123")
    assert_equal true, password.fetch(:check_password).call("long-password")
    assert_equal false, password.fetch(:check_password).call("short")
  end

  def test_dynamic_base_url_is_rejected_with_actionable_migration
    error = assert_raises(BetterAuth::Error) do
      BetterAuth.auth(secret: SECRET, base_url: {allowed_hosts: ["tenant.example.com"]})
    end

    assert_includes error.message, "serving_origins"
  end

  def test_serving_origin_selects_request_base_and_is_trusted
    captured = []
    auth = BetterAuth.auth(
      secret: SECRET,
      base_url: "https://auth.example.com",
      serving_origins: ["https://*.example.com"],
      advanced: {trusted_proxy_headers: true},
      plugins: [capture_context_plugin(captured)]
    )

    status, = auth.call(rack_env(
      "GET",
      "/api/auth/capture-context",
      headers: {
        "HTTP_X_FORWARDED_HOST" => "tenant.example.com",
        "HTTP_X_FORWARDED_PROTO" => "https",
        "HTTP_HOST" => "internal.example"
      }
    ))

    assert_equal 200, status
    assert_equal "https://tenant.example.com/api/auth", captured.first.fetch(:base_url)
    assert_equal "https://auth.example.com", captured.first.fetch(:options_base_url)
    assert_includes captured.first.fetch(:trusted_origins), "https://*.example.com"
  end

  def test_untrusted_host_falls_back_to_canonical_without_becoming_trusted
    captured = []
    auth = BetterAuth.auth(
      secret: SECRET,
      base_url: "https://auth.example.com",
      trusted_origins: ["https://frontend.example.com"],
      plugins: [capture_context_plugin(captured)]
    )

    auth.call(rack_env(
      "GET",
      "/api/auth/capture-context",
      headers: {"HTTP_HOST" => "frontend.example.com", "rack.url_scheme" => "https"}
    ))

    assert_equal "https://auth.example.com/api/auth", captured.first.fetch(:base_url)
    assert_includes captured.first.fetch(:trusted_origins), "https://frontend.example.com"
    refute_includes auth.options.serving_origins, "https://frontend.example.com"
  end

  def test_forwarded_headers_require_explicit_proxy_trust
    captured = []
    auth = BetterAuth.auth(
      secret: SECRET,
      base_url: "https://auth.example.com",
      serving_origins: ["https://proxy.example.com"],
      plugins: [capture_context_plugin(captured)]
    )

    auth.call(rack_env(
      "GET",
      "/api/auth/capture-context",
      headers: {
        "HTTP_X_FORWARDED_HOST" => "proxy.example.com",
        "HTTP_X_FORWARDED_PROTO" => "https",
        "HTTP_HOST" => "attacker.example",
        "rack.url_scheme" => "https"
      }
    ))

    assert_equal "https://auth.example.com/api/auth", captured.first.fetch(:base_url)
  end

  def test_direct_api_uses_same_serving_origin_rules_and_clears_runtime
    captured = []
    auth = BetterAuth.auth(
      secret: SECRET,
      base_url: "https://auth.example.com",
      serving_origins: ["https://tenant.example.com"],
      plugins: [capture_context_plugin(captured)]
    )

    auth.api.capture_context(headers: {"host" => "attacker.example"})
    auth.api.capture_context(headers: {"host" => "tenant.example.com"})

    assert_equal "https://auth.example.com/api/auth", captured[0].fetch(:base_url)
    assert_equal "https://tenant.example.com/api/auth", captured[1].fetch(:base_url)
    assert_equal "https://auth.example.com/api/auth", auth.context.base_url
    assert_equal "https://auth.example.com", auth.options.base_url
  end

  def test_parallel_serving_origins_do_not_bleed_between_requests
    ready = Queue.new
    release = Queue.new
    captured = []
    mutex = Mutex.new
    auth = BetterAuth.auth(
      secret: SECRET,
      base_url: "https://auth.example.com",
      serving_origins: ["https://tenant-a.example.com", "https://tenant-b.example.com"],
      plugins: [
        {
          id: "parallel-serving-origin",
          endpoints: {
            parallel_serving_origin: BetterAuth::Endpoint.new(path: "/parallel-serving-origin", method: "GET") do |ctx|
              ready << true
              release.pop
              mutex.synchronize do
                captured << [ctx.context.base_url, ctx.context.canonical_base_url, ctx.context.options.base_url]
              end
              ctx.json({ok: true})
            end
          }
        }
      ]
    )

    threads = ["tenant-a.example.com", "tenant-b.example.com"].map do |host|
      Thread.new do
        auth.call(rack_env(
          "GET",
          "/api/auth/parallel-serving-origin",
          headers: {"HTTP_HOST" => host, "rack.url_scheme" => "https"}
        ))
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:value)

    assert_equal(
      [
        ["https://tenant-a.example.com/api/auth", "https://auth.example.com/api/auth", "https://auth.example.com"],
        ["https://tenant-b.example.com/api/auth", "https://auth.example.com/api/auth", "https://auth.example.com"]
      ],
      captured.sort
    )
    assert_equal "https://auth.example.com/api/auth", auth.context.base_url
  end

  def test_direct_api_redirect_errors_include_headers_set_before_redirect
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "redirect-test",
          endpoints: {
            redirect_with_header: BetterAuth::Endpoint.new(path: "/redirect-with-header", method: "GET") do |ctx|
              ctx.set_header("key", "value")
              raise ctx.redirect("/test")
            end
          }
        }
      ]
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.redirect_with_header
    end

    assert_equal "FOUND", error.status
    assert_equal "/test", error.headers.fetch("location")
    assert_equal "value", error.headers.fetch("key")
  end

  def test_router_blocks_endpoints_marked_server_scope
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "scope-test",
          endpoints: {
            server_scoped: BetterAuth::Endpoint.new(path: "/server-scoped", method: "GET", metadata: {scope: "server"}) do
              "ok"
            end
          }
        }
      ]
    )

    assert_equal "ok", auth.api.server_scoped

    status, _headers, body = auth.call(rack_env("GET", "/api/auth/server-scoped"))

    assert_equal 403, status
    assert_equal({"error" => "Forbidden"}, JSON.parse(body.join))
  end

  def test_direct_api_server_call_hooks_cookies_and_error_chaining_match_upstream
    auth = call_parity_auth

    assert_equal({success: "true"}, auth.api.call_test)
    assert_equal({before: "test"}, auth.api.call_test(query: {test_before_hook: "true"}))
    assert_equal({success: "context-changed"}, auth.api.call_test(query: {test_context: "context-changed"}))
    assert_equal({after: "test"}, auth.api.call_test(query: {test_after_hook: "true"}))
    assert_equal({before: "global"}, auth.api.call_test(query: {test_before_global: "true"}))
    assert_equal({after: "global"}, auth.api.call_test(query: {test_after_global: "true"}))

    response = auth.api.call_cookies(
      body: {cookies: [{name: "test-cookie", value: "test-value"}]},
      query: {test_after_hook: "true"},
      return_headers: true
    )
    set_cookie = response.fetch(:headers).fetch("set-cookie")
    assert_includes set_cookie, "test-cookie=test-value"
    assert_includes set_cookie, "after=test"

    status, _headers, body = auth.api.call_test(as_response: true)
    assert_equal 200, status
    assert_equal({"success" => "true"}, JSON.parse(body.join))

    api_error = assert_raises(BetterAuth::APIError) do
      auth.api.call_throw(query: {message: "throw-api-error"})
    end
    assert_equal "BAD_REQUEST", api_error.status
    assert_equal "Test error", api_error.message

    generic_error = assert_raises(StandardError) do
      auth.api.call_throw(query: {message: "throw-error"})
    end
    assert_equal "Test error", generic_error.message

    redirect = assert_raises(BetterAuth::APIError) do
      auth.api.call_throw(query: {message: "throw redirect"})
    end
    assert_equal "FOUND", redirect.status
    assert_equal "/test", redirect.headers.fetch("location")

    after_error = assert_raises(BetterAuth::APIError) do
      auth.api.call_throw(query: {message: "throw-after-hook"})
    end
    assert_equal "BAD_REQUEST", after_error.status
    assert_includes after_error.message, "from after hook"

    chained_error = assert_raises(BetterAuth::APIError) do
      auth.api.call_throw(query: {message: "throw-chained-hook"})
    end
    assert_equal "BAD_REQUEST", chained_error.status
    assert_includes chained_error.message, "from chained hook 2"
  end

  def test_global_before_hook_can_change_sign_up_email_context
    auth = call_parity_auth

    response = auth.api.sign_up_email(
      body: {
        email: "my-email@test.com",
        password: "password123",
        name: "Test"
      }
    )

    assert_equal "changed@email.com", response.fetch(:user).fetch("email")
  end

  def test_secret_resolves_from_better_auth_secret_and_auth_secret_env_aliases
    with_env("RACK_ENV" => "test", "BETTER_AUTH_SECRET" => "env-better-auth-secret-with-enough-length", "AUTH_SECRET" => nil) do
      auth = BetterAuth.auth(base_url: "http://localhost:3000")

      assert_equal "env-better-auth-secret-with-enough-length", auth.context.secret
    end

    with_env("RACK_ENV" => "test", "BETTER_AUTH_SECRET" => nil, "AUTH_SECRET" => "legacy-auth-secret-with-enough-length") do
      auth = BetterAuth.auth(base_url: "http://localhost:3000")

      assert_equal "legacy-auth-secret-with-enough-length", auth.context.secret
    end
  end

  def test_rate_limit_disabled_normalizes_enabled_false
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      rate_limit: {enabled: false}
    )

    assert_equal false, auth.context.rate_limit_config.fetch(:enabled)
  end

  def test_context_exposes_logger_app_name_telemetry_and_database_hooks
    hooks_called = []
    logger = ->(level, message) { hooks_called << [level, message] }
    database_hooks = {
      user: {
        create: {
          before: ->(data, _context) { data.merge("hooked" => true) }
        }
      }
    }
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      app_name: "Parity App",
      logger: logger,
      telemetry: {enabled: false, debug: true},
      database_hooks: database_hooks
    )

    assert_equal "Parity App", auth.context.app_name
    assert_same logger, auth.context.logger
    assert_equal false, auth.options.telemetry.fetch(:enabled)
    assert_equal true, auth.options.telemetry.fetch(:debug)
    assert_equal database_hooks, auth.options.database_hooks

    auth.context.logger.call(:info, "context logger works")
    assert_equal [[:info, "context logger works"]], hooks_called
  end

  def test_plugin_init_does_not_overwrite_explicit_user_session_options
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      session: {expires_in: 999, update_age: 111, fresh_age: 222},
      plugins: [
        {
          id: "session-defaults",
          init: ->(_context) {
            {options: {session: {expires_in: 1, update_age: 2, fresh_age: 3, cookie_cache: {enabled: false}}}}
          }
        }
      ]
    )

    assert_equal 999, auth.options.session.fetch(:expires_in)
    assert_equal 111, auth.options.session.fetch(:update_age)
    assert_equal 222, auth.options.session.fetch(:fresh_age)
    assert_equal false, auth.options.session.dig(:cookie_cache, :enabled)
  end

  def test_plugin_context_attributes_are_exposed_on_context
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "context-plugin",
          init: ->(_context) { {context: {plugin_marker: "present", adapter: :should_not_apply}} }
        }
      ]
    )

    assert_equal "present", auth.context.plugin_marker
    refute_equal :should_not_apply, auth.context.adapter
  end

  def test_ruby_plugin_presence_is_checked_via_options_plugins_not_upstream_has_plugin
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [{id: "parity-plugin", endpoints: {}}]
    )

    assert auth.options.plugins.any? { |plugin| plugin.id == "parity-plugin" }
    refute_respond_to auth.context, :has_plugin
  end

  private

  def assert_trusted_origin(auth, url)
    assert_equal true, trusted_origin_response(auth, url)
  end

  def refute_trusted_origin(auth, url)
    assert_equal false, trusted_origin_response(auth, url)
  end

  def trusted_origin_response(auth, url)
    status, _headers, body = auth.call(rack_env("GET", "/api/auth/trusted-origin", query: URI.encode_www_form(url: url)))
    assert_equal 200, status

    JSON.parse(body.join).fetch("trusted")
  end

  def rack_env(method, path, query: "", headers: {})
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => query,
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "3000",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(""),
      "CONTENT_LENGTH" => "0"
    }.merge(headers)
  end

  def capture_context_plugin(captured)
    {
      id: "capture-context",
      endpoints: {
        capture_context: BetterAuth::Endpoint.new(path: "/capture-context", method: "GET") do |ctx|
          captured << {
            base_url: ctx.context.base_url,
            options_base_url: ctx.context.options.base_url,
            trusted_origins: ctx.context.trusted_origins,
            cookie_domain: ctx.context.auth_cookies[:session_token].attributes[:domain]
          }
          ctx.json({ok: true})
        end
      }
    }
  end

  def call_parity_auth
    BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      email_and_password: {enabled: true},
      plugins: [
        {
          id: "call-parity",
          endpoints: {
            call_test: BetterAuth::Endpoint.new(path: "/test", method: "GET") do |ctx|
              ctx.json({success: ctx.query[:message] || ctx.query["message"] || "true"})
            end,
            call_cookies: BetterAuth::Endpoint.new(path: "/test/cookies", method: "POST") do |ctx|
              Array(ctx.body[:cookies] || ctx.body["cookies"]).each do |cookie|
                ctx.set_cookie(cookie[:name] || cookie["name"], cookie[:value] || cookie["value"])
              end
              ctx.json({success: true})
            end,
            call_throw: BetterAuth::Endpoint.new(path: "/test/throw", method: "GET") do |ctx|
              message = ctx.query[:message] || ctx.query["message"]
              case message
              when "throw-api-error"
                raise BetterAuth::APIError.new("BAD_REQUEST", message: "Test error")
              when "throw-error"
                raise StandardError, "Test error"
              when "throw redirect"
                raise ctx.redirect("/test")
              else
                raise BetterAuth::APIError.new("BAD_REQUEST", message: message)
              end
            end
          },
          hooks: {
            before: [
              {
                matcher: ->(ctx) { ctx.path == "/test" },
                handler: lambda do |ctx|
                  if ctx.query[:test_before_hook] || ctx.query["test_before_hook"]
                    next ctx.json({before: "test"})
                  end
                  if (message = ctx.query[:test_context] || ctx.query["test_context"])
                    next({context: {query: {message: message}}})
                  end
                end
              }
            ],
            after: [
              {
                matcher: ->(ctx) { ctx.path == "/test" },
                handler: lambda do |ctx|
                  next unless ctx.query[:test_after_hook] || ctx.query["test_after_hook"]

                  ctx.json({after: "test"})
                end
              },
              {
                matcher: ->(ctx) { ctx.path == "/test/cookies" },
                handler: lambda do |ctx|
                  next unless ctx.query[:test_after_hook] || ctx.query["test_after_hook"]

                  ctx.set_cookie("after", "test")
                  nil
                end
              },
              {
                matcher: lambda do |ctx|
                  message = ctx.query[:message] || ctx.query["message"]
                  ctx.path == "/test/throw" && ["throw-after-hook", "throw-chained-hook"].include?(message)
                end,
                handler: lambda do |ctx|
                  message = ctx.query[:message] || ctx.query["message"]
                  if message == "throw-chained-hook"
                    raise BetterAuth::APIError.new("BAD_REQUEST", message: "from chained hook 1")
                  end
                  if ctx.returned.is_a?(BetterAuth::APIError)
                    raise ctx.error("BAD_REQUEST", message: "from after hook")
                  end
                end
              },
              {
                matcher: ->(ctx) { ctx.path == "/test/throw" && (ctx.query[:message] || ctx.query["message"]) == "throw-chained-hook" },
                handler: lambda do |ctx|
                  next unless ctx.returned.is_a?(BetterAuth::APIError)

                  raise BetterAuth::APIError.new("BAD_REQUEST", message: ctx.returned.message.sub("1", "2"))
                end
              }
            ]
          }
        }
      ],
      hooks: {
        before: lambda do |ctx|
          if ctx.path == "/sign-up/email"
            next({context: {body: {email: "changed@email.com"}}})
          end
          next ctx.json({before: "global"}) if ctx.query[:test_before_global] || ctx.query["test_before_global"]
        end,
        after: lambda do |ctx|
          next unless ctx.query[:test_after_global] || ctx.query["test_after_global"]

          ctx.json({after: "global"})
        end
      }
    )
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end

    yield
  ensure
    previous.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
