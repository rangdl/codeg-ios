#!/usr/bin/env bash
#
# Tag a release build and push it — that is the only thing that starts CI now
# (see .github/workflows/build-unsigned-ipa.yml). The tag carries both numbers,
# `<version>-<build>`, and the Release is published under it.
#
# Every build bumps the *version*, not just the build number. TrollStore clients
# (TrollApps) decide whether an update is available by comparing the version in
# the source against the installed app's CFBundleShortVersionString, and they
# ignore CFBundleVersion entirely — so a build that only bumped the build number
# would never show up as an update. The bump is committed, so the tag, the
# project and the source all agree.
#
# Usage:
#   scripts/tag-build.sh              # bump patch (1.0.1 -> 1.0.2)
#   scripts/tag-build.sh minor        # bump minor (1.0.1 -> 1.1.0)
#   scripts/tag-build.sh major        # bump major (1.0.1 -> 2.0.0)
#   scripts/tag-build.sh 1.2.0        # explicit version
#   scripts/tag-build.sh 1.2.0 42     # explicit version and build number
#
# Options:
#   --yes, -y    don't ask for confirmation before committing/pushing
#   --dry-run    print every action; change, commit, or push nothing
#   -h, --help   show this help
#
# The build number defaults to one past the highest already used by *any* build
# tag — the current `v<version>-<n>` form or the older `ios16-build-<n>` — so it
# never repeats and never has to be looked up by hand.

set -euo pipefail

# A stale GIT_CONFIG_* trio in the environment breaks every git call.
unset GIT_CONFIG_COUNT GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_0 2>/dev/null || true

cd "$(dirname "$0")/.."

REMOTE="${REMOTE:-fork}"
PROJECT_YML="project.yml"

if [[ -t 1 ]]; then
  DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
else
  DIM=""; RED=""; GRN=""; YEL=""; RST=""
fi
info() { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%swarn:%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# BSD sed (macOS) needs an explicit empty backup suffix; GNU sed rejects it.
if sed --version >/dev/null 2>&1; then
  sed_inplace() { sed -E -i "$@"; }
else
  sed_inplace() { sed -E -i '' "$@"; }
fi

# ---- args --------------------------------------------------------------------
POSITIONAL=(); ASSUME_YES=0; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)  ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        usage; die "unknown option: $1" ;;
    *)         POSITIONAL+=("$1"); shift ;;
  esac
done
[[ ${#POSITIONAL[@]} -le 2 ]] || { usage; die "too many arguments"; }
BUMP="${POSITIONAL[0]:-}"
EXPLICIT_BUILD="${POSITIONAL[1]:-}"

run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    local q="" a
    for a in "$@"; do q+=" $(printf '%q' "$a")"; done
    printf '%s[dry-run]%s%s\n' "$DIM" "$RST" "$q"
  else
    "$@"
  fi
}

# ---- preconditions -----------------------------------------------------------
command -v git >/dev/null 2>&1 || die "git not found"
[[ -f "$PROJECT_YML" ]] || die "$PROJECT_YML not found — run this from the repo"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" != "HEAD" ]] || die "detached HEAD — check out a branch first"

# The version bump is committed, so anything else in flight would be swept into
# that commit.
if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is not clean — commit or stash first so the bump commit stays focused"
fi

# ---- current version ---------------------------------------------------------
read_yml() { grep -E "^[[:space:]]*$1:" "$PROJECT_YML" | head -1 | sed -E 's/.*"([^"]+)".*/\1/'; }
OLD_VERSION="$(read_yml MARKETING_VERSION)"
OLD_BUILD="$(read_yml CURRENT_PROJECT_VERSION)"
[[ "$OLD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "can't parse MARKETING_VERSION (got '$OLD_VERSION')"
[[ "$OLD_BUILD" =~ ^[0-9]+$ ]] || die "can't parse CURRENT_PROJECT_VERSION (got '$OLD_BUILD')"

# ---- compute the new version -------------------------------------------------
IFS=. read -r MA MI PA <<<"$OLD_VERSION"
case "$BUMP" in
  ""|patch) NEW_VERSION="$MA.$MI.$((PA + 1))" ;;
  minor)    NEW_VERSION="$MA.$((MI + 1)).0" ;;
  major)    NEW_VERSION="$((MA + 1)).0.0" ;;
  *)        NEW_VERSION="$BUMP" ;;
esac
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "computed version '$NEW_VERSION' is not X.Y.Z"

if [[ -n "$EXPLICIT_BUILD" ]]; then
  [[ "$EXPLICIT_BUILD" =~ ^[0-9]+$ ]] || die "build number must be an integer (got '$EXPLICIT_BUILD')"
  NEW_BUILD="$EXPLICIT_BUILD"
else
  # The release tags live on the remote, so a local-only tag list misses them and
  # the number would go backwards. Fetch first.
  git fetch --tags --quiet "$REMOTE" 2>/dev/null || true
  highest="$(git tag -l \
    | sed -n 's/^v[0-9][0-9.]*-\([0-9][0-9]*\)$/\1/p; s/^ios16-build-\([0-9][0-9]*\)$/\1/p' \
    | sort -n | tail -1)"
  NEW_BUILD=$(( ${highest:-0} + 1 ))
fi

TAG="v${NEW_VERSION}-${NEW_BUILD}"

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
  die "tag ${TAG} already exists locally"
fi
lsr_rc=0
git ls-remote --tags --exit-code "$REMOTE" "refs/tags/$TAG" >/dev/null 2>&1 || lsr_rc=$?
if [[ "$lsr_rc" -eq 0 ]]; then
  die "tag $TAG already exists on $REMOTE — pick a newer version"
elif [[ "$lsr_rc" -ne 2 ]]; then
  die "couldn't query $REMOTE for tag $TAG (git ls-remote exit $lsr_rc) — check network/remote access"
fi

# ---- confirm -----------------------------------------------------------------
echo
info "Release plan"
printf '  version : %s  ->  %s\n' "$OLD_VERSION" "$NEW_VERSION"
printf '  build   : %s  ->  %s\n' "$OLD_BUILD" "$NEW_BUILD"
printf '  tag     : %s\n' "$TAG"
printf '  branch  : %s\n' "$BRANCH"
printf '  remote  : %s\n' "$REMOTE"
echo
if [[ "$ASSUME_YES" != 1 && "$DRY_RUN" != 1 ]]; then
  read -r -p "Proceed with this release? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "aborted"
fi

# ---- bump project.yml --------------------------------------------------------
# CI takes the version from the tag, but project.yml is what a local build (and
# scripts/release.sh) reads, so the two must not drift apart.
set_yml() {  # key value — replaces the quoted value on the "key:" line
  sed_inplace "s/^([[:space:]]*$1:[[:space:]]*)\"[^\"]*\"/\1\"$2\"/" "$PROJECT_YML"
}
if [[ "$DRY_RUN" == 1 ]]; then
  printf '%s[dry-run]%s set MARKETING_VERSION="%s" and CURRENT_PROJECT_VERSION="%s" in %s\n' \
    "$DIM" "$RST" "$NEW_VERSION" "$NEW_BUILD" "$PROJECT_YML"
else
  set_yml MARKETING_VERSION "$NEW_VERSION"
  set_yml CURRENT_PROJECT_VERSION "$NEW_BUILD"
  [[ "$(read_yml MARKETING_VERSION)" == "$NEW_VERSION" ]] || die "failed to write MARKETING_VERSION into $PROJECT_YML"
  [[ "$(read_yml CURRENT_PROJECT_VERSION)" == "$NEW_BUILD" ]] || die "failed to write CURRENT_PROJECT_VERSION into $PROJECT_YML"
fi

# ---- commit, tag, push -------------------------------------------------------
run git add "$PROJECT_YML"
run git commit -m "release: ${TAG} (version ${NEW_VERSION}, build ${NEW_BUILD})"
run git tag "$TAG"
# Push branch and tag atomically: never leave $REMOTE/$BRANCH updated without the
# tag that CI builds from.
run git push --atomic "$REMOTE" "$BRANCH" "$TAG"

echo
info "Pushed $TAG — CI is building it; the IPA will land at"
printf '  https://gh-proxy.com/https://github.com/%s/releases/download/%s/Codeg-unsigned.ipa\n' \
  "$(git remote get-url "$REMOTE" | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#')" "$TAG"
echo
info "The TrollStore source is refreshed by CI once the Release is published."
