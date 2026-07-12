#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require_relative "support/endpoint_naming"

ROOT = File.expand_path("..", __dir__)
OUTPUT = File.join(ROOT, "reference", "upstream-endpoint-registry.json")
VERSION_FILE = File.join(ROOT, "reference", "upstream-better-auth", "VERSION.md")
UPSTREAM_VERSION = File.read(VERSION_FILE)[/^\| Version \| `(\d+\.\d+\.\d+)` \|$/, 1]
raise "Could not read pinned upstream version from #{VERSION_FILE}" unless UPSTREAM_VERSION

UPSTREAM_PACKAGES = File.join(ROOT, "reference", "upstream-src", UPSTREAM_VERSION, "repository", "packages")

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

module UpstreamEndpointRegistry
  module_function

  def run!
    route_index = build_route_index
    mappings = collect_endpoint_mappings
    entries = resolve_entries(mappings, route_index)
    payload = {
      generated_at: Time.now.utc.iso8601,
      upstream_version: upstream_version,
      entries: entries.sort_by { |entry| [entry[:path], entry[:method], entry[:registry_key]] }
    }
    File.write(OUTPUT, JSON.pretty_generate(stringify_keys(payload)))
    puts "Wrote #{OUTPUT} (#{entries.length} entries)"
  end

  def build_route_index
    index = {}
    scan_route_files.each do |file|
      source = File.read(file)
      export_chunks(source).each do |export_name, chunk|
        match = chunk.match(/createAuthEndpoint\s*\(\s*"([^"]+)"/m)
        next unless match

        path = match[1]
        next if deny_path?(path)

        method = chunk[/method:\s*"([A-Z*]+)"/, 1] || chunk[/method:\s*'([A-Z*]+)'/, 1] || "*"
        comment = chunk[/\/\*\*[\s\S]*?\*\//, 0] || ""
        deprecated = comment.include?("@deprecated") || chunk.include?("@deprecated")

        entry = {
          export_name: export_name,
          path: path,
          method: method.upcase,
          source_file: relative_path(file),
          comment: comment,
          deprecated: deprecated
        }

        existing = index[export_name]
        index[export_name] = if existing.nil? || prefer_route_entry?(entry, existing)
          entry
        else
          existing
        end
      end
    end
    index
  end

  def prefer_route_entry?(candidate, existing)
    candidate_file = candidate[:source_file]
    return true if candidate_file.include?("/routes")
    return true if candidate_file.include?("/oauthClient/") || candidate_file.include?("/oauthConsent/")
    return false if existing[:source_file].include?("/routes")

    candidate_file.length <= existing[:source_file].length
  end

  def export_chunks(source)
    marks = []
    source.scan(/export const (\w+)/) do
      marks << [Regexp.last_match(1), Regexp.last_match.begin(0)]
    end
    return [] if marks.empty?

    marks.each_with_index.map do |(name, start), index|
      stop = marks[index + 1] ? marks[index + 1][1] : source.length
      [name, source[start...stop]]
    end
  end

  def collect_endpoint_mappings
    endpoint_mapping_files.flat_map do |file|
      source = File.read(file)
      plugin_id = plugin_id_for(file)
      parse_endpoint_mappings(source, plugin_id, file)
    end
  end

  def endpoint_mapping_files
    scan_route_files.select do |file|
      next false if SKIP_ENDPOINTS_FILES.any? { |suffix| file.end_with?(suffix) }

      content = File.read(file)
      content.include?("endpoints:") || content.include?("baseEndpoints")
    end
  end

  def parse_endpoint_mappings(source, plugin_id, file)
    mappings = []
    source.scan(/(?:endpoints|baseEndpoints)\s*[:=]\s*\{/m) do
      brace_start = Regexp.last_match.end(0) - 1
      block = extract_balanced_braces(source, brace_start)
      next unless block

      parse_endpoint_block_entries(block).each do |registry_key, target|
        mappings << {
          registry_key: registry_key,
          target: target,
          plugin_id: plugin_id,
          source_file: relative_path(file)
        }
      end
    end
    mappings
  end

  def parse_endpoint_block_entries(block)
    entries = {}
    depth = 0

    block.each_line do |line|
      line_start_depth = depth

      if line_start_depth == 1
        if line =~ /(\w+):\s*createAuthEndpoint\s*\(\s*"([^"]+)"/
          registry_key = Regexp.last_match(1)
          path = Regexp.last_match(2)
          tail = block[Regexp.last_match.end(0), 800] || ""
          method = tail[/method:\s*"([A-Z*]+)"/, 1] || tail[/method:\s*'([A-Z*]+)'/, 1] || "*"
          entries[registry_key] = {inline: true, path: path, method: method.upcase}
        elsif line =~ /(\w+):\s*(?:[\w.]+\.)?(\w+)(?:<[^>]*>)?\([^)]*\)/
          registry_key = Regexp.last_match(1)
          symbol = Regexp.last_match(2)
          next if entries.key?(registry_key)

          entries[registry_key] = {inline: false, symbol: symbol}
        elsif line =~ /(\w+):\s*(?:[\w.]+\.)?(\w+),?\s*$/
          registry_key = Regexp.last_match(1)
          symbol = Regexp.last_match(2)
          next if entries.key?(registry_key)

          entries[registry_key] = {inline: false, symbol: symbol}
        elsif line.strip.match?(/\A(\w+),?\z/)
          registry_key = line.strip.delete(",")
          next if INTERNAL_ENDPOINT_KEYS.include?(registry_key)
          next if entries.key?(registry_key)

          entries[registry_key] = {inline: false, symbol: registry_key}
        end
      end

      depth += line.count("{") - line.count("}")
    end

    entries.to_a
  end

  def extract_balanced_braces(source, open_index)
    depth = 0
    (open_index...source.length).each do |index|
      char = source[index]
      depth += 1 if char == "{"
      depth -= 1 if char == "}"
      return source[open_index..index] if depth.zero?
    end
    nil
  end

  def resolve_entries(mappings, route_index)
    rows = []
    mappings.each do |mapping|
      registry_key = mapping[:registry_key]
      target = mapping[:target]
      route = if target[:inline]
        {
          path: target[:path],
          method: target[:method],
          source_file: mapping[:source_file],
          comment: "",
          deprecated: false
        }
      else
        route_index[target[:symbol]]
      end
      next unless route

      path = route[:path]
      next if deny_path?(path)

      comment = route[:comment] || ""
      deprecated = route[:deprecated] || comment.include?("@deprecated")
      upstream_api = docblock_value(comment, "server") || registry_key
      upstream_client = docblock_value(comment, "client")

      rows << {
        plugin_id: mapping[:plugin_id],
        registry_key: registry_key,
        ruby_registry_key: EndpointNaming.upstream_registry_key_to_ruby(registry_key),
        path: path,
        method: route[:method],
        upstream_api: "auth.api.#{upstream_api}",
        ruby_api: "auth.api.#{EndpointNaming.upstream_registry_key_to_ruby(registry_key)}",
        upstream_client: upstream_client ? "authClient.#{upstream_client}" : infer_client_call(path),
        deprecated: deprecated,
        source_file: route[:source_file] || mapping[:source_file]
      }
    end

    dedupe_rows(rows)
  end

  def scan_route_files
    Dir.glob(File.join(UPSTREAM_PACKAGES, "**", "*.ts")).sort.reject do |file|
      file.include?(".test.") || file.include?("__tests__") || file.include?("/test/")
    end
  end

  def deny_path?(path)
    DENY_PATH_PREFIXES.any? { |prefix| path.start_with?(prefix) }
  end

  def docblock_value(comment, section)
    block = comment[/\/\*\*[\s\S]*?\*\//m]
    return nil unless block

    lines = block.lines.map { |line| line.sub(/\A\s*\*\s?/, "").strip }
    capture = false
    lines.each do |line|
      if line.match?(/\A#{section}:\z/i)
        capture = true
        next
      end
      return Regexp.last_match(1) if capture && line.match?(/\A`auth\.api\.(\w+)`\z/)

      capture = false if capture && !line.empty? && !line.start_with?("`")
    end
    nil
  end

  def infer_client_call(path)
    segments = path.to_s.split("/").reject(&:empty?)
    return nil if segments.empty?

    segments.map.with_index do |segment, index|
      parts = segment.split("-")
      parts.each_with_index.map { |part, part_index| (index.zero? && part_index.zero?) ? part.downcase : part.capitalize }.join
    end.join(".")
  end

  def plugin_id_for(file)
    relative = file.delete_prefix("#{UPSTREAM_PACKAGES}/")
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
      key = [row[:path], row[:method], row[:registry_key]]
      existing = index[key]
      index[key] = if existing
        existing.merge(row).tap do |merged|
          merged[:deprecated] = existing[:deprecated] || row[:deprecated]
          merged[:upstream_client] ||= row[:upstream_client]
        end
      else
        row
      end
    end.values
  end

  def upstream_version
    UPSTREAM_VERSION
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

UpstreamEndpointRegistry.run!
