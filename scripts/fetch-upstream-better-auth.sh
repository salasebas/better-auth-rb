#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${ROOT}/reference/upstream-better-auth/VERSION.md"
REPO_URL="https://github.com/better-auth/better-auth.git"
REGISTRY_URL="https://registry.npmjs.org/better-auth"

usage() {
	cat <<'USAGE'
Usage:
  ./scripts/fetch-upstream-better-auth.sh
  ./scripts/fetch-upstream-better-auth.sh VERSION
  ./scripts/fetch-upstream-better-auth.sh --latest-patch [MAJOR.MINOR]

With no arguments, clone the exact version pinned in VERSION.md. Pass an exact
stable VERSION to compare another release, or --latest-patch to resolve the
highest stable patch from npm for a major.minor series. When SERIES is omitted,
the pinned version's series is used.
USAGE
}

default_version() {
	if [[ ! -f "${VERSION_FILE}" ]]; then
		echo "Missing upstream version file: ${VERSION_FILE}" >&2
		return 1
	fi

	local version
	version="$(grep -E '^\| Version \|' "${VERSION_FILE}" | sed -n 's/.*`\([^`]*\)`.*/\1/p' | head -n 1)"
	if [[ -z "${version}" ]]; then
		echo "Could not read the pinned version from ${VERSION_FILE}" >&2
		return 1
	fi
	printf '%s\n' "${version}"
}

default_commit() {
	local commit
	commit="$(grep -E '^\| Repository commit \|' "${VERSION_FILE}" | sed -n 's/.*`\([^`]*\)`.*/\1/p' | head -n 1)"
	if [[ ! "${commit}" =~ ^[0-9a-f]{40}$ ]]; then
		echo "Could not read the pinned commit from ${VERSION_FILE}" >&2
		return 1
	fi
	printf '%s\n' "${commit}"
}

validate_version() {
	if [[ ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "Invalid stable version '$1'; expected MAJOR.MINOR.PATCH" >&2
		return 1
	fi
}

validate_series() {
	if [[ ! "$1" =~ ^[0-9]+\.[0-9]+$ ]]; then
		echo "Invalid series '$1'; expected MAJOR.MINOR" >&2
		return 1
	fi
}

latest_patch() {
	local series="$1"
	REGISTRY_URL="${REGISTRY_URL}" SERIES="${series}" ruby <<'RUBY'
require "json"
require "net/http"
require "rubygems/version"
require "uri"

begin
  uri = URI(ENV.fetch("REGISTRY_URL"))
  response = Net::HTTP.get_response(uri)
  raise "registry returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  versions = JSON.parse(response.body).fetch("versions", {}).keys
  pattern = /\A#{Regexp.escape(ENV.fetch("SERIES"))}\.\d+\z/
  candidates = versions.grep(pattern)
  raise "no stable releases found for series #{ENV.fetch("SERIES")}" if candidates.empty?

  puts candidates.max_by { |version| Gem::Version.new(version) }
rescue StandardError => error
  warn "Could not resolve latest patch: #{error.message}"
  exit 1
end
RUBY
}

PINNED_VERSION="$(default_version)"
validate_version "${PINNED_VERSION}"

case "${1:-}" in
	-h|--help)
		if (( $# != 1 )); then
			echo "--help does not accept arguments" >&2
			usage >&2
			exit 2
		fi
		usage
		exit 0
		;;
	--latest-patch)
		if (( $# > 2 )); then
			echo "--latest-patch accepts at most one SERIES argument" >&2
			usage >&2
			exit 2
		fi
		SERIES="${2:-${PINNED_VERSION%.*}}"
		validate_series "${SERIES}"
		VERSION="$(latest_patch "${SERIES}")"
		validate_version "${VERSION}"
		echo "Latest stable patch for ${SERIES}: ${VERSION}"
		;;
	--*)
		echo "Unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	"")
		VERSION="${PINNED_VERSION}"
		;;
	*)
		if (( $# != 1 )); then
			echo "An explicit VERSION does not accept additional arguments" >&2
			usage >&2
			exit 2
		fi
		VERSION="$1"
		validate_version "${VERSION}"
		;;
esac

DEST="${ROOT}/reference/upstream-src/${VERSION}/repository"
TAG="v${VERSION}"
EXPECTED_COMMIT=""
if [[ "${VERSION}" == "${PINNED_VERSION}" ]]; then
	EXPECTED_COMMIT="$(default_commit)"
fi

if [[ -d "${DEST}/.git" ]] || [[ -f "${DEST}/package.json" ]] || [[ -d "${DEST}/packages" ]]; then
	if [[ -n "${EXPECTED_COMMIT}" && -d "${DEST}/.git" ]]; then
		ACTUAL_COMMIT="$(git -C "${DEST}" rev-parse HEAD)"
		if [[ "${ACTUAL_COMMIT}" != "${EXPECTED_COMMIT}" ]]; then
			echo "Existing upstream tree is at ${ACTUAL_COMMIT}, expected pinned commit ${EXPECTED_COMMIT}" >&2
			exit 1
		fi
	fi
	echo "Upstream tree already exists at ${DEST}"
	echo "Remove that directory to re-clone."
	exit 0
fi

if ! git ls-remote --exit-code --refs "${REPO_URL}" "refs/tags/${TAG}" >/dev/null; then
	echo "Upstream tag ${TAG} was not found at ${REPO_URL}" >&2
	exit 1
fi

mkdir -p "$(dirname "${DEST}")"
echo "Cloning ${REPO_URL} (${TAG}) into ${DEST} ..."
git clone --depth 1 --branch "${TAG}" "${REPO_URL}" "${DEST}"
if [[ -n "${EXPECTED_COMMIT}" ]]; then
	ACTUAL_COMMIT="$(git -C "${DEST}" rev-parse HEAD)"
	if [[ "${ACTUAL_COMMIT}" != "${EXPECTED_COMMIT}" ]]; then
		echo "Cloned ${TAG} at ${ACTUAL_COMMIT}, expected pinned commit ${EXPECTED_COMMIT}" >&2
		exit 1
	fi
fi
echo "Done. Parity sources: ${DEST}/packages/"
