# frozen_string_literal: true

require_relative "../scim_test_helper"

class BetterAuthPluginsScimTest < Minitest::Test
  include SCIMTestHelper

  def test_scim_plugin_surface_exposes_version_client_and_hidden_metadata
    plugin = BetterAuth::Plugins.scim

    assert_equal BetterAuth::SCIM::VERSION, plugin.version
    assert_equal "scim-client", plugin.client.fetch("id")
    assert_equal BetterAuth::SCIM::VERSION, plugin.client.fetch("version")
    assert_equal "scim", plugin.client.fetch("serverPluginId")
    assert_equal true, plugin.endpoints.fetch(:create_scim_user).metadata.fetch(:hide)
    assert_equal "Create SCIM user.", plugin.endpoints.fetch(:create_scim_user).metadata.fetch(:openapi).fetch(:summary)
    refute plugin.endpoints.fetch(:generate_scim_token).metadata.fetch(:hide, false)

    auth = build_auth(plugins: [BetterAuth::Plugins.scim, BetterAuth::Plugins.open_api])
    paths = auth.api.generate_openapi_schema.fetch(:paths)

    assert paths.key?("/scim/generate-token")
    refute paths.key?("/scim/v2/Users")
    refute paths.key?("/scim/v2/ServiceProviderConfig")
  end

  def test_visible_endpoints_have_complete_open_api_metadata
    plugin = BetterAuth::Plugins.scim
    missing = plugin.endpoints.filter_map do |key, endpoint|
      next unless endpoint.path
      next if endpoint.metadata[:hide] || endpoint.metadata[:SERVER_ONLY] || endpoint.metadata[:server_only]

      "#{plugin.id}.#{key}" unless rich_openapi?(endpoint)
    end

    assert_empty missing
  end

  def test_scim_sql_schema_declares_global_provider_uniqueness
    auth = build_auth
    postgres = BetterAuth::Schema::SQL.create_statements(auth.context.options, dialect: :postgres).grep(/scim_provider/).join("\n")
    sqlite = BetterAuth::Schema::SQL.create_statements(auth.context.options, dialect: :sqlite).grep(/scim_provider/).join("\n")
    mysql = BetterAuth::Schema::SQL.create_statements(auth.context.options, dialect: :mysql).grep(/scim_provider/).join("\n")
    mssql = BetterAuth::Schema::SQL.create_statements(auth.context.options, dialect: :mssql).grep(/scim_provider/).join("\n")

    assert_includes postgres, 'UNIQUE ("provider_id")'
    assert_includes postgres, 'UNIQUE ("scim_token")'
    assert_includes sqlite, 'UNIQUE ("provider_id")'
    assert_includes sqlite, 'UNIQUE ("scim_token")'
    assert_includes mysql, "UNIQUE KEY `uniq_scim_providers_provider_id` (`provider_id`)"
    assert_includes mysql, "UNIQUE KEY `uniq_scim_providers_scim_token` (`scim_token`)"
    assert_includes mssql, "CONSTRAINT [uniq_scim_providers_provider_id] UNIQUE ([provider_id])"
    assert_includes mssql, "CONSTRAINT [uniq_scim_providers_scim_token] UNIQUE ([scim_token])"
  end

  def test_scim_fields_reach_migration_projection
    auth = build_auth
    fields = BetterAuth::Schema.migration_tables(auth.context.options).fetch("scim_providers").fetch(:fields)

    assert_includes fields, "provider_id"
    assert_includes fields, "scim_token"
    assert_equal true, fields.fetch("provider_id").fetch(:unique)
    assert_equal true, fields.fetch("scim_token").fetch(:unique)
  end

  def test_scim_metadata_endpoints_match_scim_v2_shapes
    auth = build_auth

    config = auth.api.get_scim_service_provider_config
    assert_equal ["urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"], config.fetch(:schemas)
    assert_equal true, config.fetch(:patch).fetch(:supported)
    assert_equal({supported: false}, config.fetch(:bulk))
    assert_equal({supported: true}, config.fetch(:filter))
    assert_equal({resourceType: "ServiceProviderConfig"}, config.fetch(:meta))
    assert_equal true, config.fetch(:authenticationSchemes).first.fetch(:primary)

    schemas = auth.api.get_scim_schemas
    assert_equal ["urn:ietf:params:scim:api:messages:2.0:ListResponse"], schemas.fetch(:schemas)
    assert_equal 1, schemas.fetch(:itemsPerPage)
    assert_equal 1, schemas.fetch(:startIndex)
    assert_operator schemas.fetch(:Resources).length, :>=, 1

    user_schema = auth.api.get_scim_schema(params: {schemaId: "urn:ietf:params:scim:schemas:core:2.0:User"})
    assert_equal "User", user_schema.fetch(:name)
    assert user_schema.fetch(:attributes).any? { |attribute| attribute.fetch(:name) == "emails" }

    resource_types = auth.api.get_scim_resource_types
    assert_equal ["urn:ietf:params:scim:api:messages:2.0:ListResponse"], resource_types.fetch(:schemas)
    assert_equal 1, resource_types.fetch(:itemsPerPage)
    assert_equal 1, resource_types.fetch(:startIndex)
    assert_equal ["User"], resource_types.fetch(:Resources).map { |resource| resource.fetch(:name) }

    resource_type = auth.api.get_scim_resource_type(params: {resourceTypeId: "User"})
    assert_equal "/Users", resource_type.fetch(:endpoint)
    assert_equal "ResourceType", resource_type.fetch(:meta).fetch(:resourceType)

    schema_error = assert_raises(BetterAuth::APIError) do
      auth.api.get_scim_schema(params: {schemaId: "unknown"})
    end
    assert_equal 404, schema_error.status_code
    assert_equal ["urn:ietf:params:scim:api:messages:2.0:Error"], schema_error.body.fetch(:schemas)

    resource_type_error = assert_raises(BetterAuth::APIError) do
      auth.api.get_scim_resource_type(params: {resourceTypeId: "unknown"})
    end
    assert_equal 404, resource_type_error.status_code
    assert_equal ["urn:ietf:params:scim:api:messages:2.0:Error"], resource_type_error.body.fetch(:schemas)
  end

  def test_scim_metadata_endpoints_match_upstream_snapshots
    auth = build_auth
    base_url = auth.context.base_url

    assert_equal(
      {
        authenticationSchemes: [
          {
            description: "Authentication scheme using the Authorization header with a bearer token tied to an organization.",
            name: "OAuth Bearer Token",
            primary: true,
            specUri: "http://www.rfc-editor.org/info/rfc6750",
            type: "oauthbearertoken"
          }
        ],
        bulk: {supported: false},
        changePassword: {supported: false},
        etag: {supported: false},
        filter: {supported: true},
        meta: {resourceType: "ServiceProviderConfig"},
        patch: {supported: true},
        schemas: ["urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"],
        sort: {supported: false}
      },
      auth.api.get_scim_service_provider_config
    )

    expected_user_schema = expected_upstream_user_schema(base_url)
    assert_equal(
      {
        schemas: ["urn:ietf:params:scim:api:messages:2.0:ListResponse"],
        Resources: [expected_user_schema],
        totalResults: 1,
        itemsPerPage: 1,
        startIndex: 1
      },
      auth.api.get_scim_schemas
    )
    assert_equal expected_user_schema, auth.api.get_scim_schema(params: {schemaId: "urn:ietf:params:scim:schemas:core:2.0:User"})

    expected_resource_type = {
      schemas: ["urn:ietf:params:scim:schemas:core:2.0:ResourceType"],
      id: "User",
      name: "User",
      endpoint: "/Users",
      description: "User Account",
      schema: "urn:ietf:params:scim:schemas:core:2.0:User",
      meta: {
        resourceType: "ResourceType",
        location: "#{base_url}/scim/v2/ResourceTypes/User"
      }
    }
    assert_equal(
      {
        schemas: ["urn:ietf:params:scim:api:messages:2.0:ListResponse"],
        Resources: [expected_resource_type],
        totalResults: 1,
        itemsPerPage: 1,
        startIndex: 1
      },
      auth.api.get_scim_resource_types
    )
    assert_equal expected_resource_type, auth.api.get_scim_resource_type(params: {resourceTypeId: "User"})
  end

  def test_scim_errors_use_scim_error_shape
    auth = build_auth

    status, _headers, body = auth.api.create_scim_user(as_response: true, body: {userName: "anon@example.com"})
    error = JSON.parse(body.join)

    assert_equal 401, status
    assert_equal ["urn:ietf:params:scim:api:messages:2.0:Error"], error.fetch("schemas")
    assert_equal "401", error.fetch("status")
    assert_equal "SCIM token is required", error.fetch("detail")
  end

  def test_scim_validates_user_and_patch_bodies
    auth = build_auth
    cookie = sign_up_cookie(auth)
    token = auth.api.generate_scim_token(headers: {"cookie" => cookie}, body: {providerId: "okta"}).fetch(:scimToken)
    headers = bearer(token)

    missing_user_name = assert_raises(BetterAuth::APIError) do
      auth.api.create_scim_user(headers: headers, body: {emails: [{value: "valid@example.com"}]})
    end
    assert_equal 400, missing_user_name.status_code
    assert_equal "Validation Error", missing_user_name.message

    invalid_email = assert_raises(BetterAuth::APIError) do
      auth.api.create_scim_user(headers: headers, body: {userName: "username", emails: [{value: "not-an-email"}]})
    end
    assert_equal 400, invalid_email.status_code
    assert_equal "Validation Error", invalid_email.message

    [
      {userName: 123},
      {userName: "username", externalId: 1},
      {userName: "username", name: "Invalid Name"},
      {userName: "username", name: {givenName: 1}},
      {userName: "username", emails: ["invalid"]},
      {userName: "username", emails: [{value: "valid@example.com", primary: "yes"}]}
    ].each do |body|
      error = assert_raises(BetterAuth::APIError) do
        auth.api.create_scim_user(headers: headers, body: body)
      end
      assert_equal 400, error.status_code
      assert_equal "Validation Error", error.message
    end

    created = auth.api.create_scim_user(headers: headers, body: {userName: "patch-validation@example.com"})
    invalid_patch_schema = assert_raises(BetterAuth::APIError) do
      auth.api.patch_scim_user(
        headers: headers,
        params: {userId: created.fetch(:id)},
        body: {schemas: ["wrong"], Operations: [{op: "replace", path: "userName", value: "ignored@example.com"}]}
      )
    end
    assert_equal 400, invalid_patch_schema.status_code
    assert_equal "Invalid schemas for PatchOp", invalid_patch_schema.message
  end

  def test_scim_create_user_sets_location_and_accepts_scim_json
    auth = build_auth
    cookie = sign_up_cookie(auth)
    token = auth.api.generate_scim_token(headers: {"cookie" => cookie}, body: {providerId: "okta"}).fetch(:scimToken)

    status, headers, body = auth.api.create_scim_user(
      as_response: true,
      headers: bearer(token).merge("content-type" => "application/scim+json"),
      body: {userName: "location@example.com"}
    )
    created = JSON.parse(body.join)

    assert_equal 201, status
    assert_match %r{/scim/v2/Users/#{created.fetch("id")}\z}, headers.fetch("location")
    assert_equal ["urn:ietf:params:scim:schemas:core:2.0:User"], created.fetch("schemas")
    assert_equal true, created.fetch("active")
    assert_equal "location@example.com", created.fetch("displayName")
    assert_equal "location@example.com", created.fetch("name").fetch("formatted")
    assert_equal [{"primary" => true, "value" => "location@example.com"}], created.fetch("emails")
    assert_equal "User", created.fetch("meta").fetch("resourceType")

    response = Rack::MockRequest.new(auth).post(
      "/api/auth/scim/v2/Users",
      "CONTENT_TYPE" => "application/scim+json",
      "HTTP_AUTHORIZATION" => "Bearer #{token}",
      :input => JSON.generate({userName: "rack-location@example.com"})
    )
    rack_created = JSON.parse(response.body)

    assert_equal 201, response.status
    assert_equal "rack-location@example.com", rack_created.fetch("userName")

    upper = auth.api.create_scim_user(headers: bearer(token), body: {userName: "Upper@Example.com"})
    assert_equal "upper@example.com", upper.fetch(:userName)
    assert_equal "upper@example.com", upper.fetch(:externalId)
  end

  def test_scim_create_user_email_selection_duplicate_and_existing_user
    auth = build_auth
    cookie = sign_up_cookie(auth)
    token = auth.api.generate_scim_token(headers: {"cookie" => cookie}, body: {providerId: "okta"}).fetch(:scimToken)
    headers = bearer(token)

    primary = auth.api.create_scim_user(
      headers: headers,
      body: {userName: "username", name: {formatted: "Primary User"}, emails: [{value: "secondary@example.com"}, {value: "primary@example.com", primary: true}]}
    )
    assert_equal "primary@example.com", primary.fetch(:userName)
    assert_equal "username", primary.fetch(:externalId)

    first = auth.api.create_scim_user(
      headers: headers,
      body: {userName: "first-username", emails: [{value: "first@example.com"}, {value: "second@example.com"}]}
    )
    assert_equal "first@example.com", first.fetch(:userName)

    auth.context.internal_adapter.create_user(email: "existing@example.com", name: "Existing User")
    existing = auth.api.create_scim_user(headers: headers, body: {userName: "external-existing", emails: [{value: "existing@example.com"}]})
    assert_equal "Existing User", existing.fetch(:displayName)
    assert_equal "external-existing", existing.fetch(:externalId)

    assert_raises(BetterAuth::APIError) do
      auth.api.create_scim_user(headers: headers, body: {userName: "external-existing"})
    end
  end

  def test_scim_create_user_matches_upstream_resource_variants
    auth = build_auth
    cookie = sign_up_cookie(auth)
    token = auth.api.generate_scim_token(headers: {"cookie" => cookie}, body: {providerId: "okta"}).fetch(:scimToken)
    headers = bearer(token)

    external = auth.api.create_scim_user(headers: headers, body: {userName: "external@example.com", externalId: "external-username"})
    assert_equal "external@example.com", external.fetch(:userName)
    assert_equal "external-username", external.fetch(:externalId)
    assert_equal "external@example.com", external.fetch(:displayName)
    assert_equal({formatted: "external@example.com"}, external.fetch(:name))
    assert_equal [{primary: true, value: "external@example.com"}], external.fetch(:emails)
    assert_equal "User", external.fetch(:meta).fetch(:resourceType)

    name_parts = auth.api.create_scim_user(headers: headers, body: {userName: "parts@example.com", name: {givenName: "Juan", familyName: "Perez"}})
    assert_equal "Juan Perez", name_parts.fetch(:displayName)
    assert_equal({formatted: "Juan Perez"}, name_parts.fetch(:name))
    assert_equal "parts@example.com", name_parts.fetch(:externalId)

    formatted = auth.api.create_scim_user(headers: headers, body: {userName: "formatted@example.com", name: {formatted: "Daniel Lopez"}})
    assert_equal "Daniel Lopez", formatted.fetch(:displayName)
    assert_equal({formatted: "Daniel Lopez"}, formatted.fetch(:name))
    assert_equal "formatted@example.com", formatted.fetch(:externalId)
  end

  def test_scim_create_user_keeps_ruby_email_canonicalization_and_upstream_verified_default
    auth = build_auth
    cookie = sign_up_cookie(auth)
    token = auth.api.generate_scim_token(headers: {"cookie" => cookie}, body: {providerId: "okta"}).fetch(:scimToken)
    headers = bearer(token)

    created = auth.api.create_scim_user(
      headers: headers,
      body: {
        userName: "mixed-user-name@example.com",
        emails: [{value: "Mixed-Email@Example.com", primary: true}]
      }
    )
    stored_user = auth.context.internal_adapter.find_user_by_id(created.fetch(:id))

    assert_equal "mixed-email@example.com", created.fetch(:userName)
    assert_equal "mixed-email@example.com", created.fetch(:emails).first.fetch(:value)
    assert_equal false, stored_user.fetch("emailVerified")
  end

  def test_scim_update_and_patch_reject_anonymous_and_missing_users
    auth = build_auth
    cookie = sign_up_cookie(auth)
    token = auth.api.generate_scim_token(headers: {"cookie" => cookie}, body: {providerId: "okta"}).fetch(:scimToken)
    headers = bearer(token)

    assert_equal 401, auth.api.update_scim_user(as_response: true, params: {userId: "missing"}, body: {userName: "anon@example.com"}).first
    assert_equal 401, auth.api.patch_scim_user(as_response: true, params: {userId: "missing"}, body: {schemas: ["urn:ietf:params:scim:api:messages:2.0:PatchOp"], Operations: []}).first

    missing_update = assert_raises(BetterAuth::APIError) do
      auth.api.update_scim_user(headers: headers, params: {userId: "missing"}, body: {userName: "missing@example.com"})
    end
    assert_equal 404, missing_update.status_code

    missing_patch = assert_raises(BetterAuth::APIError) do
      auth.api.patch_scim_user(headers: headers, params: {userId: "missing"}, body: {schemas: ["urn:ietf:params:scim:api:messages:2.0:PatchOp"], Operations: [{op: "replace", path: "userName", value: "missing@example.com"}]})
    end
    assert_equal 404, missing_patch.status_code
  end

  private

  def expected_upstream_user_schema(base_url)
    {
      id: "urn:ietf:params:scim:schemas:core:2.0:User",
      schemas: ["urn:ietf:params:scim:schemas:core:2.0:Schema"],
      name: "User",
      description: "User Account",
      attributes: [
        {name: "id", type: "string", multiValued: false, description: "Unique opaque identifier for the User", required: false, caseExact: true, mutability: "readOnly", returned: "default", uniqueness: "server"},
        {name: "userName", type: "string", multiValued: false, description: "Unique identifier for the User, typically used by the user to directly authenticate to the service provider", required: true, caseExact: false, mutability: "readWrite", returned: "default", uniqueness: "server"},
        {name: "displayName", type: "string", multiValued: false, description: "The name of the User, suitable for display to end-users.  The name SHOULD be the full name of the User being described, if known.", required: false, caseExact: true, mutability: "readOnly", returned: "default", uniqueness: "none"},
        {name: "active", type: "boolean", multiValued: false, description: "A Boolean value indicating the User's administrative status.", required: false, mutability: "readOnly", returned: "default"},
        {
          name: "name",
          type: "complex",
          multiValued: false,
          description: "The components of the user's real name.",
          required: false,
          subAttributes: [
            {name: "formatted", type: "string", multiValued: false, description: "The full name, including all middlenames, titles, and suffixes as appropriate, formatted for display(e.g., 'Ms. Barbara J Jensen, III').", required: false, caseExact: false, mutability: "readWrite", returned: "default", uniqueness: "none"},
            {name: "familyName", type: "string", multiValued: false, description: "The family name of the User, or last name in most Western languages (e.g., 'Jensen' given the fullname 'Ms. Barbara J Jensen, III').", required: false, caseExact: false, mutability: "readWrite", returned: "default", uniqueness: "none"},
            {name: "givenName", type: "string", multiValued: false, description: "The given name of the User, or first name in most Western languages (e.g., 'Barbara' given the full name 'Ms. Barbara J Jensen, III').", required: false, caseExact: false, mutability: "readWrite", returned: "default", uniqueness: "none"}
          ]
        },
        {
          name: "emails",
          type: "complex",
          multiValued: true,
          description: "Email addresses for the user.  The value SHOULD be canonicalized by the service provider, e.g., 'bjensen@example.com' instead of 'bjensen@EXAMPLE.COM'. Canonical type values of 'work', 'home', and 'other'.",
          required: false,
          mutability: "readWrite",
          returned: "default",
          uniqueness: "none",
          subAttributes: [
            {name: "value", type: "string", multiValued: false, description: "Email addresses for the user.  The value SHOULD be canonicalized by the service provider, e.g., 'bjensen@example.com' instead of 'bjensen@EXAMPLE.COM'. Canonical type values of 'work', 'home', and 'other'.", required: false, caseExact: false, mutability: "readWrite", returned: "default", uniqueness: "server"},
            {name: "primary", type: "boolean", multiValued: false, description: "A Boolean value indicating the 'primary' or preferred attribute value for this attribute, e.g., the preferred mailing address or primary email address.  The primary attribute value 'true' MUST appear no more than once.", required: false, mutability: "readWrite", returned: "default"}
          ]
        }
      ],
      meta: {
        resourceType: "Schema",
        location: "#{base_url}/scim/v2/Schemas/urn:ietf:params:scim:schemas:core:2.0:User"
      }
    }
  end

  def rich_openapi?(endpoint)
    openapi = endpoint.metadata[:openapi]
    return false unless openapi.is_a?(Hash)
    return false if openapi[:operationId].to_s.empty?
    return false if endpoint.methods.any? { |method| openapi[:description].to_s == "#{method} #{endpoint.path}" }
    return false unless openapi[:responses].is_a?(Hash) && openapi[:responses].any?
    return false if endpoint.methods.any? { |method| %w[POST PUT PATCH].include?(method) } && !meaningful_schema?(openapi.dig(:requestBody, :content, "application/json", :schema))

    true
  end

  def meaningful_schema?(schema)
    schema.is_a?(Hash) && (schema[:additionalProperties] || schema[:$ref] || schema[:items] || schema[:properties]&.any?)
  end
end
