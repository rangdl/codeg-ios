# TrollStore source

An [AltStore-format](https://github.com/AltStore/SourceRepository) source that
serves Codeg's unsigned IPA to [TrollApps](https://github.com/TheResonanceTeam/TrollApps)
(or any AltStore-compatible client), so the app can be installed/updated without
hunting for the `.ipa` by hand.

| File | Purpose |
|---|---|
| `source.json` | Links straight to GitHub (`github.com` / `raw.githubusercontent.com`) |
| `source-cn.json` | Same source, every URL rewritten through a GitHub acceleration mirror — for networks where `github.com` is unreachable |
| `icon.png` | 512×512 app icon, re-rendered from `CodegiOS/Resources/AppIcon.icon` |

Both files point at the newest `Codeg-unsigned.ipa` published by
[`.github/workflows/build-unsigned-ipa.yml`](../.github/workflows/build-unsigned-ipa.yml)
when a `v<version>-<build>` tag is pushed.

## Source URLs

Direct GitHub (needs `github.com` to be reachable):

```
https://raw.githubusercontent.com/rangdl/codeg-ios/main/trollstore/source.json
```

jsDelivr CDN (usually reachable in mainland China):

```
https://cdn.jsdelivr.net/gh/rangdl/codeg-ios@main/trollstore/source.json
```

Accelerated mirror (mainland China, no VPN):

```
https://gh-proxy.com/https://raw.githubusercontent.com/rangdl/codeg-ios/main/trollstore/source-cn.json
```

## Adding it in TrollApps

1. Open **TrollApps → Sources → +**
2. Paste one of the URLs above (the `source-cn.json` one if you are in mainland
   China) and confirm
3. **Codeg** appears under the source — tap it, then **Get / Install**; TrollApps
   hands the IPA to TrollStore, which installs it permanently

TrollStore must have **Settings → URL Scheme Enabled** turned on, otherwise
TrollApps cannot launch the install.

## Refreshing after a release

The source is generated, not hand-written. After tagging a build:

```bash
scripts/tag-build.sh              # push the tag → CI builds the IPA
scripts/trollstore-source.sh      # rewrite trollstore/*.json from that release
git add trollstore && git commit -m "chore: point the TrollStore source at vX.Y.Z-N"
git push fork main
```

Options: `scripts/trollstore-source.sh v1.0.1-116` for a specific tag,
`VERSIONS=3` to list the last three builds as older versions, `PROXY=` to skip
the accelerated variant, `BRANCH=...` if the source does not live on `main`.

> The IPA itself is **unsigned** — it only installs on a device that already has
> TrollStore (iOS 16.0+, and only on versions TrollStore supports).
