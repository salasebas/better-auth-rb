# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

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

  def test_release_please_uses_builtin_token_and_gates_publish
    workflow = release_workflow
    release_pr = job_body(workflow, "release-pr")
    publish = job_body(workflow, "publish")

    assert_includes release_pr, "token: ${{ github.token }}"
    refute_includes workflow, ["RELEASE", "PLEASE", "TOKEN"].join("_")
    assert_includes release_pr, "contents: write"
    assert_includes release_pr, "pull-requests: write"
    assert_includes release_pr, "group: release-please-pr"
    assert_includes release_pr, "cancel-in-progress: false"
    assert_includes release_pr, "releases_created: ${{ steps.release.outputs.releases_created }}"
    assert_includes publish, "needs: release-pr"
    assert_includes publish, "if: needs.release-pr.outputs.releases_created == 'true'"
    refute JSON.parse(File.read(File.join(ROOT, "release-please-config.json"))).key?("skip-github-release")
  end

  def test_pending_manifest_release_runs_full_integration_before_release_please
    workflow = release_workflow
    detection = job_body(workflow, "detect-pending-release")
    integration = job_body(workflow, "release-integration")
    release_pr = job_body(workflow, "release-pr")

    assert_includes detection, ".release-please-manifest.json"
    assert_includes detection, "release-please-config.json"
    assert_includes detection, 'IO.popen(["git", "tag", "--list"]'
    assert_includes detection, 'config.fetch("include-component-in-tag", false)'
    assert_includes detection, 'config["tag-separator"]'
    assert_includes detection, "configured_tag = include_component"
    assert_includes detection, "legacy_tag = \"\#{component}-v\#{version}\""
    assert_includes detection, "pending = !missing.empty?"
    refute_includes detection, "github.event.before"
    refute_includes detection, "git diff"
    assert_includes integration, "uses: ./.github/workflows/integration.yml"
    assert_includes integration, "full: true"
    assert_includes release_pr, "- detect-pending-release"
    assert_includes release_pr, "- release-integration"
    assert_includes release_pr, "if: >-"
    assert_includes release_pr, "needs.release-integration.result == 'success'"
  end

  def test_pending_release_detector_accepts_configured_and_legacy_tags
    assert_equal "pending=true", run_pending_release_detector
    assert_equal "pending=false", run_pending_release_detector(tag: "example/v1.2.3")
    assert_equal "pending=false", run_pending_release_detector(tag: "example-v1.2.3")
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

  def test_ci_has_stable_unfiltered_required_triggers
    workflow = File.read(File.join(ROOT, ".github/workflows/ci.yml"))

    assert_match(/^  workflow_dispatch:$/, workflow)
    assert_match(/^  pull_request:$/, workflow)
    assert_match(/^  push:$/, workflow)
    assert_match(/^  merge_group:$/, workflow)
    refute_match(/^\s+paths:/, workflow.lines.take_while { |line| line != "concurrency:\n" }.join)
  end

  def test_audit_workflow_combines_pull_request_push_and_schedule
    workflow = File.read(File.join(ROOT, ".github/workflows/audit.yml"))

    assert_match(/^  pull_request:/, workflow)
    assert_match(/^  push:/, workflow)
    assert_match(/^  schedule:/, workflow)
    refute_path_exists File.join(ROOT, ".github/workflows/pr-audit.yml")
  end

  def test_audit_installs_database_headers_before_ruby
    workflow = File.read(File.join(ROOT, ".github/workflows/audit.yml"))
    headers = workflow.index("default-libmysqlclient-dev freetds-dev")
    ruby = workflow.index("ruby/setup-ruby@")

    assert headers < ruby
    assert_includes workflow, "/etc/apt/apt-mirrors.txt"
    assert_includes workflow, "Acquire::Retries=3"
  end

  def test_release_documentation_describes_safe_nineteen_gem_process
    changelog = File.read(File.join(ROOT, "CHANGELOG.md"))
    releasing = File.read(File.join(ROOT, "RELEASING.md"))

    assert_includes changelog, "## Unreleased"
    assert_includes releasing, "19 linked gems"
    refute_includes releasing, ["RELEASE", "PLEASE", "TOKEN"].join("_")
    assert_includes releasing, "SHA-256"
    assert_includes releasing, "built-in `GITHUB_TOKEN`"
    assert_includes releasing, "Settings > Actions > General > Workflow permissions"
    assert_includes releasing, "Approve workflows to run"
    refute_includes releasing, "manually\nrun the `CI`"
    assert_includes releasing, "reusable full-integration gate"
    assert_includes releasing, "every later push rerun the full"
    assert_includes releasing, "<component>/vX.Y.Z"
    assert_includes releasing, "<component>-vX.Y.Z"
    assert_includes releasing, "Trusted Publishing"
    assert_includes releasing, "<gem-name>/vX.Y.Z"
    assert_includes releasing, "GitHub Releases"
    assert_equal 19, releasing.scan(/^- \[`better_auth[^`]*`\]\(packages\/better_auth[^)]*\/\)$/).size

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

  def pending_release_detector
    workflow = YAML.safe_load_file(File.join(ROOT, ".github/workflows/release.yml"), aliases: true)
    run = workflow.fetch("jobs").fetch("detect-pending-release").fetch("steps")
      .find { |step| step["id"] == "detect" }.fetch("run")
    match = run.match(/ruby <<'RUBY'\n(?<script>.*)\nRUBY\n?\z/m)

    refute_nil match, "pending release detector must remain an inline Ruby heredoc"
    match[:script]
  end

  def run_pending_release_detector(tag: nil)
    Dir.mktmpdir("pending-release-detector") do |dir|
      File.write(
        File.join(dir, ".release-please-manifest.json"),
        JSON.generate("packages/example" => "1.2.3")
      )
      File.write(
        File.join(dir, "release-please-config.json"),
        JSON.generate(
          "include-component-in-tag" => true,
          "tag-separator" => "/",
          "packages" => {
            "packages/example" => {
              "component" => "example",
              "package-name" => "example"
            }
          }
        )
      )
      output_path = File.join(dir, "github-output")
      initialize_tagged_repository(dir, tag)

      stdout, stderr, status = Open3.capture3(
        {"GITHUB_OUTPUT" => output_path},
        RbConfig.ruby,
        stdin_data: pending_release_detector,
        chdir: dir
      )
      assert status.success?, "#{stdout}\n#{stderr}"

      File.read(output_path).strip
    end
  end

  def initialize_tagged_repository(dir, tag)
    commands = [
      %w[git init --quiet],
      %w[git config user.email release-test@example.com],
      %w[git config user.name ReleaseTest],
      %w[git commit --quiet --allow-empty -m initial]
    ]
    commands << ["git", "tag", tag] if tag

    commands.each do |command|
      assert system(*command, chdir: dir), "failed: #{command.join(" ")}"
    end
  end

  def job_body(workflow, name)
    start = workflow.index(/^  #{Regexp.escape(name)}:\n/)
    assert start, "missing #{name} job"
    finish = workflow.index(/^  [a-z][a-z0-9-]+:\n/, start + 3) || workflow.length
    workflow[start...finish]
  end
end
