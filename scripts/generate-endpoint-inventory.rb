#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates a Markdown inventory of every BetterAuth::Endpoint.new route in the
# workspace. Combines static AST extraction (path, method, file, line) with
# runtime schema metadata when endpoints can be loaded.

require "bundler/setup"
require "fileutils"
require "json"
require "prism"
require "time"
require_relative "support/endpoint_naming"

ROOT = File.expand_path("..", __dir__)
OUTPUT_MD = File.join(ROOT, "reference", "endpoints-inventory.md")
OUTPUT_JSON = File.join(ROOT, "reference", "endpoints-inventory.json")
UPSTREAM_REGISTRY = File.join(ROOT, "reference", "upstream-endpoint-registry.json")
LIB_GLOB = File.join(ROOT, "packages", "**", "lib", "**", "*.rb")

module EndpointInventory
  module_function

  def run!
    static_rows = collect_static_endpoints
    runtime_rows = collect_runtime_endpoints
    merged = merge_rows(static_rows, runtime_rows)
    write_markdown(merged)
    write_json(merged)
    puts "Wrote #{OUTPUT_MD} (#{merged.length} routes)"
    puts "Wrote #{OUTPUT_JSON}"
  end

  def collect_static_endpoints
    rows = []
    Dir.glob(LIB_GLOB).sort.each do |file|
      source = File.read(file)
      next unless source.include?("Endpoint.new")

      parse = Prism.parse(source)
      visit_endpoint_nodes(parse.value, file, source, rows)
    end
    rows
  end

  def visit_endpoint_nodes(node, file, source, rows)
    return unless node

    if endpoint_new_call?(node)
      row = extract_static_row(node, file, source)
      rows << row if row
    end

    node.child_nodes.compact.each { |child| visit_endpoint_nodes(child, file, source, rows) }
  end

  def endpoint_new_call?(node)
    return false unless node.is_a?(Prism::CallNode)
    return false unless node.name == :new

    receiver = node.receiver
    receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :Endpoint
  end

  def extract_static_row(node, file, source)
    path = literal_keyword(node, :path)
    method_value = literal_keyword(node, :method)
    return nil if path.nil?

    methods = normalize_methods(method_value)
    line = node.location.start_line
    rel_file = file.delete_prefix("#{ROOT}/")

    endpoint_key = infer_endpoint_key(source, line)
    if rel_file.end_with?("better_auth-sso/lib/better_auth/sso/plugin/endpoints.rb")
      endpoint_key = endpoint_key&.delete_prefix("sso_")
    end

    {
      path: path,
      methods: methods,
      file: rel_file,
      line: line,
      endpoint_key: endpoint_key,
      plugin_hint: infer_plugin_hint(rel_file),
      body_fields: extract_openapi_body_fields(node),
      query_params: extract_openapi_parameters(node, "query"),
      path_params: extract_openapi_parameters(node, "path") + path_params_from_template(path),
      header_params: extract_openapi_parameters(node, "header"),
      disable_body: literal_keyword(node, :disable_body) == true,
      server_only: server_only?(node),
      source: "static"
    }
  end

  def each_keyword_argument(node)
    return enum_for(:each_keyword_argument, node) unless block_given?

    args = node.arguments
    return unless args

    Array(args.arguments).each do |argument|
      case argument
      when Prism::KeywordHashNode
        argument.elements.each do |assoc|
          next unless assoc.is_a?(Prism::AssocNode)

          key = assoc_key(assoc.key)
          yield(key, assoc.value)
        end
      when Prism::AssocNode
        yield(assoc_key(argument.key), argument.value)
      end
    end
  end

  def assoc_key(node)
    case node
    when Prism::SymbolNode then node.unescaped.to_sym
    when Prism::StringNode then node.unescaped.to_sym
    else node.to_s.to_sym
    end
  end

  def literal_keyword(node, name)
    each_keyword_argument(node) do |key, value|
      return literal_value(value) if key == name
    end
    nil
  end

  def literal_value(node)
    case node
    when Prism::StringNode then node.unescaped
    when Prism::SymbolNode then node.unescaped.to_sym
    when Prism::TrueNode then true
    when Prism::FalseNode then false
    when Prism::ArrayNode
      node.elements.compact.map { |element| literal_value(element) }
    when Prism::IntegerNode then node.value
    end
  end

  def normalize_methods(value)
    case value
    when Array then value.map { |entry| entry.to_s.upcase }
    when nil then ["*"]
    else [value.to_s.upcase]
    end
  end

  def path_params_from_template(path)
    path.to_s.scan(/:([a-zA-Z0-9_]+)/).flatten.uniq
  end

  def infer_endpoint_key(source, line)
    prefix = source.lines[0...line - 1].reverse.find { |entry| entry.match?(/\A\s*(?:def\s+(?:self\.)?)?[a-z0-9_]+_endpoint\s*\(/i) }
    if prefix
      return prefix[/\A\s*(?:def\s+(?:self\.)?)?([a-z0-9_]+)_endpoint\s*\(/i, 1]
    end

    prefix = source.lines[0...line - 1].reverse.find { |entry| entry.match?(/\A\s*(?:def\s+(?:self\.)?)?[a-z0-9_]+(?:_endpoint)?\s*\(/i) }
    return nil unless prefix

    prefix[/\A\s*(?:def\s+(?:self\.)?)?([a-z0-9_]+)/i, 1]
  end

  def infer_plugin_hint(file)
    if file.include?("/better_auth/lib/better_auth/routes/")
      "core"
    elsif file.include?("/better_auth/lib/better_auth/plugins/")
      File.basename(file, ".rb")
    else
      file.split("/lib/").last.split("/").first(3).join("/")
    end
  end

  def extract_openapi_parameters(node, location)
    metadata = hash_keyword(node, :metadata)
    openapi = metadata && (metadata[:openapi] || metadata["openapi"])
    return [] unless openapi.is_a?(Hash)

    Array(openapi[:parameters] || openapi["parameters"]).filter_map do |parameter|
      next unless parameter.is_a?(Hash)
      next unless (parameter[:in] || parameter["in"]).to_s == location

      name = (parameter[:name] || parameter["name"]).to_s
      next if name.empty?

      {
        name: name,
        required: parameter[:required] == true || parameter["required"] == true,
        type: schema_type(parameter[:schema] || parameter["schema"])
      }
    end
  end

  def extract_openapi_body_fields(node)
    metadata = hash_keyword(node, :metadata)
    openapi = metadata && (metadata[:openapi] || metadata["openapi"])
    return [] unless openapi.is_a?(Hash)

    request_body = openapi[:requestBody] || openapi["requestBody"]
    return [] unless request_body.is_a?(Hash)

    content = request_body[:content] || request_body["content"] || {}
    json_schema = content.dig("application/json", :schema) ||
      content.dig(:application_json, :schema) ||
      content.dig("application/json", "schema") ||
      content.dig("application/x-www-form-urlencoded", :schema) ||
      content.dig("application/x-www-form-urlencoded", "schema")
    return [] unless json_schema.is_a?(Hash)

    properties = json_schema[:properties] || json_schema["properties"] || {}
    required = Array(json_schema[:required] || json_schema["required"]).map(&:to_s)

    properties.map do |name, schema|
      {
        name: name.to_s,
        required: required.include?(name.to_s),
        type: schema_type(schema)
      }
    end.sort_by { |entry| entry[:name] }
  end

  def schema_type(schema)
    return nil unless schema.is_a?(Hash)

    type = schema[:type] || schema["type"]
    case type
    when Array then type.join(" | ")
    else type.to_s
    end
  end

  def hash_keyword(node, name)
    value_node = keyword_value_node(node, name)
    return nil unless value_node.is_a?(Prism::HashNode)

    hash_node_to_ruby(value_node)
  end

  def keyword_value_node(node, name)
    each_keyword_argument(node) do |key, value|
      return value if key == name
    end
    nil
  end

  def hash_node_to_ruby(node)
    return {} unless node.is_a?(Prism::HashNode)

    node.elements.each_with_object({}) do |element, result|
      key = hash_key(element.key)
      result[key] = literal_or_hash(element.value)
    end
  end

  def hash_key(node)
    case node
    when Prism::SymbolNode then node.unescaped.to_sym
    when Prism::StringNode then node.unescaped
    else node.to_s
    end
  end

  def literal_or_hash(node)
    literal = literal_value(node)
    return literal unless literal.nil?

    hash_node_to_ruby(node) if node.is_a?(Prism::HashNode)
  end

  def server_only?(node)
    metadata = hash_keyword(node, :metadata)
    return false unless metadata.is_a?(Hash)

    metadata[:SERVER_ONLY] == true || metadata[:server_only] == true ||
      metadata["SERVER_ONLY"] == true || metadata["server_only"] == true
  end

  def collect_runtime_endpoints
    auth = InventoryAuth.build_inventory_auth
    rows = []

    auth.context.options.plugins.each do |plugin|
      plugin.endpoints.each do |endpoint_key, endpoint|
        next unless endpoint.respond_to?(:path) && endpoint.path

        endpoint.methods.each do |method|
          rows << runtime_row(
            plugin_id: plugin.id,
            endpoint_key: endpoint_key.to_s,
            endpoint: endpoint,
            method: method
          )
        end
      end
    end

    BetterAuth::Core.base_endpoints.each do |endpoint_key, endpoint|
      next unless endpoint.respond_to?(:path) && endpoint.path

      endpoint.methods.each do |method|
        rows << runtime_row(
          plugin_id: "core",
          endpoint_key: endpoint_key.to_s,
          endpoint: endpoint,
          method: method
        )
      end
    end

    rows
  end
  require_relative "support/inventory_auth"

  def runtime_row(plugin_id:, endpoint_key:, endpoint:, method:)
    openapi = endpoint.metadata[:openapi] || endpoint.metadata["openapi"] || {}
    path = endpoint.path

    {
      path: path,
      methods: [method.to_s.upcase],
      plugin_id: plugin_id,
      endpoint_key: endpoint_key,
      body_fields: runtime_body_fields(endpoint, openapi),
      query_params: runtime_parameters(openapi, "query"),
      path_params: runtime_parameters(openapi, "path") + path_params_from_template(path),
      header_params: runtime_parameters(openapi, "header"),
      disable_body: endpoint.disable_body,
      server_only: endpoint.metadata[:SERVER_ONLY] == true || endpoint.metadata[:server_only] == true,
      operation_id: openapi[:operationId] || openapi["operationId"],
      source: "runtime"
    }
  end

  def runtime_parameters(openapi, location)
    Array(openapi[:parameters] || openapi["parameters"]).filter_map do |parameter|
      next unless parameter.is_a?(Hash)
      next unless (parameter[:in] || parameter["in"]).to_s == location

      name = (parameter[:name] || parameter["name"]).to_s
      next if name.empty?

      {
        name: name,
        required: parameter[:required] == true || parameter["required"] == true,
        type: schema_type(parameter[:schema] || parameter["schema"])
      }
    end
  end

  def runtime_body_fields(endpoint, openapi)
    fields = extract_request_body_fields_from_openapi(openapi)
    return fields unless fields.empty?

    infer_required_fields_from_schema(endpoint.body_schema)
  end

  def extract_request_body_fields_from_openapi(openapi)
    request_body = openapi[:requestBody] || openapi["requestBody"]
    return [] unless request_body.is_a?(Hash)

    content = request_body[:content] || request_body["content"] || {}
    schema = content.values.find { |entry| entry.is_a?(Hash) }&.dig(:schema) ||
      content.values.find { |entry| entry.is_a?(Hash) }&.dig("schema")
    return [] unless schema.is_a?(Hash)

    properties = schema[:properties] || schema["properties"] || {}
    required = Array(schema[:required] || schema["required"]).map(&:to_s)

    properties.map do |name, property_schema|
      {
        name: name.to_s,
        required: required.include?(name.to_s),
        type: schema_type(property_schema)
      }
    end.sort_by { |entry| entry[:name] }
  end

  def infer_required_fields_from_schema(schema)
    return [] unless schema.is_a?(Proc)

    source = schema.source_location
    return [] unless source

    file, line = source
    return [] unless File.file?(file)

    segment = File.read(file).lines[(line - 1)..(line + 5)]&.join || ""
    required_strings = segment[/required_strings:\s*%w\[([^\]]+)\]/, 1]
    required_nonempty = segment[/required_nonempty_strings:\s*%w\[([^\]]+)\]/, 1]
    email_strings = segment[/email_strings:\s*%w\[([^\]]+)\]/, 1]
    optional_strings = segment[/optional_strings:\s*%w\[([^\]]+)\]/, 1]

    fields = []
    required_strings&.split&.each { |name| fields << {name: name, required: true, type: "string"} }
    required_nonempty&.split&.each { |name| fields << {name: name, required: true, type: "string"} }
    email_strings&.split&.each { |name| fields << {name: name, required: true, type: "string (email)"} }
    optional_strings&.split&.each { |name| fields << {name: name, required: false, type: "string"} }
    fields.uniq { |entry| entry[:name] }
  end

  def merge_rows(static_rows, runtime_rows)
    index = {}

    static_rows.each do |row|
      row.fetch(:methods).each do |method|
        key = [row[:path], method]
        index[key] = enrich_ruby_api_fields(row.merge(method: method))
      end
    end

    runtime_rows.each do |row|
      method = row.fetch(:methods).first
      key = [row[:path], method]
      existing = index[key]
      index[key] = if existing
        enrich_ruby_api_fields(
          existing.merge(row).tap do |merged|
            merged[:file] ||= existing[:file]
            merged[:line] ||= existing[:line]
            merged[:body_fields] = prefer_richer(existing[:body_fields], row[:body_fields])
            merged[:query_params] = prefer_richer(existing[:query_params], row[:query_params])
            merged[:path_params] = (existing[:path_params] + row[:path_params]).uniq { |entry| entry.is_a?(Hash) ? entry[:name] : entry }
            merged[:header_params] = prefer_richer(existing[:header_params], row[:header_params])
            merged[:source] = "static+runtime"
          end
        )
      else
        enrich_ruby_api_fields(row.merge(method: method))
      end
    end

    index.values.sort_by { |row| [row[:path], row[:method], row[:plugin_id].to_s, row[:endpoint_key].to_s] }
  end

  def enrich_ruby_api_fields(row)
    method_name = ruby_api_method_name(row[:endpoint_key])
    enriched = row.merge(
      ruby_api_method: method_name,
      ruby_api_call: method_name ? "auth.api.#{method_name}" : nil
    )
    upstream = upstream_registry_index[[row[:path], row[:method].to_s.upcase]]
    return enriched unless upstream

    enriched.merge(
      upstream_registry_key: upstream["registry_key"],
      upstream_api_call: upstream["upstream_api"],
      upstream_client_call: upstream["upstream_client"]
    )
  end

  def upstream_registry_index
    @upstream_registry_index ||= if File.exist?(UPSTREAM_REGISTRY)
      JSON.parse(File.read(UPSTREAM_REGISTRY)).fetch("entries").each_with_object({}) do |entry, index|
        index[[entry["path"], entry["method"].to_s.upcase]] = entry
      end
    else
      {}
    end
  end

  # Mirrors BetterAuth::API#normalize_method_name for endpoint registry keys.
  def ruby_api_method_name(endpoint_key)
    key = endpoint_registry_key(endpoint_key)
    return nil if key.nil? || key.empty?

    key
      .gsub(/([a-z\d])([A-Z])/, '\1_\2')
      .tr("-", "_")
      .downcase
  end

  def endpoint_registry_key(endpoint_key)
    return nil if endpoint_key.nil?

    value = endpoint_key.to_s.strip
    return nil if value.empty? || value == "-"

    value.sub(/_endpoint\z/i, "")
  end

  def prefer_richer(left, right)
    left = Array(left)
    right = Array(right)
    (right.length >= left.length) ? right : left
  end

  def write_markdown(rows)
    FileUtils.mkdir_p(File.dirname(OUTPUT_MD))
    generated_at = Time.now.utc.iso8601

    lines = []
    lines << "# Better Auth Ruby — Endpoint Inventory"
    lines << ""
    lines << "Auto-generated by `scripts/generate-endpoint-inventory.rb`."
    lines << ""
    lines << "- **Generated at**: #{generated_at}"
    lines << "- **Routes**: #{rows.length}"
    lines << "- **Default mount**: `{baseURL}{basePath}` — e.g. `http://localhost:3000/api/auth` + path below"
    lines << "- **Sources**: static AST scan of `BetterAuth::Endpoint.new` in `packages/**/lib/**` plus runtime metadata from all loaded plugins"
    lines << ""
    lines << "## Summary by plugin"
    lines << ""

    rows.group_by { |row| row[:plugin_id] || row[:plugin_hint] || "unknown" }.sort.each do |plugin, plugin_rows|
      lines << "- **#{plugin}**: #{plugin_rows.length} route method(s)"
    end

    lines << ""
    lines << "## Routes"
    lines << ""
    lines << "| Method | Path | Ruby API | Plugin | Endpoint key | Query | Body | Path params | Source | Definition |"
    lines << "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"

    rows.each do |row|
      lines << "| #{row[:method]} | `#{row[:path]}` | #{format_ruby_api(row)} | #{row[:plugin_id] || row[:plugin_hint] || "-"} | #{row[:endpoint_key] || "-"} | #{format_params(row[:query_params])} | #{format_body(row)} | #{format_path_params(row[:path_params])} | #{row[:source]} | #{format_definition(row)} |"
    end

    lines << ""
    lines << "## Notes"
    lines << ""
    lines << "- **Body** lists JSON/form fields when OpenAPI metadata or `request_body_schema` helpers expose them. Endpoints with dynamic schemas may show `-`."
    lines << "- **Query** and **Path params** include OpenAPI parameters and `:segments` from the route template."
    lines << "- **Ruby API** maps each route to the in-process server helper on `auth.api`, using the same method names as `BetterAuth::API` (`auth.api.sign_up_email`, etc.)."
    lines << "- **Server-only** endpoints (metadata `SERVER_ONLY`) are intended for `auth.api`, not browser clients."
    lines << "- Re-run: `ruby scripts/generate-endpoint-inventory.rb`"
    lines << ""

    File.write(OUTPUT_MD, lines.join("\n"))
  end

  def write_json(rows)
    File.write(OUTPUT_JSON, JSON.pretty_generate({
      generated_at: Time.now.utc.iso8601,
      route_count: rows.length,
      routes: rows
    }))
  end

  def format_params(params)
    Array(params).map do |entry|
      if entry.is_a?(Hash)
        suffix = entry[:required] ? "*" : ""
        type = entry[:type] ? " (#{entry[:type]})" : ""
        "`#{entry[:name]}#{suffix}`#{type}"
      else
        "`#{entry}`"
      end
    end.join(", ").then { |value| value.empty? ? "-" : value }
  end

  def format_body(row)
    return "disabled" if row[:disable_body]

    fields = Array(row[:body_fields])
    return "-" if fields.empty?

    fields.map do |entry|
      suffix = entry[:required] ? "*" : ""
      type = entry[:type] ? " (#{entry[:type]})" : ""
      "`#{entry[:name]}#{suffix}`#{type}"
    end.join(", ")
  end

  def format_path_params(params)
    values = Array(params).map do |entry|
      entry.is_a?(Hash) ? entry[:name] : entry
    end.uniq
    values.empty? ? "-" : values.map { |name| "`#{name}`" }.join(", ")
  end

  def format_definition(row)
    if row[:file] && row[:line]
      "`#{row[:file]}:#{row[:line]}`"
    else
      "-"
    end
  end

  def format_ruby_api(row)
    call = row[:ruby_api_call]
    call ? "`#{call}`" : "-"
  end
end

EndpointInventory.run! if __FILE__ == $PROGRAM_NAME
