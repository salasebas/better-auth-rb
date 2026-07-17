# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "rubygems"
require "rubygems/package"
require "uri"
require "yaml"

module ReleasePublisher
  INVENTORY_FILENAME = "inventory.json"
  INVENTORY_VERSION = 1
  RELEASE_PACKAGE_COUNT = 19
  PACKAGE_DIRECTORY_PATTERN = /\Abetter_auth(?:-[a-z0-9-]+)?\z/
  ARTIFACT_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\.gem\z/
  COMMIT_PATTERN = /\A[0-9a-f]{40}\z/

  class Error < StandardError; end

  Package = Struct.new(:path, :name, :version, :specification, :manifest_index)
  Response = Struct.new(:status, :body)

  class GitTagResolver
    def resolve(reference)
      stdout, _stderr, status = Open3.capture3("git", "rev-parse", "#{reference}^{commit}")
      raise Error, "Git reference does not resolve to a commit: #{reference}" unless status.success?

      stdout.strip
    end
  end

  class GemBuilder
    def build(package, output_directory)
      artifact = File.join(output_directory, package.specification.file_name)
      package_directory = File.dirname(package.specification.loaded_from)

      Dir.chdir(package_directory) do
        Gem::Package.build(package.specification, false, false, artifact)
      end

      raise Error, "Gem build did not create #{File.basename(artifact)}" unless File.file?(artifact)

      artifact
    rescue Gem::InvalidSpecificationException => error
      raise Error, "Invalid gemspec for #{package.name}: #{error.message}"
    end
  end

  class DependencyOrder
    def self.sort(packages)
      packages_by_name = packages.to_h { |package| [package.name, package] }
      dependencies = packages.to_h { |package| [package.name, internal_dependencies(package, packages_by_name)] }
      remaining = dependencies.transform_values(&:dup)
      ordered = []

      until remaining.empty?
        ready = remaining.filter_map do |name, package_dependencies|
          packages_by_name.fetch(name) if package_dependencies.empty?
        end.min_by(&:manifest_index)
        raise Error, "Internal runtime dependency cycle detected" unless ready

        ordered << ready
        remaining.delete(ready.name)
        remaining.each_value { |package_dependencies| package_dependencies.delete(ready.name) }
      end

      ordered
    end

    def self.internal_dependencies(package, packages_by_name)
      package.specification.runtime_dependencies.filter_map do |dependency|
        target = packages_by_name[dependency.name]
        if dependency.name.match?(PACKAGE_DIRECTORY_PATTERN) && !target
          raise Error, "#{package.name} depends on missing release gem #{dependency.name}"
        end
        next unless target

        target_version = Gem::Version.new(target.version)
        unless dependency.requirement.satisfied_by?(target_version)
          raise Error, "#{package.name} requires #{dependency.name} #{dependency.requirement}, not #{target.version}"
        end

        exact_versions = dependency.requirement.requirements.filter_map do |operator, version|
          version if operator == "="
        end
        if exact_versions.any? && exact_versions.none?(target_version)
          raise Error, "#{package.name} has an inconsistent exact version for #{dependency.name}"
        end

        dependency.name
      end
    end

    private_class_method :internal_dependencies
  end

  class TagVerifier
    def initialize(resolver: GitTagResolver.new)
      @resolver = resolver
    end

    def verify(packages, release_commit)
      validate_commit!(release_commit)

      packages.each do |package|
        tag = "#{package.name}/v#{package.version}"
        actual_commit = @resolver.resolve(tag)
        validate_commit!(actual_commit)
        next if actual_commit == release_commit

        raise Error, "Tag #{tag} resolves to #{actual_commit}, expected #{release_commit}"
      end
    end

    private

    def validate_commit!(commit)
      raise Error, "Expected a full 40-character Git commit" unless commit.match?(COMMIT_PATTERN)
    end
  end

  class Catalog
    def initialize(root:)
      @root = root
    end

    def load
      release = YAML.safe_load_file(File.join(@root, ".release.yml"))
      config = JSON.parse(File.read(File.join(@root, "release-please-config.json")))
      manifest = JSON.parse(File.read(File.join(@root, ".release-please-manifest.json")))
      release_paths = release.fetch("version_files").map { |path| package_path_from_version_file(path) }
      config_paths = config.fetch("packages").keys
      manifest_paths = manifest.keys

      validate_package_paths!(release_paths, config_paths, manifest_paths)
      shared_version = release.fetch("version").to_s

      manifest_paths.each_with_index.map do |package_path, index|
        load_package(
          package_path,
          index,
          shared_version,
          config.fetch("packages").fetch(package_path),
          manifest.fetch(package_path)
        )
      end
    rescue Errno::ENOENT, JSON::ParserError, Psych::Exception, KeyError, TypeError => error
      raise Error, "Invalid release metadata: #{error.message}"
    end

    private

    def package_path_from_version_file(path)
      match = path.match(%r{\A(packages/[^/]+)/.+\z})
      raise Error, "Invalid version file path: #{path}" unless match

      match[1]
    end

    def validate_package_paths!(release_paths, config_paths, manifest_paths)
      path_sets = [release_paths, config_paths, manifest_paths].map(&:sort)
      unless path_sets.uniq.one?
        raise Error, "Release package directories differ across release metadata"
      end
      unless release_paths.uniq.size == RELEASE_PACKAGE_COUNT && release_paths.size == RELEASE_PACKAGE_COUNT
        raise Error, "Release metadata must contain exactly #{RELEASE_PACKAGE_COUNT} unique packages"
      end

      release_paths.each do |package_path|
        package_directory = File.basename(package_path)
        unless package_path == "packages/#{package_directory}" && package_directory.match?(PACKAGE_DIRECTORY_PATTERN)
          raise Error, "Invalid release package directory: #{package_path}"
        end
      end
    end

    def load_package(package_path, index, shared_version, config, manifest_version)
      gemspec_paths = Dir[File.join(@root, package_path, "*.gemspec")]
      raise Error, "#{package_path} must contain exactly one gemspec" unless gemspec_paths.one?

      gemspec_path = gemspec_paths.first
      specification = Dir.chdir(File.dirname(gemspec_path)) do
        Gem::Specification.load(gemspec_path)
      end
      raise Error, "Unable to load #{gemspec_path}" unless specification

      expected_name = config.fetch("package-name")
      versions = [specification.version.to_s, manifest_version.to_s, shared_version]
      raise Error, "Gemspec name mismatch for #{package_path}" unless specification.name == expected_name
      raise Error, "Component mismatch for #{package_path}" unless config.fetch("component") == expected_name
      raise Error, "Version mismatch for #{package_path}: #{versions.join(", ")}" unless versions.uniq.one?

      Package.new(
        path: package_path,
        name: specification.name,
        version: shared_version,
        specification: specification,
        manifest_index: index
      )
    end
  end

  class Inventory
    def self.write(output_directory, release_commit, entries)
      payload = {
        "inventory_version" => INVENTORY_VERSION,
        "commit" => release_commit,
        "gems" => entries
      }
      File.write(File.join(output_directory, INVENTORY_FILENAME), JSON.pretty_generate(payload) + "\n")
    end

    def self.load(output_directory)
      payload = JSON.parse(File.read(File.join(output_directory, INVENTORY_FILENAME)))
      validate_payload!(payload)
      payload
    rescue Errno::ENOENT, JSON::ParserError, KeyError, TypeError => error
      raise Error, "Invalid prepared inventory: #{error.message}"
    end

    def self.validate_payload!(payload)
      raise Error, "Unsupported prepared inventory version" unless payload.fetch("inventory_version") == INVENTORY_VERSION
      raise Error, "Invalid prepared release commit" unless payload.fetch("commit").match?(COMMIT_PATTERN)

      entries = payload.fetch("gems")
      raise Error, "Prepared inventory must contain exactly #{RELEASE_PACKAGE_COUNT} gems" unless entries.size == RELEASE_PACKAGE_COUNT

      names = entries.map { |entry| entry.fetch("name") }
      packages = entries.map { |entry| entry.fetch("package") }
      raise Error, "Prepared inventory contains duplicate gems" unless names.uniq.size == entries.size
      raise Error, "Prepared inventory contains duplicate packages" unless packages.uniq.size == entries.size

      entries.each do |entry|
        validate_entry!(entry, payload.fetch("commit"))
      end
    end

    def self.validate_entry!(entry, release_commit)
      name = entry.fetch("name")
      package = entry.fetch("package")
      version = entry.fetch("version")
      artifact = entry.fetch("artifact")
      expected_tag = "#{name}/v#{version}"

      raise Error, "Invalid prepared gem name: #{name}" unless name.match?(PACKAGE_DIRECTORY_PATTERN)
      raise Error, "Invalid prepared package: #{package}" unless package == "packages/#{name}"
      raise Error, "Invalid prepared artifact filename: #{artifact}" unless safe_artifact_filename?(artifact)
      raise Error, "Invalid prepared artifact checksum" unless entry.fetch("sha256").match?(/\A[0-9a-f]{64}\z/)
      raise Error, "Invalid prepared tag for #{name}" unless entry.fetch("tag") == expected_tag
      raise Error, "Invalid prepared commit for #{name}" unless entry.fetch("commit") == release_commit
    end

    def self.safe_artifact_filename?(filename)
      filename == File.basename(filename) && filename.match?(ARTIFACT_PATTERN)
    end

    private_class_method :validate_payload!, :validate_entry!
  end

  class Preparer
    def initialize(root:, builder: GemBuilder.new, tag_resolver: GitTagResolver.new, release_commit: nil)
      @root = root
      @builder = builder
      @tag_resolver = tag_resolver
      @release_commit = release_commit
    end

    def call(output_directory)
      output_directory = File.expand_path(output_directory, @root)
      FileUtils.mkdir_p(output_directory)
      packages = DependencyOrder.sort(Catalog.new(root: @root).load)
      release_commit = @release_commit || @tag_resolver.resolve("HEAD")
      TagVerifier.new(resolver: @tag_resolver).verify(packages, release_commit)

      entries = packages.map do |package|
        artifact_path = @builder.build(package, output_directory)
        artifact = File.basename(artifact_path)
        unless Inventory.safe_artifact_filename?(artifact) && File.expand_path(artifact_path) == File.join(output_directory, artifact)
          raise Error, "Gem builder returned an unsafe artifact path for #{package.name}"
        end

        {
          "name" => package.name,
          "version" => package.version,
          "package" => package.path,
          "artifact" => artifact,
          "sha256" => Digest::SHA256.file(artifact_path).hexdigest,
          "tag" => "#{package.name}/v#{package.version}",
          "commit" => release_commit
        }
      end

      Inventory.write(output_directory, release_commit, entries)
      puts "Prepared #{entries.size} release gems in #{output_directory}."
    end
  end

  class HttpDownloader
    REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze

    def initialize(max_redirects: 3, open_timeout: 10, read_timeout: 30)
      @max_redirects = max_redirects
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def download(url)
      request(URI(url), @max_redirects)
    rescue URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => error
      raise Error, "HTTPS download failed: #{error.class}"
    end

    private

    def request(uri, redirects_remaining)
      raise Error, "Artifact download must use HTTPS" unless uri.is_a?(URI::HTTPS)

      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: true,
        open_timeout: @open_timeout,
        read_timeout: @read_timeout
      ) { |http| http.request(Net::HTTP::Get.new(uri.request_uri)) }
      status = response.code.to_i

      if REDIRECT_STATUSES.include?(status)
        raise Error, "Too many HTTPS redirects" if redirects_remaining.zero?

        location = response["location"]
        raise Error, "HTTPS redirect is missing a location" unless location

        return request(URI.join(uri, location), redirects_remaining - 1)
      end

      Response.new(status: status, body: response.body.to_s.b)
    end
  end

  class GemUploader
    def push(artifact_path)
      _stdout, _stderr, status = Open3.capture3("gem", "push", artifact_path)
      raise Error, "gem push failed for #{File.basename(artifact_path)}" unless status.success?
    end
  end

  class Publisher
    DOWNLOAD_BASE = "https://rubygems.org/downloads/"
    VERIFY_ATTEMPTS = 6
    VERIFY_DELAY_SECONDS = 5

    def initialize(downloader: HttpDownloader.new, uploader: GemUploader.new, sleeper: Kernel.method(:sleep))
      @downloader = downloader
      @uploader = uploader
      @sleeper = sleeper
    end

    def call(output_directory)
      output_directory = File.expand_path(output_directory)
      entries = Inventory.load(output_directory).fetch("gems")
      artifacts = validate_local_artifacts(output_directory, entries)

      entries.each do |entry|
        publish_entry(entry, artifacts.fetch(entry.fetch("artifact")))
      end
    end

    private

    def validate_local_artifacts(output_directory, entries)
      entries.to_h do |entry|
        filename = entry.fetch("artifact")
        path = File.join(output_directory, filename)
        raise Error, "Prepared artifact is missing: #{filename}" unless File.file?(path) && !File.symlink?(path)

        actual_sha256 = Digest::SHA256.file(path).hexdigest
        unless actual_sha256 == entry.fetch("sha256")
          raise Error, "Prepared artifact checksum changed: #{filename}"
        end

        [filename, path]
      end
    end

    def publish_entry(entry, artifact_path)
      artifact = entry.fetch("artifact")
      response = @downloader.download("#{DOWNLOAD_BASE}#{artifact}")

      if response.status == 404
        @uploader.push(artifact_path)
        verify_uploaded(entry)
      elsif response.status.between?(200, 299)
        verify_remote_checksum!(entry, response.body)
        puts "Already published #{entry.fetch("name")} #{entry.fetch("version")}; checksum matches."
      else
        raise Error, "RubyGems download returned HTTP #{response.status} for #{artifact}"
      end
    end

    def verify_uploaded(entry)
      verified = false
      VERIFY_ATTEMPTS.times do |attempt|
        response = @downloader.download("#{DOWNLOAD_BASE}#{entry.fetch("artifact")}")
        if response.status.between?(200, 299)
          verify_remote_checksum!(entry, response.body)
          puts "Published and verified #{entry.fetch("name")} #{entry.fetch("version")}."
          verified = true
          break
        end
        unless response.status == 404
          raise Error, "RubyGems verification returned HTTP #{response.status} for #{entry.fetch("artifact")}"
        end

        @sleeper.call(VERIFY_DELAY_SECONDS) if attempt < VERIFY_ATTEMPTS - 1
      end

      raise Error, "Timed out verifying #{entry.fetch("artifact")} on RubyGems" unless verified
    end

    def verify_remote_checksum!(entry, body)
      remote_sha256 = Digest::SHA256.hexdigest(body)
      return if remote_sha256 == entry.fetch("sha256")

      raise Error, "RubyGems has a conflicting immutable artifact for #{entry.fetch("name")} #{entry.fetch("version")}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    mode, output_directory, extra = ARGV
    unless %w[prepare publish].include?(mode) && output_directory && !extra
      warn "Usage: ruby scripts/release/publish_gems.rb (prepare|publish) OUTPUT_DIR"
      exit 2
    end

    root = File.expand_path("../..", __dir__)
    if mode == "prepare"
      ReleasePublisher::Preparer.new(root: root, release_commit: ENV["GITHUB_SHA"]).call(output_directory)
    else
      ReleasePublisher::Publisher.new.call(File.expand_path(output_directory, root))
    end
  rescue ReleasePublisher::Error => error
    warn "Release failed: #{error.message}"
    exit 1
  end
end
