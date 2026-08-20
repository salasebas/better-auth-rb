# frozen_string_literal: true

require_relative "../../test_helper"

class OAuthProviderClientSecretStorageTest < Minitest::Test
  include OAuthProviderFlowHelpers

  class MigrationRaceMemory < BetterAuth::Adapters::Memory
    attr_accessor :replacement_secret

    def update(model:, where:, update:)
      if replacement_secret && Array(where).any? { |condition| condition[:field].to_s == "clientSecret" }
        replacement = replacement_secret
        self.replacement_secret = nil
        client_id = Array(where).find { |condition| condition[:field].to_s == "clientId" }.fetch(:value)
        super(model: model, where: [{field: "clientId", value: client_id}], update: {clientSecret: replacement})
      end
      super
    end
  end

  class SharedTokenStore
    def initialize(tokens:, refresh_tokens:)
      @tokens = tokens
      @refresh_tokens = refresh_tokens
    end

    def [](key)
      (key.to_sym == :tokens) ? @tokens : @refresh_tokens
    end
  end

  def test_client_secret_storage_default_and_custom_option_matrix
    jwt_enabled = BetterAuth::Plugins.oauth_provider
    jwt_disabled = BetterAuth::Plugins.oauth_provider(disable_jwt_plugin: true)
    custom_encryption = {
      encrypt: ->(secret) { "encrypted:#{secret}" },
      decrypt: ->(secret) { secret.delete_prefix("encrypted:") }
    }

    assert_equal false, jwt_enabled.options[:disable_jwt_plugin]
    assert_equal "hashed", jwt_enabled.options[:store_client_secret]
    assert_equal "encrypted", jwt_disabled.options[:store_client_secret]
    assert_equal custom_encryption, BetterAuth::Plugins.oauth_provider(disable_jwt_plugin: true, store_client_secret: custom_encryption).options[:store_client_secret]
    assert_equal "plain", BetterAuth::Plugins.oauth_provider(disable_jwt_plugin: true, store_client_secret: "plain").options[:store_client_secret]
    assert_equal :hashed, BetterAuth::Plugins.oauth_provider(store_client_secret: :hashed).options[:store_client_secret]
    assert_equal :encrypted, BetterAuth::Plugins.oauth_provider(disable_jwt_plugin: true, store_client_secret: :encrypted).options[:store_client_secret]

    assert_raises(BetterAuth::APIError) do
      BetterAuth::Plugins.oauth_provider(disable_jwt_plugin: true, store_client_secret: "hashed")
    end
    assert_raises(BetterAuth::APIError) do
      BetterAuth::Plugins.oauth_provider(store_client_secret: "encrypted")
    end
    assert_raises(BetterAuth::APIError) do
      BetterAuth::Plugins.oauth_provider(disable_jwt_plugin: true, store_client_secret: {encrypt: ->(secret) { secret }})
    end
    assert_raises(BetterAuth::APIError) do
      BetterAuth::Plugins.oauth_provider(disable_jwt_plugin: true, store_client_secret: {decrypt: ->(secret) { secret }})
    end
    [nil, false, "unknown", :unknown, {}, {hash: ->(secret) { secret }, unknown: true}].each do |invalid|
      assert_raises(BetterAuth::APIError) do
        BetterAuth::Plugins.oauth_provider(disable_jwt_plugin: true, store_client_secret: invalid)
      end
    end
  end

  def test_jwt_disabled_creation_registration_and_rotation_store_decryptable_secrets
    auth = build_auth(scopes: ["openid"], disable_jwt_plugin: true)
    cookie = sign_up_cookie(auth)
    created = create_client(auth, cookie, scope: "openid", skip_consent: true)
    registered = register_client(auth, cookie, scope: "openid")

    [created, registered].each do |client|
      stored = persisted_client(auth, client).fetch("clientSecret")

      refute_equal client[:client_secret], stored
      refute_equal BetterAuth::Crypto.sha256(client[:client_secret], encoding: :base64url), stored
      assert_equal client[:client_secret], BetterAuth::Crypto.symmetric_decrypt(key: auth.context.secret_config, data: stored)
    end

    fetched = auth.api.get_oauth_client(headers: {"cookie" => cookie}, query: {client_id: created[:client_id]})
    listed = auth.api.get_oauth_clients(headers: {"cookie" => cookie}).find { |client| client[:client_id] == created[:client_id] }
    rotated = auth.api.rotate_oauth_client_secret(headers: {"cookie" => cookie}, body: {client_id: created[:client_id]})
    rotated_stored = persisted_client(auth, created).fetch("clientSecret")

    assert_nil fetched[:client_secret]
    assert_nil listed[:client_secret]
    refute_equal created[:client_secret], rotated[:client_secret]
    refute_equal rotated[:client_secret], rotated_stored
    assert_equal rotated[:client_secret], BetterAuth::Crypto.symmetric_decrypt(key: auth.context.secret_config, data: rotated_stored)
  end

  def test_encrypted_client_authentication_survives_reload_and_covers_token_introspection_and_revocation
    issuer = build_auth(scopes: ["read"], disable_jwt_plugin: true)
    cookie = sign_up_cookie(issuer)
    client = create_client(issuer, cookie, scope: "read")
    shared_db = issuer.context.adapter.db
    database = ->(options) { BetterAuth::Adapters::Memory.new(options, shared_db) }
    reloaded = build_auth(scopes: ["read"], disable_jwt_plugin: true, database: database)

    tokens = reloaded.api.oauth2_token(body: client_credentials_body(client))
    active = reloaded.api.oauth2_introspect(body: introspect_body(client, tokens[:access_token]))
    revoked = reloaded.api.oauth2_revoke(body: revoke_body(client, tokens[:access_token], hint: "access_token"))
    inactive = reloaded.api.oauth2_introspect(body: introspect_body(client, tokens[:access_token]))

    assert tokens[:access_token]
    assert_equal true, active[:active]
    assert_equal({revoked: true}, revoked)
    assert_equal false, inactive[:active]
  end

  def test_jwt_disabled_id_tokens_use_client_secret_and_logout_decrypts_it
    auth = build_auth(scopes: ["openid", "offline_access"], disable_jwt_plugin: true)
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid offline_access", enable_end_session: true, skip_consent: true)
    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid offline_access")
    refreshed = auth.api.oauth2_token(body: refresh_grant_body(client, tokens[:refresh_token]))
    derived_key = legacy_signing_key(auth, client)

    payload = JWT.decode(tokens[:id_token], client[:client_secret], true, algorithm: "HS256").first
    assert_equal client[:client_id], payload["aud"]
    assert JWT.decode(refreshed[:id_token], client[:client_secret], true, algorithm: "HS256").first
    assert_raises(JWT::DecodeError) do
      JWT.decode(tokens[:id_token], derived_key, true, algorithm: "HS256")
    end
    assert_equal({status: true}, auth.api.oauth2_end_session(query: {id_token_hint: tokens[:id_token]}))
  end

  def test_prefixed_basic_credentials_authenticate_and_hs256_uses_unprefixed_secret
    prefix = "ba_cs_"
    auth = build_auth(
      scopes: ["openid", "read"],
      disable_jwt_plugin: true,
      prefix: {client_secret: prefix}
    )
    cookie = sign_up_cookie(auth)
    client = create_client(
      auth,
      cookie,
      scope: "openid read",
      token_endpoint_auth_method: "client_secret_basic",
      skip_consent: true,
      enable_end_session: true
    )
    underlying_secret = client[:client_secret].delete_prefix(prefix)
    stored_before_failures = persisted_client(auth, client).fetch("clientSecret")

    [underlying_secret, "wrong_#{underlying_secret}"].each do |invalid_secret|
      error = assert_raises(BetterAuth::APIError) do
        auth.api.oauth2_token(
          headers: basic_auth_headers(client, invalid_secret),
          body: {grant_type: "client_credentials", scope: "read"}
        )
      end
      assert_equal 401, error.status_code
      assert_match(/invalid_client/, error.message)
      assert_equal stored_before_failures, persisted_client(auth, client).fetch("clientSecret")
    end

    client_credentials = auth.api.oauth2_token(
      headers: basic_auth_headers(client),
      body: {grant_type: "client_credentials", scope: "read"}
    )
    active = auth.api.oauth2_introspect(
      headers: basic_auth_headers(client),
      body: {token: client_credentials[:access_token], token_type_hint: "access_token"}
    )
    code = authorization_code_for(auth, cookie, client, scope: "openid")
    openid = auth.api.oauth2_token(
      headers: basic_auth_headers(client),
      body: {
        grant_type: "authorization_code",
        code: code,
        redirect_uri: "https://resource.example/callback",
        code_verifier: pkce_verifier
      }
    )

    assert_equal true, active[:active]
    assert JWT.decode(openid[:id_token], underlying_secret, true, algorithm: "HS256").first
    assert_raises(JWT::DecodeError) do
      JWT.decode(openid[:id_token], client[:client_secret], true, algorithm: "HS256")
    end
    assert_equal({status: true}, auth.api.oauth2_end_session(query: {id_token_hint: openid[:id_token]}))
    assert_equal(
      {revoked: true},
      auth.api.oauth2_revoke(
        headers: basic_auth_headers(client),
        body: {token: client_credentials[:access_token], token_type_hint: "access_token"}
      )
    )
  end

  def test_prefixed_post_credentials_gate_legacy_migration_introspection_and_revocation
    prefix = "ba_cs_"
    auth = build_auth(
      scopes: ["read"],
      disable_jwt_plugin: true,
      prefix: {client_secret: prefix}
    )
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "read", token_endpoint_auth_method: "client_secret_post")
    underlying_secret = client[:client_secret].delete_prefix(prefix)
    legacy_hash = BetterAuth::Crypto.sha256(underlying_secret, encoding: :base64url)
    replace_stored_secret(auth, client, legacy_hash)

    [underlying_secret, "wrong_#{underlying_secret}"].each do |invalid_secret|
      error = assert_raises(BetterAuth::APIError) do
        auth.api.oauth2_token(
          body: client_credentials_body(client.merge(client_secret: invalid_secret))
        )
      end
      assert_equal 401, error.status_code
      assert_match(/invalid_client/, error.message)
      assert_equal legacy_hash, persisted_client(auth, client).fetch("clientSecret")
    end

    tokens = auth.api.oauth2_token(body: client_credentials_body(client))
    migrated = persisted_client(auth, client).fetch("clientSecret")
    active = auth.api.oauth2_introspect(body: introspect_body(client, tokens[:access_token]))
    revoked = auth.api.oauth2_revoke(body: revoke_body(client, tokens[:access_token], hint: "access_token"))

    refute_equal legacy_hash, migrated
    assert_equal underlying_secret, BetterAuth::Crypto.symmetric_decrypt(key: auth.context.secret_config, data: migrated)
    assert_equal true, active[:active]
    assert_equal({revoked: true}, revoked)
  end

  def test_jwt_disabled_logout_ignores_installed_jwt_plugin_and_validates_issuer
    auth = build_auth_with_jwt_and_disabled_oauth
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid", enable_end_session: true, skip_consent: true)
    now = Time.now.to_i
    claims = {sub: "user", iss: "http://localhost:3000", aud: client[:client_id], iat: now, exp: now + 300}
    context = Struct.new(:context).new(auth.context)
    jwt_plugin_token = BetterAuth::Plugins::OAuthProtocol.sign_oauth_jwt!(
      context,
      claims,
      issuer: "http://localhost:3000",
      audience: client[:client_id]
    )
    wrong_issuer_token = JWT.encode(claims.merge(iss: "https://wrong-issuer.example"), client[:client_secret], "HS256")

    _payload, header = JWT.decode(jwt_plugin_token, nil, false)
    refute_equal "HS256", header["alg"]
    [jwt_plugin_token, wrong_issuer_token].each do |token|
      error = assert_raises(BetterAuth::APIError) do
        auth.api.oauth2_end_session(query: {id_token_hint: token})
      end
      assert_equal 401, error.status_code
    end
  end

  def test_jwt_disabled_public_client_does_not_receive_id_token
    auth = build_auth(scopes: ["openid"], disable_jwt_plugin: true)
    cookie = sign_up_cookie(auth)
    client = create_client(
      auth,
      cookie,
      scope: "openid",
      skip_consent: true,
      token_endpoint_auth_method: "none",
      grant_types: ["authorization_code"]
    )

    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid")

    assert_nil client[:client_secret]
    assert_nil tokens[:id_token]
  end

  def test_transient_client_secret_is_absent_from_claim_input_and_token_snapshots
    claim_client = nil
    userinfo_client = nil
    auth = build_auth(
      scopes: ["openid", "offline_access"],
      disable_jwt_plugin: true,
      custom_id_token_claims: ->(info) {
        claim_client = info[:client]
        {}
      },
      custom_user_info_claims: ->(info) {
        userinfo_client = info[:client]
        {}
      }
    )
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid offline_access", skip_consent: true)
    tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid offline_access")
    stored_secret = persisted_client(auth, client).fetch("clientSecret")
    auth.api.oauth2_user_info(headers: {"authorization" => "Bearer #{tokens[:access_token]}"})

    [claim_client, userinfo_client].each do |client_snapshot|
      refute_includes client_snapshot.keys, "clientSecret"
      refute_includes client_snapshot.keys, "client_secret"
      refute_includes client_snapshot.keys, "__providedClientSecret"
      refute_includes client_snapshot.values, client[:client_secret]
      refute_includes client_snapshot.values, stored_secret
    end
    assert tokens[:access_token]
    assert tokens[:refresh_token]
  end

  def test_pre_upgrade_shared_token_snapshots_are_scrubbed_before_retention_and_callback_exposure
    legacy_client = {
      "clientId" => "legacy-client",
      "name" => "Retained Client",
      "metadata" => {"tenant" => "acme"},
      "clientSecret" => "stored-secret",
      "client_secret" => "alternate-secret",
      "__providedClientSecret" => "raw-secret"
    }
    access_record = {
      "clientId" => "legacy-client",
      "subject" => "legacy-user",
      "scopes" => ["openid"],
      "expiresAt" => Time.now + 300,
      "user" => {"id" => "legacy-user"},
      "client" => legacy_client.dup
    }
    refresh_record = {"client" => legacy_client.dup}
    shared_store = SharedTokenStore.new(
      tokens: {"legacy-access" => access_record},
      refresh_tokens: {"legacy-refresh" => refresh_record}
    )
    callback_client = nil
    auth = build_auth(
      scopes: ["openid"],
      disable_jwt_plugin: true,
      store: shared_store,
      custom_user_info_claims: ->(info) {
        callback_client = info[:client]
        {}
      }
    )

    assert_redacted_client(access_record.fetch("client"))
    assert_redacted_client(refresh_record.fetch("client"))
    access_record.fetch("client")["clientSecret"] = "reintroduced-secret"
    auth.api.oauth2_user_info(headers: {"authorization" => "Bearer ba_at_legacy-access"})

    assert_redacted_client(access_record.fetch("client"))
    assert_redacted_client(callback_client)
    assert_equal "Retained Client", callback_client["name"]
    assert_equal({"tenant" => "acme"}, callback_client["metadata"])
  end

  def test_implicit_legacy_hash_migrates_on_success_and_new_id_token_uses_client_secret
    auth = build_auth(scopes: ["openid", "read"], disable_jwt_plugin: true)
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid read", skip_consent: true)
    legacy_hash = BetterAuth::Crypto.sha256(client[:client_secret], encoding: :base64url)
    replace_stored_secret(auth, client, legacy_hash)

    access = auth.api.oauth2_token(body: client_credentials_body(client))
    migrated = persisted_client(auth, client).fetch("clientSecret")
    id_tokens = issue_authorization_code_tokens(auth, cookie, client, scope: "openid")

    assert access[:access_token]
    refute_equal legacy_hash, migrated
    assert_equal client[:client_secret], BetterAuth::Crypto.symmetric_decrypt(key: auth.context.secret_config, data: migrated)
    assert JWT.decode(id_tokens[:id_token], client[:client_secret], true, algorithm: "HS256").first
  end

  def test_wrong_secret_and_explicit_encrypted_mode_never_migrate_legacy_hash
    implicit = build_auth(scopes: ["read"], disable_jwt_plugin: true)
    cookie = sign_up_cookie(implicit)
    client = create_client(implicit, cookie, scope: "read")
    legacy_hash = BetterAuth::Crypto.sha256(client[:client_secret], encoding: :base64url)
    replace_stored_secret(implicit, client, legacy_hash)

    wrong = assert_raises(BetterAuth::APIError) do
      implicit.api.oauth2_token(body: client_credentials_body(client.merge(client_secret: "wrong-secret")))
    end
    assert_equal 401, wrong.status_code
    assert_equal legacy_hash, persisted_client(implicit, client).fetch("clientSecret")

    explicit = build_auth(scopes: ["read"], disable_jwt_plugin: true, store_client_secret: "encrypted")
    explicit_cookie = sign_up_cookie(explicit, email: "explicit-encrypted@example.com")
    explicit_client = create_client(explicit, explicit_cookie, scope: "read")
    explicit_hash = BetterAuth::Crypto.sha256(explicit_client[:client_secret], encoding: :base64url)
    replace_stored_secret(explicit, explicit_client, explicit_hash)

    malformed = assert_raises(BetterAuth::APIError) do
      explicit.api.oauth2_token(body: client_credentials_body(explicit_client))
    end
    assert_equal 401, malformed.status_code
    assert_equal explicit_hash, persisted_client(explicit, explicit_client).fetch("clientSecret")
  end

  def test_legacy_migration_does_not_overwrite_a_concurrent_secret_rotation
    adapter = nil
    database = ->(options) {
      adapter = MigrationRaceMemory.new(options)
    }
    auth = build_auth(scopes: ["read"], disable_jwt_plugin: true, database: database)
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "read")
    replace_stored_secret(auth, client, BetterAuth::Crypto.sha256(client[:client_secret], encoding: :base64url))
    rotated_secret = "rotated-by-concurrent-request"
    adapter.replacement_secret = BetterAuth::Crypto.symmetric_encrypt(key: auth.context.secret_config, data: rotated_secret)

    error = assert_raises(BetterAuth::APIError) do
      auth.api.oauth2_token(body: client_credentials_body(client))
    end
    persisted = persisted_client(auth, client).fetch("clientSecret")

    assert_equal 401, error.status_code
    assert_equal rotated_secret, BetterAuth::Crypto.symmetric_decrypt(key: auth.context.secret_config, data: persisted)
  end

  def test_legacy_migration_accepts_a_same_secret_compare_and_swap_winner
    adapter = nil
    database = ->(options) {
      adapter = MigrationRaceMemory.new(options)
    }
    auth = build_auth(scopes: ["read"], disable_jwt_plugin: true, database: database)
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "read")
    replace_stored_secret(auth, client, BetterAuth::Crypto.sha256(client[:client_secret], encoding: :base64url))
    adapter.replacement_secret = BetterAuth::Crypto.symmetric_encrypt(key: auth.context.secret_config, data: client[:client_secret])

    tokens = auth.api.oauth2_token(body: client_credentials_body(client))
    persisted = persisted_client(auth, client).fetch("clientSecret")

    assert tokens[:access_token]
    assert_equal client[:client_secret], BetterAuth::Crypto.symmetric_decrypt(key: auth.context.secret_config, data: persisted)
  end

  def test_malformed_encrypted_values_fail_closed_without_exposing_secrets
    encryption_secret = "current-encryption-key-with-enough-entropy-123"
    auth = build_auth(
      scopes: ["read"],
      disable_jwt_plugin: true,
      secrets: [{version: 1, value: encryption_secret}]
    )
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "read", enable_end_session: true)
    ciphertext = persisted_client(auth, client).fetch("clientSecret")
    tampered = ciphertext.dup
    tampered[-1] = (tampered[-1] == "a") ? "b" : "a"
    unknown_version = ciphertext.sub(/\A\$ba\$1\$/, "$ba$999$")
    wrong_key_config = BetterAuth::SecretConfig.new(
      keys: {1 => "wrong-encryption-key-with-enough-entropy-456"},
      current_version: 1
    )
    wrong_key = BetterAuth::Crypto.symmetric_encrypt(key: wrong_key_config, data: client[:client_secret])
    now = Time.now.to_i
    legacy_id_token = JWT.encode(
      {sub: "user", iss: "http://localhost:3000", aud: client[:client_id], iat: now, exp: now + 300},
      legacy_signing_key(auth, client),
      "HS256"
    )

    ["not-ciphertext", unknown_version, tampered, wrong_key].each do |stored_value|
      replace_stored_secret(auth, client, stored_value)
      error = assert_raises(BetterAuth::APIError) do
        auth.api.oauth2_token(body: client_credentials_body(client))
      end

      assert_equal 401, error.status_code
      assert_match(/invalid_client/, error.message)
      refute_includes error.inspect, client[:client_secret]
      refute_includes error.inspect, stored_value
      assert_equal stored_value, persisted_client(auth, client).fetch("clientSecret")

      logout_error = assert_raises(BetterAuth::APIError) do
        auth.api.oauth2_end_session(query: {id_token_hint: legacy_id_token})
      end
      assert_equal 401, logout_error.status_code
      refute_includes logout_error.inspect, client[:client_secret]
      refute_includes logout_error.inspect, stored_value
    end
  end

  def test_legacy_derived_id_token_is_verify_only_for_end_session
    auth = build_auth(scopes: ["openid", "read"], disable_jwt_plugin: true)
    cookie = sign_up_cookie(auth)
    client = create_client(auth, cookie, scope: "openid read", enable_end_session: true, skip_consent: true)
    replace_stored_secret(auth, client, BetterAuth::Crypto.sha256(client[:client_secret], encoding: :base64url))
    now = Time.now.to_i
    legacy_token = JWT.encode(
      {sub: "legacy-user", iss: "http://localhost:3000", aud: client[:client_id], iat: now, exp: now + 300},
      legacy_signing_key(auth, client),
      "HS256"
    )
    assert JWT.decode(legacy_token, legacy_signing_key(auth, client), true, algorithm: "HS256").first
    assert_raises(JWT::DecodeError) do
      JWT.decode(legacy_token, client[:client_secret], true, algorithm: "HS256")
    end

    assert auth.api.oauth2_token(body: client_credentials_body(client))[:access_token]
    migrated = persisted_client(auth, client).fetch("clientSecret")

    refute_equal BetterAuth::Crypto.sha256(client[:client_secret], encoding: :base64url), migrated
    assert_equal client[:client_secret], BetterAuth::Crypto.symmetric_decrypt(key: auth.context.secret_config, data: migrated)
    assert_equal({status: true}, auth.api.oauth2_end_session(query: {id_token_hint: legacy_token}))
  end

  def test_custom_encryption_survives_reload_and_supports_hs256_and_logout
    custom_key = "custom-client-secret-key-with-enough-entropy"
    storage = {
      encrypt: ->(secret) { BetterAuth::Crypto.symmetric_encrypt(key: custom_key, data: secret) },
      decrypt: ->(secret) { BetterAuth::Crypto.symmetric_decrypt(key: custom_key, data: secret) }
    }
    issuer = build_auth(scopes: ["openid"], disable_jwt_plugin: true, store_client_secret: storage)
    cookie = sign_up_cookie(issuer)
    client = create_client(issuer, cookie, scope: "openid", enable_end_session: true, skip_consent: true)
    stored = persisted_client(issuer, client).fetch("clientSecret")
    code = authorization_code_for(issuer, cookie, client, scope: "openid")
    shared_db = issuer.context.adapter.db
    database = ->(options) { BetterAuth::Adapters::Memory.new(options, shared_db) }
    reloaded = build_auth(
      scopes: ["openid"],
      disable_jwt_plugin: true,
      store_client_secret: storage,
      database: database
    )

    tokens = reloaded.api.oauth2_token(
      body: {
        grant_type: "authorization_code",
        code: code,
        redirect_uri: "https://resource.example/callback",
        client_id: client[:client_id],
        client_secret: client[:client_secret],
        code_verifier: pkce_verifier
      }
    )

    refute_equal client[:client_secret], stored
    assert_equal client[:client_secret], storage[:decrypt].call(stored)
    assert JWT.decode(tokens[:id_token], client[:client_secret], true, algorithm: "HS256").first
    assert_equal({status: true}, reloaded.api.oauth2_end_session(query: {id_token_hint: tokens[:id_token]}))
  end

  def test_secret_config_rotation_decrypts_old_rows_and_writes_with_current_version
    old_secret = "old-oauth-secret-with-enough-entropy-123"
    new_secret = "new-oauth-secret-with-enough-entropy-456"
    initial = build_auth(
      scopes: ["read"],
      disable_jwt_plugin: true,
      secrets: [{version: 1, value: old_secret}]
    )
    cookie = sign_up_cookie(initial)
    client = create_client(initial, cookie, scope: "read")
    assert_match(/\A\$ba\$1\$/, persisted_client(initial, client).fetch("clientSecret"))

    shared_db = initial.context.adapter.db
    database = ->(options) { BetterAuth::Adapters::Memory.new(options, shared_db) }
    rotated = build_auth(
      scopes: ["read"],
      disable_jwt_plugin: true,
      database: database,
      secrets: [{version: 2, value: new_secret}, {version: 1, value: old_secret}]
    )

    assert rotated.api.oauth2_token(body: client_credentials_body(client))[:access_token]
    rotated_cookie = sign_up_cookie(rotated, email: "rotated-key-owner@example.com")
    current_client = create_client(rotated, rotated_cookie, scope: "read")
    assert_match(/\A\$ba\$2\$/, persisted_client(rotated, current_client).fetch("clientSecret"))
  end

  private

  def persisted_client(auth, client)
    auth.context.adapter.find_one(model: "oauthClient", where: [{field: "clientId", value: client[:client_id]}])
  end

  def replace_stored_secret(auth, client, value)
    auth.context.adapter.update(
      model: "oauthClient",
      where: [{field: "clientId", value: client[:client_id]}],
      update: {clientSecret: value}
    )
  end

  def client_credentials_body(client)
    {
      grant_type: "client_credentials",
      scope: "read",
      client_id: client[:client_id],
      client_secret: client[:client_secret]
    }
  end

  def legacy_signing_key(auth, client)
    context = Struct.new(:context).new(auth.context)
    BetterAuth::Plugins::OAuthProtocol.legacy_id_token_hs256_key(context, client[:client_id])
  end

  def basic_auth_headers(client, secret = client[:client_secret])
    credentials = Base64.strict_encode64("#{client[:client_id]}:#{secret}")
    {"authorization" => "Basic #{credentials}"}
  end

  def assert_redacted_client(client)
    %w[clientSecret client_secret __providedClientSecret].each do |field|
      refute_includes client.keys, field
    end
  end

  def build_auth_with_jwt_and_disabled_oauth
    BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      database: :memory,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.jwt(jwks: {key_pair_config: {alg: "EdDSA"}}),
        BetterAuth::Plugins.oauth_provider(
          scopes: ["openid"],
          allow_dynamic_client_registration: true,
          disable_jwt_plugin: true
        )
      ]
    )
  end
end
