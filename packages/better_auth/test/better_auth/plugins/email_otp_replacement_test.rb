# frozen_string_literal: true

require "json"
require_relative "../../test_helper"

class BetterAuthPluginsEmailOTPReplacementTest < Minitest::Test
  SECRET = "phase-eight-secret-with-enough-entropy-123"

  def test_server_only_create_leaves_the_previous_code_when_the_write_raises
    body = {email: "server-create@example.com", type: "sign-in"}
    fail_once = false
    before_create = lambda do |_data, _ctx|
      if fail_once
        fail_once = false
        raise TransientVerificationWriteError
      end
    end
    auth = build_auth(
      plugins: [BetterAuth::Plugins.email_otp(generate_otp: ->(_data, _ctx) { "123456" })],
      database_hooks: {verification: {create: {before: before_create}}}
    )
    auth.api.create_verification_otp(body: body)
    fail_once = true

    assert_raises(TransientVerificationWriteError) { auth.api.create_verification_otp(body: body) }
    assert_equal({otp: "123456"}, auth.api.get_verification_otp(query: body))
  end

  def test_email_otp_replacement_keeps_the_previous_verification_until_create_completes
    verification_storage_modes.each do |mode, storage_options, _storage|
      sent = []
      otp_values = %w[111111 222222]
      block_replacement = false
      create_started = Queue.new
      continue_create = Queue.new
      before_create = lambda do |_data, _context|
        if block_replacement
          block_replacement = false
          create_started << true
          continue_create.pop
        end
      end
      auth = replacement_auth(storage_options, otp_values, sent, create: {before: before_create})
      email = "replace-#{mode}@example.com"
      identifier = "sign-in-otp-#{email}"

      auth.api.send_verification_otp(body: {email: email, type: "sign-in"})
      previous = auth.context.internal_adapter.find_verification_value(identifier)
      block_replacement = true
      replacement = Thread.new do
        auth.api.send_verification_otp(body: {email: email, type: "sign-in"})
      ensure
        create_started.close
      end

      begin
        assert create_started.pop, "Replacement exited before its create hook (#{mode})"
        observable = auth.context.internal_adapter.find_verification_value(identifier)
        assert_equal previous["id"], observable&.fetch("id"), mode
        assert_equal previous["value"], observable&.fetch("value"), mode
      ensure
        continue_create << true
        replacement.join
      end

      assert_equal({success: true}, replacement.value, mode)
      assert_equal "222222", sent.last[:otp], mode
    end
  end

  def test_email_otp_replacement_retries_a_raised_write_once_after_deleting_the_previous_verification
    verification_storage_modes.each do |mode, storage_options, storage|
      sent = []
      otp_values = %w[333333 444444]
      events = []
      attempts = []
      fail_next_create = false
      before_create = lambda do |data, _context|
        next if storage

        events << :create
        attempts << data
        if fail_next_create
          fail_next_create = false
          raise TransientVerificationWriteError
        end
      end
      auth = replacement_auth(storage_options, otp_values, sent,
        create: {before: before_create},
        delete: {before: ->(_data, _context) { events << :delete unless storage }})
      email = "retry-#{mode}@example.com"

      auth.api.send_verification_otp(body: {email: email, type: "sign-in"})
      events.clear
      attempts.clear
      if storage
        storage.events.clear
        storage.verification_writes.clear
        storage.fail_next_verification_write!
      else
        fail_next_create = true
      end

      now = Time.now
      Time.stub(:now, -> { now += 1 }) do
        assert_equal({success: true}, auth.api.send_verification_otp(body: {email: email, type: "sign-in"}), mode)
      end

      if storage
        assert_equal [:create, :delete, :create], storage.events, mode
        assert_retried_verification_payload(storage.verification_writes.first, storage.verification_writes.last, mode)
      else
        assert_equal [:create, :delete, :create], events, mode
        assert_retried_verification_payload(attempts.first, attempts.last, mode)
      end
      assert_match(/\A[0-9a-f]{32}\z/, auth.api.sign_in_email_otp(body: {email: email, otp: sent.last[:otp]})[:token], mode)
    end
  end

  def test_email_otp_replacement_does_not_delete_when_creation_is_vetoed
    verification_storage_modes.each do |mode, storage_options, _storage|
      sent = []
      otp_values = %w[555555 666666]
      veto_replacement = false
      auth = replacement_auth(storage_options, otp_values, sent,
        create: {before: ->(_data, _context) { false if veto_replacement }})
      email = "veto-#{mode}@example.com"
      identifier = "sign-in-otp-#{email}"

      auth.api.send_verification_otp(body: {email: email, type: "sign-in"})
      previous = auth.context.internal_adapter.find_verification_value(identifier)
      veto_replacement = true

      assert_equal({success: true}, auth.api.send_verification_otp(body: {email: email, type: "sign-in"}), mode)
      retained = auth.context.internal_adapter.find_verification_value(identifier)
      assert_equal previous["id"], retained&.fetch("id"), mode
      assert_equal previous["value"], retained&.fetch("value"), mode
    end
  end

  def test_email_otp_replacement_propagates_pre_create_storage_errors_without_deleting
    sent = []
    otp_values = %w[777777 888888]
    fail_transformation = false
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.email_otp(
          store_otp: {
            encrypt: lambda { |otp|
              raise PreCreateOTPStorageError, "temporary OTP storage transformation failure" if fail_transformation

              otp
            }
          },
          generate_otp: ->(_data, _ctx = nil) { otp_values.shift },
          send_verification_otp: ->(data, _ctx = nil) { sent << data }
        )
      ]
    )
    email = "pre-create-storage-error@example.com"
    identifier = "sign-in-otp-#{email}"

    auth.api.send_verification_otp(body: {email: email, type: "sign-in"})
    previous = auth.context.internal_adapter.find_verification_value(identifier)
    fail_transformation = true

    assert_raises(PreCreateOTPStorageError) do
      auth.api.send_verification_otp(body: {email: email, type: "sign-in"})
    end

    retained = auth.context.internal_adapter.find_verification_value(identifier)
    assert_equal previous["id"], retained&.fetch("id")
    assert_equal previous["value"], retained&.fetch("value")
    assert_equal 1, sent.length
  end

  private

  def verification_storage_modes
    secondary_only = ObservableVerificationStorage.new
    dual = ObservableVerificationStorage.new
    [
      [:database_only, {}, nil],
      [:secondary_only, {secondary_storage: secondary_only}, secondary_only],
      [:secondary_and_database, {secondary_storage: dual, verification: {store_in_database: true}}, dual]
    ]
  end

  def replacement_auth(storage_options, codes, sent, verification_hooks)
    plugin = BetterAuth::Plugins.email_otp(
      generate_otp: ->(_data, _ctx) { codes.shift },
      send_verification_otp: ->(data, _ctx) { sent << data }
    )
    build_auth(storage_options.merge(plugins: [plugin], database_hooks: {verification: verification_hooks}))
  end

  def assert_retried_verification_payload(first, last, mode)
    assert_equal first.slice("identifier", "value"), last.slice("identifier", "value"), mode
    assert_operator verification_expiration(last), :>, verification_expiration(first), mode
  end

  def verification_expiration(payload)
    value = payload.fetch("expiresAt")
    value.is_a?(Time) ? value : Time.parse(value)
  end

  def build_auth(options)
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET, database: :memory}.merge(options))
  end

  class TransientVerificationWriteError < StandardError
  end

  class PreCreateOTPStorageError < StandardError
  end

  class ObservableVerificationStorage
    attr_reader :events, :verification_writes

    def initialize
      @store = {}
      @events = []
      @verification_writes = []
      @fail_next_verification_write = false
      @mutex = Mutex.new
    end

    def set(key, value, _ttl = nil)
      @mutex.synchronize do
        if key.start_with?("verification:")
          @events << :create
          @verification_writes << JSON.parse(value)
          if @fail_next_verification_write
            @fail_next_verification_write = false
            raise TransientVerificationWriteError, "temporary verification storage failure"
          end
        end
        @store[key] = value
      end
    end

    def get(key)
      @mutex.synchronize { @store[key] }
    end

    def delete(key)
      @mutex.synchronize do
        @events << :delete if key.start_with?("verification:")
        @store.delete(key)
      end
    end

    def get_and_delete(key)
      @mutex.synchronize { @store.delete(key) }
    end

    def fail_next_verification_write!
      @mutex.synchronize { @fail_next_verification_write = true }
    end
  end
end
