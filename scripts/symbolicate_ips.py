#!/usr/bin/env python3
"""Pull the app's own frames out of an Apple .ips hang/crash report.

The report's stackshot carries no image *names* (only uuids), so the app's frames
are found by matching the image whose uuid equals the main binary's `LC_UUID`.
Prints an `atos` invocation that symbolises exactly those frames.

Usage:
  python3 scripts/symbolicate_ips.py <report.ips> <path/to/Codeg> [thread]
"""
from __future__ import annotations

import json
import struct
import sys


def macho_uuid(path: str) -> str | None:
    """The main binary's LC_UUID (0x1b), upper-cased, dashes kept."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as error:
        print(f"!! cannot read the binary: {error}")
        return None
    if len(data) < 32:
        return None
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic not in (0xFEEDFACF, 0xFEEDFACE):
        return None
    is64 = magic == 0xFEEDFACF
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32 if is64 else 28
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x1B:  # LC_UUID
            raw = data[off + 8 : off + 24]
            h = raw.hex()
            return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}".upper()
        off += cmdsize
    return None


def load_report(path: str) -> tuple[dict, dict]:
    raw = open(path).read()
    split = raw.index("\n")
    return json.loads(raw[:split]), json.loads(raw[split:])


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    report_path, binary = sys.argv[1], sys.argv[2]
    want_thread = sys.argv[3] if len(sys.argv) > 3 else None

    head, body = load_report(report_path)
    print(f"# report   {report_path}")
    print(f"# bug_type {body.get('bug_type')}  os {head.get('os_version')}")
    termination = body.get("termination") or {}
    details = termination.get("details")
    if details:
        print("# termination " + " | ".join(str(d) for d in details[:2]))

    stackshot = body.get("stackshot")
    if not stackshot:
        print("no stackshot in this report (crash reports carry `usedImages` instead)")
        return 1

    pid = str(body.get("pid"))
    proc = (stackshot.get("processByPid") or {}).get(pid)
    if not proc:
        print(f"process {pid} not found in stackshot")
        return 1

    images = stackshot.get("binaryImages") or []
    binary_uuid = macho_uuid(binary)
    print(f"# binary   {binary}\n# LC_UUID  {binary_uuid}")

    app_index = None
    for idx, im in enumerate(images):
        if binary_uuid and im[0].upper() == binary_uuid:
            app_index = idx
            base = im[1]
            break
    if app_index is None:
        print("!! the report's images do not contain this binary's uuid "
              "(wrong build for this report?)")
        return 1
    print(f"# app image #{app_index} base 0x{base:x}")

    threads = proc.get("threadById") or {}
    for tid, t in threads.items():
        label = t.get("dispatch_queue_label") or t.get("name") or ""
        if want_thread and want_thread not in (str(tid), label):
            continue
        frames = t.get("userFrames") or []
        app_frames = [(i, f[1]) for i, f in enumerate(frames) if f[0] == app_index]
        if not app_frames:
            continue
        # A hang's interesting thread is the main one; without an explicit request,
        # skip the others so the log stays readable.
        if want_thread is None and label != "com.apple.main-thread":
            continue
        print(f"\n## thread {tid} ({label}) state={t.get('state')} "
              f"frames={len(frames)} userTime={t.get('userTime')}")
        addrs = [base + off for _, off in app_frames]
        for i, (pos, off) in enumerate(app_frames):
            print(f"   frame #{pos:<3d} image+0x{off:x}  ->  0x{addrs[i]:x}")
        print("\n   atos -arch arm64 -o " + binary + f" -l 0x{base:x} "
              + " ".join(f"0x{a:x}" for a in addrs))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
