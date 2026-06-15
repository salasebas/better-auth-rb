# frozen_string_literal: true

require "base64"
require "json"
require "rack/mock"
require "securerandom"
require "stringio"
require "uri"
require "zlib"

require File.expand_path("../../../better_auth/test/support/password_test_helpers.rb", __dir__)

module BetterAuthSSOTestHelpers
  SECRET = "test-secret-that-is-long-enough-for-validation"

  class SecondaryStorage
    attr_reader :data, :ttls

    def initialize
      @data = {}
      @ttls = {}
    end

    def set(key, value, ttl = nil)
      @data[key] = value
      @ttls[key] = ttl
    end

    def get(key)
      @data[key]
    end

    def delete(key)
      @data.delete(key)
      @ttls.delete(key)
    end
  end

  class RateLimitStorage
    attr_reader :data

    def initialize
      @data = {}
    end

    def get(key)
      @data[key]
    end

    def set(key, value, ttl: nil, update: false)
      @data[key] = value
    end

    def keys
      @data.keys
    end
  end

  def build_sso_auth(plugin_options: {}, plugins: nil, **options)
    auth_options = {
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: :memory,
      plugins: plugins || [BetterAuth::Plugins.sso(plugin_options)]
    }
    auth_options[:email_and_password] = BetterAuthTestPasswordHelpers.fast_email_and_password_config unless options.key?(:email_and_password)

    BetterAuth.auth(auth_options.merge(options))
  end

  def sign_up_cookie(auth, email: "owner-#{SecureRandom.hex(4)}@example.com", password: "password123")
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: email, password: password, name: email.split("@").first},
      as_response: true
    )
    cookie_header(headers.fetch("set-cookie"))
  end

  def cookie_header(set_cookie)
    set_cookie.to_s.lines.map { |line| line.split(";").first }.join("; ")
  end

  def register_oidc_provider(auth, cookie:, provider_id: "oidc-#{SecureRandom.hex(4)}", domain: "example.com", issuer: "https://idp.example.com", **body)
    auth.api.register_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: provider_id,
        issuer: issuer,
        domain: domain,
        oidcConfig: {
          clientId: "client-id",
          clientSecret: "client-secret",
          skipDiscovery: true,
          pkce: true,
          authorizationEndpoint: "#{issuer}/authorize",
          tokenEndpoint: "#{issuer}/token",
          jwksEndpoint: "#{issuer}/jwks",
          getToken: ->(**_data) { {accessToken: "access-token"} },
          getUserInfo: ->(_tokens) { {id: "#{provider_id}-subject", email: "sso-user@#{domain.split(",").first}", name: "SSO User"} }
        }
      }.merge(body)
    )
  end

  def register_saml_provider(auth, cookie:, provider_id: "saml-#{SecureRandom.hex(4)}", domain: "example.com", issuer: "https://idp.example.com", **body)
    auth.api.register_sso_provider(
      headers: {"cookie" => cookie},
      body: {
        providerId: provider_id,
        issuer: issuer,
        domain: domain,
        samlConfig: {
          entryPoint: "#{issuer}/sso",
          cert: "test-cert",
          audience: "better-auth-ruby"
        }
      }.merge(body)
    )
  end

  def rack_json_request(auth, method, path, body: {}, cookie: nil, origin: "http://localhost:3000", headers: {})
    auth.call(rack_env(method, path, body: body, cookie: cookie, origin: origin, headers: headers))
  end

  def rack_form_request(auth, method, path, form:, cookie: nil, origin: "http://localhost:3000", headers: {})
    auth.call(rack_env(method, path, form: form, cookie: cookie, origin: origin, headers: headers))
  end

  def rack_env(method, path, body: nil, form: nil, cookie: nil, origin: "http://localhost:3000", headers: {})
    env = {
      "REQUEST_METHOD" => method.to_s.upcase,
      "PATH_INFO" => path.split("?").first,
      "QUERY_STRING" => URI.parse(path).query.to_s,
      "rack.url_scheme" => "http",
      "REMOTE_ADDR" => "127.0.0.1",
      "HTTP_HOST" => "localhost:3000",
      "HTTP_ORIGIN" => origin
    }
    env["HTTP_COOKIE"] = cookie if cookie
    headers.each { |key, value| env[key] = value }

    if form
      payload = URI.encode_www_form(form)
      env["CONTENT_TYPE"] = "application/x-www-form-urlencoded"
      env["CONTENT_LENGTH"] = payload.bytesize.to_s
      env["rack.input"] = StringIO.new(payload)
    elsif body
      payload = JSON.generate(body)
      env["CONTENT_TYPE"] = "application/json"
      env["CONTENT_LENGTH"] = payload.bytesize.to_s
      env["rack.input"] = StringIO.new(payload)
    else
      env["rack.input"] = StringIO.new("")
    end

    Rack::MockRequest.env_for(path, env)
  end

  def response_json(body)
    JSON.parse(body.join)
  end

  def saml_json_response(id: "assertion-#{SecureRandom.hex(4)}", email: "saml-user@example.com", name: "SAML User")
    Base64.strict_encode64(JSON.generate({id: id, email: email, name: name}))
  end

  def saml_response_xml(in_response_to: nil, assertion_id: "assertion-#{SecureRandom.hex(4)}")
    attribute = in_response_to ? " InResponseTo=\"#{in_response_to}\"" : ""
    Base64.strict_encode64("<samlp:Response xmlns:samlp=\"urn:oasis:names:tc:SAML:2.0:protocol\"#{attribute}><saml:Assertion xmlns:saml=\"urn:oasis:names:tc:SAML:2.0:assertion\" ID=\"#{assertion_id}\" /></samlp:Response>")
  end

  def saml_request_id_from_url(url)
    encoded = Rack::Utils.parse_query(URI.parse(url).query).fetch("SAMLRequest")
    compressed = Base64.decode64(encoded)
    xml = Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(compressed)
    xml[/\bID=['"]([^'"]+)['"]/, 1]
  end
end
