#!/usr/bin/env python3
"""Test the RSP bridge against the RTL.

  make sim/tb_debug_cosim.vvp sim/dbg_prog.hex
  python3 tools/test_z80dbg_bridge.py

An RSP client (this file) talks over a TCP socket to the bridge, and the
bridge drives a vvp simulation of the whole SoC with the debug unit in it
(sim/tb_debug_cosim.sv).  The target is the program of sim/dbg_prog.z80; every
expected value comes from its listing.  Nothing in the exchange is a model of
the unit: the answers are the RTL's.
"""
import hashlib
import os
import socket
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import z80dbg_bridge as zb          # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

fails = 0
checks = 0


def check(what, got, want):
    global fails, checks
    checks += 1
    if got != want:
        fails += 1
        print("FAIL: %s: got %r, expected %r" % (what, got, want))


class Rsp(object):
    def __init__(self, port, host="127.0.0.1"):
        self.s = socket.create_connection((host, port))
        self.s.settimeout(60)
        self.buf = b""

    def _byte(self):
        while not self.buf:
            self.buf = self.s.recv(4096)
            if not self.buf:
                raise EOFError
        b, self.buf = self.buf[:1], self.buf[1:]
        return b

    def send(self, text):
        p = text.encode()
        self.s.sendall(b"$" + p + b"#" + ("%02x" % zb.checksum(p)).encode())

    def recv(self):
        while self._byte() != b"$":
            pass
        out = b""
        while True:
            c = self._byte()
            if c == b"#":
                break
            out += c
        cs = self._byte() + self._byte()
        check("reply checksum", int(cs, 16), zb.checksum(out))
        self.s.sendall(b"+")
        return out.decode()

    def ask(self, text):
        self.send(text)
        while True:
            c = self._byte()
            if c == b"+":
                break
            if c == b"-":
                raise IOError("bridge refused a packet of ours")
        return self.recv()


def reg(g, name):
    i = ["af", "bc", "de", "hl", "sp", "pc", "ix", "iy", "af'", "bc'", "de'", "hl'", "ir"].index(name)
    return zb.parse16le(g[4 * i:4 * i + 4])


def lan_address():
    """An IPv4 address of this host that is not loopback, or None.  A UDP
    connect sends nothing; it only makes the system choose an interface."""
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        u.connect(("192.0.2.1", 9))
        addr = u.getsockname()[0]
    except OSError:
        return None
    finally:
        u.close()
    return None if addr.startswith("127.") or addr == "0.0.0.0" else addr


def start_bridge(vvp, *args):
    """The bridge's own main(), on the cosim: (process, port)."""
    import subprocess
    import tempfile
    import time
    pf = os.path.join(tempfile.mkdtemp(prefix="z80dbg."), "port")
    proc = subprocess.Popen([sys.executable, os.path.join(ROOT, "tools", "z80dbg_bridge.py"),
                             "--vvp", vvp, "--listen", "0", "--port-file", pf] + list(args),
                            cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE, universal_newlines=True)
    for _ in range(600):
        if os.path.exists(pf) and open(pf).read().endswith("\n"):
            return proc, int(open(pf).read())
        if proc.poll() is not None:
            break
        time.sleep(0.05)
    proc.kill()
    raise RuntimeError("the bridge gave no port: " + proc.stderr.read())


def refused(host, port):
    try:
        socket.create_connection((host, port), timeout=5).close()
    except OSError:
        return True
    return False


def stop_bridge(proc, c):
    c.s.sendall(b"$k#6b")
    proc.wait(30)
    return proc.stderr.read()


def check_listen_addr(vvp):
    """--listen-addr through main(): the address, the warning, the refusals."""
    import subprocess
    for bad in ("localhost", "1.2.3", "300.1.1.1"):
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "z80dbg_bridge.py"),
                            "--vvp", vvp, "--listen-addr", bad], cwd=ROOT,
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        check("--listen-addr %s is refused" % bad,
              r.returncode == 2 and "an IPv4 address" in r.stderr, True)
    lan = lan_address()
    proc, port = start_bridge(vvp)
    if lan:
        check("by default the bridge refuses %s" % lan, refused(lan, port), True)
    c = Rsp(port)
    check("by default: ? on 127.0.0.1", c.ask("?"), "T05")
    err = stop_bridge(proc, c)
    check("by default: listening on 127.0.0.1, no warning",
          "listening on 127.0.0.1:" in err and "WARNING" not in err, True)
    if not lan:
        print("NOTE: no LAN address on this host; the --listen-addr LAN checks were not run")
        return
    proc, port = start_bridge(vvp, "--listen-addr", "0.0.0.0")
    c = Rsp(port, lan)
    check("--listen-addr 0.0.0.0: ? on %s" % lan, c.ask("?"), "T05")
    check("--listen-addr 0.0.0.0: wait-program from the network",
          bytes.fromhex(c.ask("qRcmd," + b"wait-program".hex())).decode(), "wait-program: not armed\n")
    err = stop_bridge(proc, c)
    check("--listen-addr 0.0.0.0 prints the warning", "WARNING: listening on 0.0.0.0" in err, True)
    proc, port = start_bridge(vvp, "--listen-addr", lan)
    check("--listen-addr %s refuses 127.0.0.1" % lan, refused("127.0.0.1", port), True)
    c = Rsp(port, lan)
    check("--listen-addr %s: ? on %s" % (lan, lan), c.ask("?"), "T05")
    stop_bridge(proc, c)


def main():
    vvp = "sim/tb_debug_cosim.vvp"
    if not os.path.exists(vvp):
        sys.exit("%s is missing: make sim/tb_debug_cosim.vvp" % vvp)
    image = open("sim/dbg_prog.hex").read().split()
    prog = bytes(int(b, 16) for b in image[0x8000:0x8029])

    transport = zb.VvpTransport(vvp, cwd=ROOT)
    unit = zb.Unit(transport)
    unit.sync()
    # The cosim has RAM banks 80H and 81H only, so wait-program waits in 80H,
    # where the program calls its routine at 0100H.
    bridge = zb.Bridge(unit, poll=0, program_bank=0x80)
    ls = socket.socket()
    ls.bind(("127.0.0.1", 0))
    ls.listen(1)
    port = ls.getsockname()[1]

    def serve():
        conn, _ = ls.accept()
        bridge.serve(conn)
        conn.close()

    th = threading.Thread(target=serve)
    th.daemon = True
    th.start()
    c = Rsp(port)

    # ---- the handshake GDB makes
    sup = c.ask("qSupported:multiprocess+;swbreak+;hwbreak+")
    check("qSupported: packet size", "PacketSize=4000" in sup, True)
    check("qSupported: hwbreak", "hwbreak+" in sup, True)
    xml = ""
    while True:
        r = c.ask("qXfer:features:read:target.xml:%x,200" % len(xml))
        xml += r[1:]
        if r[0] == "l":
            break
    check("target.xml is the 16-bit-pc description", xml == zb.TARGET_XML, True)
    check("target.xml: pc is 16 bits", '<reg name="pc" bitsize="16"' in xml, True)
    check("?", c.ask("?"), "T05")
    check("qAttached", c.ask("qAttached"), "1")
    check("vCont?", c.ask("vCont?").startswith("vCont;c"), True)

    # ---- registers at reset, from the real core
    g = c.ask("g")
    check("g length: 13 registers of 4 hex digits", len(g), 52)
    check("pc at reset", reg(g, "pc"), 0)
    check("af at reset", reg(g, "af"), 0xFFFF)
    check("sp at reset", reg(g, "sp"), 0xFFFF)

    # ---- load the program, read it back, point PC at it
    check("M", c.ask("M8000,%x:%s" % (len(prog), prog.hex())), "OK")
    check("m", c.ask("m8000,%x" % len(prog)), prog.hex())
    check("P5 (pc)", c.ask("P5=" + zb.hex16le(0x8000)), "OK")
    check("p5", c.ask("p5"), "0080")
    check("memory above 64K", c.ask("m10000,1"), "E01")

    # ---- the bank view: put the routine at 0100H in RAM bank 80H, the way
    #      the program expects to find it, without changing the CPU's bank
    check("rom byte 0 is di", c.ask("m0000,1"), "f3")
    check("monitor bank 80", bytes.fromhex(c.ask("qRcmd," + b"bank 80".hex())).decode().startswith("memory view: bank 80"), True)
    check("M0100 in bank 80", c.ask("M0100,3:065ac9"), "OK")
    check("m0100 in bank 80", c.ask("m0100,3"), "065ac9")
    c.ask("qRcmd," + b"bank cur".hex())
    check("m0100 in the CPU's bank is not the routine", c.ask("m0100,3") != "065ac9", True)
    check("rom byte 0 still di", c.ask("m0000,1"), "f3")

    # ---- a software breakpoint (hardware underneath), run to it
    check("Z0 800f", c.ask("Z0,800f,1"), "OK")
    check("c to the breakpoint", c.ask("c"), "T05swbreak:;")
    g = c.ask("g")
    check("pc at the breakpoint", reg(g, "pc"), 0x800F)
    check("a at the breakpoint", reg(g, "af") >> 8, 0x11)
    check("bc", reg(g, "bc"), 0x2233)
    check("de", reg(g, "de"), 0x4455)
    check("hl", reg(g, "hl"), 0x9000)
    check("sp", reg(g, "sp"), 0xF000)

    # ---- step, and register write through G
    check("s", c.ask("s"), "T05")
    g = c.ask("g")
    check("pc after the step", reg(g, "pc"), 0x8010)
    check("a after the step", reg(g, "af") >> 8, 0x12)
    g2 = g[:12] + zb.hex16le(0x7777) + g[16:]           # hl is the 4th register
    check("G", c.ask("G" + g2), "OK")
    check("hl written by G", reg(c.ask("g"), "hl"), 0x7777)
    check("P3 (hl) back", c.ask("P3=" + zb.hex16le(0x9000)), "OK")

    # ---- a hardware breakpoint at the end, and the stack in memory
    check("z0", c.ask("z0,800f,1"), "OK")
    check("Z1 8026", c.ask("Z1,8026,1"), "OK")
    check("c to the end", c.ask("c"), "T05hwbreak:;")
    g = c.ask("g")
    check("pc at the end", reg(g, "pc"), 0x8026)
    check("bc': the routine in bank 80 ran", reg(g, "bc'"), 0x5A33)

    # ---- a bank-qualified breakpoint through monitor break-bank
    c.ask("qRcmd," + b"break-bank 00".hex())
    check("Z0 0100", c.ask("Z0,0100,1"), "OK")
    check("P5", c.ask("P5=" + zb.hex16le(0x8019)), "OK")
    check("z1", c.ask("z1,8026,1"), "OK")
    check("Z1 8026 again", c.ask("Z1,8026,1"), "OK")
    check("c: the break in bank 00 misses, the end hits", c.ask("c"), "T05hwbreak:;")
    # entered at 8019, so only the routine's B is new; C is whatever EXX swapped in
    check("b': the routine ran", reg(c.ask("g"), "bc'") >> 8, 0x5A)
    c.ask("qRcmd," + b"break-bank 80".hex())
    check("P5 again", c.ask("P5=" + zb.hex16le(0x8019)), "OK")
    check("c: the break in bank 80 hits", c.ask("c"), "T05swbreak:;")
    check("pc in the routine", reg(c.ask("g"), "pc"), 0x0100)
    status = bytes.fromhex(c.ask("qRcmd," + b"status".hex())).decode()
    check("monitor status shows the CPU bank", "cpu-bank=80" in status, True)
    c.ask("qRcmd," + b"break-bank off".hex())

    # ---- stop reasons only for a client that asked for them
    c.ask("z0,0100,1")
    c.ask("z1,8026,1")
    c.ask("qSupported:multiprocess+;vContSupported+")
    check("Z0 800f again", c.ask("Z0,800f,1"), "OK")
    check("P5 to the start, no swbreak+", c.ask("P5=" + zb.hex16le(0x8000)), "OK")
    check("without swbreak+ a Z0 stop is a plain T05", c.ask("c"), "T05")
    check("z0 800f", c.ask("z0,800f,1"), "OK")
    check("Z1 8026, no hwbreak+", c.ask("Z1,8026,1"), "OK")
    check("without hwbreak+ a Z1 stop is a plain T05", c.ask("c"), "T05")
    c.ask("qSupported:multiprocess+;swbreak+;hwbreak+")

    # ---- monitor wait-program: the program at 0100H in bank 80H is 06 5A C9
    def mon(text):
        return bytes.fromhex(c.ask("qRcmd," + text.encode().hex())).decode()

    check("wait-program, not armed", mon("wait-program"), "wait-program: not armed\n")
    check("wait-program bytes, a program that is not there",
          mon("wait-program bytes 06 5a c8").startswith("wait-program: armed; the next start at 0100H in bank 80"),
          True)
    check("P5 to the start, rule armed", c.ask("P5=" + zb.hex16le(0x8000)), "OK")
    looked = []
    real_matches = bridge.program_matches
    bridge.program_matches = lambda: looked.append(real_matches()) or looked[-1]
    check("a start that does not match runs on to the end", c.ask("c"), "T05hwbreak:;")
    check("the rule stopped at 0100H once and the bytes did not match", looked, [False])
    bridge.program_matches = real_matches
    check("pc at the end after a miss", reg(c.ask("g"), "pc"), 0x8026)
    check("the rule is still armed after a miss", mon("wait-program"), "wait-program: armed, 3 bytes\n")
    check("wait-program bytes, the routine", mon("wait-program bytes 065ac9").startswith("wait-program: armed"), True)
    check("P5 to the start, the routine", c.ask("P5=" + zb.hex16le(0x8000)), "OK")
    check("the start that matches stops with a plain T05", c.ask("c"), "T05")
    check("pc at 0100H", reg(c.ask("g"), "pc"), 0x0100)
    st = mon("status")
    check("the rule fired once", "wait-program: not armed" in st, True)
    check("the break bank is the program's", "break-bank=80" in st and "cpu-bank=80" in st, True)
    mon("break-bank off")

    sha = hashlib.sha256(bytes.fromhex("065ac9")).hexdigest()
    check("wait-program sha256", mon("wait-program sha256 3 " + sha).startswith("wait-program: armed"), True)
    check("status shows the SHA-256", ("armed, 3 bytes with SHA-256 " + sha) in mon("status"), True)
    check("P5 to the start, sha256", c.ask("P5=" + zb.hex16le(0x8000)), "OK")
    check("sha256: the start stops with T05", c.ask("c"), "T05")
    check("sha256: pc at 0100H", reg(c.ask("g"), "pc"), 0x0100)
    mon("break-bank off")

    # the debugger's own breakpoint at 0100H comes first, and the rule stays
    check("Z0 0100 with the rule", c.ask("Z0,0100,1"), "OK")
    mon("wait-program bytes 065ac9")
    check("P5 to the start, both", c.ask("P5=" + zb.hex16le(0x8000)), "OK")
    check("the debugger's breakpoint wins at 0100H", c.ask("c"), "T05swbreak:;")
    check("the rule did not fire", mon("wait-program"), "wait-program: armed, 3 bytes\n")
    check("z0 0100", c.ask("z0,0100,1"), "OK")
    check("wait-program off", mon("wait-program off"), "wait-program: off\n")

    # the rule waits in the program bank only: with 81H, the start in 80H is not seen
    bridge.program_bank = 0x81
    mon("wait-program bytes 065ac9")
    check("Z1 8026, other bank", c.ask("Z1,8026,1"), "OK")
    check("P5 to the start, other bank", c.ask("P5=" + zb.hex16le(0x8000)), "OK")
    check("a start in bank 80H does not stop a rule for bank 81H", c.ask("c"), "T05hwbreak:;")
    check("the rule for bank 81H is still armed", mon("wait-program"), "wait-program: armed, 3 bytes\n")
    mon("wait-program off")
    check("z1 8026, other bank", c.ask("z1,8026,1"), "OK")
    bridge.program_bank = 0x80

    # a word that does not parse is an error reply, and the bridge goes on
    check("wait-program sha256, a length that is not ASCII digits",
          mon("wait-program sha256 \u00b2 " + "0" * 64).startswith("wait-program sha256: give"), True)
    check("monitor bank zz is E01", c.ask("qRcmd," + b"bank zz".hex()), "E01")
    check("the bridge still answers after E01", c.ask("?"), "T05")

    check("wait-program bytes, odd digits", mon("wait-program bytes 065"),
          "wait-program bytes: give 1 to 4096 bytes as hex digits\n")
    check("wait-program bytes, not hex", mon("wait-program bytes zz"), "wait-program bytes: not a hex digit\n")
    check("wait-program sha256, bad", mon("wait-program sha256 0 " + sha).startswith("wait-program sha256: give"), True)
    check("wait-program, unknown form", mon("wait-program frob"),
          "wait-program: bytes HEX..., sha256 LENGTH HEX64, or off\n")

    # the rule holds one of the four hardware breakpoints while it is armed
    check("z1 8026 before the slot count", c.ask("z1,8026,1"), "OK")
    mon("wait-program bytes 065ac9")
    three = [c.ask("Z0,%x,1" % a) for a in (0x8000, 0x8001, 0x8002, 0x8003)]
    check("with the rule armed, three breakpoints fit", three, ["OK"] * 3 + ["E0e"])
    mon("wait-program off")
    check("wait-program with every breakpoint in use",
          (mon("wait-program bytes 065ac9") if c.ask("Z0,8003,1") == "OK" else ""),
          "wait-program: no free breakpoint; the unit has 4, and each one is in use\n")
    for a in (0x8000, 0x8001, 0x8002, 0x8003):
        c.ask("z0,%x,1" % a)
    mon("break-bank off")

    # ---- only four hardware breakpoints
    for a in (0x8000, 0x8001, 0x8002, 0x8003, 0x8004):
        c.ask("z0,%x,1" % a)
    c.ask("z0,0100,1")
    c.ask("z1,8026,1")
    answers = [c.ask("Z0,%x,1" % a) for a in (0x8000, 0x8001, 0x8002, 0x8003, 0x8004)]
    check("four fit, the fifth does not", answers, ["OK"] * 4 + ["E0e"])
    for a in (0x8000, 0x8001, 0x8002, 0x8003):
        c.ask("z0,%x,1" % a)

    # ---- ^C stops a running target
    check("P5 to the start", c.ask("P5=" + zb.hex16le(0x8000)), "OK")
    c.send("c")
    c.s.sendall(b"+")                                  # nothing: just a pause
    c.s.sendall(b"\x03")
    while True:
        b = c._byte()
        if b == b"$":
            break
    reply = ""
    while True:
        b = c._byte()
        if b == b"#":
            break
        reply += b.decode()
    c._byte(); c._byte()
    c.s.sendall(b"+")
    check("^C reply", reply, "T02")
    pc = reg(c.ask("g"), "pc")
    check("^C stopped inside the program or its spin loop", 0x8000 <= pc <= 0x8028 or pc < 0x0200, True)

    # ---- vCont and range stepping, then detach
    check("P5 to 8000", c.ask("P5=" + zb.hex16le(0x8000)), "OK")
    check("vCont;s", c.ask("vCont;s:1"), "T05")
    check("pc after vCont;s", reg(c.ask("g"), "pc"), 0x8002)
    check("vCont;r over the three loads",
          c.ask("vCont;r8002,800b:1"), "T05")
    check("pc after the range step", reg(c.ask("g"), "pc"), 0x800B)
    check("D", c.ask("D"), "OK")

    th.join(10)
    transport.close()
    check_listen_addr(vvp)
    print("%s: %d checks, bridge against the RTL" % ("PASS" if not fails else "FAIL", checks))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
