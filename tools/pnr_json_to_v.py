"""Turn a nextpnr post-place-and-route JSON netlist into Verilog.

This is the netlist `gowin_pack` turns into the bitstream, and it is not the
one yosys wrote: nextpnr's packer adds and re-types cells, so simulating the
post-synthesis netlist does not prove this one.  yosys cannot read it back
(`read_json` asserts on nextpnr's duplicate cell names), hence this.

Nets are bit ids; constants come through as the strings "0", "1", "x" and
"z".  Undefined constants become 0, which is what `setundef -undriven -zero`
would have done and what the hardware ties them to.

    python tools/pnr_json_to_v.py design_pnr.json design_pnr.v
"""
import io
import json
import re
import sys

CONST = {"0": "1'b0", "1": "1'b1", "x": "1'b0", "z": "1'b0"}

# nextpnr annotates cells with parameters that the simulation primitives do
# not declare: placement bookkeeping on the buffers, and packing hints on the
# ALU.  They carry no behaviour, and passing them makes iverilog stop.
SKIP_PARAMS = {"CIN_NETTYPE", "RAW_ALU_LUT", "NET_I", "NET_O"}


def bitref(b):
    if isinstance(b, int):
        return "w%d" % b
    return CONST.get(str(b), "1'b0")


def expr(bits):
    if len(bits) == 1:
        return bitref(bits[0])
    # JSON lists bits LSB first; Verilog concatenation is MSB first
    return "{" + ", ".join(bitref(b) for b in reversed(bits)) + "}"


# nextpnr writes a block RAM's wide ports as one scalar per bit -- AD0..AD13,
# DO0..DO35 and so on -- while the simulation model declares them as vectors.
# Nothing else needs this: a LUT's I0..I3 really are separate ports.
BUS_PORTS = {"SP": ("AD", "BLKSEL", "DI", "DO"),
             "SPX9": ("AD", "BLKSEL", "DI", "DO")}


def regroup(ctype, conns):
    fams = BUS_PORTS.get(ctype)
    if not fams:
        return conns
    out = {}
    parts = {}
    for k, v in conns.items():
        m = re.fullmatch(r"([A-Z]+)(\d+)", k)
        if m and m.group(1) in fams:
            parts.setdefault(m.group(1), {})[int(m.group(2))] = v
        else:
            out[k] = v
    for fam, bits in parts.items():
        # JSON order is LSB first, which is what expr() expects
        # a port nextpnr left unconnected comes through as an empty list
        out[fam] = [(bits[i][0] if bits[i] else "0") for i in sorted(bits)]
    return out


def paramval(v):
    if isinstance(v, bool):
        return "1'b1" if v else "1'b0"
    if isinstance(v, int):
        return "32'd%d" % v
    s = str(v)
    if s and re.fullmatch(r"[01]+", s):
        return "%d'b%s" % (len(s), s)
    if s and re.fullmatch(r"[01xz]+", s):
        return "%d'b%s" % (len(s), s.replace("x", "0").replace("z", "0"))
    return '"%s"' % s


def main(src, dst):
    d = json.load(io.open(src, encoding="utf-8"))
    mods = d["modules"]
    if len(mods) != 1:
        sys.exit("expected one module, got %d" % len(mods))
    mname, m = next(iter(mods.items()))

    ports = m.get("ports", {})
    cells = m.get("cells", {})

    # every numeric bit id that appears anywhere becomes a wire
    ids = set()

    def note(bits):
        for b in bits:
            if isinstance(b, int):
                ids.add(b)

    for p in ports.values():
        note(p["bits"])
    for c in cells.values():
        for bits in c.get("connections", {}).values():
            note(bits)

    out = [
        "// Generated from %s by tools/pnr_json_to_v.py -- do not edit." % src,
        "// This is the netlist that becomes the bitstream, not the one yosys wrote.",
        "",
    ]
    decl = []
    for pn, p in ports.items():
        w = len(p["bits"])
        rng = "" if w == 1 else "[%d:0] " % (w - 1)
        decl.append("%s %s%s" % (p["direction"], rng, pn))
    out.append("module %s (\n  %s\n);" % (mname, ",\n  ".join(decl)))

    for i in sorted(ids):
        out.append("  wire w%d;" % i)

    # tie each port to its bits
    for pn, p in ports.items():
        bits = p["bits"]
        if p["direction"] == "input":
            for k, b in enumerate(bits):
                if isinstance(b, int):
                    out.append("  assign w%d = %s;"
                               % (b, pn if len(bits) == 1 else "%s[%d]" % (pn, k)))
        else:
            lhs = pn if len(bits) == 1 else pn
            out.append("  assign %s = %s;" % (lhs, expr(bits)))

    n = 0
    for cn, c in cells.items():
        params = {k: v for k, v in c.get("parameters", {}).items()
                  if k not in SKIP_PARAMS}

        # nextpnr's carry-chain helpers carry a string ALU_MODE, or none at
        # all for a chain head.  cells_sim's ALU has no default in its
        # `case (ALU_MODE)`, so a string mode latches S and C and the netlist
        # simulates as X.  Give them their own modules; sim/gowin_alu.v has
        # them, with the meanings apicula's chipdb records.
        ctype = c["type"]
        if ctype == "ALU":
            mode = str(params.get("ALU_MODE", ""))
            if not re.fullmatch(r"[01]+", mode):
                ctype = "ALU_" + (mode if mode else "HEAD")
                params = {k: v for k, v in params.items() if k != "ALU_MODE"}

        pstr = ""
        if params:
            pstr = " #(\n    " + ",\n    ".join(
                ".%s(%s)" % (k, paramval(v)) for k, v in params.items()) + "\n  )"
        conns = regroup(ctype, c.get("connections", {}))
        cstr = ",\n    ".join(".%s(%s)" % (k, expr(v)) for k, v in conns.items() if v)
        out.append("  %s%s cell_%d (\n    %s\n  );" % (ctype, pstr, n, cstr))
        n += 1

    out.append("endmodule")
    io.open(dst, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
    print("module %s: %d cells, %d nets -> %s" % (mname, n, len(ids), dst))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
