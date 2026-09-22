#!/usr/bin/env python3
"""Turn a binary ROM image into the $readmemh text sync_ram wants.

The RomWBW images are not in this repository -- they are large, they are not
ours, and they change independently.  Point this at one you built or downloaded
yourself, the way Z80_TESTS points the opcode suite at a SingleStepTests
checkout, or let tools/romwbw_fetch.py fetch one:

    python tools/mkromhex.py path/to/SBC_simh_std.rom sim/romwbw512k.hex --size 524288

--size both truncates and pads: a short file is padded with 0xFF, the erased
state of a real ROM, and a long one is cut.  512 KB is a whole RomWBW image,
all sixteen 32 KB banks, which is what the simulation and the Nexys bitstream
both carry.

Both of those change the image, so both say so.  A <hexfile>.provenance.json
goes down beside the hex naming the image it came from and what that image
hashed to, because nothing else here records which ROM a bitstream carries.
That note is also what makes a second run cheap: when the hex already came
from exactly this image and these options, it is left alone, so a Makefile may
ask every time without a timestamp deciding which ROM got simulated.
"""

import argparse
import hashlib
import json
import os
import sys


def source_note(path, data):
    """What tools/romwbw_fetch.py recorded about `path`, if it fits `data`.

    A sidecar is only worth carrying forward if it actually describes the
    bytes just read; otherwise it is left over from some earlier image and
    would put a release number on a ROM that is not that release.
    """
    try:
        with open(path + ".provenance.json", encoding="utf-8") as f:
            note = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(note, dict):
        return None
    if note.get("size") != len(data):
        return None
    if note.get("sha256") != hashlib.sha256(data).hexdigest():
        return None
    return note


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("binary", help="input ROM image")
    ap.add_argument("hexfile", help="output $readmemh file")
    ap.add_argument("--size", type=int, default=None,
                    help="pad with 0xFF or truncate to this many bytes")
    ap.add_argument("--offset", type=int, default=0,
                    help="start this many bytes into the image")
    ap.add_argument("--per-line", type=int, default=16,
                    help="bytes per output line (default 16)")
    ap.add_argument("--expect-sha256", default=None,
                    help="fail unless the input hashes to this")
    args = ap.parse_args()

    if args.per_line < 1:
        ap.error("--per-line has to be at least 1")
    if args.offset < 0:
        ap.error("--offset cannot be negative")
    if args.size is not None and args.size < 0:
        ap.error("--size cannot be negative")

    with open(args.binary, "rb") as f:
        data = f.read()

    source_bytes = len(data)
    source_sha = hashlib.sha256(data).hexdigest()
    if args.expect_sha256 and source_sha != args.expect_sha256:
        print(f"{args.binary}: hashed {source_sha}, expected {args.expect_sha256}",
              file=sys.stderr)
        return 1

    record = {"source": args.binary,
              "source_bytes": source_bytes,
              "source_sha256": source_sha,
              "offset": args.offset,
              "size": args.size,
              "per_line": args.per_line}
    note = source_note(args.binary, data)
    if note is not None:
        record["source_provenance"] = note

    # Same image, same options, hex already there: leave it, mtime and all.
    # What the hex was made from is a hash, never a timestamp.
    # The note has to describe the output as well as the input, or a truncated
    # or hand-edited hex is reused while its sidecar swears it is something
    # else -- and that sidecar is what build_romwbw.tcl echoes into a build log.
    keys = ("source_sha256", "offset", "size", "per_line")
    try:
        with open(args.hexfile + ".provenance.json", encoding="utf-8") as f:
            was = json.load(f)
    except (OSError, ValueError):
        was = None
    if isinstance(was, dict) and all(was.get(k) == record[k] for k in keys):
        try:
            with open(args.hexfile, "rb") as f:
                on_disk = f.read()
        except OSError:
            on_disk = None
        if (on_disk is not None and was.get("hex_bytes") == len(on_disk)
                and was.get("hex_sha256") == hashlib.sha256(on_disk).hexdigest()):
            print(f"{args.hexfile} is already that image, untouched",
                  file=sys.stderr)
            return 0

    if args.offset:
        data = data[args.offset:]

    if args.size is not None:
        if len(data) > args.size:
            print(f"{args.binary}: truncated {len(data)} bytes to {args.size}",
                  file=sys.stderr)
            data = data[:args.size]
        elif len(data) < args.size:
            print(f"{args.binary}: padded {len(data)} bytes to {args.size} "
                  f"with 0xFF", file=sys.stderr)
            data = data + b"\xff" * (args.size - len(data))

    # Through a .partial, the way tools/romwbw_fetch.py writes the ROM: an
    # interrupted run must not leave half a hex under the real name.
    text = "".join(" ".join(f"{b:02x}" for b in data[i:i + args.per_line]) + "\n"
                   for i in range(0, len(data), args.per_line))
    part = args.hexfile + ".partial"
    with open(part, "w", newline="\n") as f:
        f.write(text)
    os.replace(part, args.hexfile)

    blob = text.encode("ascii")
    record["bytes"] = len(data)
    record["hex_bytes"] = len(blob)
    record["hex_sha256"] = hashlib.sha256(blob).hexdigest()
    with open(args.hexfile + ".provenance.json", "w", newline="\n") as f:
        json.dump(record, f, indent=2, sort_keys=True)
        f.write("\n")

    print(f"{args.binary} -> {args.hexfile}: {source_bytes} bytes in, "
          f"{len(data)} out, sha256 {source_sha}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
