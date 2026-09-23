"""Copy a cell library with some modules removed, so replacements can be
compiled alongside it.

The OSS CAD Suite's gowin/cells_sim.v declares the block RAM primitives as
empty `(* blackbox *)` cells, so a netlist that uses them simulates as zz;
sim/gowin_sp.v supplies real ones.  It also declares an ALU without the I2
port that nextpnr connects, so a post-place-and-route netlist will not
elaborate against it; sim/gowin_alu.v supplies that one.

A name prefixed with "-" is an ordinary module rather than a blackbox.

    python tools/strip_blackbox.py cells_sim.v cells_nobb.v SP SPX9 -ALU
"""
import io
import re
import sys


def main(src, dst, names):
    s = io.open(src, encoding="utf-8", errors="replace").read()
    for name in names:
        plain = name.startswith("-")
        name = name.lstrip("-")
        pre = "" if plain else r"\(\*[^)]*blackbox[^)]*\*\)\s*\n"
        pat = re.compile(pre + r"module " + re.escape(name)
                         + r" \(.*?\nendmodule\n", re.S)
        s, n = pat.subn("", s, count=1)
        if not n:
            sys.exit("%s: no module %s found" % (src, name))
        print("removed module %s" % name)
    io.open(dst, "w", encoding="utf-8", newline="\n").write(s)
    print("wrote", dst)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
