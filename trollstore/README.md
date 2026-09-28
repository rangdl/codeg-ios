# TrollStore source

An [AltStore-format](https://github.com/AltStore/SourceRepository) source that
serves Codeg's unsigned IPA to [TrollApps](https://github.com/TheResonanceTeam/TrollApps)
(or any AltStore-compatible client), so the app can be installed/updated without
hunting for the `.ipa` by hand.

## Where things live

| What | Where | Updated by |
|---|---|---|
| `source.json`, `source-cn.json`, `icon.png` | the **`trollstore` branch** (orphan — only these files) | CI, on every release |
| `trollstore/icon.png` (the source of that icon) | this branch | hand, rarely |
| `scripts/trollstore-source.sh` | `scripts/` | hand, rarely |

The JSON names the newest IPA, so it has to be rewritten whenever a release is
published. It lives on its own orphan branch instead of the build branch, so the
source history does not grow a commit per release and no branch you actually work
on gets touched. Nothing to commit by hand:
[`.github/workflows/build-unsigned-ipa.yml`](../.github/workflows/build-unsigned-ipa.yml)
refreshes that branch right after it publishes the Release.

## Source URLs

Direct GitHub (needs `github.com` to be reachable):

```
https://raw.githubusercontent.com/rangdl/codeg-ios/trollstore/source.json
```

jsDelivr CDN (usually reachable in mainland China, served as `application/json`):

```
https://cdn.jsdelivr.net/gh/rangdl/codeg-ios@trollstore/source.json
```

Accelerated mirror (mainland China, no VPN):

```
https://gh-proxy.com/https://raw.githubusercontent.com/rangdl/codeg-ios/trollstore/source-cn.json
```

## Adding it in TrollApps

1. Open **TrollApps → Sources → +**
2. Paste one of the URLs above (use the `source-cn.json` one in mainland China)
   and confirm
3. **Codeg** appears under the source — tap it, then **Get / Install**; TrollApps
   hands the IPA to TrollStore, which installs it permanently

TrollStore must have **Settings → URL Scheme Enabled** turned on, otherwise
TrollApps cannot launch the install.

## Refreshing by hand

CI does this automatically. To do it locally (e.g. to re-point the source at an
older build, or after changing the generator):

```bash
scripts/trollstore-source.sh                    # newest release
scripts/trollstore-source.sh v1.0.1-116         # a specific tag
OUT_DIR=/tmp/src scripts/trollstore-source.sh   # write elsewhere
VERSIONS=3 scripts/trollstore-source.sh         # list the last 3 builds
PROXY= scripts/trollstore-source.sh             # skip the accelerated variant
```

To publish the result yourself, rewrite the `trollstore` branch:

```bash
git fetch origin trollstore
git worktree add --detach /tmp/ts origin/trollstore
OUT_DIR=/tmp/ts scripts/trollstore-source.sh
git -C /tmp/ts commit -am "chore: point the source at vX.Y.Z-N"
git -C /tmp/ts push origin HEAD:trollstore
git worktree remove --force /tmp/ts
```

> The IPA is **unsigned** — it only installs on a device that already has
> TrollStore (iOS 16.0+, and only on iOS versions TrollStore supports).
