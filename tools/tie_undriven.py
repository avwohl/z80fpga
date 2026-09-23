"""Give a yosys Verilog netlist the constant-0 drivers it leaves out.

`write_verilog` aliases the constant nets onto ordinary signal names and emits
a driver only for the constant-1 one, as a VCC cell.  Whatever ended up
aliased to constant 0 is declared and never driven -- on the Tang Nano build
that is `u_soc.dma_ack`, which reaches 2396 places including every block
RAM's BLKSEL and RESET.  In hardware that is a tie to ground.  In simulation
it is x, no block ever selects, and the netlist sits dead with no other
symptom, which is the thing that makes a post-synthesis run look impossible.

Run `setundef -undriven -zero` in yosys first; this mops up what that leaves.

    python tools/tie_undriven.py netlist.v netlist_tied.v

Escaped identifiers need no special casing: a backslash is not whitespace, so
\\S+ swallows it along with the rest of the name.
"""
import io
import re
import sys

OUTP = ("DO", "O", "OF", "Q", "F", "V", "SUM", "COUT")


def main(src, dst):
    s = io.open(src, encoding="utf-8", errors="replace").read()

    decl = set(re.findall(r"\n  wire (?:\[\d+:\d+\] )?(\S+) ;", s))
    driven = set(re.findall(r"\n  assign (\S+) ", s))
    for m in re.finditer(r"\.(" + "|".join(OUTP) + r")\(([^\n]*)\)", s):
        for w in re.findall(r"[^\s,{}()\[\]]+", m.group(2)):
            driven.add(w)

    undriven = sorted(decl - driven)
    print("declared %d, driven %d, undriven %d" % (len(decl), len(driven), len(undriven)))
    for w in undriven[:8]:
        print("   tying low: %-42s (%d uses)" % (w, s.count(w)))

    add = "\n".join("  assign %s = 1'b0;" % w for w in undriven)
    io.open(dst, "w", encoding="utf-8", newline="\n").write(
        s.replace("endmodule", add + "\nendmodule", 1))
    print("wrote", dst)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
