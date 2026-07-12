# frozen_string_literal: true

require "bundler/setup"
require "better_auth"
require "better_auth/api_key"
require "better_auth/passkey"
require "better_auth/oauth_provider"
require "better_auth/scim"
require "better_auth/sso"
require "better_auth/stripe"
require "json"
require "fileutils"

ROOT = File.expand_path("../..", __dir__)
RESOURCES_PATH = File.join(ROOT, "docs-site/content/docs/reference/resources.mdx")
DATABASE_SCHEMAS_PATH = File.join(ROOT, "docs-site/content/docs/reference/database-schemas.mdx")
FORBIDDEN_PATTERN = /mcp|oidc_provider|oidc-provider|test-utils/i
DIALECTS = %i[postgres mysql sqlite mssql].freeze

def no_op
  ->(*) {}
end

def supported_plugins
  [
    BetterAuth::Plugins.username,
    BetterAuth::Plugins.anonymous,
    BetterAuth::Plugins.phone_number(send_otp: no_op),
    BetterAuth::Plugins.two_factor(otp_options: {send_otp: no_op}),
    BetterAuth::Plugins.organization(
      teams: {enabled: true},
      dynamic_access_control: {enabled: true}
    ),
    BetterAuth::Plugins.jwt,
    BetterAuth::Plugins.device_authorization,
    BetterAuth::Plugins.siwe(
      get_nonce: -> { "documentation-nonce" },
      verify_message: ->(*) { true }
    ),
    BetterAuth::Plugins.last_login_method(store_in_database: true),
    BetterAuth::Plugins.magic_link(send_magic_link: no_op),
    BetterAuth::Plugins.email_otp(send_verification_otp: no_op),
    BetterAuth::Plugins.one_time_token,
    BetterAuth::Plugins.multi_session,
    BetterAuth::Plugins.oauth_proxy,
    BetterAuth::Plugins.one_tap(
      verify_id_token: ->(*) { {"sub" => "documentation", "email" => "user@example.com", "email_verified" => true} }
    ),
    BetterAuth::Plugins.generic_oauth(
      config: [
        {
          provider_id: "generic",
          client_id: "client",
          client_secret: "secret",
          authorization_url: "https://example.com/authorize",
          token_url: "https://example.com/token"
        }
      ]
    ),
    BetterAuth::Plugins.bearer,
    BetterAuth::Plugins.captcha(
      provider: "cloudflare-turnstile",
      secret_key: "secret",
      verifier: ->(*) { {"success" => true} }
    ),
    BetterAuth::Plugins.have_i_been_pwned(range_lookup: ->(*) { "" }),
    BetterAuth::Plugins.dub(
      api_key: "dub_test_placeholder",
      oauth: {client_id: "client", client_secret: "secret"}
    ),
    BetterAuth::Plugins.api_key(
      enable_metadata: true,
      enable_session_for_api_keys: true
    ),
    BetterAuth::Plugins.passkey(origin: "http://localhost:3000"),
    BetterAuth::Plugins.oauth_provider(
      scopes: ["openid", "profile", "email"],
      store_client_secret: "hashed"
    ),
    BetterAuth::Plugins.scim(provider_ownership: {enabled: true}),
    BetterAuth::Plugins.sso(
      saml: {enabled: true, enable_single_logout: true},
      domain_verification: {
        enabled: true,
        request: no_op,
        dns_txt_resolver: ->(*) { [] }
      }
    ),
    BetterAuth::Plugins.stripe(
      api_key: "sk_test_placeholder",
      webhook_secret: "whsec_placeholder",
      subscription: {
        enabled: true,
        plans: [{name: "pro", price_id: "price_placeholder"}]
      },
      organization: {enabled: true},
      authorize_reference: ->(*) { true }
    )
  ]
end

def documentation_auth
  plugins = supported_plugins
  plugins << BetterAuth::Plugins.open_api

  BetterAuth.auth(
    secret: "x" * 40,
    base_url: "http://localhost:3000/api/auth",
    email_and_password: {enabled: true},
    rate_limit: {storage: "database"},
    plugins: plugins,
    telemetry: {enabled: false}
  )
end

def open_api_schema(auth)
  if auth.api.respond_to?(:generate_open_api_schema)
    auth.api.generate_open_api_schema
  else
    auth.api.generate_openapi_schema
  end
end

def hfetch(hash, key)
  return nil unless hash.respond_to?(:[])

  hash[key] || hash[key.to_s]
end

def escape_markdown(value)
  text = value.nil? ? "" : value.to_s
  text
    .gsub("\\", "\\\\")
    .gsub("|", "\\|")
    .gsub("\n", "<br />")
end

def inline_code(value)
  "`#{value.to_s.gsub("`", "\\`")}`"
end

def anchor_for(value)
  value.to_s
    .gsub(/([a-z\d])([A-Z])/, "\\1-\\2")
    .downcase
    .gsub(/[^a-z0-9]+/, "-")
    .gsub(/\A-|-?\z/, "")
end

def attr_value(attributes, key)
  return "" unless attributes.key?(key)

  value = attributes[key]
  case value
  when true
    "yes"
  when false
    "no"
  when Hash
    value.map { |entry_key, entry_value| "#{entry_key}: #{entry_value}" }.join(", ")
  when Proc
    "generated"
  else
    value.to_s
  end
end

def reference_value(attributes)
  reference = attributes[:references]
  return "" unless reference

  model = reference[:model]
  field = reference[:field]
  on_delete = reference[:on_delete]
  [model && "#{model}.#{field}", on_delete && "on delete #{on_delete}"].compact.join(", ")
end

def schema_summary(schema)
  return "none" unless schema.is_a?(Hash)

  reference = hfetch(schema, "$ref")
  return reference if reference

  one_of = hfetch(schema, :oneOf)
  return "one of #{one_of.length} schemas" if one_of.is_a?(Array)

  any_of = hfetch(schema, :anyOf)
  return "any of #{any_of.length} schemas" if any_of.is_a?(Array)

  type = Array(hfetch(schema, :type)).compact.join(" or ")
  type = "object" if type.empty? && hfetch(schema, :properties).is_a?(Hash)
  type = "schema" if type.empty?

  if type.include?("array")
    items = schema_summary(hfetch(schema, :items))
    return "array of #{items}"
  end

  properties = hfetch(schema, :properties)
  if properties.is_a?(Hash) && properties.any?
    names = properties.keys.map(&:to_s).sort
    shown = names.first(6)
    suffix = if names.length > shown.length
      ", and #{names.length - shown.length} more"
    else
      ""
    end
    required = Array(hfetch(schema, :required)).map(&:to_s).sort
    required_text = required.any? ? "; required: #{required.join(", ")}" : ""
    return "#{type}: #{shown.join(", ")}#{suffix}#{required_text}"
  end

  type
end

def request_summary(operation)
  body = hfetch(operation, :requestBody)
  return "none" unless body.is_a?(Hash)

  content = hfetch(body, :content)
  return "body" unless content.is_a?(Hash) && content.any?

  content.map do |media_type, data|
    schema = hfetch(data, :schema)
    "#{media_type}: #{schema_summary(schema)}"
  end.join("; ")
end

def response_summary(operation)
  responses = hfetch(operation, :responses)
  return "none" unless responses.is_a?(Hash) && responses.any?

  response_statuses = responses.keys.map(&:to_s)
  preferred = response_statuses.sort.find { |status| status.match?(/\A2|3/) } || response_statuses.min
  response = responses[preferred] || responses[preferred.to_sym]
  description = hfetch(response, :description)
  content = hfetch(response, :content)
  schema = nil
  if content.is_a?(Hash)
    json = content["application/json"] || content[:"application/json"] || content.values.first
    schema = hfetch(json, :schema)
  end
  [preferred, description, schema && schema_summary(schema)].compact.join(" - ")
end

def security_summary(operation)
  security = hfetch(operation, :security)
  return "none" if security == []
  return "global" unless security.is_a?(Array) && security.any?

  security.flat_map { |entry| entry.respond_to?(:keys) ? entry.keys.map(&:to_s) : [] }.uniq.sort.join(", ")
end

def endpoint_entries(paths)
  paths.flat_map do |path, methods|
    methods.map do |method, operation|
      tags = Array(hfetch(operation, :tags)).map(&:to_s)
      {
        tag: tags.first.to_s.empty? ? "Default" : tags.first,
        method: method.to_s.upcase,
        path: path.to_s,
        operation_id: hfetch(operation, :operationId).to_s,
        summary: hfetch(operation, :summary) || hfetch(operation, :description),
        security: security_summary(operation),
        request: request_summary(operation),
        response: response_summary(operation)
      }
    end
  end.sort_by do |entry|
    tag = if entry[:tag] == "Default"
      ""
    else
      entry[:tag]
    end
    [tag, entry[:path], entry[:method]]
  end
end

def generated_notice(kind, count)
  <<~MDX
    <RubyAuthDisclaimer />

    This page is generated by `docs-site/scripts/generate-reference-resources.rb`.
    Do not edit the generated #{kind} by hand; update the Ruby source of truth and rerun the generator.

    Generated configuration: supported Ruby plugin set, email/password auth, database-backed rate limiting, and optional schema-bearing supported plugin features. Actual app schemas and endpoints may differ when plugins are disabled or names and fields are customized.

    Generated count: #{count}.

  MDX
end

def generate_database_schemas(auth)
  tables = BetterAuth::Schema.auth_tables(auth.context.options)
  fail_if_forbidden!("table", tables.keys)

  lines = []
  lines << "---"
  lines << "title: Database Schemas"
  lines << "description: Generated RubyAuth database tables and SQL for supported plugins."
  lines << "---"
  lines << ""
  lines << generated_notice("schema reference", "#{tables.length} tables").strip
  lines << ""
  lines << "The table metadata below comes from `BetterAuth::Schema.auth_tables(auth.context.options)`. The SQL sections come from `BetterAuth::Schema::SQL.create_statements(auth.context.options, dialect: dialect)`."
  lines << ""
  lines << "## Tables"
  lines << ""

  tables.sort_by { |logical_name, table| [table[:order] || Float::INFINITY, logical_name.to_s] }.each do |logical_name, table|
    lines << "### #{logical_name}"
    lines << ""
    lines << "- Logical model key: #{inline_code(logical_name)}"
    lines << "- Physical table/model name: #{inline_code(table.fetch(:model_name))}"
    lines << ""
    lines << "| Logical field | Physical field | Type | Required | Unique | Index | Reference | Default | Returned | Input |"
    lines << "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    table.fetch(:fields).sort_by { |field_name, _attributes| field_name.to_s }.each do |field_name, attributes|
      lines << [
        inline_code(field_name),
        inline_code(attributes[:field_name] || field_name),
        escape_markdown(attributes[:type] || "string"),
        escape_markdown(attr_value(attributes, :required)),
        escape_markdown(attr_value(attributes, :unique)),
        escape_markdown(attr_value(attributes, :index)),
        escape_markdown(reference_value(attributes)),
        escape_markdown(attr_value(attributes, :default_value)),
        escape_markdown(attr_value(attributes, :returned)),
        escape_markdown(attr_value(attributes, :input))
      ].join(" | ").prepend("| ").concat(" |")
    end
    lines << ""
  end

  lines << "## SQL Creation Statements"
  lines << ""
  DIALECTS.each do |dialect|
    statements = BetterAuth::Schema::SQL.create_statements(auth.context.options, dialect: dialect)
    lines << "### #{dialect}"
    lines << ""
    lines << "```sql"
    lines << statements.join("\n\n")
    lines << "```"
    lines << ""
  end

  "#{lines.join("\n").rstrip}\n"
end

def generate_resources(auth)
  schema = open_api_schema(auth)
  paths = hfetch(schema, :paths) || {}
  fail_if_forbidden!("path", paths.keys)

  endpoints = endpoint_entries(paths)
  lines = []
  lines << "---"
  lines << "title: Resources"
  lines << "description: Links, generated endpoint index, and database schema resources for RubyAuth."
  lines << "---"
  lines << ""
  lines << generated_notice("endpoint reference", "#{endpoints.length} operations across #{paths.length} paths").strip
  lines << ""
  lines << "## Official"
  lines << ""
  lines << "- [GitHub - better-auth-rb](https://github.com/salasebas/better-auth-rb)"
  lines << "- [Documentation](/docs/introduction)"
  lines << "- [LLMs.txt](/llms.txt) - machine-readable docs"
  lines << "- [Database Schemas](/docs/reference/database-schemas) - generated table fields and SQL"
  lines << ""
  lines << "## Gems"
  lines << ""
  lines << "- [better_auth](https://rubygems.org/gems/better_auth) - core"
  lines << "- [better_auth-rails](https://rubygems.org/gems/better_auth-rails) - Rails integration"
  lines << "- Extension gems: `better_auth-api-key`, `better_auth-sso`, `better_auth-stripe`, `better_auth-passkey`, `better_auth-scim`, `better_auth-oauth-provider`"
  lines << ""
  lines << "## Endpoint Reference"
  lines << ""
  lines << "Endpoint metadata is generated from the auth API OpenAPI schema method using a documentation auth instance with the `/api/auth` base path."
  lines << ""

  endpoints.group_by { |entry| entry[:tag] }.each do |tag, entries|
    lines << "### #{tag}"
    lines << ""
    lines << "| Method | Path | Operation | Summary | Auth | Request body | Response |"
    lines << "| --- | --- | --- | --- | --- | --- | --- |"
    entries.each do |entry|
      lines << [
        inline_code(entry[:method]),
        inline_code("/api/auth#{entry[:path]}"),
        entry[:operation_id].empty? ? "" : inline_code(entry[:operation_id]),
        escape_markdown(entry[:summary]),
        escape_markdown(entry[:security]),
        escape_markdown(entry[:request]),
        escape_markdown(entry[:response])
      ].join(" | ").prepend("| ").concat(" |")
    end
    lines << ""
  end

  lines << "## Inspiration"
  lines << ""
  lines << "Design inspired by [Better Auth](https://www.better-auth.com) (TypeScript). RubyAuth is a community Ruby port, not affiliated with the upstream project."
  lines << ""
  lines << "## Community"
  lines << ""
  lines << "Open issues and discussions on GitHub. For adapter or plugin contributions see [Community plugins](/docs/plugins/community-plugins)."
  lines << ""
  lines << "## Related"
  lines << ""
  lines << "- [Contributing](/docs/reference/contributing)"
  lines << "- [FAQ](/docs/reference/faq)"
  lines << ""

  "#{lines.join("\n").rstrip}\n"
end

def fail_if_forbidden!(label, values)
  matches = values.map(&:to_s).grep(FORBIDDEN_PATTERN)
  return if matches.empty?

  abort("Forbidden #{label} generated: #{matches.uniq.sort.join(", ")}")
end

def fail_if_forbidden_text!(path, text)
  matches = text.scan(FORBIDDEN_PATTERN).uniq
  return if matches.empty?

  abort("Forbidden generated text in #{path}: #{matches.sort.join(", ")}")
end

def generated_files
  auth = documentation_auth
  files = {
    RESOURCES_PATH => generate_resources(auth),
    DATABASE_SCHEMAS_PATH => generate_database_schemas(auth)
  }
  files.each { |path, text| fail_if_forbidden_text!(path, text) }
  files
end

def write_files(files)
  files.each do |path, content|
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end

def check_files(files)
  stale = files.filter_map do |path, content|
    next if File.exist?(path) && File.read(path) == content

    path
  end
  return if stale.empty?

  abort("Generated docs are stale: #{stale.map { |path| path.delete_prefix("#{ROOT}/") }.join(", ")}")
end

case ARGV
when ["--write"]
  write_files(generated_files)
  puts "Generated reference resources."
when ["--check"]
  check_files(generated_files)
  puts "Generated reference resources are up to date."
else
  warn "Usage: ruby docs-site/scripts/generate-reference-resources.rb [--write|--check]"
  exit 1
end
