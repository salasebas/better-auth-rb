# frozen_string_literal: true

module UpstreamTestInventory
  VALID_STATUSES = %i[covered adapted partial ruby_not_applicable].freeze

  module_function

  def validate(upstream_paths:, entries:, exclusions:, test_root:, active_plans: {}, require_named_evidence: false,
    evidence_required_for: nil)
    errors = []
    classified = entries.keys + exclusions.keys
    errors.concat(duplicates(classified).map { |path| "Duplicate classification: #{path}" })
    errors.concat((upstream_paths - classified).map { |path| "Unclassified upstream test: #{path}" })
    errors.concat((classified - upstream_paths).map { |path| "Stale inventory entry: #{path}" })

    exclusions.each do |path, reason|
      errors << "Missing exclusion reason for #{path}" unless present_string?(reason)
    end

    entries.each do |path, entry|
      status = entry[:status]
      errors << "Invalid status #{status.inspect} for #{path}" unless VALID_STATUSES.include?(status)

      if status == :ruby_not_applicable
        errors << "Missing Ruby N/A reason for #{path}" unless present_string?(entry[:reason] || entry[:notes])
        next
      end

      owners = Array(entry[:owner])
      errors << "Missing Ruby owner for #{path}" if owners.empty?
      owners.each do |owner|
        owner_path = File.expand_path(owner, test_root)
        errors << "Owner points into upstream source tree for #{path}: #{owner}" if owner.include?("reference/upstream-src")
        errors << "Missing Ruby owner #{owner} for #{path}" unless File.file?(owner_path)
      end

      if %i[covered adapted].include?(status)
        errors << "Missing coverage evidence for #{path}" unless present_string?(entry[:notes]) || entry[:evidence]
        needs_named_evidence = require_named_evidence || Array(evidence_required_for).include?(path)
        errors.concat(validate_named_evidence(path, entry, test_root)) if needs_named_evidence
      elsif status == :partial
        errors << "Missing partial reason for #{path}" unless present_string?(entry[:reason] || entry[:notes])
        errors.concat(validate_partial_plan(path, entry[:plan], active_plans))
      end
    end

    errors
  end

  def validate_named_evidence(upstream_path, entry, test_root)
    evidence = entry[:evidence]
    return ["Missing named test evidence for #{upstream_path}"] unless evidence.is_a?(Hash) && !evidence.empty?

    owners = Array(entry[:owner])
    evidence.each_with_object([]) do |(owner, cases), errors|
      errors << "Evidence owner is not declared for #{upstream_path}: #{owner}" unless owners.include?(owner)
      owner_path = File.expand_path(owner, test_root)
      next unless File.file?(owner_path)

      source = File.read(owner_path)
      Array(cases).each do |test_case|
        unless test_case.to_s.start_with?("test_") && source.match?(/^\s*def\s+#{Regexp.escape(test_case.to_s)}\b/)
          errors << "Missing named test #{test_case} in #{owner} for #{upstream_path}"
        end
      end
    end
  end

  def validate_partial_plan(upstream_path, plan, active_plans)
    return ["Missing current plan for partial #{upstream_path}"] unless plan.to_s.match?(/\A\d{3}\z/)

    status = active_plans[plan.to_s]
    return ["Missing current plan #{plan} for partial #{upstream_path}"] unless status
    return ["Plan #{plan} is DONE for partial #{upstream_path}"] if status.to_sym == :done

    []
  end

  def duplicates(values)
    values.tally.select { |_value, count| count > 1 }.keys
  end

  def present_string?(value)
    value.is_a?(String) && !value.strip.empty?
  end
end

class UpstreamPackageTestLedger
  attr_reader :entries, :exclusions, :test_root, :active_plans

  def initialize(repository_root:, upstream_subpath:, test_root:, entries:, exclusions: {}, active_plans: {})
    @repository_root = repository_root
    @upstream_subpath = upstream_subpath
    @test_root = test_root
    @entries = entries.freeze
    @exclusions = exclusions.freeze
    @active_plans = active_plans.freeze
  end

  def upstream_paths
    root = File.join(@repository_root, "reference", "upstream-src", upstream_version, "repository", @upstream_subpath)
    Dir.glob(File.join(root, "**", "*.test.ts")).map { |path| path.delete_prefix("#{root}/") }.sort
  end

  def validation_errors(entries: @entries, exclusions: @exclusions, upstream_paths: self.upstream_paths,
    active_plans: @active_plans)
    UpstreamTestInventory.validate(
      upstream_paths: upstream_paths,
      entries: entries,
      exclusions: exclusions,
      test_root: @test_root,
      active_plans: active_plans,
      require_named_evidence: true
    )
  end

  private

  def upstream_version
    version_file = File.join(@repository_root, "reference", "upstream-better-auth", "VERSION.md")
    version = File.read(version_file)[/^\| Version \| `(\d+\.\d+\.\d+)` \|$/, 1]
    raise "Could not read pinned upstream version from #{version_file}" unless version

    version
  end
end

module UpstreamPackageInventoryAssertions
  def assert_inventory_contract(ledger)
    assert_empty ledger.validation_errors

    synthetic_path = "synthetic/unknown.test.ts"
    unknown_errors = ledger.validation_errors(upstream_paths: ledger.upstream_paths + [synthetic_path])
    assert_includes unknown_errors, "Unclassified upstream test: #{synthetic_path}"

    stale_path = "synthetic/stale.test.ts"
    stale_entries = ledger.entries.merge(stale_path => {status: :ruby_not_applicable, reason: "fixture"})
    assert_includes ledger.validation_errors(entries: stale_entries), "Stale inventory entry: #{stale_path}"

    path, entry = ledger.entries.find { |_path, candidate| %i[covered adapted].include?(candidate[:status]) }
    refute_nil path, "Inventory fixture requires one covered or adapted entry"
    owner = Array(entry[:owner]).first
    missing_evidence = ledger.entries.merge(
      path => entry.merge(evidence: {owner => "test_named_evidence_does_not_exist"})
    )
    evidence_errors = ledger.validation_errors(entries: missing_evidence)
    assert evidence_errors.any? { |error| error.include?("Missing named test test_named_evidence_does_not_exist") }

    partial_entries = ledger.entries.merge(
      path => {owner: entry[:owner], status: :partial, plan: "999", notes: "fixture gap"}
    )
    assert_includes ledger.validation_errors(entries: partial_entries), "Missing current plan 999 for partial #{path}"
  end
end
