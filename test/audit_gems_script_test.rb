# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class AuditGemsScriptTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "scripts", "audit_gems.rb")

  def test_checks_each_bundle_and_audits_its_directory_with_the_root_bundle
    Dir.mktmpdir("better-auth-audit-test") do |workspace|
      package_dir = File.join(workspace, "packages", "example")
      bin_dir = File.join(workspace, "bin")
      log_path = File.join(workspace, "bundle-calls.jsonl")
      FileUtils.mkdir_p([package_dir, bin_dir])
      File.write(File.join(workspace, "Gemfile"), "source \"https://rubygems.org\"\n")
      File.write(File.join(package_dir, "Gemfile"), "source \"https://rubygems.org\"\n")
      write_fake_bundle(File.join(bin_dir, "bundle"))

      stdout, stderr, status = Open3.capture3(
        {
          "AUDIT_LOG" => log_path,
          "PATH" => [bin_dir, ENV.fetch("PATH")].join(File::PATH_SEPARATOR)
        },
        RbConfig.ruby,
        SCRIPT,
        workspace
      )

      assert status.success?, "audit failed:\n#{stdout}\n#{stderr}"

      calls = File.readlines(log_path, chomp: true).map { |line| JSON.parse(line) }
      checks = calls.select { |call| call.fetch("arguments") == ["check"] }
      audits = calls.select { |call| call.fetch("arguments").first(3) == ["exec", "bundler-audit", "check"] }
      root_gemfile = File.join(workspace, "Gemfile")

      assert_equal [root_gemfile, File.join(package_dir, "Gemfile")], checks.map { |call| call.fetch("gemfile") }
      assert_equal [root_gemfile, root_gemfile], audits.map { |call| call.fetch("gemfile") }
      assert_equal [workspace, package_dir], audits.map { |call| call.fetch("arguments").last }
      assert calls.all? { |call| call.fetch("directory") == File.realpath(workspace) }
    end
  end

  private

  def write_fake_bundle(path)
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"

      call = {
        "arguments" => ARGV,
        "gemfile" => ENV.fetch("BUNDLE_GEMFILE"),
        "directory" => Dir.pwd
      }
      File.open(ENV.fetch("AUDIT_LOG"), "a") { |file| file.puts(JSON.generate(call)) }
    RUBY
    FileUtils.chmod(0o755, path)
  end
end
