#!/bin/bash
# TEMPORARY (CI repro harness, `repro-sim` branch only): boot one simulator,
# install the app, seed a server (profile + token), serve canned API answers
# on 127.0.0.1:3080, drive Settings → Chat Channels → "+" editor → Message
# Settings through the CODEG_REPRO_* env hooks, then collect evidence:
#
#   repro-<sfx>.png       screenshot (which screen did we land on?)
#   repro-mid-<sfx>.png   mid-run screenshot (editor sheet window)
#   sample-<sfx>.txt      `sample` of the app process (main-thread call graph)
#   mainsample-<sfx>.txt  the app's own rolling sampler (fps / heartbeat / depth)
#   freeze-<sfx>.txt      the app's frozen-episode archive
#   stub-<sfx>.log        canned-server request log
#   simlog-<sfx>.txt      simulator log for the process
#   verdict-<sfx>.txt     content-based REPRODUCED (cold-start noise excluded)
#
# Usage: repro_run.sh <app-path> <suffix> [forced-runtime-identifier]
# Exit code is always 0 — a failed step is evidence, not a build failure.
set +e

APP="$1"
SFX="$2"
FORCED="$3"

if [ -z "$APP" ] || [ -z "$SFX" ]; then
  echo "usage: repro_run.sh <app-path> <suffix> [runtime-id]"
  exit 0
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# --- pick the runtime: forced, else REPRO_PICK (device≈16.1, oldest, newest)
# `device` is a HARD requirement: if no iOS 16.x runtime is present we refuse to
# run rather than silently fall back to a newer one (that is what made run 8's
# "ios16" leg actually run on 26.2).
#
# LOCK: the phone runs 16.1.2, and Apple never shipped a 16.1.2 *simulator* —
# 16.1.1/16.1.2 were device-only updates, so the closest runtime that exists is
# 16.1 (20B72). REPRO_RUNTIME_PREFIX (default `16.1`) pins the device leg to it;
# a prefix matching nothing degrades to any 16.x, and the runtime actually used
# is written into the verdict so a drifted lock cannot pass unnoticed.
if [ -n "$FORCED" ]; then
  RT="$FORCED"
else
  RT=$(xcrun simctl list runtimes -j | REPRO_RUNTIME_PREFIX="${REPRO_RUNTIME_PREFIX:-16.1}" python3 -c "
import json,os,sys
d=json.load(sys.stdin)
rs=[r for r in d['runtimes'] if r.get('isAvailable') and 'iOS' in r['identifier']]
rs.sort(key=lambda r: [int(x) for x in r['version'].split('.')])
pick = '${REPRO_PICK:-oldest}'
if not rs:
    print('')
    raise SystemExit
if pick == 'newest':
    print(rs[-1]['identifier'])
elif pick == 'device':
    # Device runs 16.1.2 — lock to the REPRO_RUNTIME_PREFIX (16.1), else any
    # 16.x. No 16.x ⇒ empty (the caller refuses to run).
    pref = os.environ.get('REPRO_RUNTIME_PREFIX', '16.1')
    v16 = [r for r in rs if r['version'].startswith('16.')]
    vpref = [r for r in v16 if r['version'].startswith(pref)]
    if v16 and not vpref:
        print(f'WARNING: no iOS {pref} runtime; falling back to {v16[-1][\"identifier\"]}', file=sys.stderr)
    pool = vpref or v16
    print(pool[-1]['identifier'] if pool else '')
else:
    print(rs[0]['identifier'])
")
fi
if [ -z "$RT" ]; then
  echo "=== [$SFX] ERROR: REPRO_PICK=${REPRO_PICK:-oldest} selected no runtime" >&2
  if [ "${REPRO_PICK:-oldest}" = "device" ]; then
    echo "    device picker requires an iOS 16.x runtime; none is available." >&2
  fi
  xcrun simctl list runtimes >&2 || true
  exit 2
fi
echo "=== [$SFX] runtime=$RT (REPRO_PICK=${REPRO_PICK:-oldest} prefix=${REPRO_RUNTIME_PREFIX:-16.1})"

# Device type: the reports come from an iPhone 13 Pro Max, so the leg is locked
# to that device type (REPRO_DEVICE_TYPE overrides). Exact identifier first,
# then the old iPhone-14 fallback, then any iPhone — and a fallback says so, in
# the log and in the verdict, so it cannot masquerade as the locked run.
DT=$(xcrun simctl list devicetypes -j | REPRO_DEVICE_TYPE="${REPRO_DEVICE_TYPE:-iPhone-13-Pro-Max}" python3 -c "
import json,os,sys
want = os.environ['REPRO_DEVICE_TYPE']
ids = [t['identifier'] for t in json.load(sys.stdin)['devicetypes']]
for pref in (want, 'iPhone-14', 'iPhone'):
  hit = [i for i in ids if i.endswith('.' + pref)] or [i for i in ids if pref in i]
  if hit:
    if pref != want:
      print(f'WARNING: device type {want} is not in this Xcode; fell back to {hit[0]}', file=sys.stderr)
    print(hit[0])
    break
else:
  print('')
")
if [ -z "$DT" ]; then
  echo "=== [$SFX] ERROR: no iPhone device type available" >&2
  xcrun simctl list devicetypes >&2 || true
  exit 2
fi
echo "=== [$SFX] device-type=$DT (requested ${REPRO_DEVICE_TYPE:-iPhone-13-Pro-Max})"

UDID=$(xcrun simctl create "repro-$SFX" "$DT" "$RT" 2>&1)
echo "=== [$SFX] udid=$UDID device=$DT"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b

xcrun simctl install "$UDID" "$APP"

STUB_PORT="${REPRO_STUB_PORT:-3080}"

# Backend: a real server when REPRO_SERVER_URL (and REPRO_TOKEN) are provided
# (CI secrets), else the canned stub on 127.0.0.1:3080. Never echo the token.
USE_REAL_BACKEND=""
if [ -n "${REPRO_SERVER_URL:-}" ]; then
  if [ -z "${REPRO_TOKEN:-}" ]; then
    echo "=== [$SFX] ERROR: REPRO_SERVER_URL is set but REPRO_TOKEN is empty" >&2
    exit 2
  fi
  USE_REAL_BACKEND=1
  # The seeded urlString must survive ServerProfile.baseURL (URLComponents):
  # http/https only, a real host, no userinfo. IPv6 literals need brackets
  # (http://[v6]:port) or host parses empty. Reject here, not in the app.
  SERVER_URL="$REPRO_SERVER_URL" python3 - <<'PY' || exit 2
import os, sys
from urllib.parse import urlsplit
u = os.environ["SERVER_URL"].strip()
p = urlsplit(u)
if p.scheme not in ("http", "https"):
    print(f"ERROR: REPRO_SERVER_URL scheme must be http(s), got {p.scheme!r}", file=sys.stderr)
    sys.exit(1)
try:
    host, port = p.hostname, p.port  # .port raises on an unbracketed IPv6 literal
except ValueError:
    host = None
if not host:
    print("ERROR: REPRO_SERVER_URL has no host (IPv6 literals need brackets: http://[v6]:port)",
          file=sys.stderr)
    sys.exit(1)
if p.username or p.password:
    print("ERROR: REPRO_SERVER_URL must not embed userinfo", file=sys.stderr)
    sys.exit(1)
print(f"OK host={host} port={port}")
PY
fi

# Seed one profile through the simulator's cfprefsd. ServerStore stores
# JSONEncoder output as *Data*, so this must be `-data <hex>` — a string makes
# `defaults.data(forKey:)` miss and the app comes up on onboarding. Also seed
# the simulator Keychain fallback token for the SAME profile UUID, or every
# client(for:) is nil and the pages die with "No server selected."
if [ -n "$USE_REAL_BACKEND" ]; then
  SEED=$(SERVER_URL="$REPRO_SERVER_URL" TOKEN="$REPRO_TOKEN" python3 - <<'PY'
import json, os, uuid
pid = str(uuid.uuid4()).upper()
profile = {
    "id": pid,
    "name": "repro",
    "urlString": os.environ["SERVER_URL"],
    "createdAt": 788918400.0,
}
print(json.dumps([profile]).encode().hex())
print(pid)
print(os.environ["TOKEN"])
PY
)
else
  SEED=$(STUB_PORT="$STUB_PORT" python3 - <<'PY'
import json, os, uuid
port = os.environ.get("STUB_PORT", "3080")
pid = str(uuid.uuid4()).upper()
profile = {
    "id": pid,
    "name": "repro",
    "urlString": f"http://127.0.0.1:{port}",
    "createdAt": 788918400.0,
}
print(json.dumps([profile]).encode().hex())
print(pid)
print("repro-token")
PY
)
fi
HEX=$(printf '%s\n' "$SEED" | sed -n 1p)
PID_UUID=$(printf '%s\n' "$SEED" | sed -n 2p)
TOKEN=$(printf '%s\n' "$SEED" | sed -n 3p)
xcrun simctl spawn "$UDID" defaults write app.codeg.ios "codeg.servers.v1" -data "$HEX"
xcrun simctl spawn "$UDID" defaults write app.codeg.ios "codeg.token.fallback.$PID_UUID" "$TOKEN"
echo "=== [$SFX] seeded profile id=$PID_UUID + token fallback"

# Canned API server so the pages load real wire shapes (seed URL points at it).
# Skipped when a real backend is configured.
STUB_LOG="stub-$SFX.log"
STUB_PID=""
STUB_URL="http://127.0.0.1:$STUB_PORT"
if [ -n "$USE_REAL_BACKEND" ]; then
  echo "=== [$SFX] using REAL backend $REPRO_SERVER_URL (stub skipped)" | tee "$STUB_LOG"
elif python3 -c "import socket; s=socket.create_connection(('127.0.0.1',$STUB_PORT),0.3); s.close()" 2>/dev/null; then
  echo "=== [$SFX] WARNING: port $STUB_PORT already in use — stub will not bind" | tee -a "$STUB_LOG"
else
  STUB_PORT="$STUB_PORT" python3 "$SCRIPT_DIR/repro_stub.py" >"$STUB_LOG" 2>&1 &
  STUB_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if python3 -c "import socket; s=socket.create_connection(('127.0.0.1',$STUB_PORT),0.3); s.close()" 2>/dev/null; then
      echo "=== [$SFX] stub up pid=$STUB_PID port=$STUB_PORT"
      break
    fi
    sleep 0.3
  done
fi
# Never fail the run on stub issues — that is also evidence.

# Order: seed BEFORE starting the stub only needs the port number, so seed first
# (already done above). Choreography (seconds): leaf defers past cold start;
# Chat Channels then opens the "+" editor (2s), closes it (7s), and only then
# deep-pushes Message Settings (9s). Mid screenshot lands in the sheet window;
# final after settle.
LEAF_DELAY="${REPRO_LEAF_DELAY:-10}"
DEEP_DELAY="${REPRO_DEEP_DELAY:-9}"
SHEET_OPEN="${REPRO_SHEET_OPEN:-2}"
SHEET_CLOSE="${REPRO_SHEET_CLOSE:-7}"
# Seconds after Message Settings appears before its controls are driven. The
# device freezes after 13-20 s of a healthy 60 fps on that screen, so the hold
# has to be long enough to cover that, and the controls have to be touched at all
# — the harness used to push the screen and only wait.
CONTROLS_DELAY="${REPRO_CONTROLS_DELAY:-12}"

# SIMCTL_CHILD_* is how simctl hands env vars to the launched app.
SIMCTL_CHILD_CODEG_REPRO_TAB=settings \
SIMCTL_CHILD_CODEG_REPRO_LEAF="${REPRO_LEAF:-chatchannels}" \
SIMCTL_CHILD_CODEG_REPRO_LEAF_DELAY="$LEAF_DELAY" \
SIMCTL_CHILD_CODEG_REPRO_DEEP=1 \
SIMCTL_CHILD_CODEG_REPRO_DEEP_DELAY="$DEEP_DELAY" \
SIMCTL_CHILD_CODEG_REPRO_SHEET=1 \
SIMCTL_CHILD_CODEG_REPRO_SHEET_OPEN="$SHEET_OPEN" \
SIMCTL_CHILD_CODEG_REPRO_SHEET_CLOSE="$SHEET_CLOSE" \
SIMCTL_CHILD_CODEG_REPRO_CONTROLS="$CONTROLS_DELAY" \
  xcrun simctl launch "$UDID" app.codeg.ios

# Mid capture inside the editor-sheet window (leaf at ~10s + open at ~2s).
sleep 16
xcrun simctl io "$UDID" screenshot "repro-mid-$SFX.png"
# Let the sheet close, the deep push land, the controls run, and the screen sit
# there well past the 13-20 s the device takes to wedge.
sleep 85

xcrun simctl io "$UDID" screenshot "repro-$SFX.png"

PID=$(pgrep -f 'Codeg.app/Codeg' | head -1)
echo "=== [$SFX] pid=$PID"
APP_ALIVE=no
if [ -n "$PID" ]; then
  APP_ALIVE=yes
  sample "$PID" 8 -file "sample-$SFX.txt"
fi

# The app's own sampler output.
DATA=$(xcrun simctl get_app_container "$UDID" app.codeg.ios data 2>/dev/null)
if [ -n "$DATA" ]; then
  cp -f "$DATA/Documents/mainsample.txt" "mainsample-$SFX.txt" 2>/dev/null
  cp -f "$DATA/Documents/mainsample-freeze.txt" "freeze-$SFX.txt" 2>/dev/null
fi

# Content-based verdict: cold-start noise (no settings-path app frames, short
# duration) never counts — only episodes with real Codeg $s frames on the
# settings path, or a long stall (>=10s, watchdog-scale). Also fold in liveness
# and final-window health so a wedged-but-alive app still reads as REPRODUCED.
VERDICT="verdict-$SFX.txt"
python3 - "$SFX" "$RT" "$APP_ALIVE" "freeze-$SFX.txt" "mainsample-$SFX.txt" "$VERDICT" "$DT" <<'PY'
import re, sys

sfx, rt, alive, freeze_path, mainsample_path, out_path, device = sys.argv[1:8]

# Settings-path markers from the device freeze archive (leafRows / EditorSection /
# ChatChannelEditorSheet / ChatChannelsSettingsView / Theme.accent / GroupedRow /
# confirmationDialog+presenting specializations). Bare `presenting` alone is too
# generic — require a Codeg settings symbol or a path-specific substring.
path_re = re.compile(
    r"leafRows|SettingsView|SettingsLeaf|ChatChannels|ChannelRow|ChatChannel"
    r"|EditorSection|ChatGlobal|GroupedRow|screenTitle|ThemeO6accent"
    r"|RootView|AppearanceSettings|ChannelTypeAvatar|ChannelStatus"
    r"|confirmationDialog.*presenting",
    re.I,
)
app_sym_re = re.compile(r"Codeg (\$s[0-9A-Za-z_]+)")

episodes = []
try:
    text = open(freeze_path, encoding="utf-8", errors="replace").read()
except OSError:
    text = ""

for m in re.finditer(
    r"^===== main queue stalled for (\d+) ms\s+\(([^)]+)\) =====",
    text,
    re.M,
):
    dur = int(m.group(1))
    ts = m.group(2)
    body_start = m.end()
    nxt = re.search(r"^===== main queue stalled for", text[body_start:], re.M)
    body = text[body_start : body_start + (nxt.start() if nxt else len(text) - body_start)]
    syms = app_sym_re.findall(body)
    non_onboard = [s for s in syms if "Onboarding" not in s]
    path = [s for s in non_onboard if path_re.search(s)]
    if path or dur >= 10_000:
        kind = "interesting"
    elif non_onboard:
        kind = "app-frame"  # real Codeg frames but off the settings path
    else:
        kind = "cold-start-noise"
    episodes.append((kind, dur, ts, path[:3]))

interesting = [e for e in episodes if e[0] == "interesting"]
app_frames = [e for e in episodes if e[0] == "app-frame"]
noise = [e for e in episodes if e[0] == "cold-start-noise"]

# Final sampler window (last [Ns ago] fps/hb/depth line).
fps = hb = depth = None
try:
    ms = open(mainsample_path, encoding="utf-8", errors="replace").read()
    windows = re.findall(
        r"\[(\d+)s ago\]\s+fps=(\d+)\s+hb-max=(\d+)ms\s+depth=(\d+)\s+state=(\w+)",
        ms,
    )
    if windows:
        # Prefer the freshest window with age <= 5s; else the last one.
        fresh = [w for w in windows if int(w[0]) <= 5] or windows
        fps, hb, depth = int(fresh[-1][1]), int(fresh[-1][2]), int(fresh[-1][3])
except OSError:
    pass

healthy = fps is not None and fps >= 30 and hb <= 500 and depth <= 40
# REPRODUCED: a content-interesting freeze, OR the app died, OR the final
# window is unhealthy (wedged / frozen display) even if no episode stuck.
reproduced = bool(interesting) or alive != "yes" or (fps is not None and not healthy)

lines = [
    f"runtime={rt}",
    f"device={device}",
    f"freeze-episodes={len(episodes)}",
    f"interesting-episodes={len(interesting)}",
    f"app-frame-episodes={len(app_frames)}",
    f"cold-start-noise-episodes={len(noise)}",
    f"app-alive={alive}",
    f"final-window=fps={fps} hb-max={hb} depth={depth}",
]
for kind, dur, ts, path in interesting[:5]:
    lines.append(f"  interesting: dur={dur}ms ts={ts} path={path}")
for kind, dur, ts, path in noise[:3]:
    lines.append(f"  noise: dur={dur}ms ts={ts}")
lines.append(
    f"REPRODUCED[{sfx}]=yes"
    if reproduced
    else (
        f"REPRODUCED[{sfx}]=no (0 interesting episodes, app alive"
        + (
            f", final window healthy fps={fps})"
            if healthy
            else ", no final-window sample)"
            if fps is None
            else f", final window fps={fps} hb={hb} depth={depth})"
        )
    )
)
if reproduced:
    reasons = []
    if interesting:
        reasons.append(f"{len(interesting)} interesting freeze episodes")
    if alive != "yes":
        reasons.append("app not alive")
    if fps is not None and not healthy:
        reasons.append(f"unhealthy final window (fps={fps} hb={hb} depth={depth})")
    lines[-1] = f"REPRODUCED[{sfx}]=yes ({'; '.join(reasons)})"

text = "\n".join(lines) + "\n"
open(out_path, "w", encoding="utf-8").write(text)
sys.stdout.write(text)
PY

# Roll the last windows of the in-app sampler into the step log for a quick read.
tail -30 "mainsample-$SFX.txt" 2>/dev/null
tail -20 "stub-$SFX.log" 2>/dev/null

xcrun simctl spawn "$UDID" log show --last 4m --style compact \
  --predicate 'process == "Codeg"' > "simlog-$SFX.txt" 2>/dev/null
tail -40 "simlog-$SFX.txt"

xcrun simctl shutdown "$UDID" 2>/dev/null
xcrun simctl delete "$UDID" 2>/dev/null
if [ -n "$STUB_PID" ]; then
  kill "$STUB_PID" 2>/dev/null
  wait "$STUB_PID" 2>/dev/null
fi
exit 0
