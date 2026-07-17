# frozen_string_literal: true

require "minitest/autorun"
require "json"

class ReleaseWorkflowsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CHECKOUT_ACTION = "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0"
  CREDENTIAL_ACTION = "rubygems/configure-rubygems-credentials@dc5a8d8553e6ee01fc26761a49e99e733d17954a"

  def test_release_workflow_prepares_before_one_oidc_configuration_and_publish
    workflow = release_workflow
    publish = job_body(workflow, "publish")
    prepare_index = publish.index("ruby scripts/release/publish_gems.rb prepare tmp/release-gems")
    credentials_index = publish.index(CREDENTIAL_ACTION)
    publish_index = publish.index("ruby scripts/release/publish_gems.rb publish tmp/release-gems")

    assert_equal 1, workflow.scan(CREDENTIAL_ACTION).size
    refute_includes workflow, ["rubygems", "release-gem"].join("/")
    assert prepare_index < credentials_index
    assert credentials_index < publish_index
    assert_equal 1, publish.scan("ruby/setup-ruby@").size
    refute_includes workflow, "RUBYGEMS_API_KEY"
  end

  def test_publish_has_protected_least_privilege_and_exact_checkout
    publish = job_body(release_workflow, "publish")

    assert_includes publish, "environment: release"
    assert_includes publish, "group: rubygems-production"
    assert_includes publish, "cancel-in-progress: false"
    assert_includes publish, "contents: read"
    assert_includes publish, "id-token: write"
    refute_includes publish, "contents: write"
    assert_includes publish, "uses: #{CHECKOUT_ACTION}"
    assert_includes publish, "fetch-depth: 0"
    assert_includes publish, "persist-credentials: false"
    assert_includes publish, "ref: ${{ github.sha }}"
  end

  def test_release_please_uses_custom_token_and_gates_publish
    workflow = release_workflow
    release_pr = job_body(workflow, "release-pr")
    publish = job_body(workflow, "publish")

    assert_includes release_pr, "token: ${{ secrets.RELEASE_PLEASE_TOKEN }}"
    refute_includes release_pr, "token: ${{ secrets.GITHUB_TOKEN }}"
    assert_includes release_pr, "permissions: {}"
    refute_includes release_pr, "contents: write"
    refute_includes release_pr, "pull-requests: write"
    assert_includes release_pr, "group: release-please-pr"
    assert_includes release_pr, "cancel-in-progress: false"
    assert_includes release_pr, "releases_created: ${{ steps.release.outputs.releases_created }}"
    assert_includes publish, "needs: release-pr"
    assert_includes publish, "if: needs.release-pr.outputs.releases_created == 'true'"
    refute JSON.parse(File.read(File.join(ROOT, "release-please-config.json"))).key?("skip-github-release")
  end

  def test_every_active_action_is_full_sha_pinned
    active_workflows.each do |path|
      refs = File.read(path).scan(/^\s*(?:-\s*)?uses:\s*[^\s@]+@([^\s#]+)/).flatten

      refute_empty refs, "#{File.basename(path)} must use at least one action"
      refs.each do |ref|
        assert_match(/\A[0-9a-f]{40}\z/, ref, "#{File.basename(path)} action ref #{ref} must be immutable")
      end
    end
  end

  def test_every_active_checkout_disables_persisted_credentials
    checkout_count = 0

    active_workflows.each do |path|
      lines = File.readlines(path)
      lines.each_with_index do |line, index|
        next unless line.include?(CHECKOUT_ACTION)

        checkout_count += 1
        nearby_lines = lines[(index + 1)..(index + 5)].join
        assert_includes nearby_lines, "persist-credentials: false", "#{File.basename(path)} checkout at line #{index + 1}"
      end
    end

    assert_operator checkout_count, :>, 0
  end

  def test_ci_filters_cover_retained_release_automation_only
    workflow = File.read(File.join(ROOT, ".github/workflows/ci.yml"))
    retained_paths = %w[
      .release.yml
      .release-please-manifest.json
      release-please-config.json
      scripts/**
      .github/workflows/release.yml
    ]

    retained_paths.each { |path| assert_equal 2, workflow.scan("'#{path}'").size, "#{path} must trigger PR and push CI" }
    removed_workflow = ".github/workflows/" + "api-compatibility.yml"
    refute_includes workflow, removed_workflow
  end

  def test_audit_workflow_combines_pull_request_push_and_schedule
    workflow = File.read(File.join(ROOT, ".github/workflows/audit.yml"))

    assert_match(/^  pull_request:/, workflow)
    assert_match(/^  push:/, workflow)
    assert_match(/^  schedule:/, workflow)
    refute_path_exists File.join(ROOT, ".github/workflows/pr-audit.yml")
  end

  def test_release_documentation_describes_safe_nineteen_gem_process
    changelog = File.read(File.join(ROOT, "CHANGELOG.md"))
    releasing = File.read(File.join(ROOT, "RELEASING.md"))

    assert_includes changelog, "## Unreleased"
    assert_includes releasing, "19 linked gems"
    assert_includes releasing, "RELEASE_PLEASE_TOKEN"
    assert_includes releasing, "SHA-256"
    assert_includes releasing, "built-in `GITHUB_TOKEN`"
    assert_includes releasing, "<gem-name>/vX.Y.Z"
    assert_includes releasing, "GitHub Releases"

    trusted_publisher = releasing.scan(
      /^- (Repository owner|Repository name|Workflow filename|Environment): `([^`]+)`$/
    ).to_h
    assert_equal({
      "Repository owner" => "salasebas",
      "Repository name" => "better-auth-rb",
      "Workflow filename" => "release.yml",
      "Environment" => "release"
    }, trusted_publisher)
  end

  private

  def active_workflows
    @active_workflows ||= Dir[File.join(ROOT, ".github/workflows/*.{yml,yaml}")].sort
  end

  def release_workflow
    @release_workflow ||= File.read(File.join(ROOT, ".github/workflows/release.yml"))
  end

  def job_body(workflow, name)
    start = workflow.index(/^  #{Regexp.escape(name)}:\n/)
    assert start, "missing #{name} job"
    finish = workflow.index(/^  [a-z][a-z0-9-]+:\n/, start + 3) || workflow.length
    workflow[start...finish]
  end
end
