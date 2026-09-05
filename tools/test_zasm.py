#!/usr/bin/env python3
"""Check tools/zasm.py against known encodings.

  python tools/test_zasm.py

The cases are the forms that are easy to get wrong: the index-register halves,
the DD CB displacement order, the ED-prefixed 16-bit loads, relative jumps
both ways, and the number and expression syntax.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zasm import assemble, AsmError

CASES = [
    # plain register and immediate loads
    ("ld a,b",              "78"),
    ("ld b,(hl)",           "46"),
    ("ld (hl),c",           "71"),
    ("ld h,55h",            "26 55"),
    ("ld bc,1234h",         "01 34 12"),
    ("ld sp,hl",            "F9"),
    ("ld a,(bc)",           "0A"),
    ("ld (de),a",           "12"),
    ("ld (1234h),a",        "32 34 12"),
    ("ld a,(1234h)",        "3A 34 12"),
    ("ld (1234h),hl",       "22 34 12"),
    ("ld hl,(1234h)",       "2A 34 12"),
    ("ld (1234h),de",       "ED 53 34 12"),
    ("ld de,(1234h)",       "ED 5B 34 12"),
    ("ld a,i",              "ED 57"),
    ("ld r,a",              "ED 4F"),

    # index registers
    ("ld ix,1234h",         "DD 21 34 12"),
    ("ld iy,(1234h)",       "FD 2A 34 12"),
    ("ld (1234h),ix",       "DD 22 34 12"),
    ("ld a,(ix+5)",         "DD 7E 05"),
    ("ld a,(iy-1)",         "FD 7E FF"),
    ("ld (ix+7fh),b",       "DD 70 7F"),
    ("ld (ix+0),80h",       "DD 36 00 80"),
    ("ld ixh,a",            "DD 67"),
    ("ld a,iyl",            "FD 7D"),
    ("ld sp,ix",            "DD F9"),
    ("inc (ix+2)",          "DD 34 02"),
    ("add a,(iy+3)",        "FD 86 03"),
    ("push iy",             "FD E5"),
    ("ex (sp),ix",          "DD E3"),
    ("jp (ix)",             "DD E9"),
    ("add ix,de",           "DD 19"),

    # arithmetic and logic
    ("add a,b",             "80"),
    ("add a,7",             "C6 07"),
    ("sub c",               "91"),
    ("cp 0FFh",             "FE FF"),
    ("and (hl)",            "A6"),
    ("adc hl,bc",           "ED 4A"),
    ("sbc hl,sp",           "ED 72"),
    ("add hl,hl",           "29"),
    ("inc de",              "13"),
    ("dec (hl)",            "35"),
    ("neg",                 "ED 44"),

    # rotates and bits
    ("rlca",                "07"),
    ("rlc b",               "CB 00"),
    ("rr (hl)",             "CB 1E"),
    ("srl a",               "CB 3F"),
    ("bit 7,h",             "CB 7C"),
    ("res 0,(hl)",          "CB 86"),
    ("set 3,e",             "CB DB"),
    ("rlc (ix+4)",          "DD CB 04 06"),
    ("bit 5,(iy-2)",        "FD CB FE 6E"),
    ("set 1,(ix+1)",        "DD CB 01 CE"),

    # control flow
    ("jp 1234h",            "C3 34 12"),
    ("jp nz,1234h",         "C2 34 12"),
    ("jp (hl)",             "E9"),
    ("call 1234h",          "CD 34 12"),
    ("call pe,1234h",       "EC 34 12"),
    ("ret",                 "C9"),
    ("ret m",               "F8"),
    ("rst 38h",             "FF"),
    ("im 2",                "ED 5E"),
    ("reti",                "ED 4D"),

    # I/O and blocks
    ("in a,(0feh)",         "DB FE"),
    ("in e,(c)",            "ED 58"),
    ("out (0feh),a",        "D3 FE"),
    ("out (c),d",           "ED 51"),
    ("out (c),0",           "ED 71"),
    ("ldir",                "ED B0"),
    ("otdr",                "ED BB"),
]

# whole-source cases, where labels and the current address matter
SOURCES = [
    ("""        org 100h
back:   nop
        jr back
        djnz back
fwd:    jr nz,done
        nop
done:   halt
""", "00 18 FD 10 FB 20 01 00 76"),
    ("""        org 0
val     equ 12h
        ld a,val
        ld hl,tab
        db 1,2,"AB",0
tab:    dw $
""", "3E 12 21 0A 00 01 02 41 42 00 0A 00"),
]


def assemble_one(text):
    mem, _syms, _rows = assemble(text)
    lo = min(mem)
    return " ".join("%02X" % mem[a] for a in range(lo, max(mem) + 1))


def main():
    bad = 0
    for src, want in CASES:
        try:
            got = assemble_one("        org 0\n        " + src + "\n")
        except AsmError as e:
            print("%-24s ERROR %s" % (src, e))
            bad += 1
            continue
        if got != want:
            print("%-24s got %-18s want %s" % (src, got, want))
            bad += 1
    for src, want in SOURCES:
        try:
            got = assemble_one(src)
        except AsmError as e:
            print("source case ERROR %s" % e)
            bad += 1
            continue
        if got != want:
            print("source case got %s" % got)
            print("            want %s" % want)
            bad += 1

    total = len(CASES) + len(SOURCES)
    print("%d/%d assembler cases failed" % (bad, total))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
