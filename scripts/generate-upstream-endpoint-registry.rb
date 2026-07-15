#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "time"
require_relative "support/endpoint_naming"

module UpstreamEndpointRegistry
  ROOT = File.expand_path("..", __dir__)
  OUTPUT = File.join(ROOT, "reference", "upstream-endpoint-registry.json")
  VERSION_FILE = File.join(ROOT, "reference", "upstream-better-auth", "VERSION.md")
  UNSUPPORTED_PLUGINS = %w[mcp electron oidc-provider].freeze
  DENY_PATH_PREFIXES = %w[
    /body
    /cookie
    /error
    /ok
    /test
    /reference
    /docs
  ].freeze
  SKIP_ENDPOINTS_FILES = %w[
    client/types.ts
    client/test-plugin.ts
    api/to-auth-endpoints.ts
  ].freeze
  INTERNAL_ENDPOINT_KEYS = %w[ok error].freeze
  ACCOUNTED_DYNAMIC_SPREADS = [
    {
      source_suffix: "packages/better-auth/src/api/index.ts",
      expression: "pluginEndpoints",
      resolution: "runtime plugin endpoint aggregate; plugin declarations are scanned independently",
      expected_keys: []
    },
    {
      source_suffix: "packages/better-auth/src/plugins/organization/organization.ts",
      expression: "(api as OrganizationEndpoints<O>)",
      resolution: "typed wrapper around the local endpoint object; the underlying endpoint object is scanned directly",
      expected_keys: %w[hasPermission]
    },
    {
      source_suffix: "packages/better-auth/src/plugins/two-factor/index.ts",
      expression: "totp.endpoints",
      resolution: "nested TOTP plugin endpoints scanned at their declaration",
      expected_keys: %w[generateTOTP getTOTPURI verifyTOTP]
    },
    {
      source_suffix: "packages/better-auth/src/plugins/two-factor/index.ts",
      expression: "otp.endpoints",
      resolution: "nested OTP plugin endpoints scanned at their declaration",
      expected_keys: %w[sendTwoFactorOTP verifyTwoFactorOTP]
    },
    {
      source_suffix: "packages/better-auth/src/plugins/two-factor/index.ts",
      expression: "backupCode.endpoints",
      resolution: "nested backup-code plugin endpoints scanned at their declaration",
      expected_keys: %w[generateBackupCodes viewBackupCodes verifyBackupCode]
    }
  ].freeze

  class UnresolvedSpreadError < StandardError; end

  module_function

  def run!
    metadata = upstream_metadata
    upstream_packages = validate_upstream!(metadata)
    route_index = build_route_index(scan_route_files(upstream_packages))
    mappings, spread_accounting = collect_endpoint_mappings(endpoint_mapping_files(upstream_packages))
    entries, unresolved = resolve_entries(mappings, route_index)
    extracted_keys = entries.map { |entry| entry[:registry_key] }
    missing_accounted_keys = spread_accounting.flat_map do |spread|
      spread.fetch(:expected_keys) - extracted_keys
    end.uniq
    unless missing_accounted_keys.empty?
      raise "Accounted endpoint spreads lost expected keys: #{missing_accounted_keys.join(", ")}"
    end
    unexpected = unresolved.reject { |row| UNSUPPORTED_PLUGINS.include?(row[:plugin_id].to_s) }
    unless unexpected.empty?
      details = unexpected.map { |row| "#{row[:plugin_id]}:#{row[:registry_key]} (#{row[:target]})" }.join(", ")
      raise "Unresolved supported endpoint mappings: #{details}"
    end

    payload = {
      generated_at: Time.now.utc.iso8601,
      upstream_version: metadata.fetch(:version),
      upstream_commit: metadata.fetch(:commit),
      extraction_loss_count: 0,
      extraction_losses: [],
      accounted_spread_count: spread_accounting.length,
      accounted_spreads: spread_accounting,
      unresolved_mapping_count: unresolved.length,
      unresolved_mappings: unresolved,
      entries: entries.sort_by { |entry| [entry[:path].to_s, entry[:method].to_s, entry[:registry_key]] }
    }
    File.write(OUTPUT, JSON.pretty_generate(stringify_keys(payload)))
    puts "Wrote #{OUTPUT} (#{entries.length} entries; #{unresolved.length} unresolved unsupported mappings)"
  end

  def upstream_metadata(version_file = VERSION_FILE)
    source = File.read(version_file)
    version = source[/^\| Version \| `(\d+\.\d+\.\d+)` \|$/, 1]
    commit = source[/^\| Repository commit \| `([0-9a-f]{40})` \|$/, 1]
    raise "Could not read pinned upstream version from #{version_file}" unless version
    raise "Could not read pinned upstream commit from #{version_file}" unless commit

    {version: version, commit: commit}
  end

  def validate_upstream!(metadata, root: ROOT)
    repository = File.join(root, "reference", "upstream-src", metadata.fetch(:version), "repository")
    packages = File.join(repository, "packages")
    raise "Pinned upstream packages directory does not exist: #{packages}" unless File.directory?(packages)

    output, status = Open3.capture2e("git", "-C", repository, "rev-parse", "HEAD")
    raise "Could not read upstream git HEAD from #{repository}: #{output.strip}" unless status.success?

    actual_commit = output.strip
    expected_commit = metadata.fetch(:commit)
    raise "Pinned upstream commit mismatch: expected #{expected_commit}, got #{actual_commit}" unless actual_commit == expected_commit

    packages
  end

  def build_route_index(files)
    property_aliases = []
    index = files.each_with_object({}) do |file, route_index|
      source = File.read(file)
      property_aliases.concat(object_property_aliases(source))
      declaration_chunks(source).each do |declaration_name, chunk|
        route = parse_endpoint_definition(chunk)
        unless route
          alias_symbol = declaration_alias(chunk, declaration_name)
          route_index[declaration_name] ||= {alias_symbol: alias_symbol} if alias_symbol
          next
        end
        next if route[:path] && deny_path?(route[:path])

        entry = route.merge(
          declaration_name: declaration_name,
          source_file: relative_path(file),
          comment: adjacent_docblock(chunk),
          deprecated: chunk.include?("@deprecated")
        )
        existing = route_index[declaration_name]
        route_index[declaration_name] = if existing.nil? || existing[:alias_symbol] || prefer_route_entry?(entry, existing)
          entry
        else
          existing
        end
      end
    end
    property_aliases.each do |name, target|
      next if index.key?(name)
      next unless resolve_route_index_entry(index[target], index, [name])

      index[name] = {alias_symbol: target}
    end
    index
  end

  def prefer_route_entry?(candidate, existing)
    candidate_file = candidate[:source_file]
    return true if candidate_file.include?("/routes") && !existing[:source_file].include?("/routes")
    return true if candidate_file.include?("/oauthClient/") || candidate_file.include?("/oauthConsent/")
    return false if existing[:source_file].include?("/routes") && !candidate_file.include?("/routes")

    candidate_file.length <= existing[:source_file].length
  end

  def declaration_chunks(source)
    masked = mask_non_code(source)
    matches = masked.to_enum(:scan, /(?:export\s+)?(?:const|function)\s+([A-Za-z_$][\w$]*)/).map do
      match = Regexp.last_match
      [match[1], match.begin(0)]
    end

    depth = 0
    cursor = 0
    declarations = matches.filter_map do |name, position|
      masked[cursor...position].each_char do |character|
        depth += 1 if character == "{"
        depth -= 1 if character == "}"
      end
      cursor = position
      next if depth > 1

      [name, position, depth]
    end

    marks = declarations.map do |name, declaration_start, declaration_depth|
      prefix = source[0...declaration_start]
      docblock = prefix.match(/(\/\*\*(?:(?!\*\/)[\s\S])*\*\/)\s*\z/)
      chunk_start = docblock ? docblock.begin(1) : declaration_start
      [name, declaration_start, chunk_start, declaration_depth]
    end

    marks.each_with_index.map do |(name, _declaration_start, chunk_start, declaration_depth), index|
      following = marks[(index + 1)..].find { |_next_name, _next_start, _next_chunk, next_depth| next_depth <= declaration_depth }
      chunk_end = following ? following[2] : source.length
      [name, source[chunk_start...chunk_end]]
    end
  end

  def parse_endpoint_definition(source)
    masked = mask_non_code(source)
    match = masked.match(/createAuthEndpoint(?<server_only>\.serverOnly)?\s*\(/)
    return nil unless match

    open_index = masked.index("(", match.begin(0))
    call = extract_balanced(source, open_index, "(", ")")
    return nil unless call

    server_only_call = !match[:server_only].nil?
    server_only = server_only_call || call.match?(/\bSERVER_ONLY\s*:\s*true/)
    first_argument = call[1..]
    path = first_argument.match(/\A\s*["'`]([^"'`]+)["'`]/)&.[](1) unless server_only_call
    path_variable = first_argument.match(/\A\s*([A-Za-z_$][\w$]*)\s*,/)&.[](1) unless server_only_call || path
    return nil unless path || path_variable || server_only

    methods = parse_methods(call)
    hidden_metadata = call.include?("HIDE_METADATA")
    explicit_http_scope = call.match?(/\bscope\s*:\s*["']http["']/)
    exposure = if server_only
      "server_only"
    elsif hidden_metadata
      "http_hidden_metadata"
    else
      "http"
    end

    {
      path: path,
      path_variable: path_variable,
      methods: methods,
      server_only: server_only,
      exposure: exposure,
      hidden_metadata: hidden_metadata,
      explicit_http_scope: explicit_http_scope
    }
  end

  def declaration_alias(source, declaration_name)
    masked = mask_non_code(source)
    match = masked.match(/\bconst\s+#{Regexp.escape(declaration_name)}\s*=\s*(?:await\s+)?(?:[A-Za-z_$][\w$]*\.)*([A-Za-z_$][\w$]*)\s*\(/m)
    match&.[](1)
  end

  def object_property_aliases(source)
    masked = mask_non_code(source)
    masked.scan(/\b([A-Za-z_$][\w$]*)\s*:\s*(?:[A-Za-z_$][\w$]*\.)*([A-Za-z_$][\w$]*)\s*\(/).reject do |_name, target|
      target == "createAuthEndpoint"
    end
  end

  def parse_methods(source)
    value = source.match(/\bmethod\s*:\s*(\[[\s\S]*?\]|["'][A-Za-z*]+["'])/)&.[](1)
    return ["*"] unless value

    methods = value.scan(/["']([A-Za-z*]+)["']/).flatten.map(&:upcase).uniq
    methods.empty? ? ["*"] : methods
  end

  def collect_endpoint_mappings(files)
    accounted_spreads = []
    mappings = files.flat_map do |file|
      parse_endpoint_mappings(File.read(file), plugin_id_for(file), file, accounted_spreads: accounted_spreads)
    end
    [mappings, accounted_spreads.uniq]
  end

  def endpoint_mapping_files(upstream_packages)
    scan_route_files(upstream_packages).select do |file|
      next false if SKIP_ENDPOINTS_FILES.any? { |suffix| file.end_with?(suffix) }

      content = File.read(file)
      content.include?("endpoints:") || content.include?("baseEndpoints")
    end
  end

  def parse_endpoint_mappings(source, plugin_id, file, accounted_spreads: [])
    masked = mask_non_code(source)
    object_blocks = endpoint_object_blocks(source)
    mappings = []
    masked.to_enum(:scan, /(?:endpoints|baseEndpoints)\s*[:=]\s*\{/).each do
      brace_start = masked.index("{", Regexp.last_match.begin(0))
      block = extract_balanced(source, brace_start, "{", "}")
      next unless block

      parse_endpoint_block_entries(
        block,
        object_blocks: object_blocks,
        accounted_spreads: accounted_spreads,
        source_file: relative_path(file)
      ).each do |registry_key, target, comment|
        if target[:inline] && target[:path].nil? && target[:path_variable]
          target = target.merge(path: path_variable_default(source, target[:path_variable]))
        end
        mappings << {
          registry_key: registry_key,
          target: target,
          comment: comment,
          plugin_id: plugin_id,
          source_file: relative_path(file)
        }
      end
    end

    endpoint_value_expressions(source).each do |expression|
      symbol = referenced_symbol(expression)
      next unless symbol && object_blocks[symbol]

      parse_endpoint_block_entries(
        object_blocks.fetch(symbol),
        object_blocks: object_blocks,
        accounted_spreads: accounted_spreads,
        source_file: relative_path(file),
        spread_stack: [symbol]
      ).each do |registry_key, target, comment|
        mappings << {
          registry_key: registry_key,
          target: target,
          comment: comment,
          plugin_id: plugin_id,
          source_file: relative_path(file)
        }
      end
    end
    mappings
  end

  def parse_endpoint_block_entries(block, object_blocks: {}, accounted_spreads: [], source_file: "fixture.ts", spread_stack: [])
    body = block.start_with?("{") ? block[1...-1] : block
    split_top_level_expressions(body).flat_map do |raw_entry|
      comment = adjacent_docblock(raw_entry)
      entry = raw_entry.sub(/\A\s*(?:\/\*[\s\S]*?\*\/\s*)+/, "").strip
      next [] if entry.empty?

      if entry.start_with?("...")
        expression = entry.delete_prefix("...").strip
        normalized_expression = expression.gsub(/\s+/, " ").strip
        dynamic = ACCOUNTED_DYNAMIC_SPREADS.find do |known|
          source_file.end_with?(known.fetch(:source_suffix)) &&
            normalized_expression == known.fetch(:expression)
        end
        if dynamic
          accounted_spreads << {
            source_file: source_file,
            expression: normalized_expression,
            resolution: dynamic.fetch(:resolution),
            expected_keys: dynamic.fetch(:expected_keys)
          }
          next []
        end

        symbols = object_blocks.keys.select { |name| expression.match?(/\b#{Regexp.escape(name)}\b/) }
        symbols -= spread_stack
        unless symbols.empty?
          next symbols.flat_map do |symbol|
            parse_endpoint_block_entries(
              object_blocks.fetch(symbol),
              object_blocks: object_blocks,
              accounted_spreads: accounted_spreads,
              source_file: source_file,
              spread_stack: spread_stack + [symbol]
            )
          end
        end

        raise UnresolvedSpreadError,
          "Unresolved supported endpoint spread in #{source_file}: #{expression.gsub(/\s+/, " ")[0, 200]}"
      end

      colon = top_level_character_index(entry, ":")
      if colon
        registry_key = entry[0...colon].strip.delete_prefix("\"").delete_suffix("\"").delete_prefix("'").delete_suffix("'")
        expression = entry[(colon + 1)..].strip
      elsif entry.match?(/\A[A-Za-z_$][\w$]*\z/)
        registry_key = entry
        expression = entry
      else
        next []
      end
      next [] if INTERNAL_ENDPOINT_KEYS.include?(registry_key)

      route = parse_endpoint_definition(expression)
      target = if route
        route.merge(inline: true)
      elsif (target_reference = referenced_target(expression))
        target_reference
      else
        {inline: false, unresolved: true, expression: expression.gsub(/\s+/, " ")[0, 200]}
      end
      [[registry_key, target, comment]]
    end
  end

  def endpoint_object_blocks(source)
    blocks = {}
    masked = mask_non_code(source)
    masked.to_enum(:scan, /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*\{/).each do
      name = Regexp.last_match[1]
      brace = masked.index("{", Regexp.last_match.begin(0))
      block = extract_balanced(source, brace, "{", "}")
      blocks[name] ||= block if block
    end

    declaration_chunks(source).each do |name, chunk|
      returned = last_returned_object(chunk)
      blocks[name] ||= returned if returned
    end
    blocks
  end

  def last_returned_object(source)
    masked = mask_non_code(source)
    positions = masked.to_enum(:scan, /\breturn\s*\{/).map { Regexp.last_match.begin(0) }
    position = positions.last
    return nil unless position

    brace = masked.index("{", position)
    extract_balanced(source, brace, "{", "}")
  end

  def endpoint_value_expressions(source)
    declaration_chunks(source).filter_map do |_name, chunk|
      returned = last_returned_object(chunk)
      next unless returned

      body = returned[1...-1]
      raw = split_top_level_expressions(body).find do |entry|
        cleaned = entry.sub(/\A\s*(?:\/\*[\s\S]*?\*\/\s*)+/, "").strip
        cleaned.match?(/\Aendpoints\s*:/)
      end
      next unless raw

      cleaned = raw.sub(/\A\s*(?:\/\*[\s\S]*?\*\/\s*)+/, "").strip
      colon = top_level_character_index(cleaned, ":")
      cleaned[(colon + 1)..].strip if colon
    end
  end

  def referenced_symbol(expression)
    masked = mask_non_code(expression).strip
    match = masked.match(/\A(?:await\s+)?(?:[A-Za-z_$][\w$]*\.)*([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*(?:\(|\z)/m)
    match&.[](1)
  end

  def referenced_target(expression)
    symbol = referenced_symbol(expression)
    return nil unless symbol

    argument_path = expression.match(/\A[\s\S]*?\(\s*["'`]([^"'`]+)["'`]/)&.[](1)
    {inline: false, symbol: symbol, path_override: argument_path}
  end

  def path_variable_default(source, variable)
    assignment = source.match(/\b(?:const|let)\s+#{Regexp.escape(variable)}\s*=([\s\S]*?);/)&.[](1)
    return nil unless assignment

    assignment.scan(/["'`]((?:\/)[^"'`]+)["'`]/).flatten.last
  end

  def split_top_level_expressions(source)
    masked = mask_non_code(source)
    depths = {"{" => 0, "(" => 0, "[" => 0}
    closing = {"}" => "{", ")" => "(", "]" => "["}
    start = 0
    entries = []
    masked.each_char.with_index do |character, index|
      if depths.key?(character)
        depths[character] += 1
      elsif closing.key?(character)
        opener = closing.fetch(character)
        depths[opener] -= 1
      elsif character == "," && depths.values.all?(&:zero?)
        entries << source[start...index]
        start = index + 1
      end
    end
    entries << source[start..]
    entries
  end

  def top_level_character_index(source, target)
    masked = mask_non_code(source)
    depths = {"{" => 0, "(" => 0, "[" => 0}
    closing = {"}" => "{", ")" => "(", "]" => "["}
    masked.each_char.with_index do |character, index|
      return index if character == target && depths.values.all?(&:zero?)

      if depths.key?(character)
        depths[character] += 1
      elsif closing.key?(character)
        depths[closing.fetch(character)] -= 1
      end
    end
    nil
  end

  def extract_balanced(source, open_index, opener, closer)
    return nil unless open_index && source[open_index] == opener

    masked = mask_non_code(source)
    depth = 0
    (open_index...source.length).each do |index|
      character = masked[index]
      depth += 1 if character == opener
      depth -= 1 if character == closer
      return source[open_index..index] if depth.zero?
    end
    nil
  end

  def mask_non_code(source)
    masked = source.dup
    state = :code
    quote = nil
    index = 0
    while index < source.length
      character = source[index]
      following = source[index + 1]

      case state
      when :code
        if character == "/" && following == "/"
          masked[index, 2] = "  "
          state = :line_comment
          index += 1
        elsif character == "/" && following == "*"
          masked[index, 2] = "  "
          state = :block_comment
          index += 1
        elsif ["\"", "'", "`"].include?(character)
          quote = character
          masked[index] = " "
          state = :string
        end
      when :line_comment
        if character == "\n"
          state = :code
        else
          masked[index] = " "
        end
      when :block_comment
        masked[index] = " " unless character == "\n"
        if character == "*" && following == "/"
          masked[index + 1] = " "
          state = :code
          index += 1
        end
      when :string
        masked[index] = " " unless character == "\n"
        if character == "\\"
          masked[index + 1] = " " if following
          index += 1
        elsif character == quote
          state = :code
        end
      end
      index += 1
    end
    masked
  end

  def resolve_entries(mappings, route_index)
    rows = []
    unresolved = []
    mappings_by_registry_key = mappings.group_by { |mapping| mapping[:registry_key] }
    mappings.each do |mapping|
      target = mapping[:target]
      route = resolve_mapping_route(mapping, route_index, mappings_by_registry_key)
      unless route
        unresolved << {
          plugin_id: mapping[:plugin_id],
          registry_key: mapping[:registry_key],
          target: target[:symbol] || target[:expression] || "unparsed expression",
          source_file: mapping[:source_file]
        }
        next
      end

      path = route[:path]
      next if path && deny_path?(path)

      comment = [mapping[:comment], route[:comment]].compact.join("\n")
      deprecated = route[:deprecated] || comment.include?("@deprecated")
      server_call = docblock_call(comment, "server", /auth\.api\.[A-Za-z0-9_.]+/)
      client_call = docblock_call(comment, "client", /authClient\.[A-Za-z0-9_.]+/)
      client_visibility = if route[:server_only]
        "server_only"
      elsif route[:hidden_metadata]
        "hidden_metadata"
      elsif client_call
        "documented"
      else
        "undocumented"
      end

      route.fetch(:methods).each do |method|
        registry_key = mapping[:registry_key]
        rows << {
          plugin_id: mapping[:plugin_id],
          registry_key: registry_key,
          ruby_registry_key: EndpointNaming.upstream_registry_key_to_ruby(registry_key),
          path: path,
          method: method,
          upstream_api: server_call || "auth.api.#{registry_key}",
          ruby_api: "auth.api.#{EndpointNaming.upstream_registry_key_to_ruby(registry_key)}",
          upstream_client: client_call,
          deprecated: deprecated,
          server_only: route[:server_only],
          exposure: route[:exposure],
          client_visibility: client_visibility,
          source_file: route[:source_file] || mapping[:source_file]
        }
      end
    end

    [dedupe_rows(rows), unresolved]
  end

  def resolve_mapping_route(mapping, route_index, mappings_by_registry_key, seen = [])
    target = mapping[:target]
    return target if target[:inline]

    symbol = target[:symbol]
    return nil if symbol.nil? || seen.include?(symbol)

    route = resolve_route_index_entry(route_index[symbol], route_index, seen + [symbol])
    if route.nil?
      candidate = mappings_by_registry_key.fetch(symbol, []).find { |nested| nested != mapping }
      route = resolve_mapping_route(candidate, route_index, mappings_by_registry_key, seen + [symbol]) if candidate
    end
    return nil unless route

    target[:path_override] ? route.merge(path: target[:path_override], path_variable: nil) : route
  end

  def resolve_route_index_entry(route, route_index, seen)
    return nil unless route
    return route unless route[:alias_symbol]
    return nil if seen.include?(route[:alias_symbol])

    resolve_route_index_entry(route_index[route[:alias_symbol]], route_index, seen + [route[:alias_symbol]])
  end

  def scan_route_files(upstream_packages)
    Dir.glob(File.join(upstream_packages, "**", "*.ts")).sort.reject do |file|
      file.include?(".test.") || file.include?("__tests__") || file.include?("/test/")
    end
  end

  def deny_path?(path)
    DENY_PATH_PREFIXES.any? { |prefix| path.start_with?(prefix) }
  end

  def adjacent_docblock(source)
    source[/\A\s*(\/\*\*(?:(?!\*\/)[\s\S])*\*\/)/, 1] || ""
  end

  def docblock_call(comment, section, call_pattern)
    lines = comment.lines.map { |line| line.sub(/\A\s*\*\s?/, "").strip }
    section_index = lines.index { |line| line.match?(/\A(?:\*\*)?#{section}:(?:\*\*)?\z/i) }
    return nil unless section_index

    lines[(section_index + 1)..].each do |line|
      break if line.match?(/\A(?:\*\*)?(?:server|client):(?:\*\*)?\z/i)

      call = line[call_pattern]
      return call if call
    end
    nil
  end

  def plugin_id_for(file)
    upstream_packages = file[%r{\A(.*/reference/upstream-src/[^/]+/repository/packages)/}, 1]
    relative = upstream_packages ? file.delete_prefix("#{upstream_packages}/") : file
    if relative.start_with?("better-auth/src/plugins/")
      relative.split("/")[3]
    elsif relative.start_with?("better-auth/src/api/")
      "core"
    else
      relative.split("/").first
    end
  end

  def relative_path(file)
    file.delete_prefix("#{ROOT}/")
  end

  def dedupe_rows(rows)
    rows.each_with_object({}) do |row, index|
      key = [row[:path], row[:method], row[:registry_key], row[:server_only]]
      existing = index[key]
      index[key] = if existing
        existing.merge(row).tap do |merged|
          merged[:deprecated] = existing[:deprecated] || row[:deprecated]
          merged[:upstream_client] ||= existing[:upstream_client]
        end
      else
        row
      end
    end.values
  end

  def stringify_keys(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, object), result| result[key.to_s] = stringify_keys(object) }
    when Array
      value.map { |entry| stringify_keys(entry) }
    else
      value
    end
  end
end

UpstreamEndpointRegistry.run! if $PROGRAM_NAME == __FILE__
