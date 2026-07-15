#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require_relative "support/endpoint_naming"

module EndpointApiComparison
  ROOT = File.expand_path("..", __dir__)
  UPSTREAM_REGISTRY = File.join(ROOT, "reference", "upstream-endpoint-registry.json")
  RUBY_INVENTORY = File.join(ROOT, "reference", "endpoints-inventory.json")
  OUTPUT_MD = File.join(ROOT, "reference", "endpoints-api-comparison.md")
  OUTPUT_JSON = File.join(ROOT, "reference", "endpoints-api-comparison.json")
  UNSUPPORTED_PLUGINS = %w[mcp electron oidc-provider].freeze
  KNOWN_GAPS = [
    {
      plugin_id: "oauth-popup",
      path: "/oauth-popup/start",
      method: "GET",
      reason: "unimplemented_plugin",
      details: "Actual OAuth popup functionality is absent in Ruby"
    },
    {
      plugin_id: "siwe",
      path: "/siwe/get-nonce",
      method: "POST",
      reason: "wire_alias_missing",
      details: "The upstream URL alias is absent, while equivalent Ruby functionality exists",
      ruby_equivalent: {method: "POST", path: "/siwe/nonce"}
    }
  ].freeze
  PASSKEY_METHOD_OVERRIDES = {
    "GET /passkey/generate-authenticate-options" => "POST",
    "GET /passkey/generate-register-options" => "POST"
  }.freeze
  RUBY_ONLY_ROUTES = [
    ["POST", "/admin/oauth2/create-client", "Ruby OAuth Provider administrative management endpoint"],
    ["PATCH", "/admin/oauth2/update-client", "Ruby OAuth Provider administrative management endpoint"],
    ["POST", "/api-key/delete-all-expired-api-keys", "Ruby exposes upstream cleanup behavior as an explicit maintenance endpoint"],
    ["POST", "/api-key/verify", "Ruby exposes API-key verification over HTTP as well as direct server calls"],
    ["POST", "/dub/link", "Ruby Dub integration endpoint"],
    ["GET", "/error", "Ruby core diagnostic route intentionally omitted from the upstream public registry"],
    ["DELETE", "/oauth2/consent", "Ruby OAuth Provider REST adaptation for consent management"],
    ["GET", "/oauth2/consent", "Ruby OAuth Provider REST adaptation for consent management"],
    ["PATCH", "/oauth2/consent", "Ruby OAuth Provider REST adaptation for consent management"],
    ["GET", "/oauth2/consents", "Ruby OAuth Provider REST adaptation for consent management"],
    ["POST", "/oauth2/end-session", "Ruby OAuth Provider accepts POST in addition to the upstream registered form"],
    ["GET", "/ok", "Ruby core health route intentionally omitted from the upstream public registry"],
    ["POST", "/organization/add-member", "Ruby exposes the upstream server-side organization operation over HTTP"],
    ["GET", "/reference", "Ruby OpenAPI reference UI route"],
    ["POST", "/set-password", "Ruby exposes the upstream server-side password operation over HTTP"],
    ["GET", "/subscription/cancel/callback", "Ruby Stripe callback adaptation for redirect completion"],
    ["POST", "/totp/generate", "Ruby exposes the upstream server-side TOTP generation operation over HTTP"]
  ].map { |method, path, reason| {method: method, path: path, reason: reason} }.freeze

  module_function

  def run!
    report = build_report(load_upstream_registry, load_ruby_inventory)
    write_markdown(report)
    write_json(report)
    print_summary(report)
    exit(1) if report[:registry_key_mismatch_count].positive? ||
      report[:missing_ruby_count].positive? ||
      report[:missing_upstream_count].positive?
  end

  def load_upstream_registry
    registry = JSON.parse(File.read(UPSTREAM_REGISTRY))
    losses = registry.fetch("extraction_loss_count", 0)
    raise "Upstream endpoint registry has #{losses} unexplained extraction losses" if losses.positive?

    registry.fetch("entries").map do |row|
      row.transform_keys(&:to_sym).merge(
        ruby_registry_key: row["ruby_registry_key"] || EndpointNaming.upstream_registry_key_to_ruby(row["registry_key"])
      )
    end
  end

  def load_ruby_inventory
    inventory = JSON.parse(File.read(RUBY_INVENTORY))
    inventory.fetch("routes").map { |row| row.transform_keys(&:to_sym) }
  end

  def build_report(upstream_rows, ruby_rows)
    http_upstream = upstream_rows.reject { |row| row[:server_only] || row[:path].nil? }
    excluded_unsupported = http_upstream.select { |row| unsupported?(row) }
    known_gaps = http_upstream.select { |row| known_gap?(row) }
    comparable_upstream = http_upstream.reject do |row|
      unsupported?(row) || known_gap?(row)
    end

    aligned = []
    registry_key_mismatches = []
    missing_ruby = []
    deprecated_pairs = []

    comparable_upstream.group_by { |upstream| route_group_key(upstream) }.each_value do |group|
      upstream = group.first
      ruby = ruby_rows.find { |row| routes_match?(upstream, row) }

      if ruby.nil?
        missing_ruby << upstream unless group.all? { |entry| entry[:deprecated] }
        next
      end

      matching = group.find { |entry| registry_entry_matches_ruby?(entry, ruby) }
      pair = (matching || upstream).merge(
        ruby_endpoint_key: ruby[:endpoint_key],
        ruby_api_method: ruby[:ruby_api_method],
        ruby_api_call: ruby[:ruby_api_call],
        ruby_plugin: ruby[:plugin_id] || ruby[:plugin_hint]
      )

      if group.any? { |entry| entry[:deprecated] } && !matching
        deprecated_pairs << pair
      elsif matching
        aligned << pair
      else
        registry_key_mismatches << pair
      end
    end

    missing_upstream_candidates = ruby_rows.reject do |ruby|
      http_upstream.any? { |upstream| routes_match?(upstream, ruby) }
    end
    ruby_only_classified, missing_upstream = missing_upstream_candidates.partition do |ruby|
      ruby_only_definition(ruby)
    end
    ruby_only_classified = ruby_only_classified.map { |ruby| ruby.merge(ruby_only_definition(ruby)) }

    email_otp_focus = (aligned + registry_key_mismatches + deprecated_pairs + missing_ruby)
      .select { |row| row[:path].to_s.include?("email-otp") || row[:path].to_s.include?("forget-password") }
      .uniq { |row| [row[:path], row[:method]] }
      .sort_by { |row| [row[:path], row[:method].to_s] }

    {
      generated_at: Time.now.utc.iso8601,
      upstream_route_count: upstream_rows.length,
      upstream_http_route_count: http_upstream.length,
      upstream_server_only_count: upstream_rows.count { |row| row[:server_only] || row[:path].nil? },
      ruby_route_count: ruby_rows.length,
      aligned_count: aligned.length,
      registry_key_mismatch_count: registry_key_mismatches.length,
      api_name_mismatch_count: registry_key_mismatches.length,
      missing_ruby_count: missing_ruby.length,
      missing_upstream_count: missing_upstream.length,
      ruby_only_classified_count: ruby_only_classified.length,
      deprecated_pair_count: deprecated_pairs.length,
      excluded_unsupported_count: excluded_unsupported.length,
      excluded_unsupported_plugins: UNSUPPORTED_PLUGINS,
      known_gap_count: known_gaps.length,
      aligned: aligned,
      registry_key_mismatches: registry_key_mismatches,
      api_name_mismatches: registry_key_mismatches,
      missing_ruby: missing_ruby,
      missing_upstream: missing_upstream,
      ruby_only_classified: ruby_only_classified,
      deprecated_pairs: deprecated_pairs,
      excluded_unsupported: excluded_unsupported,
      known_gaps: known_gaps.map { |row| row.merge(known_gap_definition(row)) },
      email_otp_focus: email_otp_focus
    }
  end

  def routes_match?(upstream, ruby)
    return false unless upstream[:path] == ruby[:path]

    upstream_method = normalized_upstream_method(upstream)
    ruby_method = ruby[:method].to_s.upcase
    upstream_method == "*" || ruby_method == "*" || upstream_method == ruby_method
  end

  def route_group_key(upstream)
    [upstream[:path], normalized_upstream_method(upstream)]
  end

  def normalized_upstream_method(upstream)
    method = upstream[:method].to_s.upcase
    PASSKEY_METHOD_OVERRIDES.fetch("#{method} #{upstream[:path]}", method)
  end

  def unsupported?(row)
    UNSUPPORTED_PLUGINS.include?(row[:plugin_id].to_s)
  end

  def known_gap?(row)
    !known_gap_definition(row).nil?
  end

  def known_gap_definition(row)
    KNOWN_GAPS.find do |gap|
      gap[:plugin_id] == row[:plugin_id].to_s &&
        gap[:path] == row[:path] &&
        gap[:method] == normalized_upstream_method(row)
    end
  end

  def registry_entry_matches_ruby?(upstream, ruby)
    EndpointNaming.registry_keys_equivalent?(upstream[:registry_key], ruby[:endpoint_key])
  end

  def ruby_only_definition(row)
    RUBY_ONLY_ROUTES.find do |definition|
      definition[:method] == row[:method].to_s.upcase && definition[:path] == row[:path]
    end
  end

  def write_markdown(report)
    lines = []
    lines << "# Upstream vs RubyAuth API naming comparison"
    lines << ""
    lines << "Auto-generated by `scripts/compare-endpoint-api-names.rb`."
    lines << ""
    lines << "- **Generated at**: #{report[:generated_at]}"
    lines << "- **Upstream registry entries**: #{report[:upstream_route_count]} (`reference/upstream-endpoint-registry.json`)"
    lines << "- **Upstream HTTP routes**: #{report[:upstream_http_route_count]}"
    lines << "- **Upstream server-only entries**: #{report[:upstream_server_only_count]}"
    lines << "- **Ruby routes**: #{report[:ruby_route_count]} (`reference/endpoints-inventory.json`)"
    lines << "- **Aligned registry keys**: #{report[:aligned_count]}"
    lines << "- **Registry key mismatches**: #{report[:registry_key_mismatch_count]}"
    lines << "- **Missing in Ruby inventory**: #{report[:missing_ruby_count]}"
    lines << "- **Known gaps**: #{report[:known_gap_count]}"
    lines << "- **Excluded unsupported plugin routes**: #{report[:excluded_unsupported_count]} (#{report[:excluded_unsupported_plugins].join(", ")})"
    lines << "- **Classified Ruby extensions**: #{report[:ruby_only_classified_count]}"
    lines << "- **Unexplained Ruby-only / not found upstream**: #{report[:missing_upstream_count]}"
    lines << "- **Deprecated upstream pairs still in Ruby**: #{report[:deprecated_pair_count]}"
    lines << ""
    lines << "Naming policy: `reference/ruby-api-naming-policy.md`"
    lines << ""
    lines << "## Known gaps"
    lines << ""
    lines << "| Method | Path | Upstream registry key | Reason | Ruby equivalent |"
    lines << "| --- | --- | --- | --- | --- |"
    report[:known_gaps].each do |row|
      equivalent = row[:ruby_equivalent]
      equivalent_text = equivalent ? "`#{equivalent[:method]} #{equivalent[:path]}`" : "-"
      lines << "| #{row[:method]} | `#{row[:path]}` | `#{row[:registry_key]}` | `#{row[:reason]}`: #{row[:details]} | #{equivalent_text} |"
    end
    lines << ""
    lines << "## Explicitly excluded unsupported plugins"
    lines << ""
    lines << "The following upstream plugins are outside supported Ruby parity: `#{report[:excluded_unsupported_plugins].join("`, `")}`."
    lines << ""
    lines << "| Method | Path | Plugin | Upstream registry key |"
    lines << "| --- | --- | --- | --- |"
    report[:excluded_unsupported].each do |row|
      lines << "| #{row[:method]} | `#{row[:path]}` | `#{row[:plugin_id]}` | `#{row[:registry_key]}` |"
    end
    lines << ""
    lines << "## Classified Ruby extensions"
    lines << ""
    lines << "| Method | Path | Ruby endpoint key | Reason |"
    lines << "| --- | --- | --- | --- |"
    report[:ruby_only_classified].each do |row|
      lines << "| #{row[:method]} | `#{row[:path]}` | `#{row[:endpoint_key] || "-"}` | #{row[:reason]} |"
    end
    lines << ""
    lines << "## Email OTP password reset focus"
    lines << ""
    lines << "| Method | Path | Upstream registry key | Ruby registry key | Status |"
    lines << "| --- | --- | --- | --- | --- |"

    report[:email_otp_focus].each do |row|
      lines << "| #{row[:method]} | `#{row[:path]}` | `#{row[:registry_key]}` | `#{row[:ruby_endpoint_key] || "-"}` | #{email_otp_status(row, report)} |"
    end

    sections = [
      ["Registry key mismatches (path matches, canonical key differs)", :registry_key_mismatches, mismatch_row],
      ["Deprecated upstream routes still present in Ruby", :deprecated_pairs, deprecated_row],
      ["Missing in Ruby inventory (non-deprecated upstream)", :missing_ruby, upstream_only_row],
      ["Ruby-only routes (not found upstream registry)", :missing_upstream, ruby_only_row]
    ]

    sections.each do |title, key, formatter|
      rows = report[key]
      next if rows.empty?

      lines << ""
      lines << "## #{title}"
      lines << ""
      lines << formatter[:header]
      lines << formatter[:divider]
      rows.first(100).each { |row| lines << formatter[:row].call(row) }
      lines << ""
      lines << "_Showing #{[rows.length, 100].min} of #{rows.length}._" if rows.length > 100
    end

    lines << ""
    lines << "## Re-run"
    lines << ""
    lines << "```bash"
    lines << "ruby scripts/generate-upstream-endpoint-registry.rb"
    lines << "ruby scripts/generate-endpoint-inventory.rb"
    lines << "ruby scripts/compare-endpoint-api-names.rb"
    lines << "```"
    lines << ""

    File.write(OUTPUT_MD, lines.join("\n"))
  end

  def email_otp_status(row, report)
    if row[:deprecated]
      "deprecated upstream"
    elsif report[:registry_key_mismatches].any? { |entry| routes_match?(entry, row) }
      "registry key mismatch"
    elsif report[:missing_ruby].any? { |entry| routes_match?(entry, row) }
      "missing ruby"
    elsif row[:ruby_endpoint_key]
      "aligned"
    else
      "unknown"
    end
  end

  def mismatch_row
    {
      header: "| Path | Upstream registry key | Expected Ruby key | Ruby endpoint key |",
      divider: "| --- | --- | --- | --- |",
      row: ->(row) {
        expected = EndpointNaming.upstream_registry_key_to_ruby(row[:registry_key])
        "| `#{row[:method]} #{row[:path]}` | `#{row[:registry_key]}` | `#{expected}` | `#{row[:ruby_endpoint_key] || "-"}` |"
      }
    }
  end

  def deprecated_row
    {
      header: "| Path | Upstream registry key | Ruby endpoint key | Notes |",
      divider: "| --- | --- | --- | --- |",
      row: ->(row) {
        "| `#{row[:method]} #{row[:path]}` | `#{row[:registry_key]}` | `#{row[:ruby_endpoint_key] || "-"}` | deprecated upstream route |"
      }
    }
  end

  def upstream_only_row
    {
      header: "| Path | Upstream registry key | Expected Ruby key | Source |",
      divider: "| --- | --- | --- | --- |",
      row: ->(row) {
        "| `#{row[:method]} #{row[:path]}` | `#{row[:registry_key]}` | `#{row[:ruby_registry_key]}` | `#{row[:source_file]}` |"
      }
    }
  end

  def ruby_only_row
    {
      header: "| Path | Ruby endpoint key | Plugin |",
      divider: "| --- | --- | --- |",
      row: ->(row) {
        "| `#{row[:method]} #{row[:path]}` | `#{row[:endpoint_key] || "-"}` | `#{row[:plugin_id] || row[:plugin_hint] || "-"}` |"
      }
    }
  end

  def write_json(report)
    File.write(OUTPUT_JSON, JSON.pretty_generate(stringify_keys(report)))
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

  def print_summary(report)
    puts "Wrote #{OUTPUT_MD}"
    puts "Wrote #{OUTPUT_JSON}"
    puts "Upstream: #{report[:upstream_route_count]} | HTTP: #{report[:upstream_http_route_count]} | Server-only: #{report[:upstream_server_only_count]} | Ruby: #{report[:ruby_route_count]} | Aligned: #{report[:aligned_count]}"
    puts "Registry key mismatches: #{report[:registry_key_mismatch_count]} | Missing Ruby: #{report[:missing_ruby_count]} | Known gaps: #{report[:known_gap_count]} | Excluded unsupported: #{report[:excluded_unsupported_count]} | Ruby-only: #{report[:missing_upstream_count]} | Deprecated pairs: #{report[:deprecated_pair_count]}"
  end
end

EndpointApiComparison.run! if $PROGRAM_NAME == __FILE__
