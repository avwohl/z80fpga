#!/usr/bin/env python3
"""Run the core against the SingleStepTests per-opcode suite.

  python tools/run_sst.py 00 01 80          # named opcodes
  python tools/run_sst.py --all             # every opcode file
  python tools/run_sst.py --all -n 50       # 50 tests per opcode, a fast sweep
  python tools/run_sst.py 36 --cycles -v    # compare bus traces too, verbose

Point --suite at a checkout of https://github.com/SingleStepTests/z80 (or set
Z80_TESTS).  The bench itself is sim/tb_sst.sv; this script only marshals data
in and out of it.
"""
import argparse, json, os, subprocess, sys, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SUITE = os.environ.get("Z80_TESTS", r"C:/temp/tools/z80tests")

REGS8  = ["a", "f", "b", "c", "d", "e", "h", "l"]
REGS16 = ["af_", "bc_", "de_", "hl_", "ix", "iy", "sp", "pc", "wz"]
MISC   = ["i", "r", "iff1", "iff2", "im", "q"]
FIELDS = REGS8 + REGS16 + MISC

PIN_CHARS = "rwmi"


def write_vectors(path, tests):
    out = ["%d\n" % len(tests)]
    for t in tests:
        s = t["initial"]
        vals = ["%02x" % s[k] for k in REGS8]
        vals += ["%04x" % s[k] for k in REGS16]
        vals += ["%02x" % s[k] for k in MISC]
        # the byte any IN during this test should see
        ioval = 0
        for p in t.get("ports", []) or []:
            if p[2] == "r":
                ioval = p[1]
        vals.append("%02x" % ioval)
        out.append(" ".join(vals) + "\n")
        ram = s["ram"]
        out.append("%d\n" % len(ram))
        out += ["%04x %02x\n" % (addr, val) for addr, val in ram]
        chk = t["final"]["ram"]
        out.append("%d\n" % len(chk))
        out += ["%04x\n" % addr for addr, _ in chk]
    open(path, "w").write("".join(out))


def parse_results(path):
    blocks, cur = [], None
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == "R":
            cur = {"regs": p[1:], "mem": [], "cycles": []}
        elif p[0] == "M" and cur is not None:
            cur["mem"] = p[1:]
        elif p[0] == "C" and cur is not None and len(p) == 4:
            cur["cycles"].append(p[1:])
        elif p[0] == "E":
            blocks.append(cur)
            cur = None
    return blocks


def hx(v):
    """Values the bench could not resolve come back as x; keep them visible."""
    try:
        return int(v, 16)
    except ValueError:
        return -1


def compare(test, res, check_cycles):
    bad = []
    f = test["final"]
    got = res["regs"]
    n = 0
    for k in REGS8:
        if hx(got[n]) != f[k]:
            bad.append("%s: got %s want %02x" % (k, got[n], f[k]))
        n += 1
    for k in REGS16:
        if hx(got[n]) != f[k]:
            bad.append("%s: got %s want %04x" % (k, got[n], f[k]))
        n += 1
    for k in MISC:
        want = f[k]
        have = hx(got[n]) if k in ("i", "r", "q") else int(got[n])
        if have != want:
            bad.append("%s: got %s want %x" % (k, got[n], want))
        n += 1
    tstates = int(got[n]); n += 1
    io_dir = int(got[n]); n += 1
    io_addr = hx(got[n]); n += 1
    io_val = hx(got[n])

    for i, (addr, val) in enumerate(f["ram"]):
        if i < len(res["mem"]) and hx(res["mem"][i]) != val:
            bad.append("ram[%04x]: got %s want %02x"
                       % (addr, res["mem"][i], val))

    want_cycles = test["cycles"]
    if tstates != len(want_cycles):
        bad.append("T-states: got %d want %d" % (tstates, len(want_cycles)))

    ports = test.get("ports") or []
    if ports:
        paddr, pval, pdir = ports[0]
        wdir = 1 if pdir == "r" else 2
        if (io_dir, io_addr) != (wdir, paddr) or (wdir == 2 and io_val != pval):
            bad.append("port: got dir%d %04x %02x want dir%d %04x %02x"
                       % (io_dir, io_addr, io_val, wdir, paddr, pval))
    elif io_dir != 0:
        bad.append("port: unexpected transaction dir%d %04x" % (io_dir, io_addr))

    if check_cycles:
        for i, want in enumerate(want_cycles):
            if i >= len(res["cycles"]):
                break
            ga, gd, gp = res["cycles"][i]
            ga, gd, gp = hx(ga), hx(gd), hx(gp)
            gpins = "".join(PIN_CHARS[j] if (gp >> (3 - j)) & 1 else "-"
                            for j in range(4))
            if want[0] is not None and ga != want[0]:
                bad.append("T%d addr: got %04x want %04x" % (i + 1, ga, want[0]))
            if want[1] is not None and gd != want[1]:
                bad.append("T%d data: got %03x want %02x" % (i + 1, gd, want[1]))
            if gpins != want[2]:
                bad.append("T%d pins: got %s want %s" % (i + 1, gpins, want[2]))
    return bad


def run(names, suite, limit, check_cycles, verbose, build_dir, chunk=250):
    """Batch many opcode files into one bench run; launching vvp dominates."""
    vvp = os.path.join(build_dir, "tb_sst.vvp")
    vec = os.path.join(build_dir, "vec.txt")
    res = os.path.join(build_dir, "res.txt")
    total_fail = total = 0
    per_op, symptoms, examples = {}, {}, {}

    for start in range(0, len(names), chunk):
        group = names[start:start + chunk]
        loaded = []
        for name in group:
            tests = json.load(open(os.path.join(suite, "v1", name + ".json")))
            loaded.append((name, tests[:limit] if limit else tests))
        write_vectors(vec, [t for _, ts in loaded for t in ts])
        cmd = ["vvp", vvp, "+vec=" + vec, "+out=" + res]
        if check_cycles:
            cmd.append("+cyc=1")
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
        if r.returncode != 0:
            print("SIM ERROR" + chr(10) + r.stdout + r.stderr)
            return 1
        blocks = parse_results(res)
        i = 0
        for name, tests in loaded:
            fails = 0
            for t in tests:
                if i >= len(blocks):
                    break
                bad = compare(t, blocks[i], check_cycles)
                i += 1
                if bad:
                    fails += 1
                    key = bad[0].split(":")[0]
                    symptoms[key] = symptoms.get(key, 0) + 1
                    examples.setdefault(name, (t, bad))
            total += len(tests)
            total_fail += fails
            if fails:
                per_op[name] = (fails, len(tests))

    for name in sorted(per_op):
        fails, n = per_op[name]
        print("%-14s %4d/%4d FAIL" % (name, fails, n))
        if verbose:
            t, bad = examples[name]
            print("   initial: " + " ".join("%s=%x" % (k, t["initial"][k])
                                            for k in FIELDS))
            for m in bad[:10]:
                print("     " + m)
    print(chr(10) + "%d/%d tests failed across %d opcodes (%d opcodes clean)"
          % (total_fail, total, len(names), len(names) - len(per_op)))
    if symptoms:
        print("first-symptom histogram:")
        for k, v in sorted(symptoms.items(), key=lambda kv: -kv[1])[:15]:
            print("   %-24s %d" % (k, v))
    return 1 if total_fail else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("opcodes", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--suite", default=DEFAULT_SUITE)
    ap.add_argument("-n", "--limit", type=int, default=0)
    ap.add_argument("--cycles", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--build", default=os.path.join(ROOT, "sim"))
    ap.add_argument("--chunk", type=int, default=250,
                    help="opcode files per bench invocation")
    a = ap.parse_args()

    if a.all:
        names = sorted(os.path.basename(p)[:-5]
                       for p in glob.glob(os.path.join(a.suite, "v1", "*.json")))
    else:
        names = a.opcodes
    if not names:
        ap.error("name some opcodes, or pass --all")
    sys.exit(run(names, a.suite, a.limit, a.cycles, a.verbose, a.build,
                 a.chunk))


if __name__ == "__main__":
    main()
