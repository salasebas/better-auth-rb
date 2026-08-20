# frozen_string_literal: true

require "json"
require_relative "../../test_helper"
require_relative "adapter_contract"

class BetterAuthPostgresAdapterTest < Minitest::Test
  include BetterAuthAdapterContract

  SECRET = "test-secret-that-is-long-enough-for-validation"

  def test_postgres_adapter_can_be_instantiated_without_rails
    connection = Object.new
    adapter = BetterAuth::Adapters::Postgres.new(connection: connection)

    assert_equal :postgres, adapter.dialect
    assert_same connection, adapter.connection
  end

  def test_postgres_adapter_runs_core_crud_against_docker_service
    require "pg"

    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory)
    connection = PG.connect(ENV.fetch("BETTER_AUTH_POSTGRES_URL", "postgres://user:password@localhost:5432/better_auth"))
    reset_schema(connection)
    BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).each { |statement| connection.exec(statement) }
    adapter = BetterAuth::Adapters::Postgres.new(config, connection: connection)

    user = adapter.create(model: "user", data: {id: "user-1", name: "Ada", email: "ada@example.com"}, force_allow_id: true)
    found = adapter.find_one(model: "user", where: [{field: "email", value: "ada@example.com"}])

    assert_equal "user-1", user["id"]
    assert_equal false, user["emailVerified"]
    assert_equal "Ada", found["name"]
  rescue LoadError
    skip "pg gem is not installed"
  rescue PG::ConnectionBad
    skip "PostgreSQL test service is not available"
  ensure
    connection&.close
  end

  def test_postgres_adapter_persists_auth_routes_and_get_session_reads_database_rows
    require "pg"

    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory)
    connection = PG.connect(ENV.fetch("BETTER_AUTH_POSTGRES_URL", "postgres://user:password@localhost:5432/better_auth"))
    reset_schema(connection)
    create_schema(connection, config)
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: ->(options) { BetterAuth::Adapters::Postgres.new(options, connection: connection) },
      email_and_password: {enabled: true},
      session: {cookie_cache: {enabled: false}}
    )

    status, headers, body = auth.api.sign_up_email(
      body: {email: "postgres-route@example.com", password: "password123", name: "Postgres Route"},
      as_response: true
    )
    payload = JSON.parse(body.join)
    token = payload.fetch("token")
    user_id = payload.fetch("user").fetch("id")

    assert_equal 200, status
    assert_equal "postgres-route@example.com", direct_postgres_value(connection, %(SELECT email FROM "users" WHERE id = $1), [user_id])
    assert_equal "credential", direct_postgres_value(connection, %(SELECT provider_id FROM "accounts" WHERE user_id = $1), [user_id])
    assert_equal user_id, direct_postgres_value(connection, %(SELECT user_id FROM "sessions" WHERE token = $1), [token])

    connection.exec_params(%(UPDATE "users" SET "name" = $1 WHERE id = $2), ["Postgres Direct Update", user_id])
    session = auth.api.get_session(headers: {"cookie" => cookie_header(headers.fetch("set-cookie"))})

    assert_equal token, session[:session]["token"]
    assert_equal user_id, session[:session]["userId"]
    assert_equal "Postgres Direct Update", session[:user]["name"]
  rescue LoadError
    skip "pg gem is not installed"
  rescue PG::ConnectionBad
    skip "PostgreSQL test service is not available"
  ensure
    connection&.close
  end

  def test_postgres_phone_number_disassociation_releases_unique_value_for_reclaim
    require "pg"

    sent = []
    connection = PG.connect(ENV.fetch("BETTER_AUTH_POSTGRES_URL", "postgres://user:password@localhost:5432/better_auth"))
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: ->(options) { BetterAuth::Adapters::Postgres.new(options, connection: connection) },
      email_and_password: {enabled: true},
      session: {cookie_cache: {enabled: false}},
      plugins: [
        BetterAuth::Plugins.phone_number(send_otp: ->(data, _ctx = nil) { sent << data })
      ]
    )
    reset_schema(connection)
    create_schema(connection, auth.context.options)
    phone_number = "+15551234569"

    _status, original_headers, _body = auth.api.sign_up_email(
      body: {email: "postgres-phone-owner@example.com", password: "password123", name: "Phone Owner"},
      as_response: true
    )
    original_cookie = cookie_header(original_headers.fetch("set-cookie"))
    original_user_id = auth.api.get_session(headers: {"cookie" => original_cookie})[:user]["id"]
    auth.api.send_phone_number_otp(body: {phoneNumber: phone_number})
    auth.api.verify_phone_number(
      headers: {"cookie" => original_cookie},
      body: {phoneNumber: phone_number, code: sent.last[:code], updatePhoneNumber: true}
    )

    auth.api.update_user(headers: {"cookie" => original_cookie}, body: {phoneNumber: nil})
    released = connection.exec_params(
      %(SELECT phone_number, phone_number_verified FROM "users" WHERE id = $1),
      [original_user_id]
    ).first
    assert_nil released.fetch("phone_number")
    assert_equal "f", released.fetch("phone_number_verified")

    _status, reclaimer_headers, _body = auth.api.sign_up_email(
      body: {email: "postgres-phone-reclaimer@example.com", password: "password123", name: "Phone Reclaimer"},
      as_response: true
    )
    reclaimer_cookie = cookie_header(reclaimer_headers.fetch("set-cookie"))
    auth.api.send_phone_number_otp(body: {phoneNumber: phone_number})
    reclaimed = auth.api.verify_phone_number(
      headers: {"cookie" => reclaimer_cookie},
      body: {phoneNumber: phone_number, code: sent.last[:code], updatePhoneNumber: true}
    )

    assert_equal phone_number, reclaimed[:user]["phoneNumber"]
    assert_equal true, reclaimed[:user]["phoneNumberVerified"]
    assert_equal phone_number, direct_postgres_value(connection, %(SELECT phone_number FROM "users" WHERE id = $1), [reclaimed[:user]["id"]])
    assert_nil direct_postgres_value(connection, %(SELECT phone_number FROM "users" WHERE id = $1), [original_user_id])
  rescue LoadError
    skip "pg gem is not installed"
  rescue PG::ConnectionBad
    skip "PostgreSQL test service is not available"
  ensure
    connection&.close
  end

  def test_postgres_reservation_loser_keeps_outer_transaction_usable
    require "pg"

    config = BetterAuth::Configuration.new(secret: SECRET, database: :memory)
    setup = PG.connect(ENV.fetch("BETTER_AUTH_POSTGRES_URL", "postgres://user:password@localhost:5432/better_auth"))
    reset_schema(setup)
    create_schema(setup, config)
    connections = 2.times.map { PG.connect(ENV.fetch("BETTER_AUTH_POSTGRES_URL", "postgres://user:password@localhost:5432/better_auth")) }
    ready = Queue.new
    start = Queue.new
    threads = connections.map do |connection|
      Thread.new do
        adapter = BetterAuth::Adapters::Postgres.new(config, connection: connection)
        internal = BetterAuth::Adapters::InternalAdapter.new(adapter, config)
        adapter.transaction do
          ready << true
          start.pop
          won = internal.reserve_verification_value(identifier: "pg-reservation", value: "marker", expiresAt: Time.now + 120)
          [won, connection.exec("SELECT 1").first.fetch("?column?")]
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }

    results = threads.map(&:value)
    assert_equal [false, true], results.map(&:first).sort_by(&:to_s)
    assert_equal ["1", "1"], results.map(&:last)
    assert_equal 1, setup.exec(%(SELECT COUNT(*) FROM "verifications" WHERE identifier = 'pg-reservation')).first.fetch("count").to_i
  rescue LoadError
    skip "pg gem is not installed"
  rescue PG::ConnectionBad
    skip "PostgreSQL test service is not available"
  ensure
    connections&.each(&:close)
    setup&.close
  end

  private

  def with_contract_adapter(config)
    require "pg"

    connection = PG.connect(ENV.fetch("BETTER_AUTH_POSTGRES_URL", "postgres://user:password@localhost:5432/better_auth"))
    reset_schema(connection)
    create_schema(connection, config)
    yield BetterAuth::Adapters::Postgres.new(config, connection: connection)
  rescue LoadError
    skip "pg gem is not installed"
  rescue PG::ConnectionBad
    skip "PostgreSQL test service is not available"
  ensure
    connection&.close
  end

  def reset_schema(connection)
    tables = connection.exec("SELECT tablename FROM pg_tables WHERE schemaname = 'public'").map { |row| row.fetch("tablename") }
    tables.each do |table|
      connection.exec(%(DROP TABLE IF EXISTS "#{table}" CASCADE))
    end
  end

  def create_schema(connection, config)
    BetterAuth::Schema::SQL.create_statements(config, dialect: :postgres).each { |statement| connection.exec(statement) }
  end

  def direct_postgres_value(connection, sql, params)
    connection.exec_params(sql, params).first&.values&.first
  end

  def cookie_header(set_cookie)
    set_cookie.lines.map { |line| line.split(";").first }.join("; ")
  end
end
