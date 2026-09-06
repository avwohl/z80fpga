#!/usr/bin/env python3
"""Turn a binary ROM image into the $readmemh text sync_ram wants.

The RomWBW images are not in this repository -- they are large, they are not
ours, and they change independently.  Point this at one you built or downloaded
yourself, the way Z80_TESTS points the opcode suite at a SingleStepTests
checkout:

    python tools/mkromhex.py path/to/SBC_simh_std.rom sim/romwbw64k.hex --size 65536

--size both truncates and pads: a short file is padded with 0xFF, the erased
state of a real ROM, and a long one is cut.  64 KB is the first two 32 KB banks
of a 512 KB RomWBW image, which is HBIOS and the loader -- enough to reach the
boot prompt, and all that fits beside 512 KB of RAM in block RAM.
"""

import argparse
import sys


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
    args = ap.parse_args()

    with open(args.binary, "rb") as f:
        data = f.read()

    if args.offset:
        data = data[args.offset:]

    if args.size is not None:
        if len(data) > args.size:
            data = data[:args.size]
        else:
            data = data + b"\xff" * (args.size - len(data))

    with open(args.hexfile, "w", newline="\n") as f:
        for i in range(0, len(data), args.per_line):
            f.write(" ".join(f"{b:02x}" for b in data[i:i + args.per_line]) + "\n")

    print(f"{args.binary} -> {args.hexfile}: {len(data)} bytes", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
