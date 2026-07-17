# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/release/publish_gems"

class ReleasePublisherTest < Minitest::Test
  RELEASE_NAMES = %w[
    better_auth
    better_auth-api-key
    better_auth-cli
    better_auth-grape
    better_auth-hanami
    better_auth-mongo-adapter
    better_auth-mongodb
    better_auth-oauth-provider
    better_auth-oidc
    better_auth-passkey
    better_auth-rails
    better_auth-redis-storage
    better_auth-roda
    better_auth-saml
    better_auth-scim
    better_auth-sinatra
    better_auth-sso
    better_auth-stripe
    better_auth-telemetry
  ].freeze

  FakeDownloader = Struct.new(:handler, :calls) do
    def download(url)
      calls << url
      handler.call(url, calls.size)
    end
  end

  FakeUploader = Struct.new(:paths) do
    def push(path)
      paths << path
    end
  end

  FakeTagResolver = Struct.new(:commits) do
    def resolve(reference)
      commits.fetch(reference)
    end
  end

  def test_missing_remote_artifact_is_pushed_then_checksum_verified
    with_inventory do |directory, entries, bodies|
      first_artifact = entries.first.fetch("artifact")
      first_downloads = 0
      downloader = fake_downloader do |url, _call|
        artifact = File.basename(url)
        if artifact == first_artifact
          first_downloads += 1
          next response(404) if first_downloads == 1
        end
        response(200, bodies.fetch(artifact))
      end
      uploader = FakeUploader.new([])

      ReleasePublisher::Publisher.new(downloader: downloader, uploader: uploader, sleeper: ->(_seconds) {}).call(directory)

      assert_equal [File.join(directory, first_artifact)], uploader.paths
      assert_equal 2, first_downloads
    end
  end

  def test_matching_remote_artifacts_are_skipped_without_push
    with_inventory do |directory, _entries, bodies|
      downloader = fake_downloader { |url, _call| response(200, bodies.fetch(File.basename(url))) }
      uploader = FakeUploader.new([])

      ReleasePublisher::Publisher.new(downloader: downloader, uploader: uploader).call(directory)

      assert_empty uploader.paths
      assert_equal RELEASE_NAMES.size, downloader.calls.size
    end
  end

  def test_conflicting_remote_artifact_aborts_before_push
    with_inventory do |directory, _entries, _bodies|
      downloader = fake_downloader { |_url, _call| response(200, "different gem bytes") }
      uploader = FakeUploader.new([])

      error = assert_raises(ReleasePublisher::Error) do
        ReleasePublisher::Publisher.new(downloader: downloader, uploader: uploader).call(directory)
      end

      assert_includes error.message, "conflicting immutable artifact"
      assert_empty uploader.paths
      assert_equal 1, downloader.calls.size
    end
  end

  def test_server_and_network_failures_abort_without_push
    with_inventory do |directory, _entries, _bodies|
      uploader = FakeUploader.new([])
      server_error = fake_downloader { |_url, _call| response(503) }

      error = assert_raises(ReleasePublisher::Error) do
        ReleasePublisher::Publisher.new(downloader: server_error, uploader: uploader).call(directory)
      end
      assert_includes error.message, "HTTP 503"

      network_error = fake_downloader { |_url, _call| raise ReleasePublisher::Error, "HTTPS download failed" }
      assert_raises(ReleasePublisher::Error) do
        ReleasePublisher::Publisher.new(downloader: network_error, uploader: uploader).call(directory)
      end
      assert_empty uploader.paths
    end
  end

  def test_all_local_checksums_are_validated_before_network_access
    with_inventory do |directory, entries, _bodies|
      File.binwrite(File.join(directory, entries.last.fetch("artifact")), "tampered")
      downloader = fake_downloader { |_url, _call| flunk "network must not be used" }

      error = assert_raises(ReleasePublisher::Error) do
        ReleasePublisher::Publisher.new(downloader: downloader, uploader: FakeUploader.new([])).call(directory)
      end

      assert_includes error.message, "checksum changed"
      assert_empty downloader.calls
    end
  end

  def test_dependency_order_is_stable_and_places_internal_dependencies_first
    packages = [
      package("better_auth", 0),
      package("better_auth-mongo-adapter", 1, "better_auth-mongodb" => "= 0.10.0"),
      package("better_auth-mongodb", 2, "better_auth" => "~> 0.1"),
      package("better_auth-sso", 3, "better_auth-oidc" => "= 0.10.0"),
      package("better_auth-oidc", 4, "better_auth" => "~> 0.1")
    ]

    ordered = ReleasePublisher::DependencyOrder.sort(packages).map(&:name)

    assert_equal %w[
      better_auth
      better_auth-mongodb
      better_auth-mongo-adapter
      better_auth-oidc
      better_auth-sso
    ], ordered
  end

  def test_dependency_cycle_aborts
    packages = [
      package("better_auth-a", 0, "better_auth-b" => "= 0.10.0"),
      package("better_auth-b", 1, "better_auth-a" => "= 0.10.0")
    ]

    error = assert_raises(ReleasePublisher::Error) do
      ReleasePublisher::DependencyOrder.sort(packages)
    end

    assert_includes error.message, "cycle"
  end

  def test_tag_mismatch_aborts
    package = package("better_auth", 0)
    expected_commit = "a" * 40
    resolver = FakeTagResolver.new({"better_auth/v0.10.0" => "b" * 40})

    error = assert_raises(ReleasePublisher::Error) do
      ReleasePublisher::TagVerifier.new(resolver: resolver).verify([package], expected_commit)
    end

    assert_includes error.message, "expected #{expected_commit}"
  end

  private

  def with_inventory
    Dir.mktmpdir("release-publisher-test") do |directory|
      entries = RELEASE_NAMES.map do |name|
        artifact = "#{name}-0.10.0.gem"
        body = "gem bytes for #{name}"
        File.binwrite(File.join(directory, artifact), body)
        {
          "name" => name,
          "version" => "0.10.0",
          "package" => "packages/#{name}",
          "artifact" => artifact,
          "sha256" => Digest::SHA256.hexdigest(body),
          "tag" => "#{name}/v0.10.0",
          "commit" => "a" * 40
        }
      end
      bodies = entries.to_h { |entry| [entry.fetch("artifact"), File.binread(File.join(directory, entry.fetch("artifact")))] }
      ReleasePublisher::Inventory.write(directory, "a" * 40, entries)

      yield directory, entries, bodies
    end
  end

  def fake_downloader(&handler)
    FakeDownloader.new(handler, [])
  end

  def response(status, body = "")
    ReleasePublisher::Response.new(status: status, body: body)
  end

  def package(name, index, dependencies = {})
    specification = Gem::Specification.new do |spec|
      spec.name = name
      spec.version = "0.10.0"
      spec.summary = name
      spec.authors = ["Test"]
      spec.files = []
      dependencies.each { |dependency, requirement| spec.add_runtime_dependency(dependency, requirement) }
    end
    ReleasePublisher::Package.new(
      path: "packages/#{name}",
      name: name,
      version: "0.10.0",
      specification: specification,
      manifest_index: index
    )
  end
end
