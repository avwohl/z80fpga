#!/usr/bin/env python3
"""Turn a binary ROM image into the $readmemh text sync_ram wants.

The RomWBW images are not in this repository -- they are large, they are not
ours, and they change independently.  Point this at one you built or downloaded
yourself, the way Z80_TESTS points the opcode suite at a SingleStepTests
checkout, or let tools/romwbw_fetch.py fetch one:

    python tools/mkromhex.py path/to/SBC_simh_std.rom sim/romwbw64k.hex --size 65536

--size both truncates and pads: a short file is padded with 0xFF, the erased
state of a real ROM, and a long one is cut.  64 KB is the first two 32 KB banks
of a 512 KB RomWBW image, which is HBIOS and the loader -- enough to reach the
boot prompt, and all that fits beside 512 KB of RAM in block RAM.

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
    keys = ("source_sha256", "offset", "size", "per_line")
    try:
        with open(args.hexfile + ".provenance.json", encoding="utf-8") as f:
            was = json.load(f)
    except (OSError, ValueError):
        was = None
    if (isinstance(was, dict) and os.path.exists(args.hexfile)
            and all(was.get(k) == record[k] for k in keys)):
        print(f"{args.hexfile} is already that image, untouched", file=sys.stderr)
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

    with open(args.hexfile, "w", newline="\n") as f:
        for i in range(0, len(data), args.per_line):
            f.write(" ".join(f"{b:02x}" for b in data[i:i + args.per_line]) + "\n")

    record["bytes"] = len(data)
    with open(args.hexfile + ".provenance.json", "w", newline="\n") as f:
        json.dump(record, f, indent=2, sort_keys=True)
        f.write("\n")

    print(f"{args.binary} -> {args.hexfile}: {source_bytes} bytes in, "
          f"{len(data)} out, sha256 {source_sha}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
