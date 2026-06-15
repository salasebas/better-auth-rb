# frozen_string_literal: true

require "json"
require "rack/mock_request"
require_relative "../test_helper"

class BetterAuthAPITest < Minitest::Test
  SECRET = "test-secret-that-is-long-enough-for-validation"

  def test_endpoint_registry_exposes_path_and_options_metadata
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            echo: BetterAuth::Endpoint.new(path: "/echo", method: "POST", metadata: {scope: "server"}) { {ok: true} }
          }
        }
      ]
    )

    endpoint = auth.api.endpoints.fetch(:echo)

    assert_equal "/echo", endpoint.path
    assert_equal "POST", endpoint.options.fetch(:method)
    assert_equal "server", endpoint.options.fetch(:metadata).fetch(:scope)
  end

  def test_direct_api_runs_before_hooks_and_replaces_arrays
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            echo: BetterAuth::Endpoint.new(path: "/echo", method: "GET") do |ctx|
              {query: ctx.query}
            end
          }
        }
      ],
      hooks: {
        before: lambda do |ctx|
          next unless ctx.path == "/echo"

          {
            context: {
              query: {
                name: "from-hook",
                tags: ["hook"]
              }
            }
          }
        end
      }
    )

    response = auth.api.echo(query: {keep: "caller", tags: ["caller"]})

    assert_equal "from-hook", response[:query][:name]
    assert_equal "caller", response[:query][:keep]
    assert_equal ["hook"], response[:query][:tags]
  end

  def test_direct_api_before_hooks_can_set_body_params_headers_path_request_and_context
    request = Object.new
    endpoint_context = nil
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            inspect: BetterAuth::Endpoint.new(path: "/inspect", method: "POST") do |ctx|
              endpoint_context = ctx
              {
                body: ctx.body,
                params: ctx.params,
                headers: ctx.headers,
                path: ctx.path,
                request_equal: ctx.request.equal?(request),
                context_equal: ctx.context.equal?(auth.context)
              }
            end
          }
        }
      ],
      hooks: {
        before: lambda do |ctx|
          next unless ctx.path == "/inspect"

          {
            context: {
              body: {from_hook: true, tags: ["hook"]},
              params: {id: "from-hook"},
              headers: {"x_from_hook" => "yes"},
              path: "/inspect-mutated",
              request: request,
              context: auth.context
            }
          }
        end
      }
    )

    response = auth.api.inspect(
      body: {from_caller: true, tags: ["caller"]},
      params: {slug: "caller"},
      headers: {"x-from-caller" => "yes"}
    )

    assert_equal({from_caller: true, tags: ["hook"], from_hook: true}, response[:body])
    assert_equal({slug: "caller", id: "from-hook"}, response[:params])
    assert_equal "yes", response[:headers]["x-from-caller"]
    assert_equal "yes", response[:headers]["x-from-hook"]
    assert_equal "/inspect-mutated", response[:path]
    assert_equal true, response[:request_equal]
    assert_equal true, response[:context_equal]
    assert_same auth.context, endpoint_context.context
  end

  def test_direct_api_resets_runtime_context_before_endpoint_execution
    observed_session = :not_called
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            runtime: BetterAuth::Endpoint.new(path: "/runtime", method: "GET") do |ctx|
              observed_session = ctx.context.current_session
              {ok: true}
            end
          }
        }
      ]
    )
    auth.context.set_current_session({user_id: "stale"})

    assert_equal({ok: true}, auth.api.runtime)
    assert_nil observed_session
  end

  def test_direct_api_before_hook_can_short_circuit
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            echo: BetterAuth::Endpoint.new(path: "/echo", method: "GET") { {ok: true} }
          }
        }
      ],
      hooks: {
        before: ->(_ctx) { {before: true} }
      }
    )

    assert_equal({before: true}, auth.api.echo)
  end

  def test_direct_api_runs_after_hooks_and_last_response_wins
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            echo: BetterAuth::Endpoint.new(path: "/echo", method: "GET") { {hello: "world"} }
          },
          hooks: {
            after: [
              {
                matcher: ->(ctx) { ctx.path == "/echo" },
                handler: ->(_ctx) { {hello: "plugin"} }
              }
            ]
          }
        }
      ],
      hooks: {
        after: ->(_ctx) { {hello: "user"} }
      }
    )

    assert_equal({hello: "plugin"}, auth.api.echo)
  end

  def test_direct_api_can_return_rack_response_headers_and_status
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            cookies: BetterAuth::Endpoint.new(path: "/cookies", method: "POST") do |ctx|
              ctx.set_status(201)
              ctx.set_cookie("session", "endpoint")
              {ok: true}
            end
          },
          hooks: {
            after: [
              {
                matcher: ->(ctx) { ctx.path == "/cookies" },
                handler: lambda do |ctx|
                  ctx.set_header("x-after", "yes")
                  ctx.set_cookie("after", "hook")
                  nil
                end
              }
            ]
          }
        }
      ]
    )

    data = auth.api.cookies(return_headers: true, return_status: true)

    assert_equal 201, data[:status]
    assert_equal({ok: true}, data[:response])
    assert_equal "yes", data[:headers]["x-after"]
    assert_includes data[:headers]["set-cookie"], "session=endpoint"
    assert_includes data[:headers]["set-cookie"], "after=hook"
    assert_equal ["session=endpoint", "after=hook"], data[:headers]["set-cookie"].split("\n")

    status, headers, body = auth.api.cookies(as_response: true)
    assert_equal 201, status
    assert_includes headers["set-cookie"], "session=endpoint"
    assert_equal({ok: true}, JSON.parse(body.join, symbolize_names: true))
  end

  def test_direct_api_as_response_returns_response_object_that_can_be_used_as_rack_tuple
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            response: BetterAuth::Endpoint.new(path: "/response", method: "GET") do |ctx|
              ctx.set_status(201)
              ctx.set_header("x-test", "yes")
              {ok: true}
            end
          }
        }
      ]
    )

    response = auth.api.response(as_response: true)
    status, headers, body = response

    assert_instance_of BetterAuth::Response, response
    assert_equal 201, response.status
    assert_equal 201, status
    assert_equal "yes", response.headers.fetch("x-test")
    assert_equal "yes", headers.fetch("x-test")
    assert_equal({ok: true}, JSON.parse(body.join, symbolize_names: true))
    assert_equal({ok: true}, response.json(symbolize_names: true))
  end

  def test_direct_api_uses_request_context_and_returns_rack_response
    seen_context = nil
    request = Rack::Request.new(
      Rack::MockRequest.env_for(
        "/from-request",
        "REQUEST_METHOD" => "POST",
        "HTTP_X_API_CLIENT" => "rack"
      )
    )
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            from_request: BetterAuth::Endpoint.new(path: "/from-request", method: ["POST", "GET"]) do |ctx|
              seen_context = ctx
              ctx.set_cookie("session", "value")
              {method: ctx.method, header: ctx.headers["x-api-client"], same_request: ctx.request.equal?(request)}
            end
          },
          hooks: {
            after: [
              {
                matcher: ->(ctx) { ctx.path == "/from-request" },
                handler: lambda do |ctx|
                  ctx.set_cookie("after", "hook")
                  nil
                end
              }
            ]
          }
        }
      ]
    )

    status, headers, body = auth.api.from_request(request: request)

    assert_equal 200, status
    assert_includes headers["set-cookie"], "session=value"
    assert_includes headers["set-cookie"], "after=hook"
    assert_equal({method: "POST", header: "rack", same_request: true}, JSON.parse(body.join, symbolize_names: true))
    assert_same request, seen_context.request
  end

  def test_direct_api_errors_throw_unless_as_response_is_requested
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            fail: BetterAuth::Endpoint.new(path: "/fail", method: "GET") do |ctx|
              raise ctx.error("FORBIDDEN", message: "Blocked")
            end
          }
        }
      ]
    )

    assert_raises(BetterAuth::APIError) { auth.api.fail }

    status, _headers, body = auth.api.fail(as_response: true)
    assert_equal 403, status
    assert_equal({code: "FORBIDDEN", message: "Blocked"}, JSON.parse(body.join, symbolize_names: true))
  end

  def test_direct_api_error_preserves_headers_accumulated_before_raise
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            fail: BetterAuth::Endpoint.new(path: "/fail", method: "POST") do |ctx|
              ctx.set_cookie("session", "", max_age: 0)
              ctx.set_cookie("session_data", "", max_age: 0)
              raise ctx.error("UNAUTHORIZED", message: "cleared")
            end
          }
        }
      ]
    )

    error = assert_raises(BetterAuth::APIError) { auth.api.fail }

    assert_equal "UNAUTHORIZED", error.status
    assert_includes error.headers.fetch("set-cookie"), "session="
    assert_includes error.headers.fetch("set-cookie"), "session_data="
    assert_includes error.headers.fetch("set-cookie"), "Max-Age=0"

    status, headers, _body = auth.api.fail(as_response: true)
    assert_equal 401, status
    assert_includes headers.fetch("set-cookie"), "session="
    assert_includes headers.fetch("set-cookie"), "session_data="
  end

  def test_direct_api_error_merges_accumulated_headers_with_explicit_error_headers
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            redirect: BetterAuth::Endpoint.new(path: "/redirect", method: "POST") do |ctx|
              ctx.set_cookie("session", "", max_age: 0)
              raise BetterAuth::APIError.new("FOUND", message: "redirect", headers: {"location" => "/login"})
            end
          }
        }
      ]
    )

    error = assert_raises(BetterAuth::APIError) { auth.api.redirect }

    assert_equal "FOUND", error.status
    assert_equal "/login", error.headers.fetch("location")
    assert_includes error.headers.fetch("set-cookie"), "session="

    status, headers, _body = auth.api.redirect(as_response: true)
    assert_equal 302, status
    assert_equal "/login", headers.fetch("location")
    assert_includes headers.fetch("set-cookie"), "session="
  end

  def test_after_hook_error_preserves_headers_accumulated_by_endpoint_and_hook
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            fail_after: BetterAuth::Endpoint.new(path: "/fail-after", method: "POST") do |ctx|
              ctx.set_cookie("endpoint", "value")
              {ok: true}
            end
          },
          hooks: {
            after: [
              {
                matcher: ->(ctx) { ctx.path == "/fail-after" },
                handler: lambda do |ctx|
                  ctx.set_cookie("after", "value")
                  raise BetterAuth::APIError.new("BAD_REQUEST", message: "from after", headers: {"x-error" => "yes"})
                end
              }
            ]
          }
        }
      ]
    )

    error = assert_raises(BetterAuth::APIError) { auth.api.fail_after }

    assert_equal "BAD_REQUEST", error.status
    assert_equal "yes", error.headers.fetch("x-error")
    assert_includes error.headers.fetch("set-cookie"), "endpoint=value"
    assert_includes error.headers.fetch("set-cookie"), "after=value"

    status, headers, _body = auth.api.fail_after(as_response: true)
    assert_equal 400, status
    assert_equal "yes", headers.fetch("x-error")
    assert_includes headers.fetch("set-cookie"), "endpoint=value"
    assert_includes headers.fetch("set-cookie"), "after=value"
  end

  def test_direct_api_before_hook_can_short_circuit_with_rack_tuple
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            echo: BetterAuth::Endpoint.new(path: "/echo", method: "GET") { {ok: true} }
          }
        }
      ],
      hooks: {
        before: lambda do |_ctx|
          [418, {"content-type" => "text/plain", "x-short-circuit" => "rack"}, ["teapot"]]
        end
      }
    )

    status, headers, body = auth.api.echo(as_response: true)

    assert_equal 418, status
    assert_equal "rack", headers.fetch("x-short-circuit")
    assert_equal ["teapot"], body
  end

  def test_direct_api_before_hook_can_short_circuit_with_endpoint_result
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            echo: BetterAuth::Endpoint.new(path: "/echo", method: "GET") { {ok: true} }
          }
        }
      ],
      hooks: {
        before: lambda do |ctx|
          BetterAuth::Endpoint::Result.new(response: {from: "result"}, status: 202, headers: {"x-result" => "yes"})
        end
      }
    )

    data = auth.api.echo(return_headers: true, return_status: true)

    assert_equal 202, data[:status]
    assert_equal({from: "result"}, data[:response])
    assert_equal "yes", data[:headers]["x-result"]
  end

  def test_direct_api_before_hook_can_short_circuit_with_api_error_response
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            echo: BetterAuth::Endpoint.new(path: "/echo", method: "GET") { {ok: true} }
          }
        }
      ],
      hooks: {
        before: lambda do |_ctx|
          raise BetterAuth::APIError.new("FORBIDDEN", message: "short-circuit", headers: {"x-error" => "before"})
        end
      }
    )

    error = assert_raises(BetterAuth::APIError) { auth.api.echo }
    assert_equal "FORBIDDEN", error.status
    assert_equal "before", error.headers.fetch("x-error")

    status, headers, body = auth.api.echo(as_response: true)
    assert_equal 403, status
    assert_equal "before", headers.fetch("x-error")
    assert_equal({code: "FORBIDDEN", message: "short-circuit"}, JSON.parse(body.join, symbolize_names: true))
  end

  def test_disabled_paths_return_not_found_for_rack_but_remain_callable_via_direct_api
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      disabled_paths: ["/blocked"],
      plugins: [
        {
          id: "test",
          endpoints: {
            blocked: BetterAuth::Endpoint.new(path: "/blocked", method: "GET") { {ok: true} }
          }
        }
      ]
    )

    assert_equal({ok: true}, auth.api.blocked)
    assert_equal 404, auth.call(BetterAuthTestHelpers.json_rack_env("GET", "/api/auth/blocked")).first
  end

  def test_direct_api_error_supports_custom_response_headers_on_known_status_codes
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "test",
          endpoints: {
            custom_error: BetterAuth::Endpoint.new(path: "/custom-error", method: "GET") do |_ctx|
              raise BetterAuth::APIError.new("NOT_FOUND", message: "custom", headers: {"x-custom" => "yes"})
            end
          }
        }
      ]
    )

    error = assert_raises(BetterAuth::APIError) { auth.api.custom_error }
    assert_equal "NOT_FOUND", error.status
    assert_equal 404, error.status_code
    assert_equal "yes", error.headers.fetch("x-custom")

    status, headers, = auth.api.custom_error(as_response: true)
    assert_equal 404, status
    assert_equal "yes", headers.fetch("x-custom")
  end
end
