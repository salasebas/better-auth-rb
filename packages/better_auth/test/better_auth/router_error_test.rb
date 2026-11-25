# frozen_string_literal: true

require "rack/mock"
require_relative "../test_helper"

class BetterAuthRouterErrorTest < Minitest::Test
  def test_unexpected_handler_error_returns_empty_500_and_runs_response_hook
    error = RuntimeError.new("endpoint failure")
    seen = []
    on_response = lambda do |response, _ctx|
      seen << response
      nil
    end
    auth = build_auth(
      endpoint: ->(_ctx) { raise error },
      plugin: {on_response: on_response}
    )
    env = request_env

    status, headers, body = auth.call(env)

    assert_equal 500, status
    refute headers.key?("content-type")
    assert_empty body.join
    assert_equal [500], seen.map(&:first)
    assert_includes env.fetch("rack.errors").string, error.message
    assert_same error, assert_raises(RuntimeError) { auth.api.probe }
  end

  def test_error_callback_receives_auth_context_and_its_return_value_is_ignored
    error = RuntimeError.new("endpoint failure")
    received = []
    auth = build_auth(
      endpoint: ->(_ctx) { raise error },
      on_api_error: {on_error: lambda { |failure, ctx|
        received << [failure, ctx]
        [418, {}, ["ignored"]]
      }}
    )

    assert_equal [500, {}, []], auth.call(request_env)
    assert_equal [[error, auth.context]], received
  end

  def test_throw_takes_precedence_over_callback
    error = RuntimeError.new("endpoint failure")
    auth = build_auth(
      endpoint: ->(_ctx) { raise error },
      on_api_error: {throw: true, on_error: ->(*) { flunk "callback ran" }}
    )

    assert_same error, assert_raises(RuntimeError) { auth.call(request_env) }
  end

  def test_callback_exception_propagates_or_becomes_an_api_error_response
    unexpected = RuntimeError.new("callback failure")
    api_error = BetterAuth::APIError.new("BAD_REQUEST", message: "callback rejected request")
    endpoint = ->(_ctx) { raise "endpoint failure" }
    raising = build_auth(endpoint: endpoint, on_api_error: {on_error: ->(*) { raise unexpected }})
    rejecting = build_auth(endpoint: endpoint, on_api_error: {on_error: ->(*) { raise api_error }})

    assert_same unexpected, assert_raises(RuntimeError) { raising.call(request_env) }
    status, _headers, body = rejecting.call(request_env)
    assert_equal 400, status
    assert_equal api_error.to_h, JSON.parse(body.join, symbolize_names: true)
  end

  def test_only_api_errors_raised_outside_the_endpoint_result_reach_the_boundary
    error = BetterAuth::APIError.new("FORBIDDEN", message: "denied")
    endpoint = build_auth(endpoint: ->(_ctx) { raise error }, on_api_error: {on_error: ->(*) { flunk "endpoint error reached boundary" }})
    received = []
    before = build_auth(hooks: {before: ->(_ctx) { raise error }}, on_api_error: {on_error: ->(failure, _ctx) { received << failure }})

    assert_equal 403, endpoint.call(request_env).first
    assert_equal 403, before.call(request_env).first
    assert_equal [error], received
    throwing = build_auth(hooks: {before: ->(_ctx) { raise error }}, on_api_error: {throw: true})
    assert_equal 403, throwing.call(request_env).first
  end

  def test_origin_check_error_reaches_error_callback
    received = []
    auth = build_auth(on_api_error: {on_error: ->(failure, _ctx) { received << failure }})
    env = request_env(method: "POST", input: '{"callbackURL":"https://outside.example/welcome"}')

    assert_equal 403, auth.call(env).first
    assert_equal ["FORBIDDEN"], received.map(&:status)
  end

  def test_redirect_from_before_hook_skips_error_handling
    auth = build_auth(
      hooks: {before: lambda { |ctx|
        ctx.set_cookie("notice", "saved")
        raise ctx.redirect("/next")
      }},
      on_api_error: {throw: true, on_error: ->(*) { flunk "callback ran" }}
    )

    status, headers, _body = auth.call(request_env)

    assert_equal 302, status
    assert_equal "/next", headers["location"]
    assert_equal "notice=saved", headers["set-cookie"]
  end

  def test_endpoint_redirect_serializes_each_cookie_once
    auth = build_auth(
      endpoint: lambda { |ctx|
        ctx.set_cookie("notice", "saved")
        ctx.set_cookie("other", "value")
        raise ctx.redirect("/next")
      },
      hooks: {after: ->(ctx) { ctx.returned }}
    )

    status, headers, _body = auth.call(request_env)

    assert_equal 302, status
    assert_equal ["notice=saved", "other=value"], headers.fetch("set-cookie")
  end

  def test_after_hook_can_update_and_reraise_a_redirect
    auth = build_auth(
      endpoint: ->(ctx) { raise ctx.redirect("/next") },
      hooks: {after: lambda { |ctx|
        error = ctx.returned
        error.headers["location"] = "/replacement"
        raise error
      }}
    )

    status, headers, _body = auth.call(request_env)

    assert_equal 302, status
    assert_equal "/replacement", headers.fetch("location")
  end

  def test_plugin_endpoint_can_use_dispatch_as_its_api_key
    endpoint = BetterAuth::Endpoint.new(path: "/plugin-dispatch", method: "GET") { {plugin: "dispatch"} }
    auth = build_auth(plugins: [{id: "custom", endpoints: {dispatch: endpoint}}])

    status, _headers, body = auth.call(request_env)
    assert_equal 200, status
    assert_equal({"ok" => true}, JSON.parse(body.join))
    assert_equal({plugin: "dispatch"}, auth.api.dispatch)
    assert_equal({ok: true}, auth.api.probe)
  end

  def test_malformed_json_reaches_error_callback_as_bad_request
    received = []
    auth = build_auth(on_api_error: {on_error: ->(failure, _ctx) { received << failure }})

    status, _headers, body = auth.call(request_env(method: "POST", input: "not json"))

    assert_equal 400, status
    assert_equal({"code" => "BAD_REQUEST", "message" => "Invalid JSON in request body"}, JSON.parse(body.join))
    assert_equal ["BAD_REQUEST"], received.map(&:status)
  end

  def test_empty_json_request_reaches_endpoint_without_body_data
    auth = build_auth(endpoint: ->(ctx) { {received: ctx.body} })

    status, _headers, body = auth.call(request_env(method: "POST", input: ""))

    assert_equal 200, status
    assert_equal({"received" => {}}, JSON.parse(body.join))
  end

  def test_transport_hooks_run_outside_error_boundary
    error = RuntimeError.new("transport hook failure")
    [:on_request, :on_response].each do |hook|
      auth = build_auth(plugin: {hook => ->(*) { raise error }}, on_api_error: {on_error: ->(*) { flunk "callback ran" }})

      assert_same error, assert_raises(RuntimeError) { auth.call(request_env) }
    end
  end

  def test_first_truthy_response_hook_result_stops_the_chain_even_without_a_response
    [nil, [202, {}, ["replacement"]]].each do |replacement|
      auth = build_auth(
        plugin: {on_response: ->(*) { replacement ? {response: replacement} : {} }},
        plugins: [{id: "later", on_response: ->(*) { flunk "later hook ran" }}]
      )

      assert_equal replacement || [200, {"content-type" => "application/json"}, ['{"ok":true}']], auth.call(request_env)
    end
  end

  def test_before_matcher_failure_is_logged_and_replaced_with_a_generic_api_error
    logs = []
    auth = build_auth(
      logger: ->(level, message) { logs << [level, message] },
      plugin: {hooks: {before: [{matcher: ->(_ctx) { raise "private matcher detail" }, handler: ->(_ctx) { flunk "hook ran" }}]}}
    )

    error = assert_raises(BetterAuth::APIError) { auth.api.probe }
    assert_equal "An error occurred during hook matcher execution. Check the logs for more details.", error.message
    assert_equal "INTERNAL_SERVER_ERROR", error.status
    status, _headers, body = auth.call(request_env)
    assert_equal 500, status
    assert_equal error.to_h, JSON.parse(body.join, symbolize_names: true)
    assert logs.any? { |level, message| level == :error && message.include?("plugin:probe hook matcher execution") && message.include?("private matcher detail") }
    assert logs.any? { |level, message| level == :error && message.start_with?("INTERNAL_SERVER_ERROR") }
  end

  def test_primitive_before_hook_result_is_ignored
    [true, "continue", 42].each do |primitive|
      auth = build_auth(hooks: {before: ->(_ctx) { primitive }, after: ->(_ctx) { {after: true} }})

      assert_equal({after: true}, auth.api.probe)
      assert_equal({"after" => true}, JSON.parse(auth.call(request_env).last.join))
    end
  end

  def test_dispatch_creates_and_reuses_request_state
    state = BetterAuth::RequestState.define { "initial" }
    auth = build_auth(endpoint: ->(_ctx) { {value: state.get} }, hooks: {before: lambda { |_ctx|
      state.set("from hook") if state.get == "initial"
      nil
    }})

    assert_equal({value: "from hook"}, auth.api.probe)
    assert_equal({"value" => "from hook"}, JSON.parse(auth.call(request_env).last.join))
    BetterAuth::RequestState.run do
      state.set("outer scope")
      assert_equal({value: "outer scope"}, auth.api.probe)
      assert_equal "outer scope", state.get
    end
    refute BetterAuth::RequestState.present?
  end

  def test_dispatch_records_route_and_hook_spans
    spans = []
    record = lambda do |name, attributes:, **, &block|
      spans << [name, attributes]
      block.call
    end
    options = {
      plugin: {on_request: ->(*) {}, on_response: ->(*) {}},
      hooks: {before: ->(*) {}, after: ->(*) {}}
    }
    BetterAuth::Instrumentation.stub(:with_span, record) do
      build_auth(**options).call(request_env)
    end

    assert_equal ["onRequest probe", "GET /probe", "hook before /probe user", "handler /probe", "hook after /probe user", "onResponse probe"], spans.map(&:first)
    assert_equal({"http.route" => "/probe", "better_auth.operation_id" => "probe"}, spans[1].last)
    assert_equal 200, spans.last.last["http.response.status_code"]
  end

  def test_direct_dispatch_span_observes_raised_errors_only
    auth = build_auth(endpoint: ->(ctx) { raise ctx.error("FORBIDDEN") })
    failed_spans = []
    record = lambda do |name, **, &block|
      block.call
    rescue BetterAuth::APIError => error
      failed_spans << [name, error.status]
      raise
    end

    BetterAuth::Instrumentation.stub(:with_span, record) do
      assert_raises(BetterAuth::APIError) { auth.api.probe }
      assert_equal [["handler /probe", "FORBIDDEN"], ["GET /probe", "FORBIDDEN"]], failed_spans
      failed_spans.clear
      assert_equal 403, auth.api.probe(as_response: true).status
      assert_equal [["handler /probe", "FORBIDDEN"]], failed_spans
    end
  end

  private

  def build_auth(endpoint: ->(_ctx) { {ok: true} }, plugin: {}, plugins: [], **options)
    probe = BetterAuth::Endpoint.new(path: "/probe", method: %w[GET POST], &endpoint)
    BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: "test-secret-that-is-long-enough-for-validation",
      plugins: [{id: "probe", endpoints: {probe: probe}}.merge(plugin), *plugins],
      **options
    )
  end

  def request_env(method: "GET", input: nil)
    opts = {:method => method, "rack.errors" => StringIO.new}
    if input
      opts[:input] = input
      opts["CONTENT_TYPE"] = "application/json"
    end
    Rack::MockRequest.env_for("http://localhost:3000/api/auth/probe", opts)
  end
end
