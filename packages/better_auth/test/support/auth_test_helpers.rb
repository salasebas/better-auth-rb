# frozen_string_literal: true

require "json"
require "stringio"

module BetterAuthTestHelpers
  SECRET = "test-secret-that-is-long-enough-for-validation"

  module_function

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth(
      {
        base_url: "http://localhost:3000",
        secret: SECRET,
        database: :memory,
        email_and_password: email_and_password
      }.merge(options)
    )
  end

  def json_rack_env(method, path, body: {}, query: "", cookie: nil, headers: {})
    payload = JSON.generate(body)
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => query.to_s,
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "3000",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(payload),
      "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => payload.bytesize.to_s,
      "HTTP_COOKIE" => cookie,
      "HTTP_ORIGIN" => "http://localhost:3000"
    }
    headers.each { |key, value| env[key] = value }
    env.compact
  end

  def cookie_header(set_cookie)
    set_cookie.to_s.lines.map { |line| line.split(";").first }.join("; ")
  end

  def json_response_body(body)
    JSON.parse(body.join)
  end

  def sign_up_cookie(auth, email:, password: "password123", name: "Test User", extra: {})
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: email, password: password, name: name}.merge(extra),
      as_response: true
    )
    cookie_header(headers.fetch("set-cookie"))
  end
end
