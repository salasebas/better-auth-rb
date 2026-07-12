# frozen_string_literal: true

require "minitest/autorun"
require "pathname"
require "yaml"

class CIWorkflowPackageCoverageTest < Minitest::Test
  WORKFLOW_PATH = Pathname(".github/workflows/ci.yml")
  PACKAGES_PATH = Pathname("packages")
  REGRESSION_PACKAGES = [
    "better_auth-mongodb",
    "better_auth-mongo-adapter"
  ].freeze

  def setup
    @workflow = YAML.safe_load_file(WORKFLOW_PATH, aliases: true)
    @jobs = @workflow.fetch("jobs")
  end

  def test_linted_packages_with_tests_have_main_ci_package_test_jobs
    missing_packages = linted_packages_with_tests.reject do |package|
      package_test_jobs_by_package.key?(package)
    end

    assert_empty(
      missing_packages,
      "Expected main CI package test jobs for linted packages with test/spec " \
        "directories. Missing: #{missing_packages.join(", ")}. Regression " \
        "packages: #{REGRESSION_PACKAGES.join(", ")}."
    )
  end

  def test_package_test_jobs_are_required_by_aggregate_ci
    missing_needs = package_test_jobs_by_package.values.flatten.reject do |job_id|
      ci_needs.include?(job_id)
    end

    assert_empty(
      missing_needs,
      "Expected aggregate ci.needs to include every package test job. " \
        "Missing: #{missing_needs.join(", ")}."
    )
  end

  def test_mongodb_packages_have_main_ci_regression_coverage
    REGRESSION_PACKAGES.each do |package|
      assert_includes(
        package_test_jobs_by_package.keys,
        package,
        "Regression: #{package} must have a main CI package test job."
      )
    end
  end

  private

  def linted_packages
    @jobs.fetch("lint-package")
      .fetch("strategy")
      .fetch("matrix")
      .fetch("package")
  end

  def linted_packages_with_tests
    linted_packages.select do |package|
      package_path = PACKAGES_PATH.join(package)
      package_path.join("test").directory? || package_path.join("spec").directory?
    end
  end

  def package_test_jobs_by_package
    @package_test_jobs_by_package ||= linted_packages_with_tests.to_h do |package|
      [
        package,
        package_test_job_ids_for(package)
      ]
    end.reject { |_package, job_ids| job_ids.empty? }
  end

  def package_test_job_ids_for(package)
    working_directory = "packages/#{package}"

    @jobs.filter_map do |job_id, job|
      next unless job_id.start_with?("test-")
      next unless working_directories(job).include?(working_directory)

      job_id
    end
  end

  def working_directories(value)
    case value
    when Hash
      value.flat_map do |key, nested_value|
        if key == "working-directory"
          nested_value
        else
          working_directories(nested_value)
        end
      end
    when Array
      value.flat_map { |nested_value| working_directories(nested_value) }
    else
      []
    end
  end

  def ci_needs
    Array(@jobs.fetch("ci").fetch("needs"))
  end
end
