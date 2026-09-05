#!/usr/bin/env python3
"""Build the Z80 microcode ROM and dispatch tables, and emit them for the RTL.

Run from the repository root:  python tools/gen_z80.py

Writes rtl/core/z80_defs.svh   - field encodings and sizes
       rtl/core/z80_ucode.mem  - the micro-program ROM
       rtl/core/z80_dispatch.mem - opcode -> micro-program entry point

Every T-state count below is the documented Z80 figure; the harness in
sim/ checks them against the SingleStepTests bus traces.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import z80_enc as E

# --------------------------------------------------------------------------
# micro-op constructor
# --------------------------------------------------------------------------
def U(bus="NONE", tx=0, asrc="PC", ainc="NONE", ds="NONE", dd="NONE",
      pd="NONE", wsrc="NONE", alu="NOP", fw=0, eop="NONE", ctl="NONE",
      nx="NEXT"):
    return dict(bus=E.BUS[bus], tx=tx, asrc=E.ASRC[asrc], ainc=E.AINC[ainc],
                ds=E.DAT[ds], dd=E.DAT[dd], pd=E.DAT[pd], wsrc=E.DAT[wsrc],
                alu=E.ALU[alu], fw=int(fw), eop=E.EOP[eop], ctl=E.CTL[ctl],
                nx=E.NX[nx])

def has_action(u):
    return (u["alu"] != E.ALU["NOP"] or u["dd"] != E.DAT["NONE"]
            or u["eop"] != E.EOP["NONE"] or u["ctl"] != E.CTL["NONE"]
            or u["fw"] != 0)

def pack(u):
    word, pos = 0, 0
    for name, width in E.FIELDS:
        v = u[name]
        assert 0 <= v < (1 << width), "%s=%d does not fit in %d bits" % (name, v, width)
        word |= v << pos
        pos += width
    return word

# --------------------------------------------------------------------------
# opcode tables
# --------------------------------------------------------------------------
ALU_Y = ["ADD", "ADC", "SUB", "SBC", "AND", "XOR", "OR", "CP"]
ROT_Y = ["RLC", "RRC", "RL", "RR", "SLA", "SRA", "SLL", "SRL"]
ACC_Y = ["RLCA", "RRCA", "RLA", "RRA", "DAA", "CPL", "SCF", "CCF"]

def alu_dst(name):
    """CP and BIT keep the flags but throw the result away."""
    return "NONE" if name in ("CP", "BIT") else "A"

def rd(dest="NONE", **kw):
    """Read the byte at PC into `dest` and bump PC."""
    return U(bus="MR", asrc="PC", ainc="POSTINC", pd=dest, **kw)

# --------------------------------------------------------------------------
# unprefixed opcodes
# --------------------------------------------------------------------------
def base_prog(op, mem="HL"):
    """Micro-program for unprefixed opcode `op`.

    `mem` names the address source standing in for (HL); the DD/FD variants
    pass "WZ" after computing IX+d into it.
    """
    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    p, q = y >> 1, y & 1

    if x == 0:
        if z == 0:
            if y == 0:                                          # NOP        4
                return [U(nx="END")]
            if y == 1:                                          # EX AF,AF'  4
                return [U(ctl="EX_AF", nx="END")]
            if y == 2:                                          # DJNZ d  13/8
                return [U(bus="INT", eop="DEC_B"),
                        rd(nx="NZ_B"),
                        U(bus="INT", tx=4, eop="JR", nx="END")]
            if y == 3:                                          # JR d       12
                return [rd(), U(bus="INT", tx=4, eop="JR", nx="END")]
            return [rd(nx="CCJ"),                               # JR cc,d 12/7
                    U(bus="INT", tx=4, eop="JR", nx="END")]
        if z == 1:
            if q == 0:                                          # LD rp,nn  10
                return [rd("RPL"), rd("RPH", nx="END")]
            return [U(bus="INT", tx=6, eop="ADD_HL",            # ADD HL,rp 11
                      fw=1, nx="END")]
        if z == 2:
            if q == 0:
                if p in (0, 1):                                 # LD (BC|DE),A 7
                    return [U(bus="MW", asrc="BC" if p == 0 else "DE",
                              wsrc="A", eop="WZ_WRA", nx="END")]
                if p == 2:                                      # LD (nn),HL 16
                    return [rd("Z"), rd("W"),
                            U(bus="MW", asrc="WZ", ainc="POSTINC", wsrc="L"),
                            U(bus="MW", asrc="WZ", wsrc="H", nx="END")]
                return [rd("Z"), rd("W"),                       # LD (nn),A  13
                        U(bus="MW", asrc="WZ", wsrc="A",
                          eop="WZ_WRA", nx="END")]
            if p in (0, 1):                                     # LD A,(BC|DE) 7
                return [U(bus="MR", asrc="BC" if p == 0 else "DE",
                          pd="A", eop="WZ_A1", nx="END")]
            if p == 2:                                          # LD HL,(nn) 16
                return [rd("Z"), rd("W"),
                        U(bus="MR", asrc="WZ", ainc="POSTINC", pd="L"),
                        U(bus="MR", asrc="WZ", pd="H", nx="END")]
            return [rd("Z"), rd("W"),                           # LD A,(nn)  13
                    U(bus="MR", asrc="WZ", pd="A", eop="WZ_A1", nx="END")]
        if z == 3:                                              # INC/DEC rp  6
            return [U(bus="INT", tx=1, eop="DEC_RP" if q else "INC_RP",
                      nx="END")]
        if z in (4, 5):                                         # INC/DEC r 4/11
            aop = "INC" if z == 4 else "DEC"
            if y == 6:
                return [U(bus="MR", asrc=mem, tx=1),
                        U(bus="MW", asrc=mem, ds="DIN", dd="TMP", alu=aop,
                          fw=1, wsrc="TMP", nx="END")]
            return [U(ds="RHI", dd="RHI", alu=aop, fw=1, nx="END")]
        if z == 6:                                              # LD r,n   7/10
            if y == 6:
                return [rd(), U(bus="MW", asrc=mem, wsrc="DIN", nx="END")]
            return [rd("RHI", nx="END")]
        return [U(ds="A", dd="A", alu=ACC_Y[y], fw=1, nx="END")]  # z == 7   4

    if x == 1:                                                  # LD r,r'  4/7
        if y == 6 and z == 6:
            return [U(ctl="HALT", nx="END")]
        if z == 6:
            return [U(bus="MR", asrc=mem, pd="RHIR", nx="END")]
        if y == 6:
            return [U(bus="MW", asrc=mem, wsrc="RLOR", nx="END")]
        return [U(ds="RLO", dd="RHI", nx="END")]

    if x == 2:                                                  # ALU A,r  4/7
        aop = ALU_Y[y]
        if z == 6:
            return [U(bus="MR", asrc=mem),
                    U(ds="DIN", dd=alu_dst(aop), alu=aop, fw=1, nx="END")]
        return [U(ds="RLO", dd=alu_dst(aop), alu=aop, fw=1, nx="END")]

    # x == 3
    if z == 0:                                                  # RET cc  11/5
        return [U(bus="INT", nx="CC"),
                U(bus="MR", asrc="SP", ainc="POSTINC", pd="Z"),
                U(bus="MR", asrc="SP", ainc="POSTINC", pd="W"),
                U(eop="PC_WZ", nx="END")]
    if z == 1:
        if q == 0:                                              # POP rp2   10
            return [U(bus="MR", asrc="SP", ainc="POSTINC", pd="RQL"),
                    U(bus="MR", asrc="SP", ainc="POSTINC", pd="RQH",
                      nx="END")]
        if p == 0:                                              # RET       10
            return [U(bus="MR", asrc="SP", ainc="POSTINC", pd="Z"),
                    U(bus="MR", asrc="SP", ainc="POSTINC", pd="W"),
                    U(eop="PC_WZ", nx="END")]
        if p == 1:                                              # EXX        4
            return [U(ctl="EXX", nx="END")]
        if p == 2:                                              # JP (HL)    4
            return [U(eop="PC_HL", nx="END")]
        return [U(bus="INT", tx=1, eop="SP_HL", nx="END")]      # LD SP,HL   6
    if z == 2:                                                  # JP cc,nn  10
        return [rd("Z"), rd("W", nx="CC"), U(eop="PC_WZ", nx="END")]
    if z == 3:
        if y == 0:                                              # JP nn     10
            return [rd("Z"), rd("W"), U(eop="PC_WZ", nx="END")]
        if y == 2:                                              # OUT (n),A 11
            return [rd("Z"),
                    U(bus="IOW", asrc="AZ", wsrc="A", eop="WZ_WRA",
                      nx="END")]
        if y == 3:                                              # IN A,(n)  11
            return [rd("Z"),
                    U(bus="IOR", asrc="AZ", pd="A", eop="WZ_A1", nx="END")]
        if y == 4:                                              # EX (SP),HL 19
            return [U(bus="MR", asrc="SP", pd="Z"),
                    U(bus="MR", asrc="SPP1", tx=1, pd="W"),
                    U(bus="MW", asrc="SPP1", wsrc="H"),
                    U(bus="MW", asrc="SP", tx=2, wsrc="L"),
                    U(eop="HL_WZ", nx="END")]
        if y == 5:                                              # EX DE,HL   4
            return [U(ctl="EX_DE_HL", nx="END")]
        return [U(ctl="DI" if y == 6 else "EI", nx="END")]      # DI / EI    4
    if z == 4:                                                  # CALL cc 17/10
        return [rd("Z"), rd("W", nx="CC"),
                U(bus="INT"),
                U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="PCH"),
                U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="PCL"),
                U(eop="PC_WZ", nx="END")]
    if z == 5:
        if q == 0:                                              # PUSH rp2  11
            return [U(bus="INT"),
                    U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="RQH"),
                    U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="RQL",
                      nx="END")]
        return [rd("Z"), rd("W"),                               # CALL nn   17
                U(bus="INT"),
                U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="PCH"),
                U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="PCL"),
                U(eop="PC_WZ", nx="END")]
    if z == 6:                                                  # ALU A,n    7
        aop = ALU_Y[y]
        return [rd(), U(ds="DIN", dd=alu_dst(aop), alu=aop, fw=1, nx="END")]
    return [U(bus="INT"),                                       # RST y*8   11
            U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="PCH"),
            U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="PCL"),
            U(eop="PC_RST", nx="END")]

# --------------------------------------------------------------------------
# DD / FD prefixed: only the (HL)-as-memory forms change shape
# --------------------------------------------------------------------------
def uses_hl_memory(op):
    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    if x == 0 and z in (4, 5, 6) and y == 6:
        return True
    if x == 1 and (y == 6) != (z == 6):
        return True
    if x == 2 and z == 6:
        return True
    return False

def ddfd_prog(op):
    if not uses_hl_memory(op):
        return base_prog(op)
    x, z = op >> 6, op & 7
    if x == 0 and z == 6:                                       # LD (IX+d),n 19
        return [rd(),
                U(bus="MR", asrc="PC", ainc="POSTINC", tx=2, eop="DISP"),
                U(bus="MW", asrc="WZ", wsrc="DIN", nx="END")]
    return [rd(), U(bus="INT", tx=4, eop="DISP")] + base_prog(op, mem="WZ")

# --------------------------------------------------------------------------
# CB prefix
# --------------------------------------------------------------------------
def cb_prog(op):
    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    aop = ROT_Y[y] if x == 0 else ("BIT", "RES", "SET")[x - 1]
    flags = 0 if aop in ("RES", "SET") else 1
    if z != 6:                                                  # 8
        return [U(ds="RLO", dd="NONE" if aop == "BIT" else "RLO",
                  alu=aop, fw=flags, nx="END")]
    if x == 1:                                                  # BIT b,(HL) 12
        return [U(bus="MR", asrc="HL", tx=1),
                U(ds="DIN", alu="BITM", fw=1, nx="END")]
    return [U(bus="MR", asrc="HL", tx=1),                       # 15
            U(bus="MW", asrc="HL", ds="DIN", dd="TMP", alu=aop, fw=flags,
              wsrc="TMP", nx="END")]

def ddcb_prog(op):
    """DD CB d op - the fetch unit has already put IX+d in WZ."""
    x, y = op >> 6, (op >> 3) & 7
    aop = ROT_Y[y] if x == 0 else ("BIT", "RES", "SET")[x - 1]
    flags = 0 if aop in ("RES", "SET") else 1
    if x == 1:                                                  # 20
        return [U(bus="MR", asrc="WZ", tx=1),
                U(ds="DIN", alu="BITM", fw=1, nx="END")]
    # The result also lands in r[z]; RLOT sends the z == 6 case to TMP, so the
    # same register supplies the byte written back to memory either way.
    return [U(bus="MR", asrc="WZ", tx=1),                       # 23
            U(bus="MW", asrc="WZ", ds="DIN", dd="RLOT", alu=aop, fw=flags,
              wsrc="RLOT", nx="END")]

# --------------------------------------------------------------------------
# ED prefix
# --------------------------------------------------------------------------
def ed_prog(op):
    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    q = y & 1
    NOP = [U(nx="END")]
    if x == 1:
        if z == 0:                                              # IN r,(C)  12
            return [U(bus="IOR", asrc="BCR"),
                    U(ds="DIN", dd="RHIR" if y != 6 else "NONE", alu="INF",
                      fw=1, eop="WZ_BC_INC", nx="END")]
        if z == 1:                                              # OUT (C),r 12
            return [U(bus="IOW", asrc="BCR",
                      wsrc="RHIR" if y != 6 else "ZERO",
                      eop="WZ_BC_INC", nx="END")]
        if z == 2:                                              # SBC/ADC HL 15
            return [U(bus="INT", tx=6, eop="ADC_HL" if q else "SBC_HL",
                      fw=1, nx="END")]
        if z == 3:
            if q == 0:                                          # LD (nn),rp 20
                return [rd("Z"), rd("W"),
                        U(bus="MW", asrc="WZ", ainc="POSTINC", wsrc="RPL"),
                        U(bus="MW", asrc="WZ", wsrc="RPH", nx="END")]
            return [rd("Z"), rd("W"),                           # LD rp,(nn) 20
                    U(bus="MR", asrc="WZ", ainc="POSTINC", pd="RPL"),
                    U(bus="MR", asrc="WZ", pd="RPH", nx="END")]
        if z == 4:                                              # NEG        8
            return [U(ds="A", dd="A", alu="NEG", fw=1, nx="END")]
        if z == 5:                                              # RETN/RETI 14
            return [U(bus="MR", asrc="SP", ainc="POSTINC", pd="Z"),
                    U(bus="MR", asrc="SP", ainc="POSTINC", pd="W"),
                    U(eop="PC_WZ", ctl="RETN", nx="END")]
        if z == 6:                                              # IM n       8
            return [U(ctl="SET_IM", nx="END")]
        if y == 0:                                              # LD I,A     9
            return [U(bus="INT", ds="A", dd="I", nx="END")]
        if y == 1:                                              # LD R,A     9
            return [U(bus="INT", ds="A", dd="R", nx="END")]
        if y in (2, 3):                                         # LD A,I/R   9
            return [U(bus="INT", ds="I" if y == 2 else "R", dd="A",
                      alu="LDAIR", fw=1, ctl="SET_P", nx="END")]
        if y in (4, 5):                                         # RRD / RLD 18
            m, a = ("RRDM", "RRDA") if y == 4 else ("RLDM", "RLDA")
            return [U(bus="MR", asrc="HL"),
                    U(bus="INT", tx=3, ds="DIN", dd="TMP", alu=m),
                    U(bus="MW", asrc="HL", ds="DIN", dd="A", alu=a, fw=1,
                      wsrc="TMP", eop="WZ_HL1", nx="END")]
        return NOP                                              # y == 6, 7
    if x == 2 and z <= 3 and y >= 4:                            # block ops
        rep = y >= 6
        dec = (y & 1) == 1
        tail = ([U(bus="INT", tx=4), U(eop="REPEAT", nx="END")]
                if rep else [])
        last = "BLK" if rep else "END"                          # 21 / 16
        if z == 0:                                              # LDI/LDD/...
            return [U(bus="MR", asrc="HLR"),
                    U(bus="MW", asrc="DER", tx=2, wsrc="DIN"),
                    U(eop="LDD" if dec else "LDI", fw=1, nx=last)] + tail
        if z == 1:                                              # CPI/CPD/...
            return [U(bus="MR", asrc="HLR"),
                    U(bus="INT", tx=4, eop="CPD" if dec else "CPI", fw=1,
                      nx=last)] + tail
        if z == 2:                                              # INI/IND/...
            return [U(bus="INT"),
                    U(bus="IOR", asrc="BCR"),
                    U(bus="MW", asrc="HLR", wsrc="DIN"),
                    U(eop="IND" if dec else "INI", fw=1, nx=last)] + tail
        return [U(bus="INT"),                                   # OUTI/OUTD/...
                U(bus="MR", asrc="HLR"),
                U(bus="IOW", asrc="BCR", wsrc="DIN", eop="DEC_B"),
                U(eop="OUTD" if dec else "OUTI", fw=1, nx=last)] + tail
    return NOP

# --------------------------------------------------------------------------
# interrupt and NMI entry sequences
# --------------------------------------------------------------------------
# The fetch unit runs the acknowledge cycle and preloads WZ (0066 for NMI,
# 0038 for IM 1, {I, vector} for IM 2) before jumping to one of these.
def trap_prog(kind):
    if kind == 0:                                          # NMI          11
        return [U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="PCH"),
                U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="PCL"),
                U(eop="PC_WZ", nx="END")]
    if kind == 1:                                          # INT, IM 1    13
        return [U(bus="INT"),
                U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="PCH"),
                U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="PCL"),
                U(eop="PC_WZ", nx="END")]
    return [U(bus="INT"),                                  # INT, IM 2    19
            U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="PCH"),
            U(bus="MW", asrc="SP", ainc="PREDEC", wsrc="PCL"),
            U(bus="MR", asrc="WZ", ainc="POSTINC", pd="PCL"),
            U(bus="MR", asrc="WZ", pd="PCH", nx="END")]

# --------------------------------------------------------------------------
# assemble the ROM
# --------------------------------------------------------------------------
TABLE_NAMES = ["BASE", "DDFD", "CB", "DDCB", "ED"]
TRAP_NAMES  = ["NMI", "IM1", "IM2"]

def build():
    rom, index = [], {}

    def add(name, op, prog):
        where = "%s %02x" % (name, op)
        for a, b in zip(prog, prog[1:]):
            if a["bus"] == E.BUS["NONE"]:
                assert not has_action(b), (
                    "%s: a zero-length micro-op is followed by one that also "
                    "has an action; one clock edge can apply only one" % where)
        assert prog[-1]["nx"] == E.NX["END"], "%s: must end with END" % where
        key = tuple(pack(u) for u in prog)
        if key not in index:
            index[key] = len(rom)
            rom.extend(key)
        return index[key]

    gen = dict(BASE=base_prog, DDFD=ddfd_prog, CB=cb_prog,
               DDCB=ddcb_prog, ED=ed_prog)
    tables = {n: [add(n, op, gen[n](op)) for op in range(256)]
              for n in TABLE_NAMES}
    traps = [add("TRAP", k, trap_prog(k)) for k in range(3)]
    return rom, tables, traps

# --------------------------------------------------------------------------
# emission
# --------------------------------------------------------------------------
BANNER = ("// Generated by tools/gen_z80.py -- do not edit.\n"
          "// Regenerate with:  python tools/gen_z80.py\n\n")

def emit_defs(path, rom, traps):
    upcw = max(1, (len(rom) - 1).bit_length())
    # No include guard: these are module-scoped localparams, and every module
    # that runs micro-code needs its own copy.
    out = [BANNER,
           "localparam int UW     = %d;   // micro-op width\n" % E.UWIDTH,
           "localparam int UROM_N = %d;  // micro-op count\n" % len(rom),
           "localparam int UPCW   = %d;   // micro-PC width\n\n" % upcw]
    pos = 0
    out.append("// micro-op field slices: read one as uw[UFL_x +: UFW_x]\n")
    for name, width in E.FIELDS:
        out.append("localparam int UFL_%-4s = %2d, UFW_%-4s = %d;\n"
                   % (name.upper(), pos, name.upper(), width))
        pos += width
    out.append("\n")
    out.append("\n// interrupt entry points\n")
    for name, addr in zip(TRAP_NAMES, traps):
        out.append("localparam int UENT_%s = %d;\n" % (name, addr))
    out.append("\n")
    for group, table in E.ENUMS.items():
        width = max(1, max(table.values()).bit_length())
        out.append("// %s\n" % group)
        for name, val in sorted(table.items(), key=lambda kv: kv[1]):
            out.append("localparam logic [%d:0] %s_%s = %d;\n"
                       % (width - 1, group, name, val))
        out.append("\n")
    open(path, "w").write("".join(out))

def emit_rom(path, rom):
    hexw = (E.UWIDTH + 3) // 4
    open(path, "w").write("".join("%0*x\n" % (hexw, w) for w in rom))

def emit_dispatch(path, tables):
    out = []
    for name in TABLE_NAMES:
        out += ["%03x\n" % tables[name][op] for op in range(256)]
    open(path, "w").write("".join(out))

if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    rom, tables, traps = build()
    core = os.path.join(root, "rtl", "core")
    emit_defs(os.path.join(core, "z80_defs.svh"), rom, traps)
    emit_rom(os.path.join(core, "z80_ucode.mem"), rom)
    emit_dispatch(os.path.join(core, "z80_dispatch.mem"), tables)
    print("microcode ROM: %d words x %d bits = %d bytes"
          % (len(rom), E.UWIDTH, (len(rom) * E.UWIDTH + 7) // 8))
    print("  traps NMI/IM1/IM2 at %s" % traps)
    for name in TABLE_NAMES:
        print("  %-5s %3d distinct entry points" % (name, len(set(tables[name]))))
