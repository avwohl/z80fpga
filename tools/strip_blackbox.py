"""Copy a cell library with some `(* blackbox *)` modules removed.

The OSS CAD Suite's gowin/cells_sim.v declares the block RAM primitives as
empty blackboxes, so a netlist that uses them simulates as zz.  sim/gowin_sp.v
supplies real ones; this drops the empty declarations so the two can be
compiled together.

    python tools/strip_blackbox.py cells_sim.v cells_nobb.v SP SPX9
"""
import io
import re
import sys


def main(src, dst, names):
    s = io.open(src, encoding="utf-8", errors="replace").read()
    for name in names:
        pat = re.compile(r"\(\*[^)]*blackbox[^)]*\*\)\s*\nmodule " + re.escape(name)
                         + r" \(.*?\nendmodule\n", re.S)
        s, n = pat.subn("", s, count=1)
        if not n:
            sys.exit("%s: no blackbox module %s found" % (src, name))
        print("removed blackbox %s" % name)
    io.open(dst, "w", encoding="utf-8", newline="\n").write(s)
    print("wrote", dst)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
