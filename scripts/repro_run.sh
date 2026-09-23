#!/bin/bash
# TEMPORARY (CI repro harness, `repro-sim` branch only): boot one simulator,
# install the app, seed a server, drive Settings → Chat Channels → Message
# Settings through the CODEG_REPRO_* env hooks, then collect evidence:
#
#   repro-<sfx>.png       screenshot (which screen did we land on?)
#   sample-<sfx>.txt      `sample` of the app process (main-thread call graph)
#   mainsample-<sfx>.txt  the app's own rolling sampler (fps / heartbeat / depth)
#   freeze-<sfx>.txt      the app's frozen-episode archive — ANY "stalled"
#                         header in here means the hang reproduced (the
#                         container is fresh each run)
#   simlog-<sfx>.txt      simulator log for the process
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

# --- pick the runtime: forced, else oldest (or newest with REPRO_PICK=newest)
if [ -n "$FORCED" ]; then
  RT="$FORCED"
else
  RT=$(xcrun simctl list runtimes -j | python3 -c "
import json,sys
d=json.load(sys.stdin)
rs=[r for r in d['runtimes'] if r.get('isAvailable') and 'iOS' in r['identifier']]
rs.sort(key=lambda r: [int(x) for x in r['version'].split('.')])
pick = '${REPRO_PICK:-oldest}'
print((rs[-1] if pick=='newest' else rs[0])['identifier'] if rs else '')
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

# Seed one profile through the simulator's cfprefsd. ServerStore stores
# JSONEncoder output as *Data*, so this must be `-data <hex>` — a string makes
# `defaults.data(forKey:)` miss and the app comes up on onboarding.
HEX=$(python3 - <<'PY'
import json, uuid
profile = {
    "id": str(uuid.uuid4()).upper(),
    "name": "repro",
    "urlString": "http://127.0.0.1:3080",
    "createdAt": 788918400.0,
}
print(json.dumps([profile]).encode().hex())
PY
)
xcrun simctl spawn "$UDID" defaults write app.codeg.ios "codeg.servers.v1" -data "$HEX"

# SIMCTL_CHILD_* is how simctl hands env vars to the launched app. Three hooks:
# tab → Settings root, leaf → push Chat Channels, deep → push Message Settings
# (each one destination-style, exactly like the row taps they stand in for).
SIMCTL_CHILD_CODEG_REPRO_TAB=settings \
SIMCTL_CHILD_CODEG_REPRO_LEAF="${REPRO_LEAF:-chatchannels}" \
SIMCTL_CHILD_CODEG_REPRO_DEEP=1 \
  xcrun simctl launch "$UDID" app.codeg.ios
sleep 40

xcrun simctl io "$UDID" screenshot "repro-$SFX.png"

PID=$(pgrep -f 'Codeg.app/Codeg' | head -1)
echo "=== [$SFX] pid=$PID"
if [ -n "$PID" ]; then
  sample "$PID" 8 -file "sample-$SFX.txt"
fi

# The app's own sampler output — the freeze archive is the primary verdict:
# the container starts empty, so any episode header in it = hang reproduced.
DATA=$(xcrun simctl get_app_container "$UDID" app.codeg.ios data 2>/dev/null)
if [ -n "$DATA" ]; then
  cp -f "$DATA/Documents/mainsample.txt" "mainsample-$SFX.txt" 2>/dev/null
  cp -f "$DATA/Documents/mainsample-freeze.txt" "freeze-$SFX.txt" 2>/dev/null
fi
STALLS=$(grep -c 'main queue stalled' "freeze-$SFX.txt" 2>/dev/null)
STALLS=${STALLS:-0}
LASTFPS=$(grep -o 'fps=[0-9]*' "mainsample-$SFX.txt" 2>/dev/null | tail -1)
VERDICT="verdict-$SFX.txt"
{
  echo "runtime=$RT"
  echo "freeze-episodes=$STALLS"
  echo "last-window=${LASTFPS:-unknown}"
  if [ "$STALLS" -gt 0 ]; then
    echo "REPRODUCED[$SFX]=yes ($STALLS freeze episodes)"
  else
    echo "REPRODUCED[$SFX]=no (0 freeze episodes)"
  fi
} | tee "$VERDICT"
# Roll the last windows of the in-app sampler into the step log for a quick read.
tail -30 "mainsample-$SFX.txt" 2>/dev/null

xcrun simctl spawn "$UDID" log show --last 4m --style compact \
  --predicate 'process == "Codeg"' > "simlog-$SFX.txt" 2>/dev/null
tail -40 "simlog-$SFX.txt"

xcrun simctl shutdown "$UDID" 2>/dev/null
xcrun simctl delete "$UDID" 2>/dev/null
exit 0
