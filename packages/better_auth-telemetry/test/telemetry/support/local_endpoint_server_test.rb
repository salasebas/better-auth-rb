# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "local_endpoint_server"
require "net/http"
require "uri"

class LocalEndpointServerTest < Minitest::Test
  LocalEndpointServer = BetterAuth::Telemetry::Test::LocalEndpointServer

  def teardown
    @server&.stop
  end

  def test_url_advertises_telemetry_path_on_loopback
    @server = LocalEndpointServer.new

    uri = URI.parse(@server.url)

    assert_equal "http", uri.scheme
    assert_equal "127.0.0.1", uri.host
    assert_equal "/telemetry", uri.path
    assert_equal @server.port, uri.port
    assert_operator uri.port, :>, 0
  end

  def test_post_is_captured_with_headers_path_and_body
    @server = LocalEndpointServer.new

    body = '{"hello":"world","n":42}'
    response = Net::HTTP.post(
      URI(@server.url),
      body,
      "Content-Type" => "application/json",
      "User-Agent" => "better_auth-telemetry/test",
      "X-Custom" => "trace-1"
    )

    assert_equal "204", response.code

    captured = @server.captured
    refute_nil captured, "server should capture the POST"

    assert_equal "/telemetry", captured.path
    assert_equal @server.url, captured.url
    assert_equal body, captured.body
    assert_equal "application/json", captured.headers["content-type"]
    assert_equal "better_auth-telemetry/test", captured.headers["user-agent"]
    assert_equal "trace-1", captured.headers["x-custom"]
    assert_equal body.bytesize.to_s, captured.headers["content-length"]
  end

  def test_stop_is_idempotent_and_does_not_leak_threads
    server_threads_before = telemetry_server_threads
    initial_count = server_threads_before.size

    @server = LocalEndpointServer.new
    Net::HTTP.post(URI(@server.url), "{}", "Content-Type" => "application/json")

    @server.stop
    @server.stop # second call must be a no-op

    # Give the acceptor loop a brief grace window to exit cleanly.
    deadline = Time.now + 1.0
    while telemetry_server_threads.size > initial_count && Time.now < deadline
      sleep 0.01
    end

    assert_equal initial_count,
      telemetry_server_threads.size,
      "LocalEndpointServer should not leak its acceptor thread after #stop"
  end

  def test_listening_port_is_released_after_stop
    @server = LocalEndpointServer.new
    port = @server.port
    @server.stop

    # Re-bind on the same port; if the previous server still owned it,
    # this would raise Errno::EADDRINUSE.
    rebound = TCPServer.new("127.0.0.1", port)
    rebound.close
  rescue Errno::EADDRINUSE
    flunk "LocalEndpointServer did not release its listening port on #stop"
  end

  private

  def telemetry_server_threads
    Thread.list.select do |thread|
      next false unless thread.alive?
      backtrace = thread.backtrace || []
      backtrace.any? { |frame| frame.include?("local_endpoint_server.rb") }
    end
  end
end
