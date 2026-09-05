#!/usr/bin/env python3
"""A small two-pass Z80 assembler.

  python tools/zasm.py boot.z80 -o boot.hex          # one hex byte per line
  python tools/zasm.py boot.z80 -o boot.bin --bin
  python tools/zasm.py boot.z80 -l                   # listing on stdout

It covers the documented instruction set, the DD/FD index forms, and the
usual directives (ORG, EQU, DB/DEFB, DW/DEFW, DS/DEFS, END).  Numbers may be
written 1234, 0x1F, 1Fh, $1F, %1010 or 'c'.  `$` on its own is the current
address.  Expressions take + - * / ( ) and & | ^ << >>.
"""
import argparse, re, sys

R8   = {"b": 0, "c": 1, "d": 2, "e": 3, "h": 4, "l": 5, "(hl)": 6, "a": 7}
RP   = {"bc": 0, "de": 1, "hl": 2, "sp": 3}
RP2  = {"bc": 0, "de": 1, "hl": 2, "af": 3}
CC   = {"nz": 0, "z": 1, "nc": 2, "c": 3, "po": 4, "pe": 5, "p": 6, "m": 7}
ALU  = {"add": 0, "adc": 1, "sub": 2, "sbc": 3,
        "and": 4, "xor": 5, "or": 6, "cp": 7}
ROT  = {"rlc": 0, "rrc": 1, "rl": 2, "rr": 3,
        "sla": 4, "sra": 5, "sll": 6, "srl": 7}
BITOP = {"bit": 1, "res": 2, "set": 3}
ACC  = {"rlca": 0x07, "rrca": 0x0F, "rla": 0x17, "rra": 0x1F,
        "daa": 0x27, "cpl": 0x2F, "scf": 0x37, "ccf": 0x3F}
SIMPLE = {"nop": [0x00], "halt": [0x76], "di": [0xF3], "ei": [0xFB],
          "exx": [0xD9], "ret": [0xC9],
          "neg": [0xED, 0x44], "retn": [0xED, 0x45], "reti": [0xED, 0x4D],
          "rrd": [0xED, 0x67], "rld": [0xED, 0x6F],
          "ldi": [0xED, 0xA0], "cpi": [0xED, 0xA1],
          "ini": [0xED, 0xA2], "outi": [0xED, 0xA3],
          "ldd": [0xED, 0xA8], "cpd": [0xED, 0xA9],
          "ind": [0xED, 0xAA], "outd": [0xED, 0xAB],
          "ldir": [0xED, 0xB0], "cpir": [0xED, 0xB1],
          "inir": [0xED, 0xB2], "otir": [0xED, 0xB3],
          "lddr": [0xED, 0xB8], "cpdr": [0xED, 0xB9],
          "indr": [0xED, 0xBA], "otdr": [0xED, 0xBB]}
IDX = {"ix": 0xDD, "iy": 0xFD}


class AsmError(Exception):
    pass


# --------------------------------------------------------------------------
# expressions
# --------------------------------------------------------------------------
def parse_num(tok):
    t = tok.strip()
    if re.fullmatch(r"'(\\.|[^'])'", t):
        c = t[1:-1]
        return ord({"\\n": "\n", "\\r": "\r", "\\t": "\t",
                    "\\0": "\0", "\\\\": "\\", "\\'": "'"}.get(c, c[-1]))
    if t.lower().startswith("0x"):
        return int(t[2:], 16)
    if t.startswith("$") and len(t) > 1:
        return int(t[1:], 16)
    if t.startswith("%"):
        return int(t[1:], 2)
    if re.fullmatch(r"[0-9][0-9a-fA-F]*[hH]", t):
        return int(t[:-1], 16)
    if re.fullmatch(r"[01]+[bB]", t):
        return int(t[:-1], 2)
    if re.fullmatch(r"-?\d+", t):
        return int(t)
    return None


def evaluate(expr, syms, pc, strict):
    expr = expr.strip()
    if not expr:
        raise AsmError("empty expression")
    out, i = [], 0
    while i < len(expr):
        ch = expr[i]
        if ch == "'":
            j = expr.index("'", i + 1)
            while j + 1 < len(expr) and expr[j] == "\\":
                j = expr.index("'", j + 1)
            out.append(str(parse_num(expr[i:j + 1])))
            i = j + 1
            continue
        m = re.match(r"[A-Za-z_.][A-Za-z0-9_.]*|\$[0-9A-Fa-f]*|[0-9][0-9A-Fa-fhHxXbB]*",
                     expr[i:])
        if m:
            tok = m.group(0)
            i += len(tok)
            if tok == "$":
                out.append(str(pc))
                continue
            n = parse_num(tok)
            if n is None:
                key = tok.lower()
                if key in syms:
                    out.append(str(syms[key]))
                elif strict:
                    raise AsmError("undefined symbol %s" % tok)
                else:
                    out.append("0")
            else:
                out.append(str(n))
            continue
        out.append(ch)
        i += 1
    src = "".join(out)
    if not re.fullmatch(r"[-+*/()&|^<>% \d]*", src):
        raise AsmError("bad expression %r" % expr)
    try:
        return int(eval(src, {"__builtins__": {}}, {}))    # noqa: S307
    except Exception as e:
        raise AsmError("bad expression %r (%s)" % (expr, e))


# --------------------------------------------------------------------------
# operand helpers
# --------------------------------------------------------------------------
def idx_operand(op):
    """(ix+d) / (iy-d) / (ix) -> (prefix, displacement expression)."""
    m = re.fullmatch(r"\(\s*(ix|iy)\s*([+-][^)]*)?\)", op, re.I)
    if not m:
        return None
    return IDX[m.group(1).lower()], (m.group(2) or "0")


def idx_half(op):
    """ixh / ixl / iyh / iyl -> (prefix, r8 code)."""
    m = re.fullmatch(r"(ix|iy)([hl])", op, re.I)
    if not m:
        return None
    return IDX[m.group(1).lower()], 4 if m.group(2).lower() == "h" else 5


class Asm:
    def __init__(self):
        self.syms = {}
        self.pc = 0

    # ------------------------------------------------------------------
    def r8(self, op, allow_idx=True):
        """Resolve an 8-bit operand to (prefix, code, disp) or None."""
        k = op.lower()
        if k in R8:
            return (None, R8[k], None)
        if allow_idx:
            h = idx_half(op)
            if h:
                return (h[0], h[1], None)
            ix = idx_operand(op)
            if ix:
                return (ix[0], 6, ix[1])
        return None

    def imm8(self, expr, strict):
        v = evaluate(expr, self.syms, self.pc, strict)
        return v & 0xFF

    def imm16(self, expr, strict):
        v = evaluate(expr, self.syms, self.pc, strict)
        return [v & 0xFF, (v >> 8) & 0xFF]

    def disp(self, expr, strict):
        v = evaluate(expr, self.syms, self.pc, strict)
        return v & 0xFF

    # ------------------------------------------------------------------
    def encode(self, mnem, ops, strict):
        m = mnem.lower()
        if m in SIMPLE and not ops:
            return list(SIMPLE[m])
        if m in ACC and not ops:
            return [ACC[m]]

        fn = getattr(self, "op_" + m, None)
        if fn is None:
            raise AsmError("unknown mnemonic %r" % mnem)
        return fn(ops, strict)

    # ---------------------------------------------------------- load / exchange
    def op_ld(self, ops, strict):
        if len(ops) != 2:
            raise AsmError("ld needs two operands")
        dst, src = ops
        d, s = dst.lower(), src.lower()

        for pair, code in (("i", 0x47), ("r", 0x4F)):
            if d == pair and s == "a":
                return [0xED, code]
        if d == "a" and s == "i":
            return [0xED, 0x57]
        if d == "a" and s == "r":
            return [0xED, 0x5F]

        if d == "sp" and s in ("hl",):
            return [0xF9]
        if d == "sp" and s in ("ix", "iy"):
            return [IDX[s], 0xF9]

        # 16-bit register targets
        if d in RP or d in IDX:
            pfx = [IDX[d]] if d in IDX else []
            code = 2 if d in IDX else RP[d]
            mm = re.fullmatch(r"\((.*)\)", src)
            if mm and self.r8(src) is None:
                if d == "hl":
                    return [0x2A] + self.imm16(mm.group(1), strict)
                if d in IDX:
                    return pfx + [0x2A] + self.imm16(mm.group(1), strict)
                return [0xED, 0x4B | (RP[d] << 4)] + self.imm16(mm.group(1), strict)
            return pfx + [0x01 | (code << 4)] + self.imm16(src, strict)

        # (bc) and (de) are register-indirect, not addresses
        if d in ("(bc)", "(de)") and s == "a":
            return [0x02 if d == "(bc)" else 0x12]
        if d == "a" and s in ("(bc)", "(de)"):
            return [0x0A if s == "(bc)" else 0x1A]

        # (nn) <- register
        mm = re.fullmatch(r"\((.*)\)", dst)
        if mm and self.r8(dst) is None:
            addr = mm.group(1)
            if s == "a":
                return [0x32] + self.imm16(addr, strict)
            if s == "hl":
                return [0x22] + self.imm16(addr, strict)
            if s in IDX:
                return [IDX[s], 0x22] + self.imm16(addr, strict)
            if s in RP:
                return [0xED, 0x43 | (RP[s] << 4)] + self.imm16(addr, strict)
            raise AsmError("cannot store %s" % src)

        if d == "a" and re.fullmatch(r"\((.*)\)", src) and self.r8(src) is None:
            return [0x3A] + self.imm16(src[1:-1], strict)

        # 8-bit register moves and immediates
        rd = self.r8(dst)
        if rd is None:
            raise AsmError("bad ld destination %r" % dst)
        pfx_d, cd, dd = rd
        rs = self.r8(src)
        if rs is None:                                  # ld r,n
            pfx = [pfx_d] if pfx_d else []
            tail = [] if dd is None else [self.disp(dd, strict)]
            return pfx + [0x06 | (cd << 3)] + tail + [self.imm8(src, strict)]
        pfx_s, cs, ds = rs
        if pfx_d and pfx_s and pfx_d != pfx_s:
            raise AsmError("cannot mix IX and IY")
        if cd == 6 and cs == 6:
            raise AsmError("ld (hl),(hl) is halt")
        pfx = pfx_d or pfx_s
        # the displacement, if either side is an index form; both cannot be
        tail = []
        if dd is not None:
            tail = [self.disp(dd, strict)]
        elif ds is not None:
            tail = [self.disp(ds, strict)]
        return ([pfx] if pfx else []) + [0x40 | (cd << 3) | cs] + tail

    def op_ex(self, ops, strict):
        a, b = (o.lower() for o in ops)
        if (a, b) == ("de", "hl"):
            return [0xEB]
        if (a, b) == ("af", "af'"):
            return [0x08]
        if a == "(sp)":
            if b == "hl":
                return [0xE3]
            if b in IDX:
                return [IDX[b], 0xE3]
        raise AsmError("bad ex operands")

    # --------------------------------------------------------------- stack
    def op_push(self, ops, strict):
        return self._stack(ops, 0xC5)

    def op_pop(self, ops, strict):
        return self._stack(ops, 0xC1)

    def _stack(self, ops, base):
        r = ops[0].lower()
        if r in IDX:
            return [IDX[r], base | (2 << 4)]
        if r in RP2:
            return [base | (RP2[r] << 4)]
        raise AsmError("bad stack operand %r" % ops[0])

    # ----------------------------------------------------------- arithmetic
    def _alu(self, name, ops, strict):
        code = ALU[name]
        src = ops[-1]
        if len(ops) == 2 and ops[0].lower() != "a":
            raise AsmError("%s destination must be a" % name)
        r = self.r8(src)
        if r is None:
            return [0xC6 | (code << 3), self.imm8(src, strict)]
        pfx, c, d = r
        tail = [self.disp(d, strict)] if d is not None else []
        return ([pfx] if pfx else []) + [0x80 | (code << 3) | c] + tail

    def op_add(self, ops, strict):
        d = ops[0].lower()
        if d in ("hl", "ix", "iy") and len(ops) == 2:
            s = ops[1].lower()
            pfx = [IDX[d]] if d in IDX else []
            if s == d and d in IDX:
                s = "hl"
            if s not in RP:
                raise AsmError("bad add %s,%s" % (ops[0], ops[1]))
            return pfx + [0x09 | (RP[s] << 4)]
        return self._alu("add", ops, strict)

    def op_adc(self, ops, strict):
        return self._hl16("adc", ops, strict, 0x4A)

    def op_sbc(self, ops, strict):
        return self._hl16("sbc", ops, strict, 0x42)

    def _hl16(self, name, ops, strict, base):
        if len(ops) == 2 and ops[0].lower() == "hl" and ops[1].lower() in RP:
            return [0xED, base | (RP[ops[1].lower()] << 4)]
        return self._alu(name, ops, strict)

    def op_sub(self, ops, strict):
        return self._alu("sub", ops, strict)

    def op_and(self, ops, strict):
        return self._alu("and", ops, strict)

    def op_xor(self, ops, strict):
        return self._alu("xor", ops, strict)

    def op_or(self, ops, strict):
        return self._alu("or", ops, strict)

    def op_cp(self, ops, strict):
        return self._alu("cp", ops, strict)

    def op_inc(self, ops, strict):
        return self._incdec(ops, strict, 0x03, 0x04)

    def op_dec(self, ops, strict):
        return self._incdec(ops, strict, 0x0B, 0x05)

    def _incdec(self, ops, strict, base16, base8):
        o = ops[0].lower()
        if o in IDX:
            return [IDX[o], base16 | (2 << 4)]
        if o in RP:
            return [base16 | (RP[o] << 4)]
        r = self.r8(ops[0])
        if r is None:
            raise AsmError("bad operand %r" % ops[0])
        pfx, c, d = r
        tail = [self.disp(d, strict)] if d is not None else []
        return ([pfx] if pfx else []) + [base8 | (c << 3)] + tail

    # ------------------------------------------------------------- control
    def op_jp(self, ops, strict):
        if len(ops) == 1:
            o = ops[0].lower()
            if o == "(hl)":
                return [0xE9]
            if o in ("(ix)", "(iy)"):
                return [IDX[o[1:3]], 0xE9]
            return [0xC3] + self.imm16(ops[0], strict)
        cc = ops[0].lower()
        if cc not in CC:
            raise AsmError("bad condition %r" % ops[0])
        return [0xC2 | (CC[cc] << 3)] + self.imm16(ops[1], strict)

    def op_jr(self, ops, strict):
        if len(ops) == 1:
            return [0x18, self._rel(ops[0], strict, 2)]
        cc = ops[0].lower()
        if cc not in ("nz", "z", "nc", "c"):
            raise AsmError("jr takes only nz, z, nc or c")
        return [0x20 | (CC[cc] << 3), self._rel(ops[1], strict, 2)]

    def op_djnz(self, ops, strict):
        return [0x10, self._rel(ops[0], strict, 2)]

    def _rel(self, expr, strict, size):
        target = evaluate(expr, self.syms, self.pc, strict)
        d = target - (self.pc + size)
        if strict and not -128 <= d <= 127:
            raise AsmError("relative jump out of range (%d)" % d)
        return d & 0xFF

    def op_call(self, ops, strict):
        if len(ops) == 1:
            return [0xCD] + self.imm16(ops[0], strict)
        cc = ops[0].lower()
        if cc not in CC:
            raise AsmError("bad condition %r" % ops[0])
        return [0xC4 | (CC[cc] << 3)] + self.imm16(ops[1], strict)

    def op_ret(self, ops, strict):
        cc = ops[0].lower()
        if cc not in CC:
            raise AsmError("bad condition %r" % ops[0])
        return [0xC0 | (CC[cc] << 3)]

    def op_rst(self, ops, strict):
        v = evaluate(ops[0], self.syms, self.pc, strict)
        if v & ~0x38:
            raise AsmError("rst target must be a multiple of 8 below 0x40")
        return [0xC7 | v]

    def op_im(self, ops, strict):
        v = evaluate(ops[0], self.syms, self.pc, strict)
        return [0xED, {0: 0x46, 1: 0x56, 2: 0x5E}[v]]

    # ------------------------------------------------------------------ I/O
    def op_in(self, ops, strict):
        if len(ops) == 2 and ops[1].lower() == "(c)":
            r = ops[0].lower()
            if r not in R8 or r == "(hl)":
                raise AsmError("bad in destination")
            return [0xED, 0x40 | (R8[r] << 3)]
        if len(ops) == 2 and ops[0].lower() == "a":
            mm = re.fullmatch(r"\((.*)\)", ops[1])
            if mm:
                return [0xDB, self.imm8(mm.group(1), strict)]
        raise AsmError("bad in operands")

    def op_out(self, ops, strict):
        if ops[0].lower() == "(c)":
            s = ops[1].lower()
            if s == "0":
                return [0xED, 0x71]
            if s not in R8 or s == "(hl)":
                raise AsmError("bad out source")
            return [0xED, 0x41 | (R8[s] << 3)]
        mm = re.fullmatch(r"\((.*)\)", ops[0])
        if mm and ops[1].lower() == "a":
            return [0xD3, self.imm8(mm.group(1), strict)]
        raise AsmError("bad out operands")

    # ------------------------------------------------------- rotates and bits
    def _cb(self, code, ops, strict, bit=None):
        r = self.r8(ops[-1])
        if r is None:
            raise AsmError("bad operand %r" % ops[-1])
        pfx, c, d = r
        op = (code << 3) | c if bit is None else (code << 6) | (bit << 3) | c
        if pfx:
            return [pfx, 0xCB, self.disp(d, strict), op]
        return [0xCB, op]

    def _bitop(self, name, ops, strict):
        bit = evaluate(ops[0], self.syms, self.pc, strict)
        if not 0 <= bit <= 7:
            raise AsmError("bit index out of range")
        return self._cb(BITOP[name], ops, strict, bit)


for _name, _code in ROT.items():
    setattr(Asm, "op_" + _name,
            (lambda c: lambda self, ops, strict: self._cb(c, ops, strict))(_code))
for _name in BITOP:
    setattr(Asm, "op_" + _name,
            (lambda n: lambda self, ops, strict: self._bitop(n, ops, strict))(_name))


# --------------------------------------------------------------------------
# the two passes
# --------------------------------------------------------------------------
def split_operands(text):
    out, depth, cur, q = [], 0, "", None
    for ch in text:
        if q:
            cur += ch
            if ch == q:
                q = None
            continue
        if ch in "'\"":
            q = ch
            cur += ch
        elif ch == "(":
            depth += 1
            cur += ch
        elif ch == ")":
            depth -= 1
            cur += ch
        elif ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def strip_comment(line):
    out, q = "", None
    for ch in line:
        if q:
            out += ch
            if ch == q:
                q = None
        elif ch in "'\"":
            q = ch
            out += ch
        elif ch == ";":
            break
        else:
            out += ch
    return out


def assemble(text, listing=False):
    a = Asm()
    lines = text.splitlines()
    out = {}
    listing_rows = []

    for strict in (False, True):
        a.pc = 0
        out = {}
        for lineno, raw in enumerate(lines, 1):
            line = strip_comment(raw).rstrip()
            if not line.strip():
                continue
            label = None
            m = re.match(r"^([A-Za-z_.][A-Za-z0-9_.]*):?\s", line + " ")
            if line[0] not in " \t" and m:
                label = m.group(1)
                line = line[m.end(1):].lstrip()
                if line.startswith(":"):
                    line = line[1:].lstrip()
            parts = line.split(None, 1)
            mnem = parts[0].lower() if parts else ""
            rest = parts[1] if len(parts) > 1 else ""
            ops = split_operands(rest)

            if label and mnem not in ("equ", "="):
                a.syms[label.lower()] = a.pc

            try:
                if mnem in ("equ", "="):
                    if not label:
                        raise AsmError("equ needs a label")
                    a.syms[label.lower()] = evaluate(ops[0], a.syms, a.pc, strict)
                    continue
                if mnem == "org":
                    a.pc = evaluate(ops[0], a.syms, a.pc, strict)
                    continue
                if mnem == "end":
                    break
                if mnem in ("ds", "defs"):
                    a.pc += evaluate(ops[0], a.syms, a.pc, strict)
                    continue
                if not mnem:
                    continue

                if mnem in ("db", "defb", "defm"):
                    data = []
                    for o in ops:
                        if re.fullmatch(r'".*"', o, re.S):
                            data += [ord(c) for c in o[1:-1]]
                        else:
                            data.append(evaluate(o, a.syms, a.pc, strict) & 0xFF)
                elif mnem in ("dw", "defw"):
                    data = []
                    for o in ops:
                        v = evaluate(o, a.syms, a.pc, strict)
                        data += [v & 0xFF, (v >> 8) & 0xFF]
                else:
                    data = a.encode(mnem, ops, strict)
            except AsmError as e:
                raise AsmError("line %d: %s" % (lineno, e))

            if strict:
                for i, b in enumerate(data):
                    out[a.pc + i] = b & 0xFF
                if listing:
                    listing_rows.append((a.pc, data, raw.rstrip()))
            a.pc += len(data)

    return out, a.syms, listing_rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("-o", "--output")
    ap.add_argument("--bin", action="store_true", help="raw binary, not hex")
    ap.add_argument("--size", type=int, default=0, help="pad to this many bytes")
    ap.add_argument("-l", "--listing", action="store_true")
    a = ap.parse_args()

    try:
        mem, syms, rows = assemble(open(a.source).read(), a.listing)
    except AsmError as e:
        print("%s: %s" % (a.source, e), file=sys.stderr)
        sys.exit(1)

    if a.listing:
        for pc, data, src in rows:
            print("%04X  %-12s %s" % (pc, " ".join("%02X" % b for b in data), src))

    if not mem:
        print("nothing assembled", file=sys.stderr)
        sys.exit(1)
    top = max(mem) + 1
    size = a.size or top
    image = bytes(mem.get(i, 0) for i in range(size))

    if a.output:
        if a.bin:
            open(a.output, "wb").write(image)
        else:
            open(a.output, "w").write("".join("%02x\n" % b for b in image))
        print("%s: %d bytes, %d symbols" % (a.output, len(image), len(syms)))


if __name__ == "__main__":
    main()
