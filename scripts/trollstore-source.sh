#!/usr/bin/env bash
#
# scripts/trollstore-source.sh — regenerate the TrollStore / AltStore source
# under trollstore/ from a GitHub release of this repo.
#
# TrollApps (or any AltStore-compatible client) reads that JSON: it lists the
# app and points at the newest unsigned IPA that CI published
# (.github/workflows/build-unsigned-ipa.yml). CI runs this after every release so
# the source always points at the newest IPA — the JSON is a generated artifact
# and lives on its own branch (default: trollstore), never on the build branch.
#
# Usage:
#   scripts/trollstore-source.sh                 # newest release
#   scripts/trollstore-source.sh v1.0.1-116      # a specific tag
#
# Environment:
#   REPO      repo to read releases from              (default: rangdl/codeg-ios)
#   BRANCH    branch the JSON (and the icon) live on  (default: trollstore)
#   OUT_DIR   where to write the JSON + icon          (default: <repo>/trollstore)
#   PROXY     acceleration prefix used by the *-cn.json variant, for users who
#             cannot reach github.com directly        (default: https://gh-proxy.com/)
#             Set PROXY= to skip the accelerated variant entirely.
#   VERSIONS  how many recent releases to list        (default: 1)
#   APP_VERSION  the version string the IPA actually carries; wins over the
#             tag-derived guess for the newest entry. CI passes the value it read
#             out of the built IPA.
#   MIN_OS    minimum iOS version advertised in the source (default: read from
#             project.yml at the released tag, falling back to the working tree)
#
# After running, publish the output (CI does this on every release).

set -euo pipefail

# A forced-colour environment (CLICOLOR_FORCE=1) makes `gh api` wrap its JSON in
# ANSI escapes, which the JSON parser downstream cannot read.
unset CLICOLOR_FORCE CLICOLOR 2>/dev/null || true
export NO_COLOR=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/trollstore}"

REPO="${REPO:-rangdl/codeg-ios}"
BRANCH="${BRANCH:-trollstore}"
PROXY="${PROXY-https://gh-proxy.com/}"
VERSIONS="${VERSIONS:-1}"
TAG="${1:-}"

if [[ -t 1 ]]; then
  GRN=$'\033[32m'; RED=$'\033[31m'; RST=$'\033[0m'
else
  GRN=""; RED=""; RST=""
fi
info() { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
die()  { printf '%serror:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

command -v gh      >/dev/null 2>&1 || die "gh not found (brew install gh)"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
gh auth status >/dev/null 2>&1     || die "gh is not logged in (run: gh auth login)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -n "$TAG" ]]; then
  info "Reading release $TAG from $REPO"
  gh api "repos/$REPO/releases/tags/$TAG" >"$TMP/releases.json"
else
  info "Reading the newest release from $REPO"
  gh api "repos/$REPO/releases?per_page=$VERSIONS" >"$TMP/releases.json"
fi

# The tag the source will point at, needed before the JSON is built so the
# minimum OS version can be read from that exact revision.
REF_TAG="${TAG:-$(RELEASES_JSON="$TMP/releases.json" python3 -c '
import json, os, re
raw = re.sub(r"\x1b\[[0-9;]*m", "", open(os.environ["RELEASES_JSON"]).read())
d = json.loads(raw)
d = d if isinstance(d, list) else [d]
print(d[0]["tag_name"])
')}"

# Minimum iOS version comes from project.yml *at the released tag*, not from the
# working tree: the source is served from one branch while builds are tagged off
# another, so the two can disagree. MIN_OS overrides the lookup.
resolve_min_os() {
  local ref="$1" yml
  yml="$(gh api "repos/$REPO/contents/project.yml?ref=$ref" --jq '.content' 2>/dev/null \
        | base64 -d 2>/dev/null || true)"
  printf '%s\n' "$yml" | grep -A1 -m1 'deploymentTarget:' | grep -m1 'iOS:' \
    | sed -E 's/.*"([^"]+)".*/\1/'
}

if [[ -z "${MIN_OS:-}" ]]; then
  MIN_OS="$(resolve_min_os "$REF_TAG" || true)"
  [[ -n "$MIN_OS" ]] || info "Could not read project.yml at $REF_TAG — falling back to the working tree"
fi
if [[ -z "${MIN_OS:-}" ]]; then
  MIN_OS="$(grep -A1 -m1 'deploymentTarget:' "$ROOT/project.yml" \
            | grep -m1 'iOS:' | sed -E 's/.*"([^"]+)".*/\1/')"
fi
[[ -n "${MIN_OS:-}" ]] || die "could not determine the minimum iOS version (set MIN_OS)"

mkdir -p "$OUT_DIR"

# The source branch is self-contained: the icon ships next to the JSON, so the
# source keeps working even if the build branch is renamed or merged away.
if [[ -f "$ROOT/trollstore/icon.png" && "$OUT_DIR" != "$ROOT/trollstore" ]]; then
  cp "$ROOT/trollstore/icon.png" "$OUT_DIR/icon.png"
fi

RELEASES_JSON="$TMP/releases.json" OUT_DIR="$OUT_DIR" REPO="$REPO" BRANCH="$BRANCH" \
PROXY="$PROXY" VERSIONS="$VERSIONS" MIN_OS="$MIN_OS" \
APP_VERSION="${APP_VERSION:-}" python3 - <<'PY'
import json
import os
import re

releases_path = os.environ['RELEASES_JSON']
out_dir = os.environ['OUT_DIR']
repo = os.environ['REPO']
branch = os.environ['BRANCH']
proxy = os.environ['PROXY']
limit = int(os.environ['VERSIONS'])
min_os = os.environ['MIN_OS']
app_version = os.environ.get('APP_VERSION', '').strip()

# Strip ANSI colour codes: `gh api` emits them when the environment forces colour.
raw = re.sub(r'\x1b\[[0-9;]*m', '', open(releases_path).read())
data = json.loads(raw)
if isinstance(data, dict):          # /releases/tags/<tag> returns one object
    data = [data]

APP_DESCRIPTION = (
    "Codeg for iOS —— codeg 多智能体编码服务器的原生客户端（iPhone / iPad）。\n\n"
    "管理服务器、浏览会话、阅读完整对话记录（Markdown、推理过程、工具调用），"
    "并实时接收 Agent 的流式回复。\n\n"
    "本构建为未签名 IPA，由 GitHub Actions 从 tag 自动构建，需要 TrollStore 安装。"
)

SOURCE_DESCRIPTION = (
    "Codeg for iOS 的未签名构建，直接取自 GitHub Releases。\n\n"
    "每次推送 v<版本>-<构建号> tag 时 CI 会自动产出 Codeg-unsigned.ipa，"
    "本源指向最新一次构建。安装需要 TrollStore（iOS 16.0+）。"
)

PRIVACY = {
    "NSLocalNetworkUsageDescription":
        "Codeg connects to your codeg server, which may run on your local network.",
    "NSPhotoLibraryUsageDescription":
        "Codeg attaches photos you pick to your message to the agent.",
    "NSCameraUsageDescription":
        "Codeg uses the camera to take photos for your messages and to scan a server's QR code.",
}


def parse_tag(tag):
    """v1.0.1-116 -> ('1.0.1', '116')."""
    stripped = tag.lstrip('v')
    if '-' in stripped:
        version, build = stripped.split('-', 1)
    else:
        version, build = stripped, '0'
    return version, build


# The unsigned IPA advertises "<version>.<build>" as its
# CFBundleShortVersionString (see the build workflow), and that is the string a
# TrollStore client compares against the installed app — CFBundleVersion is
# ignored, so a build that only bumps the build number would otherwise never
# look like an update. APP_VERSION (read out of the built IPA by CI) wins over
# the tag-derived guess.
versions = []
for index, rel in enumerate(data[:limit]):
    asset = next((a for a in rel.get('assets', []) if a['name'].endswith('.ipa')), None)
    if asset is None:
        continue
    version, build = parse_tag(rel['tag_name'])
    if build != '0':
        version = f"{version}.{build}"
    if index == 0 and app_version:
        version = app_version
    notes = (rel.get('body') or '').strip().splitlines()
    versions.append({
        "version": version,
        "buildVersion": build,
        "date": (rel.get('published_at') or '')[:10],
        "downloadURL": asset['browser_download_url'],
        "size": asset['size'],
        "minOSVersion": min_os,
        "localizedDescription": notes[0] if notes else f"Build {build}",
    })

if not versions:
    raise SystemExit('no release with an .ipa asset found — tag a build first')

# The icon sits on the same branch as the JSON, so it is always reachable
# wherever the source is published.
icon_raw = f"https://raw.githubusercontent.com/{repo}/{branch}/icon.png"


def build_source(identifier, name, subtitle, prefix):
    def url(u):
        return f"{prefix}{u}" if prefix else u

    app_versions = []
    for v in versions:
        v = dict(v)
        v['downloadURL'] = url(v['downloadURL'])
        app_versions.append(v)

    icon_url = url(icon_raw)
    return {
        "name": name,
        "identifier": identifier,
        "subtitle": subtitle,
        "description": SOURCE_DESCRIPTION,
        "iconURL": icon_url,
        "website": f"https://github.com/{repo}",
        "tintColor": "#1E1E36",
        "featuredApps": ["app.codeg.ios"],
        "apps": [{
            "name": "Codeg",
            "bundleIdentifier": "app.codeg.ios",
            "developerName": "xintaofei / rangdl",
            "subtitle": "codeg 多智能体编码服务器的 iOS 客户端",
            "localizedDescription": APP_DESCRIPTION,
            "iconURL": icon_url,
            "tintColor": "#1E1E36",
            "category": "developer",
            "screenshots": [],
            "versions": app_versions,
            "appPermissions": {
                "entitlements": [],
                "privacy": PRIVACY,
            },
        }],
        "news": [],
    }


written = []

plain = build_source(
    "app.codeg.ios.source",
    "Codeg (GitHub)",
    "Codeg for iOS 未签名构建 · GitHub 直连",
    "",
)
path = os.path.join(out_dir, "source.json")
json.dump(plain, open(path, 'w'), ensure_ascii=False, indent=2)
written.append(path)

if proxy:
    accelerated = build_source(
        "app.codeg.ios.source.cn",
        "Codeg (国内加速)",
        "Codeg for iOS 未签名构建 · 走 GitHub 加速镜像",
        proxy,
    )
    path = os.path.join(out_dir, "source-cn.json")
    json.dump(accelerated, open(path, 'w'), ensure_ascii=False, indent=2)
    written.append(path)

for path in written:
    print(f"  wrote {path}")
print(f"  versions: {', '.join(v['version'] + '-' + v['buildVersion'] for v in versions)}")
PY

info "Done. Publish the output so these URLs resolve:"
printf '  https://raw.githubusercontent.com/%s/%s/source.json\n' "$REPO" "$BRANCH"
printf '  https://cdn.jsdelivr.net/gh/%s@%s/source.json\n' "$REPO" "$BRANCH"
if [[ -n "$PROXY" ]]; then
  printf '  %shttps://raw.githubusercontent.com/%s/%s/source-cn.json  (国内)\n' \
    "$PROXY" "$REPO" "$BRANCH"
fi
