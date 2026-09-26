#!/usr/bin/env bash
#
# Tag a build and push it — that is the only thing that starts CI now (see
# .github/workflows/build-unsigned-ipa.yml). The tag carries both numbers,
# `<version>-<build>`, and the Release is published under it.
#
# Usage:
#   scripts/tag-build.sh              # version from project.yml, build = highest + 1
#   scripts/tag-build.sh 1.0.2        # explicit version, build = highest + 1
#   scripts/tag-build.sh 1.0.2 42     # both explicit
#
# The build number defaults to one past the highest already used by *any* build
# tag — the current `v<version>-<n>` form or the older `ios16-build-<n>` — so it
# never repeats and never has to be looked up by hand.

set -euo pipefail

# A stale GIT_CONFIG_* trio in the environment breaks every git call.
unset GIT_CONFIG_COUNT GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_0 2>/dev/null || true

cd "$(dirname "$0")/.."

REMOTE="${REMOTE:-fork}"

version="${1:-}"
build="${2:-}"

if [[ -z "$version" ]]; then
  version="$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')"
fi
if [[ -z "$version" ]]; then
  echo "error: could not read MARKETING_VERSION from project.yml" >&2
  exit 1
fi

if [[ -z "$build" ]]; then
  # The release tags are created by CI on the remote, so a local-only tag list
  # misses them and the number would go backwards. Fetch first.
  git fetch --tags --quiet "$REMOTE" 2>/dev/null || true
  highest="$(git tag -l \
    | sed -n 's/^v[0-9][0-9.]*-\([0-9][0-9]*\)$/\1/p; s/^ios16-build-\([0-9][0-9]*\)$/\1/p' \
    | sort -n | tail -1)"
  build=$(( ${highest:-0} + 1 ))
fi

tag="v${version}-${build}"

if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  echo "error: tag ${tag} already exists" >&2
  exit 1
fi

echo "tagging ${tag}  (MARKETING_VERSION=${version}, CURRENT_PROJECT_VERSION=${build})"
git tag "${tag}"
git push "${REMOTE}" "${tag}"

echo
echo "pushed ${tag} — CI is building it; the IPA will land at"
echo "  https://gh-proxy.org/https://github.com/rangdl/codeg-ios/releases/download/${tag}/Codeg-unsigned.ipa"
