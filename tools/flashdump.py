"""Read the Tang Nano 20K's answers back out of its configuration flash.

That board's USB-UART bridge is dead silicon, so `boards/tang_nano_20k/
flashreport_top.sv` reports through the SPI flash instead: the Z80 writes
F0h|n to the LED port, flash_wr page-programs that byte at
<region><n>000h, and this reads it out over JTAG.

Two traps are built into the format and both have bitten:

  * A page program only clears bits and nothing here erases, so a marker from
    an earlier run is still there and reads as this one's.  Use a fresh
    region per run, or at least check the pages you care about read FFh
    first -- `--check-erased` does that without loading anything.

  * Marker 15 is written as FFh, which is exactly what an erased page reads.
    It can never be told from nothing, so nothing should use it.

Only regions 70h..7Fh are usable: the flash wraps at 8 MB, so 80h and up
alias onto the bitstream, and the bitstream itself ends near 7.3 MB.
"""
import argparse
import os
import subprocess
import sys
import tempfile


def dump(region, size, loader, freq):
    """Read one region off the board, returning its bytes."""
    off = region * 0x10000
    fd, path = tempfile.mkstemp(suffix=".bin")
    os.close(fd)
    os.unlink(path)
    cmd = [loader, "-b", "tangnano20k", "--freq", str(freq),
           "--dump-flash", "--file-size", str(size), "-o", str(off), path]
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=1800)
    except FileNotFoundError:
        sys.exit("%s is not on PATH -- source tools/ossenv.sh first" % loader)
    except subprocess.CalledProcessError as e:
        sys.exit("%s failed (%d); is the board attached?" % (loader, e.returncode))
    except subprocess.TimeoutExpired:
        sys.exit("%s timed out" % loader)
    if not os.path.exists(path):
        sys.exit("the dump produced no file, so this run says nothing at all")
    with open(path, "rb") as f:
        d = f.read()
    os.unlink(path)
    if len(d) < size:
        sys.exit("short dump: %d of %d bytes, so this run says nothing" % (len(d), size))
    return d


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--region", default="0x7F",
                    help="64 KB region the markers were written to (70..7F)")
    ap.add_argument("--check-erased", action="store_true",
                    help="only report whether the region is clean, and load nothing")
    ap.add_argument("--loader", default="openFPGALoader")
    ap.add_argument("--freq", type=int, default=1000000)
    a = ap.parse_args()

    region = int(str(a.region), 0)
    if not 0x70 <= region <= 0x7F:
        sys.exit("region %02X is outside 70..7F; see this file's header" % region)

    d = dump(region, 0x10000, a.loader, a.freq)
    page = [d[n * 0x1000] for n in range(16)]

    if a.check_erased:
        dirty = [n for n in range(16) if page[n] != 0xFF]
        if dirty:
            print("region %02X is NOT clean: pages %s already written"
                  % (region, ", ".join(str(n) for n in dirty)))
            return 1
        print("region %02X is erased; a run into it will be unambiguous" % region)
        return 0

    hit = [n for n in range(16) if page[n] == (0xF0 | n)]
    stale = [(n, page[n]) for n in range(16)
             if page[n] != 0xFF and page[n] != (0xF0 | n)]

    print("region %02X" % region)
    print("  markers : %s" % (", ".join("F%X" % n for n in hit) or "none"))
    if 15 in hit:
        print("  note    : F is indistinguishable from an erased page; ignore it")
    if stale:
        print("  stale   : %s" % ", ".join("page %d holds %02X" % t for t in stale))
    if not hit:
        print("  nothing was written. That is a board that said nothing OR a")
        print("  channel that never worked -- they look identical here, which")
        print("  is why a run should emit a marker from ROM before anything else.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
