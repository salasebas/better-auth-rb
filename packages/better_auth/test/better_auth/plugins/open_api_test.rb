# frozen_string_literal: true

require "json"
require_relative "../../test_helper"

class BetterAuthPluginsOpenAPITest < Minitest::Test
  SECRET = "phase-seven-secret-with-enough-entropy-123"

  def test_open_api_generates_schema_from_routes_and_models
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.jwt,
        BetterAuth::Plugins.open_api
      ],
      user: {
        additional_fields: {
          role: {type: "string", required: true, default_value: "user"},
          preferences: {type: "string", required: false}
        }
      }
    )

    schema = auth.api.generate_open_api_schema

    assert_equal "3.1.1", schema[:openapi]
    assert_equal "Better Auth", schema.dig(:info, :title)
    assert_equal "API Reference for your Better Auth Instance", schema.dig(:info, :description)
    assert_equal "1.1.0", schema.dig(:info, :version)
    assert_equal({type: "string"}, schema.dig(:components, :schemas, :User, :properties, :id))
    assert_equal "user", schema.dig(:components, :schemas, :User, :properties, :role, :default)
    assert_includes schema.dig(:components, :schemas, :User, :required), "role"
    assert_includes schema[:paths].keys, "/sign-in/social"
    assert_includes schema[:paths].keys, "/token"
    refute_includes schema[:paths].keys, "/open-api/generate-schema"
    assert_equal [{url: "http://localhost:3000/api/auth"}], schema[:servers]
    assert_equal(
      {
        apiKeyCookie: {
          type: "apiKey",
          in: "cookie",
          name: "apiKeyCookie",
          description: "API Key authentication via cookie"
        },
        bearerAuth: {
          type: "http",
          scheme: "bearer",
          description: "Bearer token authentication"
        }
      },
      schema.dig(:components, :securitySchemes)
    )
  end

  def test_open_api_base_path_inventory_matches_upstream_snapshot
    auth = build_auth(plugins: [BetterAuth::Plugins.open_api])

    schema = auth.api.generate_open_api_schema

    assert_equal(
      [
        "/account-info",
        "/callback/{id}",
        "/change-email",
        "/change-password",
        "/delete-user",
        "/delete-user/callback",
        "/error",
        "/get-access-token",
        "/get-session",
        "/link-social",
        "/list-accounts",
        "/list-sessions",
        "/ok",
        "/refresh-token",
        "/request-password-reset",
        "/reset-password",
        "/reset-password/{token}",
        "/revoke-other-sessions",
        "/revoke-session",
        "/revoke-sessions",
        "/send-verification-email",
        "/sign-in/email",
        "/sign-in/social",
        "/sign-out",
        "/sign-up/email",
        "/unlink-account",
        "/update-session",
        "/update-user",
        "/verify-email",
        "/verify-password"
      ],
      schema[:paths].keys.sort
    )
  end

  def test_open_api_base_routes_have_upstream_rich_schemas
    auth = build_auth(plugins: [BetterAuth::Plugins.open_api])

    schema = auth.api.generate_open_api_schema

    assert_equal(
      {
        type: "object",
        properties: {
          ok: {
            type: "boolean",
            description: "Indicates if the API is working"
          }
        },
        required: ["ok"]
      },
      json_schema(schema, "/ok", :get, "200")
    )
    assert_equal(
      {
        type: "object",
        properties: {
          user: {
            type: "object",
            properties: {
              id: {type: "string"},
              name: {type: "string"},
              email: {type: "string"},
              image: {type: "string"},
              emailVerified: {type: "boolean"}
            },
            required: ["id", "emailVerified"]
          },
          data: {
            type: "object",
            properties: {},
            additionalProperties: true
          }
        },
        required: ["user", "data"],
        additionalProperties: false
      },
      json_schema(schema, "/account-info", :get, "200")
    )
    assert_equal(
      {
        type: "object",
        properties: {
          html: {
            type: "string",
            description: "The HTML content of the error page"
          }
        },
        required: ["html"]
      },
      json_schema(schema, "/error", :get, "200")
    )
  end

  def test_open_api_model_schema_matches_upstream_field_metadata
    auth = build_auth(plugins: [BetterAuth::Plugins.open_api])

    schema = auth.api.generate_open_api_schema

    assert_equal(
      {type: "boolean", default: false, readOnly: true},
      schema.dig(:components, :schemas, :User, :properties, :emailVerified)
    )
    assert_equal(
      {type: "string", format: "date-time", default: "Generated at runtime"},
      schema.dig(:components, :schemas, :User, :properties, :createdAt)
    )
    refute_includes schema.dig(:components, :schemas, :User, :required), "emailVerified"
    assert_includes schema.dig(:components, :schemas, :Session, :required), "token"
  end

  def test_open_api_uses_upstream_31_nullable_request_body_shapes
    auth = build_auth(plugins: [BetterAuth::Plugins.open_api])

    schema = auth.api.generate_open_api_schema
    social_body = schema.dig(:paths, "/sign-in/social", :post, :requestBody, :content, "application/json", :schema)
    id_token = social_body.dig(:properties, :idToken)

    assert_equal ["object", "null"], id_token[:type]
    assert_equal "string", id_token.dig(:properties, :token, :type)
    assert_equal ["string", "null"], id_token.dig(:properties, :accessToken, :type)
    assert_equal ["string", "null"], id_token.dig(:properties, :refreshToken, :type)
    assert_nil id_token.dig(:properties, :accessToken, :nullable)
    assert_nil id_token[:nullable]
    assert_includes id_token[:required], "token"
    refute_includes social_body.fetch(:required), "idToken"
  end

  def test_open_api_uses_upstream_31_nullable_get_session_response_shape
    auth = build_auth(plugins: [BetterAuth::Plugins.open_api])

    schema = auth.api.generate_open_api_schema
    get_session = schema.dig(:paths, "/get-session", :post, :responses, "200", :content, "application/json", :schema)

    assert_equal ["object", "null"], get_session[:type]
    assert_nil get_session[:nullable]
    assert_equal({type: "object", "$ref": "#/components/schemas/Session"}, get_session.dig(:properties, :session))
    assert_equal({type: "object", "$ref": "#/components/schemas/User"}, get_session.dig(:properties, :user))
  end

  def test_core_route_open_api_metadata_lives_on_endpoints
    {
      account_info: "accountInfo",
      change_email: "changeEmail",
      change_password: "changePassword",
      callback_oauth: "callbackOAuth",
      delete_user: "deleteUser",
      delete_user_callback: "deleteUserCallback",
      get_access_token: "getAccessToken",
      get_session: "getSession",
      link_social: "linkSocialAccount",
      link_social_account: "linkSocialAccount",
      list_accounts: "listUserAccounts",
      list_user_accounts: "listUserAccounts",
      list_sessions: "listSessions",
      refresh_token: "refreshToken",
      request_password_reset: "requestPasswordReset",
      request_password_reset_callback: "requestPasswordResetCallback",
      reset_password: "resetPassword",
      revoke_other_sessions: "revokeOtherSessions",
      revoke_session: "revokeSession",
      revoke_sessions: "revokeSessions",
      send_verification_email: "sendVerificationEmail",
      set_password: "setPassword",
      sign_in_email: "signInEmail",
      sign_in_social: "socialSignIn",
      sign_out: "signOut",
      sign_up_email: "signUpWithEmailAndPassword",
      unlink_account: "unlinkAccount",
      update_session: "updateSession",
      update_user: "updateUser",
      verify_email: "verifyEmail",
      verify_password: "verifyPassword"
    }.each do |route, operation_id|
      metadata = BetterAuth::Core.base_endpoints.fetch(route).metadata.fetch(:openapi)

      assert_equal operation_id, metadata.fetch(:operationId)
      assert metadata[:requestBody] || metadata[:responses]
    end
  end

  def test_account_info_open_api_account_id_query_parameter_is_optional
    parameters = BetterAuth::Core.base_endpoints
      .fetch(:account_info)
      .metadata
      .fetch(:openapi)
      .fetch(:parameters)
    account_id = parameters.find { |parameter| parameter.fetch(:name) == "accountId" }

    assert_equal false, account_id.fetch(:required)
  end

  def test_auth_plugin_route_open_api_metadata_lives_on_endpoints
    {
      BetterAuth::Plugins.anonymous => {
        sign_in_anonymous: "signInAnonymous",
        delete_anonymous_user: "deleteAnonymousUser"
      },
      BetterAuth::Plugins.magic_link => {
        sign_in_magic_link: "signInMagicLink",
        magic_link_verify: "magicLinkVerify"
      },
      BetterAuth::Plugins.one_time_token => {
        generate_one_time_token: "generateOneTimeToken",
        verify_one_time_token: "verifyOneTimeToken"
      },
      BetterAuth::Plugins.username => {
        sign_in_username: "signInUsername",
        is_username_available: "isUsernameAvailable"
      },
      BetterAuth::Plugins.phone_number => {
        sign_in_phone_number: "signInPhoneNumber",
        send_phone_number_otp: "sendPhoneNumberOTP",
        verify_phone_number: "verifyPhoneNumber",
        request_password_reset_phone_number: "requestPasswordResetPhoneNumber",
        reset_password_phone_number: "resetPasswordPhoneNumber"
      },
      BetterAuth::Plugins.email_otp => {
        send_verification_otp: "sendVerificationOTP",
        get_verification_otp: "getVerificationOTP",
        check_verification_otp: "checkVerificationOTP",
        verify_email_otp: "verifyEmailOTP",
        sign_in_email_otp: "signInEmailOTP",
        request_email_change_email_otp: "requestEmailChangeOTP",
        change_email_email_otp: "changeEmailWithEmailOTP",
        request_password_reset_email_otp: "requestPasswordResetEmailOTP",
        forget_password_email_otp: "forgetPasswordEmailOTP",
        reset_password_email_otp: "resetPasswordEmailOTP"
      },
      BetterAuth::Plugins.siwe => {
        get_siwe_nonce: "getSiweNonce",
        verify_siwe_message: "verifySiweMessage"
      }
    }.each do |plugin, routes|
      routes.each do |route, operation_id|
        metadata = plugin.endpoints.fetch(route).metadata.fetch(:openapi)

        assert_equal operation_id, metadata.fetch(:operationId)
        assert metadata[:requestBody] || metadata[:responses]
      end
    end
  end

  def test_public_plugin_endpoints_receive_default_open_api_metadata
    endpoint = BetterAuth::Endpoint.new(path: "/custom-plugin-route", method: "POST") {}
    metadata = endpoint.metadata.fetch(:openapi)

    assert_equal "postCustomPluginRoute", metadata.fetch(:operationId)
    assert_equal "Execute the postCustomPluginRoute endpoint.", metadata.fetch(:description)
    assert_equal BetterAuth::OpenAPI.default_request_body, metadata.fetch(:requestBody)
    assert meaningful_responses?(metadata.fetch(:responses))
  end

  def test_admin_and_multi_session_route_open_api_metadata_lives_on_endpoints
    {
      BetterAuth::Plugins.admin => {
        set_role: "setUserRole",
        get_user: "getUser",
        create_user: "createUser",
        admin_update_user: "adminUpdateUser",
        list_users: "listUsers",
        list_user_sessions: "adminListUserSessions",
        unban_user: "unbanUser",
        ban_user: "banUser",
        impersonate_user: "impersonateUser",
        stop_impersonating: "stopImpersonating",
        revoke_user_session: "revokeUserSession",
        revoke_user_sessions: "revokeUserSessions",
        remove_user: "removeUser",
        set_user_password: "setUserPassword",
        user_has_permission: "hasPermission"
      },
      BetterAuth::Plugins.multi_session => {
        list_device_sessions: "listDeviceSessions",
        set_active_session: "setActiveSession",
        revoke_device_session: "revokeDeviceSession"
      }
    }.each do |plugin, routes|
      routes.each do |route, operation_id|
        metadata = plugin.endpoints.fetch(route).metadata.fetch(:openapi)

        assert_equal operation_id, metadata.fetch(:operationId)
        assert metadata[:requestBody] || metadata[:responses]
      end
    end
  end

  def test_organization_route_open_api_metadata_lives_on_endpoints
    plugin = BetterAuth::Plugins.organization(
      teams: {enabled: true},
      dynamic_access_control: {enabled: true}
    )

    {
      create_organization: "createOrganization",
      check_organization_slug: "checkOrganizationSlug",
      list_organizations: "listOrganizations",
      update_organization: "updateOrganization",
      delete_organization: "deleteOrganization",
      set_active_organization: "setActiveOrganization",
      get_full_organization: "getOrganization",
      create_invitation: "createOrganizationInvitation",
      accept_invitation: "acceptOrganizationInvitation",
      reject_invitation: "rejectOrganizationInvitation",
      cancel_invitation: "cancelOrganizationInvitation",
      get_invitation: "getOrganizationInvitation",
      list_invitations: "listOrganizationInvitations",
      list_user_invitations: "listUserInvitations",
      add_member: "addOrganizationMember",
      remove_member: "removeOrganizationMember",
      update_member_role: "updateOrganizationMemberRole",
      get_active_member: "getActiveOrganizationMember",
      get_active_member_role: "getActiveOrganizationMemberRole",
      leave_organization: "leaveOrganization",
      list_members: "listOrganizationMembers",
      has_permission: "hasOrganizationPermission",
      create_team: "createOrganizationTeam",
      list_organization_teams: "listOrganizationTeams",
      update_team: "updateOrganizationTeam",
      remove_team: "removeOrganizationTeam",
      set_active_team: "setActiveOrganizationTeam",
      list_user_teams: "listUserTeams",
      list_team_members: "listTeamMembers",
      add_team_member: "addTeamMember",
      remove_team_member: "removeTeamMember",
      create_org_role: "createOrganizationRole",
      list_org_roles: "listOrganizationRoles",
      get_org_role: "getOrganizationRole",
      update_org_role: "updateOrganizationRole",
      delete_org_role: "deleteOrganizationRole"
    }.each do |route, operation_id|
      metadata = plugin.endpoints.fetch(route).metadata.fetch(:openapi)

      assert_equal operation_id, metadata.fetch(:operationId)
      assert metadata.fetch(:responses)
    end
  end

  def test_oauth_jwt_mcp_and_device_route_open_api_metadata_lives_on_endpoints
    {
      BetterAuth::Plugins.jwt => {
        get_jwks: "getJSONWebKeySet",
        get_token: "getJSONWebToken"
      },
      BetterAuth::Plugins.generic_oauth(config: []) => {
        sign_in_with_oauth2: "signInOAuth2",
        o_auth2_callback: "oauth2Callback",
        o_auth2_link_account: "linkOAuth2"
      },
      BetterAuth::Plugins.device_authorization => {
        device_code: "requestDeviceCode",
        device_token: "exchangeDeviceToken",
        device_verify: "getDeviceVerification",
        device_approve: "approveDevice",
        device_deny: "denyDevice"
      },
      BetterAuth::Plugins.oauth_proxy => {
        o_auth_proxy: "oauthProxyCallback"
      }
    }.each do |plugin, routes|
      routes.each do |route, operation_id|
        metadata = plugin.endpoints.fetch(route).metadata.fetch(:openapi)

        assert_equal operation_id, metadata.fetch(:operationId)
        assert metadata.fetch(:responses)
      end
    end
  end

  def test_two_factor_and_small_plugin_route_open_api_metadata_lives_on_endpoints
    {
      BetterAuth::Plugins.two_factor => {
        enable_two_factor: "enableTwoFactor",
        disable_two_factor: "disableTwoFactor",
        generate_totp: "generateTOTP",
        get_totp_uri: "getTOTPURI",
        verify_totp: "verifyTOTP",
        send_two_factor_otp: "sendTwoFactorOTP",
        verify_two_factor_otp: "verifyTwoFactorOTP",
        verify_backup_code: "verifyBackupCode",
        generate_backup_codes: "generateBackupCodes"
      },
      BetterAuth::Plugins.dub => {
        dub_link: "dubLink"
      },
      BetterAuth::Plugins.expo => {
        expo_authorization_proxy: "expoAuthorizationProxy"
      },
      BetterAuth::Plugins.one_tap => {
        one_tap_callback: "oneTapCallback"
      }
    }.each do |plugin, routes|
      routes.each do |route, operation_id|
        metadata = plugin.endpoints.fetch(route).metadata.fetch(:openapi)

        assert_equal operation_id, metadata.fetch(:operationId)
        assert metadata.fetch(:responses)
      end
    end
  end

  def test_open_api_unwraps_default_values_and_boolean_types
    auth = build_auth(plugins: [BetterAuth::Plugins.open_api])

    schema = auth.api.generate_open_api_schema
    sign_in = schema.dig(:paths, "/sign-in/email", :post, :requestBody, :content, "application/json", :schema, :properties)
    sign_up = schema.dig(:paths, "/sign-up/email", :post, :requestBody, :content, "application/json", :schema, :properties)

    assert_equal ["boolean", "null"], sign_in.dig(:rememberMe, :type)
    assert_equal true, sign_in.dig(:rememberMe, :default)
    assert_equal "boolean", sign_up.dig(:rememberMe, :type)
    refute sign_up.fetch(:rememberMe).key?(:default)
  end

  def test_open_api_matches_upstream_change_email_schema
    auth = build_auth(plugins: [BetterAuth::Plugins.open_api])

    schema = auth.api.generate_open_api_schema
    operation = schema.dig(:paths, "/change-email", :post)
    body_schema = operation.dig(:requestBody, :content, "application/json", :schema)

    assert_nil operation[:description]
    assert_equal "changeEmail", operation[:operationId]
    assert_equal true, operation.dig(:requestBody, :required)
    assert_equal ["newEmail"], body_schema[:required]
    assert_equal(
      {type: "string", description: "The new email address to set must be a valid email address"},
      body_schema.dig(:properties, :newEmail)
    )
    assert_equal(
      {type: ["string", "null"], description: "The URL to redirect to after email verification"},
      body_schema.dig(:properties, :callbackURL)
    )
    assert_equal "Email change request processed successfully", operation.dig(:responses, "200", :description)
    assert_equal "Unprocessable Entity. Email already exists", operation.dig(:responses, "422", :description)
    assert_equal ["status"], operation.dig(:responses, "200", :content, "application/json", :schema, :required)
    assert_equal(
      {type: "boolean", description: "Indicates if the request was successful"},
      operation.dig(:responses, "200", :content, "application/json", :schema, :properties, :status)
    )
  end

  def test_open_api_matches_upstream_change_password_schema
    auth = build_auth(plugins: [BetterAuth::Plugins.open_api])

    schema = auth.api.generate_open_api_schema
    operation = schema.dig(:paths, "/change-password", :post)
    body_schema = operation.dig(:requestBody, :content, "application/json", :schema)
    response_schema = operation.dig(:responses, "200", :content, "application/json", :schema)

    assert_equal "Change the password of the user", operation[:description]
    assert_equal "changePassword", operation[:operationId]
    assert_equal true, operation.dig(:requestBody, :required)
    assert_equal ["newPassword", "currentPassword"], body_schema[:required]
    assert_equal(
      {type: "string", description: "The new password to set"},
      body_schema.dig(:properties, :newPassword)
    )
    assert_equal(
      {type: ["boolean", "null"], description: "Must be a boolean value"},
      body_schema.dig(:properties, :revokeOtherSessions)
    )
    assert_equal "Password successfully changed", operation.dig(:responses, "200", :description)
    assert_equal ["user"], response_schema[:required]
    assert_equal(
      {type: "string", nullable: true, description: "New session token if other sessions were revoked"},
      response_schema.dig(:properties, :token)
    )
    assert_equal "email", response_schema.dig(:properties, :user, :properties, :email, :format)
    assert_equal "uri", response_schema.dig(:properties, :user, :properties, :image, :format)
    assert_equal ["id", "email", "name", "emailVerified", "createdAt", "updatedAt"], response_schema.dig(:properties, :user, :required)
  end

  def test_open_api_adds_default_operation_metadata_and_path_parameters
    auth = build_auth(plugins: [BetterAuth::Plugins.open_api])

    schema = auth.api.generate_open_api_schema
    callback = schema.dig(:paths, "/callback/{id}", :get)

    assert callback
    assert_equal ["Default"], callback[:tags]
    assert_equal [{bearerAuth: []}], callback[:security]
    assert_equal(
      [{name: "id", in: "path", required: true, schema: {type: "string"}}],
      callback[:parameters]
    )
    assert_includes callback[:responses].keys, "400"
    assert_equal(
      "Bad Request. Usually due to missing parameters, or invalid parameters.",
      callback.dig(:responses, "400", :description)
    )
  end

  def test_open_api_reference_returns_html
    auth = build_auth(plugins: [BetterAuth::Plugins.open_api(theme: "moon", nonce: "abc123")])

    status, headers, body = auth.api.open_api_reference(as_response: true)

    assert_equal 200, status
    assert_equal "text/html", headers["content-type"]
    assert_includes body.join, "Scalar API Reference"
    assert_includes body.join, "nonce=\"abc123\""
    assert_includes body.join, "var configuration = {"
    assert_includes body.join, "favicon: \"data:image/svg+xml;utf8,"
    assert_includes body.join, "theme: \"moon\""
    assert_includes body.join, "metaData: {"
    assert_includes body.join, "title: \"Better Auth API\""
    assert_includes body.join, "document.getElementById('api-reference').dataset.configuration"
  end

  def test_open_api_reference_can_be_disabled
    auth = build_auth(plugins: [BetterAuth::Plugins.open_api(disable_default_reference: true)])

    error = assert_raises(BetterAuth::APIError) do
      auth.api.open_api_reference
    end

    assert_equal 404, error.status_code
  end

  def test_open_api_respects_disabled_paths
    auth = build_auth(
      disabled_paths: ["/sign-in/social"],
      plugins: [BetterAuth::Plugins.open_api]
    )

    schema = auth.api.generate_open_api_schema

    refute_includes schema[:paths].keys, "/sign-in/social"
  end

  def test_open_api_schema_excludes_removed_core_provider_plugins
    auth = build_auth(plugins: [BetterAuth::Plugins.open_api])
    schema = auth.api.generate_open_api_schema
    paths = schema[:paths].keys

    refute paths.any? { |path| path.start_with?("/mcp/") }
    refute_includes paths, "/oauth2/authorize"
  end

  def test_visible_core_plugin_endpoints_have_rich_open_api_metadata
    plugins = [
      BetterAuth::Plugins.admin,
      BetterAuth::Plugins.anonymous,
      BetterAuth::Plugins.device_authorization,
      BetterAuth::Plugins.dub,
      BetterAuth::Plugins.email_otp,
      BetterAuth::Plugins.expo,
      BetterAuth::Plugins.generic_oauth(config: []),
      BetterAuth::Plugins.jwt,
      BetterAuth::Plugins.magic_link,
      BetterAuth::Plugins.multi_session,
      BetterAuth::Plugins.oauth_proxy,
      BetterAuth::Plugins.one_tap,
      BetterAuth::Plugins.one_time_token,
      BetterAuth::Plugins.organization(teams: {enabled: true}, dynamic_access_control: {enabled: true}),
      BetterAuth::Plugins.phone_number,
      BetterAuth::Plugins.siwe,
      BetterAuth::Plugins.two_factor,
      BetterAuth::Plugins.username
    ]

    missing = plugins.flat_map do |plugin|
      plugin.endpoints.filter_map do |key, endpoint|
        next unless endpoint.path
        next if endpoint.metadata[:hide] || endpoint.metadata[:SERVER_ONLY] || endpoint.metadata[:server_only]

        openapi = endpoint.metadata[:openapi]
        responses = openapi && openapi[:responses]
        request_body = openapi && openapi[:requestBody]
        default_descriptions = endpoint.methods.reject { |method| method == "*" }.map { |method| "#{method} #{endpoint.path}" }
        next if openapi &&
          openapi[:operationId].to_s != "" &&
          !default_descriptions.include?(openapi[:description].to_s) &&
          meaningful_responses?(responses) &&
          (!request_body_method?(endpoint) || meaningful_request_body?(request_body))

        "#{plugin.id}.#{key}"
      end
    end

    assert_empty missing
  end

  private

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET, database: :memory}.merge(options).merge(email_and_password: email_and_password))
  end

  def json_schema(schema, path, method, status)
    schema.dig(:paths, path, method, :responses, status, :content, "application/json", :schema)
  end

  def meaningful_schema?(schema)
    return false unless schema.is_a?(Hash)
    return true if schema[:additionalProperties] || schema[:$ref]
    return true if schema[:items]
    return true if schema[:properties]&.any?
    Array(schema[:type]).include?("null") && Array(schema[:type]).length > 1
  end

  def meaningful_responses?(responses)
    return false unless responses.is_a?(Hash) && responses.any?

    responses.any? do |status, response|
      schema = response.dig(:content, "application/json", :schema)
      meaningful_schema?(schema) || (status.to_s.start_with?("3") && response[:description].to_s != "")
    end
  end

  def request_body_method?(endpoint)
    endpoint.methods.any? { |method| %w[POST PUT PATCH].include?(method) }
  end

  def meaningful_request_body?(request_body)
    schema = request_body&.dig(:content, "application/json", :schema)
    return false unless schema.is_a?(Hash)
    return false if schema[:additionalProperties] == true && schema[:properties] == {}

    meaningful_schema?(schema) || schema.key?(:properties)
  end
end
