# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class WorkspaceToolingManifestTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_standard_paths_cover_released_packages_with_rakefiles
    released_packages_with_rakefiles.each do |package|
      assert_includes standard_paths, "packages/#{package}/Rakefile", "#{package} Rakefile must be linted by root STANDARD_PATHS"
      assert_includes standard_paths, "packages/#{package}/lib", "#{package} lib must be linted by root STANDARD_PATHS"

      test_directories(package).each do |directory|
        assert_includes standard_paths, "packages/#{package}/#{directory}", "#{package} #{directory} must be linted by root STANDARD_PATHS"
      end
    end
  end

  def test_workspace_ci_runs_released_packages_with_tests
    ci_body = rake_task_body(:ci)

    released_packages_with_tests.each do |package|
      assert_includes ci_body, %(cd "packages/#{package}"), "#{package} must be represented in root rake ci"
    end
  end

  def test_workspace_test_task_discovers_root_tests_and_excludes_only_database_smoke
    assert_includes root_rakefile, 'WORKSPACE_TEST_PATHS = Dir["test/**/*_test.rb"].sort.reject'
    assert_includes root_rakefile, 'path == "test/mysql_plugin_schema_smoke_test.rb"'
    assert_includes rake_task_body(:ci), 'Rake::Task["test:workspace"].invoke'
  end

  def test_root_package_tasks_cover_released_package_gemfiles
    released_packages_with_gemfiles.each do |package|
      assert_includes rake_task_body(:install), %(cd "packages/#{package}"), "#{package} must be represented in root rake install"
      assert_includes rake_task_body(:lint), %(cd "packages/#{package}"), "#{package} must be represented in root rake lint"
      assert_includes rake_task_body("lint:fix"), %(cd "packages/#{package}"), "#{package} must be represented in root rake lint:fix"
      assert_includes rake_task_body(:clean), %(cd "packages/#{package}"), "#{package} must be represented in root rake clean"
    end
  end

  def test_makefile_workspace_targets_delegate_to_rake
    {
      "install" => "bundle exec rake install",
      "lint" => "bundle exec rake lint",
      "lint-fix" => "bundle exec rake lint:fix",
      "test" => "bundle exec rake ci",
      "ci" => "bundle exec rake ci",
      "clean" => "bundle exec rake clean"
    }.each do |target, command|
      body = make_target_body(target)

      assert_includes body, command, "make #{target} must delegate to #{command}"
      refute_match(/^\tcd packages\//, body, "make #{target} must not maintain a package list")
    end
  end

  private

  def release_manifest
    # standard:disable Style/YAMLFileRead
    YAML.safe_load(File.read(File.join(ROOT, ".release.yml")))
    # standard:enable Style/YAMLFileRead
  end

  def released_package_names
    release_manifest.fetch("version_files").map { |path| path.split("/")[1] }.uniq
  end

  def released_packages_with_rakefiles
    released_package_names.select { |package| File.exist?(File.join(ROOT, "packages", package, "Rakefile")) }
  end

  def released_packages_with_tests
    released_packages_with_rakefiles.select { |package| test_directories(package).any? }
  end

  def released_packages_with_gemfiles
    released_package_names.select { |package| File.exist?(File.join(ROOT, "packages", package, "Gemfile")) }
  end

  def test_directories(package)
    ["test", "spec"].select { |directory| File.directory?(File.join(ROOT, "packages", package, directory)) }
  end

  def standard_paths
    match = root_rakefile.match(/STANDARD_PATHS = \[(.*?)\]\.freeze/m)
    assert match, "Rakefile must define STANDARD_PATHS"

    match[1].scan(/"([^"]+)"/).flatten
  end

  def rake_task_body(task_name)
    task_marker = case task_name
    when :ci
      "task :ci do"
    when :install
      "task :install do"
    when :lint
      "task :lint do"
    when :clean
      "task :clean do"
    else
      %(task "#{task_name}" do)
    end

    start_index = root_rakefile.index(task_marker)
    assert start_index, "Rakefile must define #{task_name}"

    body_start = start_index + task_marker.length
    next_desc_index = root_rakefile.index(/\ndesc /, body_start) || root_rakefile.length
    root_rakefile[body_start...next_desc_index]
  end

  def make_target_body(target)
    match = makefile.match(/^#{Regexp.escape(target)}:\n(?<body>(?:\t.*\n)*)/)

    assert match, "Makefile must define #{target}"
    match[:body]
  end

  def root_rakefile
    @root_rakefile ||= File.read(File.join(ROOT, "Rakefile"))
  end

  def makefile
    @makefile ||= File.read(File.join(ROOT, "Makefile"))
  end
end
