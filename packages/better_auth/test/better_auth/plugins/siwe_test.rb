# frozen_string_literal: true

require "json"
require "rack/mock"
require_relative "../../test_helper"

class BetterAuthPluginsSiweTest < Minitest::Test
  SECRET = "phase-eight-secret-with-enough-entropy-123"
  WALLET = "0x000000000000000000000000000000000000dEaD"
  OTHER_WALLET = "0x000000000000000000000000000000000000bEEF"
  NONCE_PATHS = ["/api/auth/siwe/nonce", "/api/auth/siwe/get-nonce"].freeze

  def test_nonce_routes_accept_both_single_field_address_aliases
    auth = build_auth
    request = Rack::MockRequest.new(auth)

    NONCE_PATHS.product([{walletAddress: WALLET}, {address: WALLET}]).each_with_index do |(path, body), index|
      chain_id = 100 + index
      response = post_json(request, path, body.merge(chainId: chain_id))

      assert_equal 200, response.status
      assert_equal({"nonce" => "nonce-#{index + 1}"}, JSON.parse(response.body))
      stored = auth.context.internal_adapter.find_verification_value("siwe:#{WALLET}:#{chain_id}")
      assert_equal "nonce-#{index + 1}", stored["value"]
    end

    assert_equal({nonce: "nonce-5"}, auth.api.get_nonce(body: {address: WALLET, chainId: 137}))

    NONCE_PATHS.each do |path|
      response = post_json(request, path, {})
      assert_equal 400, response.status
      assert_equal "walletAddress or address is required", JSON.parse(response.body).fetch("message")
    end
  end

  def test_nonce_routes_reject_each_invalid_present_address_alias
    auth = build_auth
    request = Rack::MockRequest.new(auth)
    cases = [
      [NONCE_PATHS.fetch(0), {walletAddress: WALLET, address: "invalid", chainId: 201}],
      [NONCE_PATHS.fetch(1), {walletAddress: WALLET, address: nil, chainId: 202}],
      [NONCE_PATHS.fetch(0), {walletAddress: nil, chainId: 203}]
    ]

    cases.each do |path, body|
      response = post_json(request, path, body)

      assert_equal 400, response.status
      assert_equal "Invalid walletAddress", JSON.parse(response.body).fetch("message")
      assert_nil auth.context.internal_adapter.find_verification_value("siwe:#{WALLET}:#{body.fetch(:chainId)}")
    end
  end

  def test_nonce_routes_prefer_wallet_address_when_both_aliases_are_valid
    auth = build_auth
    request = Rack::MockRequest.new(auth)

    NONCE_PATHS.each_with_index do |path, index|
      chain_id = 300 + index
      response = post_json(
        request,
        path,
        {walletAddress: WALLET, address: OTHER_WALLET, chainId: chain_id}
      )

      assert_equal 200, response.status
      assert_equal({"nonce" => "nonce-#{index + 1}"}, JSON.parse(response.body))
      selected = auth.context.internal_adapter.find_verification_value("siwe:#{WALLET}:#{chain_id}")
      assert_equal "nonce-#{index + 1}", selected["value"]
      assert_nil auth.context.internal_adapter.find_verification_value("siwe:#{OTHER_WALLET}:#{chain_id}")
    end
  end

  def test_nonce_is_stored_per_wallet_and_chain
    auth = build_auth

    result = auth.api.get_siwe_nonce(body: {walletAddress: WALLET, chainId: 137})

    assert_equal "nonce-1", result[:nonce]
    stored = auth.context.internal_adapter.find_verification_value("siwe:#{WALLET}:137")
    refute_nil stored
    assert_equal "nonce-1", stored["value"]
    assert_in_delta Time.now + (15 * 60), stored["expiresAt"], 2
  end

  def test_verify_creates_wallet_user_account_session_and_consumes_nonce
    auth = build_auth(ens_lookup: ->(wallet_address:) { {name: "vitalik.eth", avatar: "https://example.com/v.png"} })
    auth.api.get_siwe_nonce(body: {walletAddress: WALLET, chainId: 1})

    status, headers, body = auth.api.verify_siwe_message(
      body: {message: siwe_message(nonce: "nonce-1"), signature: "valid-signature", walletAddress: WALLET, chainId: 1},
      as_response: true
    )
    data = JSON.parse(body.first)

    assert_equal 200, status
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
    assert_equal true, data.fetch("success")
    assert_equal WALLET, data.dig("user", "walletAddress")
    assert_equal 1, data.dig("user", "chainId")

    wallet = auth.context.adapter.find_one(model: "walletAddress", where: [{field: "address", value: WALLET}])
    refute_nil wallet
    assert_equal true, wallet["isPrimary"]
    user = auth.context.internal_adapter.find_user_by_id(wallet["userId"])
    assert_equal "vitalik.eth", user["name"]
    assert_equal "https://example.com/v.png", user["image"]
    assert auth.context.internal_adapter.find_account_by_provider_id("#{WALLET}:1", "siwe")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_siwe_message(body: {message: siwe_message(nonce: "nonce-1"), signature: "valid-signature", walletAddress: WALLET, chainId: 1})
    end
    assert_equal 401, error.status_code
    assert_equal "UNAUTHORIZED_INVALID_OR_EXPIRED_NONCE", error.status
  end

  def test_concurrent_siwe_verification_has_exactly_one_winner
    auth = build_auth
    auth.api.get_siwe_nonce(body: {walletAddress: WALLET, chainId: 1})
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = 5.times.map do
      Thread.new do
        ready << true
        start.pop
        results << [:success, auth.api.verify_siwe_message(body: {message: siwe_message(nonce: "nonce-1"), signature: "valid-signature", walletAddress: WALLET, chainId: 1})]
      rescue BetterAuth::APIError => error
        results << [:error, error]
      end
    end
    5.times { ready.pop }
    5.times { start << true }
    threads.each(&:join)

    outcomes = 5.times.map { results.pop }
    assert_equal 1, outcomes.count { |kind, _| kind == :success }
    assert_equal 4, outcomes.count { |kind, error| kind == :error && error.status == "UNAUTHORIZED_INVALID_OR_EXPIRED_NONCE" }
  end

  def test_verify_rejects_missing_nonce_invalid_signature_and_invalid_wallet
    auth = build_auth

    missing_nonce = assert_raises(BetterAuth::APIError) do
      auth.api.verify_siwe_message(body: {message: siwe_message(nonce: "nonce-1"), signature: "valid-signature", walletAddress: WALLET})
    end
    assert_equal 401, missing_nonce.status_code

    auth.api.get_siwe_nonce(body: {walletAddress: WALLET})
    invalid_signature = assert_raises(BetterAuth::APIError) do
      auth.api.verify_siwe_message(body: {message: siwe_message(nonce: "nonce-1"), signature: "bad-signature", walletAddress: WALLET})
    end
    assert_equal 401, invalid_signature.status_code
    assert_equal "Unauthorized: Invalid SIWE signature", invalid_signature.message

    invalid_wallet = assert_raises(BetterAuth::APIError) do
      auth.api.get_siwe_nonce(body: {walletAddress: "invalid"})
    end
    assert_equal 400, invalid_wallet.status_code
  end

  def test_anonymous_false_requires_valid_email
    auth = build_auth(anonymous: false)

    auth.api.get_siwe_nonce(body: {walletAddress: WALLET})
    missing_email = assert_raises(BetterAuth::APIError) do
      auth.api.verify_siwe_message(body: {message: siwe_message(nonce: "nonce-1"), signature: "valid-signature", walletAddress: WALLET})
    end
    assert_equal 400, missing_email.status_code
    assert_equal "Email is required when anonymous is disabled.", missing_email.message

    invalid_email = assert_raises(BetterAuth::APIError) do
      auth.api.verify_siwe_message(body: {message: "valid-message", signature: "valid-signature", walletAddress: WALLET, email: "not-an-email"})
    end
    assert_equal 400, invalid_email.status_code

    auth.api.get_siwe_nonce(body: {walletAddress: WALLET})
    result = auth.api.verify_siwe_message(body: {message: siwe_message(nonce: "nonce-2"), signature: "valid-signature", walletAddress: WALLET, email: "WALLET@EXAMPLE.COM"})
    assert_equal true, result[:success]
    wallet = auth.context.adapter.find_one(model: "walletAddress", where: [{field: "address", value: WALLET}])
    user = auth.context.internal_adapter.find_user_by_id(wallet["userId"])
    assert_equal "wallet@example.com", user["email"]
  end

  def test_verify_message_callback_receives_upstream_equivalent_payload_and_response_shape
    calls = []
    auth = build_auth(
      verify_message: lambda do |message:, signature:, address:, chain_id:, cacao:|
        calls << {message: message, signature: signature, address: address, chain_id: chain_id, cacao: cacao}
        true
      end
    )

    auth.api.get_siwe_nonce(body: {walletAddress: WALLET})
    message = siwe_message(nonce: "nonce-1")
    result = auth.api.verify_siwe_message(body: {message: message, signature: "valid-signature", walletAddress: WALLET})

    assert_equal true, result.fetch(:success)
    assert_kind_of String, result.fetch(:token)
    assert_equal WALLET, result.dig(:user, :walletAddress)
    assert_equal 1, result.dig(:user, :chainId)
    assert_kind_of String, result.dig(:user, :id)

    call = calls.fetch(0)
    assert_equal message, call.fetch(:message)
    assert_equal "valid-signature", call.fetch(:signature)
    assert_equal WALLET, call.fetch(:address)
    assert_equal 1, call.fetch(:chain_id)
    assert_equal "caip122", call.dig(:cacao, :h, :t)
    assert_equal "nonce-1", call.dig(:cacao, :p, :nonce)
    assert_equal "example.com", call.dig(:cacao, :p, :domain)
  end

  def test_same_wallet_on_different_chains_reuses_user_and_adds_address
    auth = build_auth

    auth.api.get_siwe_nonce(body: {walletAddress: WALLET, chainId: 1})
    first = auth.api.verify_siwe_message(body: {message: siwe_message(nonce: "nonce-1"), signature: "valid-signature", walletAddress: WALLET, chainId: 1})
    auth.api.get_siwe_nonce(body: {walletAddress: WALLET, chainId: 137})
    second = auth.api.verify_siwe_message(body: {message: siwe_message(nonce: "nonce-2", chain_id: 137), signature: "valid-signature", walletAddress: WALLET, chainId: 137})

    assert_equal first[:user][:id], second[:user][:id]
    wallets = auth.context.adapter.find_many(model: "walletAddress", where: [{field: "address", value: WALLET}])
    assert_equal 2, wallets.length
    assert_equal [1, 137], wallets.map { |wallet| wallet["chainId"] }.sort
    refute wallets.find { |wallet| wallet["chainId"] == 137 }["isPrimary"]
  end

  def test_wallet_addresses_are_stored_and_returned_in_checksum_format
    auth = build_auth
    lowercase_wallet = WALLET.downcase

    auth.api.get_siwe_nonce(body: {walletAddress: lowercase_wallet, chainId: 1})
    result = auth.api.verify_siwe_message(body: {message: siwe_message(nonce: "nonce-1", address: lowercase_wallet), signature: "valid-signature", walletAddress: lowercase_wallet, chainId: 1})

    assert_equal WALLET, result.dig(:user, :walletAddress)
    wallet = auth.context.adapter.find_one(model: "walletAddress", where: [{field: "address", value: WALLET}])
    refute_nil wallet
    assert_equal WALLET, wallet["address"]
  end

  def test_wallet_lookup_is_case_insensitive_without_duplicate_records
    auth = build_auth

    auth.api.get_siwe_nonce(body: {walletAddress: WALLET.downcase, chainId: 1})
    first = auth.api.verify_siwe_message(body: {message: siwe_message(nonce: "nonce-1", address: WALLET.downcase), signature: "valid-signature", walletAddress: WALLET.downcase, chainId: 1})
    auth.api.get_siwe_nonce(body: {walletAddress: WALLET.upcase, chainId: 1})
    second = auth.api.verify_siwe_message(body: {message: siwe_message(nonce: "nonce-2", address: WALLET.upcase), signature: "valid-signature", walletAddress: WALLET.upcase, chainId: 1})

    assert_equal first.dig(:user, :id), second.dig(:user, :id)
    wallets = auth.context.adapter.find_many(model: "walletAddress", where: [{field: "address", value: WALLET}])
    assert_equal 1, wallets.length
    assert_equal true, wallets.first["isPrimary"]
  end

  def test_custom_schema_merges_model_and_field_names_without_losing_base_metadata
    auth = build_auth(
      schema: {
        walletAddress: {
          modelName: "wallet_address",
          fields: {
            userId: "user_id",
            address: "wallet_address",
            chainId: "chain_id",
            isPrimary: "is_primary",
            createdAt: "created_at"
          }
        }
      }
    )

    table = BetterAuth::Schema.auth_tables(auth.context.options).fetch("walletAddress")
    assert_equal "wallet_address", table[:model_name]
    assert_equal "string", table.dig(:fields, "userId", :type)
    assert_equal true, table.dig(:fields, "userId", :required)
    assert_equal "user_id", table.dig(:fields, "userId", :field_name)
    assert_equal "wallet_address", table.dig(:fields, "address", :field_name)
    assert_equal "chain_id", table.dig(:fields, "chainId", :field_name)
  end

  def test_missing_get_nonce_callback_returns_internal_error
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      plugins: [BetterAuth::Plugins.siwe(domain: "example.com")]
    )

    error = assert_raises(BetterAuth::APIError) do
      auth.api.get_siwe_nonce(body: {walletAddress: WALLET})
    end

    assert_equal 500, error.status_code
    assert_equal "SIWE nonce callback is required", error.message
  end

  def test_verify_rejects_expired_nonce
    auth = build_auth
    auth.api.get_siwe_nonce(body: {walletAddress: WALLET, chainId: 1})
    stored = auth.context.internal_adapter.find_verification_value("siwe:#{WALLET}:1")
    auth.context.internal_adapter.update_verification_value(stored["id"], expiresAt: Time.now - 60)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.verify_siwe_message(body: {message: siwe_message(nonce: "nonce-1"), signature: "valid-signature", walletAddress: WALLET, chainId: 1})
    end

    assert_equal 401, error.status_code
    assert_equal "UNAUTHORIZED_INVALID_OR_EXPIRED_NONCE", error.status
  end

  def test_verify_binds_erc4361_message_to_server_state
    cases = {
      domain: -> { siwe_message(nonce: "nonce-1", domain: "evil.example") },
      nonce: -> { siwe_message(nonce: "wrong-nonce") },
      address: -> { siwe_message(nonce: "nonce-1", address: "0x000000000000000000000000000000000000bEEF") },
      chain: -> { siwe_message(nonce: "nonce-1", chain_id: 137) },
      arbitrary_text: -> { "this is signed but is not an ERC-4361 message" }
    }

    cases.each do |name, message|
      auth = build_auth(verify_message: ->(**) { true })
      auth.api.get_siwe_nonce(body: {walletAddress: WALLET, chainId: 1})

      error = assert_raises(BetterAuth::APIError, "#{name} should be rejected") do
        auth.api.verify_siwe_message(
          body: {message: message.call, signature: "valid-signature", walletAddress: WALLET, chainId: 1}
        )
      end

      assert_equal 401, error.status_code
      assert_equal "UNAUTHORIZED", error.status
      assert_equal "UNAUTHORIZED_SIWE_MESSAGE_MISMATCH", error.code
    end
  end

  def test_verify_enforces_signed_expiration_and_not_before
    now = Time.now.utc
    cases = {
      ["UNAUTHORIZED_SIWE_MESSAGE_EXPIRED", now - 60, nil] => :expiration_time,
      ["UNAUTHORIZED_SIWE_MESSAGE_NOT_YET_VALID", nil, now + 60] => :not_before
    }

    cases.each do |(status, expiration_time, not_before), _kind|
      auth = build_auth(verify_message: ->(**) { true })
      auth.api.get_siwe_nonce(body: {walletAddress: WALLET, chainId: 1})
      message = siwe_message(nonce: "nonce-1", expiration_time: expiration_time, not_before: not_before)

      error = assert_raises(BetterAuth::APIError) do
        auth.api.verify_siwe_message(
          body: {message: message, signature: "valid-signature", walletAddress: WALLET, chainId: 1}
        )
      end

      assert_equal 401, error.status_code
      assert_equal "UNAUTHORIZED", error.status
      assert_equal status, error.code
    end
  end

  def test_occupied_email_silently_falls_back_to_wallet_placeholder
    ["taken@example.com", "TAKEN@EXAMPLE.COM"].each do |requested_email|
      auth = build_auth(anonymous: false)
      owner = auth.context.internal_adapter.create_user(name: "Owner", email: "taken@example.com")
      auth.api.get_siwe_nonce(body: {walletAddress: WALLET, chainId: 1})

      result = auth.api.verify_siwe_message(
        body: {
          message: siwe_message(nonce: "nonce-1"),
          signature: "valid-signature",
          walletAddress: WALLET,
          chainId: 1,
          email: requested_email
        }
      )

      wallet_user = auth.context.internal_adapter.find_user_by_id(result.dig(:user, :id))
      assert_equal "#{WALLET}@localhost".downcase, wallet_user["email"]
      assert_equal owner["id"], auth.context.internal_adapter.find_user_by_email("taken@example.com").dig(:user, "id")
    end
  end

  def test_wallet_placeholder_uses_canonical_host_not_signing_domain
    auth = build_auth(base_url: "https://auth.example.test", domain: "signing.example.test")
    auth.api.get_siwe_nonce(body: {walletAddress: WALLET, chainId: 1})

    result = auth.api.verify_siwe_message(
      body: {
        message: siwe_message(nonce: "nonce-1", domain: "signing.example.test"),
        signature: "valid-signature",
        walletAddress: WALLET,
        chainId: 1
      }
    )

    user = auth.context.internal_adapter.find_user_by_id(result.dig(:user, :id))
    assert_equal "#{WALLET}@auth.example.test".downcase, user["email"]

    explicit = build_auth(
      base_url: "https://auth.example.test",
      domain: "signing.example.test",
      email_domain_name: "wallets.example.test"
    )
    explicit.api.get_siwe_nonce(body: {walletAddress: WALLET, chainId: 1})
    explicit_result = explicit.api.verify_siwe_message(
      body: {
        message: siwe_message(nonce: "nonce-1", domain: "signing.example.test"),
        signature: "valid-signature",
        walletAddress: WALLET,
        chainId: 1
      }
    )
    explicit_user = explicit.context.internal_adapter.find_user_by_id(explicit_result.dig(:user, :id))
    assert_equal "#{WALLET}@wallets.example.test".downcase, explicit_user["email"]
  end

  private

  def post_json(request, path, body)
    request.post(
      path,
      "CONTENT_TYPE" => "application/json",
      :input => JSON.generate(body)
    )
  end

  def siwe_message(nonce:, domain: "example.com", address: WALLET, chain_id: 1, expiration_time: nil, not_before: nil)
    lines = [
      "#{domain} wants you to sign in with your Ethereum account:",
      address,
      "",
      "Sign in to Better Auth.",
      "",
      "URI: https://#{domain}",
      "Version: 1",
      "Chain ID: #{chain_id}",
      "Nonce: #{nonce}",
      "Issued At: #{Time.now.utc.iso8601}"
    ]
    lines << "Expiration Time: #{expiration_time.utc.iso8601}" if expiration_time
    lines << "Not Before: #{not_before.utc.iso8601}" if not_before
    lines.join("\n")
  end

  def build_auth(options = {})
    nonce = 0
    base_url = options.delete(:base_url) || "http://localhost:3000"
    verify_message = options.delete(:verify_message) || lambda do |message:, signature:, address:, chain_id:, cacao:|
      signature == "valid-signature" &&
        message.include?("wants you to sign in with your Ethereum account") &&
        address == WALLET &&
        chain_id.to_i.positive? &&
        cacao[:p][:nonce].start_with?("nonce-")
    end

    BetterAuth.auth(
      base_url: base_url,
      secret: SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.siwe({
          domain: "example.com",
          get_nonce: -> {
            nonce += 1
            "nonce-#{nonce}"
          },
          verify_message: verify_message
        }.merge(options))
      ]
    )
  end
end
