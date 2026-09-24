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
if [ -n "$FORCED" ]; then
  RT="$FORCED"
else
  RT=$(xcrun simctl list runtimes -j | python3 -c "
import json,sys
d=json.load(sys.stdin)
rs=[r for r in d['runtimes'] if r.get('isAvailable') and 'iOS' in r['identifier']]
rs.sort(key=lambda r: [int(x) for x in r['version'].split('.')])
pick = '${REPRO_PICK:-oldest}'
if not rs:
    print(''); raise SystemExit
if pick == 'newest':
    print(rs[-1]['identifier'])
elif pick == 'device':
    # Device runs 16.1.2 — prefer any 16.1.x, else any 16.x, else oldest.
    v16 = [r for r in rs if r['version'].startswith('16.')]
    v161 = [r for r in v16 if r['version'].startswith('16.1')]
    pool = v161 or v16
    print(pool[-1]['identifier'] if pool else rs[0]['identifier'])
else:
    print(rs[0]['identifier'])
")
fi
echo "=== [$SFX] runtime=$RT"

DT=$(xcrun simctl list devicetypes -j | python3 -c "
import json,sys
d=json.load(sys.stdin)
for t in d['devicetypes']:
  if 'iPhone-14' in t['identifier']:
    print(t['identifier']); break
else:
  for t in d['devicetypes']:
    if 'iPhone' in t['identifier']:
      print(t['identifier']); break
")

UDID=$(xcrun simctl create "repro-$SFX" "$DT" "$RT" 2>&1)
echo "=== [$SFX] udid=$UDID device=$DT"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b

xcrun simctl install "$UDID" "$APP"

STUB_PORT="${REPRO_STUB_PORT:-3080}"

# Seed one profile through the simulator's cfprefsd. ServerStore stores
# JSONEncoder output as *Data*, so this must be `-data <hex>` — a string makes
# `defaults.data(forKey:)` miss and the app comes up on onboarding. Also seed
# the simulator Keychain fallback token for the SAME profile UUID, or every
# client(for:) is nil and the pages die with "No server selected."
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
HEX=$(printf '%s\n' "$SEED" | sed -n 1p)
PID_UUID=$(printf '%s\n' "$SEED" | sed -n 2p)
TOKEN=$(printf '%s\n' "$SEED" | sed -n 3p)
xcrun simctl spawn "$UDID" defaults write app.codeg.ios "codeg.servers.v1" -data "$HEX"
xcrun simctl spawn "$UDID" defaults write app.codeg.ios "codeg.token.fallback.$PID_UUID" "$TOKEN"
echo "=== [$SFX] seeded profile id=$PID_UUID + token fallback"

# Canned API server so the pages load real wire shapes (seed URL points at it).
STUB_LOG="stub-$SFX.log"
STUB_PID=""
STUB_URL="http://127.0.0.1:$STUB_PORT"
if python3 -c "import socket; s=socket.create_connection(('127.0.0.1',$STUB_PORT),0.3); s.close()" 2>/dev/null; then
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

# SIMCTL_CHILD_* is how simctl hands env vars to the launched app.
SIMCTL_CHILD_CODEG_REPRO_TAB=settings \
SIMCTL_CHILD_CODEG_REPRO_LEAF="${REPRO_LEAF:-chatchannels}" \
SIMCTL_CHILD_CODEG_REPRO_LEAF_DELAY="$LEAF_DELAY" \
SIMCTL_CHILD_CODEG_REPRO_DEEP=1 \
SIMCTL_CHILD_CODEG_REPRO_DEEP_DELAY="$DEEP_DELAY" \
SIMCTL_CHILD_CODEG_REPRO_SHEET=1 \
SIMCTL_CHILD_CODEG_REPRO_SHEET_OPEN="$SHEET_OPEN" \
SIMCTL_CHILD_CODEG_REPRO_SHEET_CLOSE="$SHEET_CLOSE" \
  xcrun simctl launch "$UDID" app.codeg.ios

# Mid capture inside the editor-sheet window (leaf at ~10s + open at ~2s).
sleep 16
xcrun simctl io "$UDID" screenshot "repro-mid-$SFX.png"
# Let the sheet close, deep push land, and the app settle.
sleep 29

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
python3 - "$SFX" "$RT" "$APP_ALIVE" "freeze-$SFX.txt" "mainsample-$SFX.txt" "$VERDICT" <<'PY'
import re, sys

sfx, rt, alive, freeze_path, mainsample_path, out_path = sys.argv[1:7]

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
kill "$STUB_PID" 2>/dev/null
wait "$STUB_PID" 2>/dev/null
exit 0
