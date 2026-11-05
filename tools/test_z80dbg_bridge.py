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
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port))
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


def main():
    vvp = "sim/tb_debug_cosim.vvp"
    if not os.path.exists(vvp):
        sys.exit("%s is missing: make sim/tb_debug_cosim.vvp" % vvp)
    image = open("sim/dbg_prog.hex").read().split()
    prog = bytes(int(b, 16) for b in image[0x8000:0x8029])

    transport = zb.VvpTransport(vvp, cwd=ROOT)
    unit = zb.Unit(transport)
    unit.sync()
    bridge = zb.Bridge(unit, poll=0)
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
    print("%s: %d checks, bridge against the RTL" % ("PASS" if not fails else "FAIL", checks))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
