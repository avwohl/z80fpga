#!/usr/bin/env python3
"""Test the JTAG link of the debug unit without the RTL or a board.

  python3 tools/test_z80dbg_jtag.py

Three layers, each against a model:
  JtagLink       on a Python model of the FPGA side of the link (the rules of
                 docs/debug_unit.md, JTAG link), with a mailbox that frees only
                 after a set number of scans, so that rejects happen
  Jtag           on fake FTDI devices for both back ends (pyftdi and d2xx):
                 the exact MPSSE bytes of an IR scan and a DR batch, and the
                 calls that the back ends make to open the device
  the whole      JtagLink, Jtag and a back end over a fake MPSSE that clocks a
                 model TAP with IDCODE, USER3 and BYPASS registers

The model of the link is written from the rules, not from dbg_jtag.sv.  The
RTL is tested by its own bench (sim/tb_debug_cosim_jtag.sv).
"""
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import z80dbg_bridge as zb          # noqa: E402
import z80dbg_jtag as zj            # noqa: E402

fails = 0
checks = 0


def check(what, got, want):
    global fails, checks
    checks += 1
    if got != want:
        fails += 1
        print("FAIL: %s: got %r, expected %r" % (what, got, want))


# ---------------------------------------------------------------- the FPGA side

class FpgaLink(object):
    """The FPGA side of the JTAG link, one scan at a time.

    The unit's clock is modelled in scans: the host mailbox, once filled,
    stays full for free_after more scans (a number, or a function that returns
    one); the unit puts the next byte of out_queue into the FPGA-to-host
    mailbox on the first scan in which that mailbox is empty."""

    def __init__(self, free_after=0, rng=None):
        self.free_after = free_after
        self.rng = rng or random.Random(1)
        self.mbox = None            # host to FPGA, one byte
        self.age = 0
        self.hold = 0
        self.sticky = False
        self.tx = None              # FPGA to host, one byte
        self.out_queue = []         # what the unit will send
        self.received = []         # what the unit took from the host mailbox
        self.rejects = 0
        self.rj = 0

    def _hold(self):
        f = self.free_after
        return f() if callable(f) else f

    def tick(self):
        """The unit's clock runs between two scans."""
        if self.mbox is not None:
            self.age += 1
            if self.age > self.hold:
                self.received.append(self.mbox)
                self.mbox = None
        if self.tx is None and self.out_queue:
            self.tx = self.out_queue.pop(0)

    def capture(self):
        self.tick()
        self.rj = 1 if (self.mbox is not None or self.sticky) else 0
        self.taking = self.tx is not None
        word = self.rj << 9
        if self.tx is not None:
            word |= 0x100 | self.tx
        return word

    def update(self, word):
        if self.taking:
            self.tx = None
        if word & 0x100:
            if self.rj == 0:
                self.mbox = word & 0xFF
                self.age = 0
                self.hold = self._hold()
            else:
                self.sticky = True
                self.rejects += 1
        else:
            self.sticky = False

    def scan(self, words):
        out = []
        for w in words:
            out.append(self.capture())
            self.update(w)
        return out

    def reset(self):
        self.sticky = False


def run_traffic(seed, free_after, batch, ops=150):
    """Random writes and reads on a JtagLink over an FpgaLink: order, no
    loss, no duplicates in both directions."""
    rng = random.Random(seed)
    fpga = FpgaLink(free_after, random.Random(seed + 1))
    link = zb.JtagLink(fpga.scan, batch=batch, max_idle=10000)
    sent, want_rx, got_rx = [], [], []
    owed = 0                        # bytes the unit has queued, not yet read
    for _ in range(ops):
        op = rng.random()
        if op < 0.5:
            data = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 60)))
            if rng.random() < 0.5:      # the unit answers while the host writes
                more = [rng.randrange(256) for _ in range(rng.randrange(1, 8))]
                fpga.out_queue.extend(more)
                want_rx.extend(more)
                owed += len(more)
            link.write(data)
            sent.extend(data)
        elif op < 0.8:
            more = [rng.randrange(256) for _ in range(rng.randrange(1, 10))]
            fpga.out_queue.extend(more)
            want_rx.extend(more)
            owed += len(more)
        elif owed:
            n = rng.randrange(1, owed + 1)
            got_rx.extend(link.read(n))
            owed -= n
    if owed:
        got_rx.extend(link.read(owed))
    # let the unit take the last host byte
    for _ in range(20):
        fpga.tick()
    return fpga, link, sent, want_rx, got_rx


def test_link_model():
    for free_after in (0, 1, 2, 5):
        for batch in (1, 4, 32):
            for seed in (1, 2, 3):
                fpga, link, sent, want_rx, got_rx = run_traffic(seed, free_after, batch)
                tag = "free_after=%d batch=%d seed=%d" % (free_after, batch, seed)
                check("link to unit, order and no loss: " + tag, fpga.received, sent)
                check("unit to link, order and no loss: " + tag, got_rx, want_rx)
                check("no stray bytes left in the link: " + tag, bytes(link.rx), b"")
                if free_after and batch > 1 and seed == 1:
                    check("rejects happened: " + tag, fpga.rejects > 0, True)
    # a random hold time per byte
    rng = random.Random(9)
    fpga, link, sent, want_rx, got_rx = run_traffic(7, lambda: rng.randrange(0, 6), 16, ops=300)
    check("random hold: to unit", fpga.received, sent)
    check("random hold: from unit", got_rx, want_rx)


def test_link_cases():
    # a unit byte that arrives in a scan that also carries a host byte
    fpga = FpgaLink(0)
    fpga.out_queue.extend([0xA1, 0xA2, 0xA3])
    link = zb.JtagLink(fpga.scan)
    link.write(b"\x01\x02\x03\x04")
    check("host bytes", fpga.received[:3], [1, 2, 3])
    check("unit bytes that rode on host scans", link.read(3), b"\xa1\xa2\xa3")

    # a mailbox that never empties: write raises instead of looping
    fpga = FpgaLink(10 ** 9)
    link = zb.JtagLink(fpga.scan, max_idle=50)
    try:
        link.write(b"ab")
        raised = False
    except TimeoutError:
        raised = True
    check("a mailbox that never empties raises TimeoutError", raised, True)

    # nothing from the unit: read raises
    fpga = FpgaLink(0)
    link = zb.JtagLink(fpga.scan, max_idle=50)
    try:
        link.read(1)
        raised = False
    except TimeoutError:
        raised = True
    check("read with a silent unit raises TimeoutError", raised, True)

    # the wall-clock timeout, the one JtagTransport uses (max_idle is None)
    for what in ("write", "read"):
        fpga = FpgaLink(10 ** 9 if what == "write" else 0)
        link = zb.JtagLink(fpga.scan, timeout=0.2)
        t0 = time.monotonic()
        try:
            link.write(b"ab") if what == "write" else link.read(1)
            raised = False
        except TimeoutError:
            raised = True
        dt = time.monotonic() - t0
        check("wall-clock timeout on %s raises TimeoutError" % what, raised, True)
        check("wall-clock timeout on %s within 0.2 to 2 s" % what, 0.2 <= dt < 2.0, True)

    # a sticky flag left from before the first write: the lead HV = 0 scan clears it
    fpga = FpgaLink(0)
    fpga.sticky = True
    link = zb.JtagLink(fpga.scan, max_idle=50)
    link.write(b"\x07")
    check("stale sticky flag, first write: byte delivered", fpga.received + [fpga.mbox], [7])
    check("stale sticky flag, first write: no rejection", fpga.rejects, 0)

    # after an HV = 0 poll the lead scan is skipped; a sticky flag set since
    # then costs one rejection, and the retry delivers the byte
    fpga = FpgaLink(0)
    link = zb.JtagLink(fpga.scan, max_idle=50)
    link.write(b"\x01")
    fpga.out_queue.append(0x55)
    check("poll before the stale flag", link.read(1), b"\x55")
    fpga.sticky = True
    link.write(b"\x07")
    check("stale sticky flag after a poll: one rejection", fpga.rejects, 1)
    check("stale sticky flag after a poll: bytes delivered", (fpga.received + [fpga.mbox])[-2:], [1, 7])

    # a model that takes a byte after a rejected one is a broken link
    class Broken(FpgaLink):
        def capture(self):
            w = FpgaLink.capture(self)
            self.n = getattr(self, "n", 0) + 1
            return w & ~0x200 if self.n == 3 else w | (0x200 if self.n == 2 else 0)
    link = zb.JtagLink(Broken(0).scan, batch=8)
    try:
        link.write(b"abcdef")
        raised = False
    except IOError:
        raised = True
    check("a byte taken after a rejected one is reported", raised, True)

    # idle drops what the unit sent while nobody asked, and clears the sticky flag
    fpga = FpgaLink(3)
    fpga.out_queue.extend([5, 6, 7])
    link = zb.JtagLink(fpga.scan)
    link.pause_for = lambda s: None
    link.idle(0.012)
    check("idle drains the unit's bytes", (fpga.tx, fpga.out_queue, bytes(link.rx)), (None, [], b""))
    fpga.sticky = True
    link.idle(0.012)
    check("idle clears the sticky flag", fpga.sticky, False)

    # the unit's command N as the bridge's sync() sends it
    class EchoN(FpgaLink):
        def tick(self):
            FpgaLink.tick(self)
            if self.mbox is None and self.received and self.received[-1] == ord("N") \
                    and not getattr(self, "answered", False):
                self.answered = True
                self.out_queue.append(ord("N"))
    fpga = EchoN(2)
    unit = zb.Unit(zb.JtagLink(fpga.scan, max_idle=1000))
    unit.t.pause_for = lambda s: None
    unit.sync()
    check("Unit.sync over the link", fpga.received, [ord("N")])


# ---------------------------------------------------------------- fake FTDI devices

TAP_NEXT = {   # state: (next on TMS 0, next on TMS 1)
    "TLR": ("RTI", "TLR"), "RTI": ("RTI", "SDR"),
    "SDR": ("CDR", "SIR"), "CDR": ("SHDR", "E1DR"), "SHDR": ("SHDR", "E1DR"),
    "E1DR": ("PDR", "UDR"), "PDR": ("PDR", "E2DR"), "E2DR": ("SHDR", "UDR"),
    "UDR": ("RTI", "SDR"),
    "SIR": ("CIR", "TLR"), "CIR": ("SHIR", "E1IR"), "SHIR": ("SHIR", "E1IR"),
    "E1IR": ("PIR", "UIR"), "PIR": ("PIR", "E2IR"), "E2IR": ("SHIR", "UIR"),
    "UIR": ("RTI", "SDR"),
}
IDCODE_VALUE = 0x13631093


class FakeMpsse(object):
    """An FT2232H MPSSE that records every byte written to it and clocks a
    model TAP: IR of 6 bits (captures 0x35), IDCODE, USER3 (the link, 10 bits)
    and BYPASS."""

    def __init__(self, link):
        self.link = link
        self.log = bytearray()
        self.out = bytearray()
        self.state = "TLR"
        self.tms = 0
        self.ir = 0x09
        self.reg = 0
        self.nbits = 0
        self.ir_shift = 0
        self.commands = []          # (opcode, args) as parsed
        self.low = self.high = None
        self.div = None

    # -- the TAP
    def clock(self, tms, tdi):
        tdo = 0
        if self.state == "CDR":
            if self.ir == 0x09:
                self.reg, self.nbits = IDCODE_VALUE, 32
            elif self.ir == zj.IR_USER3:
                self.reg, self.nbits = self.link.capture(), 10
            else:
                self.reg, self.nbits = 0, 1
        elif self.state == "CIR":
            self.reg, self.nbits = 0x35, 6
        elif self.state in ("SHDR", "SHIR"):
            tdo = self.reg & 1
            self.reg = (self.reg >> 1) | (tdi << (self.nbits - 1))
        new = TAP_NEXT[self.state][tms]
        if new == "UDR" and self.ir == zj.IR_USER3:
            self.link.update(self.reg)
        if new == "UIR":
            self.ir = self.reg
        if new == "TLR":
            self.ir = 0x09
            self.link.reset()
        self.state = new
        return tdo

    # -- the MPSSE
    def write(self, data):
        self.log += data
        self.buf = getattr(self, "buf", bytearray()) + data
        b = self.buf
        i = 0
        while i < len(b):
            op = b[i]
            if op in (0x80, 0x82, 0x86, 0x4B, 0x6B, 0x3B):
                if i + 3 > len(b):
                    break
                a = bytes(b[i + 1:i + 3])
                i += 3
                self.commands.append((op, a))
                if op == 0x80:
                    self.low = tuple(a)
                elif op == 0x82:
                    self.high = tuple(a)
                elif op == 0x86:
                    self.div = a[0] | (a[1] << 8)
                elif op in (0x4B, 0x6B):
                    n, d = a[0] + 1, a[1]
                    tdi = d >> 7
                    bits = []
                    for k in range(n):
                        self.tms = (d >> k) & 1
                        bits.append(self.clock(self.tms, tdi))
                    if op == 0x6B:
                        self.out.append(sum(t << (8 - n + k) for k, t in enumerate(bits)))
                else:       # 0x3B
                    n, d = a[0] + 1, a[1]
                    bits = [self.clock(self.tms, (d >> k) & 1) for k in range(n)]
                    self.out.append(sum(t << (8 - n + k) for k, t in enumerate(bits)))
            elif op == 0x39:
                if i + 3 > len(b):
                    break
                n = (b[i + 1] | (b[i + 2] << 8)) + 1
                if i + 3 + n > len(b):
                    break
                self.commands.append((op, bytes(b[i + 1:i + 3 + n])))
                for byte in b[i + 3:i + 3 + n]:
                    bits = [self.clock(self.tms, (byte >> k) & 1) for k in range(8)]
                    self.out.append(sum(t << k for k, t in enumerate(bits)))
                i += 3 + n
            elif op in (0x85, 0x8A, 0x97, 0x8D, 0x87):
                self.commands.append((op, b""))
                i += 1
            else:
                self.commands.append((op, b""))
                self.out += bytes((0xFA, op))
                i += 1
        self.buf = bytearray(b[i:])


class FakePyftdi(object):
    """pyftdi.ftdi.Ftdi's methods the back end uses."""

    def __init__(self, mpsse, max_write=None, max_read=None):
        self.m = mpsse
        self.calls = []
        self.max_write = max_write
        self.max_read = max_read

    def open_mpsse_from_url(self, url, direction=0, initial=0, frequency=6e6, latency=16, debug=False):
        self.calls.append(("open_mpsse_from_url", url, direction, initial, frequency, latency))
        return frequency

    def write_data(self, data):
        data = bytes(data)[:self.max_write] if self.max_write else bytes(data)
        self.m.write(data)
        return len(data)

    def read_data_bytes(self, size, attempt=1, request_gen=None):
        size = min(size, self.max_read) if self.max_read else size
        data, self.m.out = self.m.out[:size], self.m.out[size:]
        return bytearray(data)

    def purge_buffers(self):
        self.calls.append(("purge_buffers",))

    def close(self):
        self.calls.append(("close",))


class FakeD2xx(object):
    """ftd2xx.FTD2XX's methods the back end uses."""

    def __init__(self, mpsse, max_write=None, max_read=None):
        self.m = mpsse
        self.calls = []
        self.max_write = max_write
        self.max_read = max_read

    def _rec(name):
        def f(self, *a):
            self.calls.append((name,) + a)
        return f
    resetDevice = _rec("resetDevice")
    setUSBParameters = _rec("setUSBParameters")
    setChars = _rec("setChars")
    setTimeouts = _rec("setTimeouts")
    setLatencyTimer = _rec("setLatencyTimer")
    setFlowControl = _rec("setFlowControl")
    setBitMode = _rec("setBitMode")

    def purge(self, mask=0):
        self.calls.append(("purge", mask))

    def write(self, data):
        data = bytes(data)[:self.max_write] if self.max_write else bytes(data)
        self.m.write(data)
        return len(data)

    def read(self, n):
        n = min(n, self.max_read) if self.max_read else n
        data, self.m.out = self.m.out[:n], self.m.out[n:]
        return bytes(data)

    def close(self):
        self.calls.append(("close",))


def make_stack(kind, link, freq=6e6, **kw):
    m = FakeMpsse(link)
    if kind == "pyftdi":
        dev = FakePyftdi(m, **kw)
        backend = zj.PyftdiBackend(freq=freq, ftdi=dev)
    else:
        dev = FakeD2xx(m, **kw)
        backend = zj.D2xxBackend(0, freq, dev=dev)
    return m, dev, backend


INIT = "80e8eb 820060 85 8a 97 8d 860400 aa87 4b051f87".replace(" ", "")
IR_USER3_BYTES = "4b0303 3b0402 6b0283 87".replace(" ", "")
DR_BATCH_BYTES = ("4b0201 390000 41 3b0001 6b0203 "      # 0x141: byte 41, bit 8 = 1, bit 9 = 0
                  "4b0201 390000 00 3b0000 6b0203 "      # 0x000
                  "4b0201 390000 ff 3b0001 6b0283 "      # 0x3ff
                  "87").replace(" ", "")


def test_mpsse_bytes():
    check("divisor 6 MHz", zj.divisor_for(6e6), (4, 6e6))
    check("divisor 30 MHz", zj.divisor_for(30e6), (0, 30e6))
    check("divisor 1 MHz", zj.divisor_for(1e6), (29, 1e6))
    check("divisor too slow clamps", zj.divisor_for(1)[0], 65535)
    check("divisor too fast clamps", zj.divisor_for(100e6)[0], 0)
    for f in (25e6, 7e6, 20e6, 13e6, 5.5e6, 100e3):
        check("divisor for %g never exceeds the request" % f, zj.divisor_for(f)[1] <= f, True)
    try:
        zj.divisor_for(0)
        raised = False
    except ValueError:
        raised = True
    check("divisor for 0 Hz raises ValueError", raised, True)

    for kind in ("pyftdi", "d2xx"):
        m, dev, backend = make_stack(kind, FpgaLink(0))
        j = zj.Jtag(backend, 6e6)
        check(kind + ": init and reset bytes", bytes(m.log).hex(), INIT)
        check(kind + ": GPIO low and high", (m.low, m.high), ((0xE8, 0xEB), (0x00, 0x60)))
        m.log.clear()
        ir = j.ir_scan(zj.IR_USER3)
        check(kind + ": IR scan USER3 bytes", bytes(m.log).hex(), IR_USER3_BYTES)
        check(kind + ": IR capture", ir, 0x35)
        m.log.clear()
        got = j.dr_scan_batch([0x141, 0x000, 0x3FF], 10)
        check(kind + ": DR batch bytes", bytes(m.log).hex(), DR_BATCH_BYTES)
        check(kind + ": USER3 data with an empty link", got, [0x000, 0x000, 0x000])
        m.log.clear()
        check(kind + ": IDCODE", j.idcode(), IDCODE_VALUE)
        check(kind + ": IDCODE scan bytes", bytes(m.log).hex(),
              "4b0303 3b0409 6b0203 87 4b0201 390200 000000 3b0600 6b0203 87".replace(" ", ""))
        j.close()
        check(kind + ": close", dev.calls[-1], ("close",))
        if kind == "pyftdi":
            check("pyftdi open", dev.calls[0],
                  ("open_mpsse_from_url", "ftdi://0x0403:0x6010/1", 0xEB, 0xE8, 6e6, 16))
        else:
            names = [c[0] for c in dev.calls]
            check("d2xx open sequence", names[:8],
                  ["resetDevice", "purge", "setUSBParameters", "setChars", "setTimeouts",
                   "setLatencyTimer", "setFlowControl", "setBitMode"])
            check("d2xx goes to MPSSE", [c for c in dev.calls if c[0] == "setBitMode"],
                  [("setBitMode", 0x00, 0), ("setBitMode", 0xEB, 2)])

    # 30 MHz and a partial USB write and read
    for kind in ("pyftdi", "d2xx"):
        m, dev, backend = make_stack(kind, FpgaLink(0), max_write=7, max_read=2)
        j = zj.Jtag(backend, 30e6)
        check(kind + ": 30 MHz divisor on the wire", m.div, 0)
        j.ir_scan(zj.IR_USER3)
        got = j.dr_scan_batch([0x141, 0x000, 0x3FF], 10)
        check(kind + ": short USB writes and reads lose nothing", got, [0, 0, 0])
        check(kind + ": TAP is in USER3", m.ir, zj.IR_USER3)

    # a batch longer than max_batch is split, and the answers stay in order
    fpga = FpgaLink(0)
    m, dev, backend = make_stack("pyftdi", fpga)
    j = zj.Jtag(backend, 6e6)
    j.max_batch = 8
    j.ir_scan(zj.IR_USER3)
    fpga.out_queue.extend(range(40))
    got = j.dr_scan_batch([0] * 30, 10)
    check("batches of 8 keep the order", [w & 0xFF for w in got if w & 0x100], list(range(30)))
    check("a batch of 30 at 8 is four writes", sum(1 for c in m.commands if c[0] == 0x87), 1 + 1 + 1 + 4)

    # a dead MPSSE is reported
    class Dead(FakeMpsse):
        def write(self, data):
            self.log += data
    dead = Dead(FpgaLink(0))
    backend = zj.PyftdiBackend(ftdi=FakePyftdi(dead))
    try:
        zj.Jtag(backend, 6e6)
        raised = False
    except (IOError, TimeoutError):
        raised = True
    check("a silent device raises", raised, True)

    check("unknown back end", _raises(ValueError, zj.open_backend, "libftdi"), True)


def _raises(exc, fn, *a):
    try:
        fn(*a)
    except exc:
        return True
    return False


# ---------------------------------------------------------------- the whole

def test_whole_stack():
    for kind in ("pyftdi", "d2xx"):
        for free_after, batch in ((0, 32), (2, 8), (4, 32)):
            rng = random.Random(100 + free_after)
            fpga = FpgaLink(free_after)
            m, dev, backend = make_stack(kind, fpga, max_write=4000)
            j = zj.Jtag(backend, 6e6)
            j.ir_scan(zj.IR_USER3)
            link = zb.JtagLink(lambda words: j.dr_scan_batch(words, 10), batch=batch, max_idle=10000)
            sent, want_rx, got_rx, owed = [], [], [], 0
            for _ in range(40):
                data = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 100)))
                more = [rng.randrange(256) for _ in range(rng.randrange(0, 6))]
                fpga.out_queue.extend(more)
                want_rx.extend(more)
                owed += len(more)
                link.write(data)
                sent.extend(data)
                if owed and rng.random() < 0.5:
                    got_rx.extend(link.read(owed))
                    owed = 0
            got_rx.extend(link.read(owed))
            for _ in range(20):
                fpga.tick()
            tag = "%s free_after=%d batch=%d" % (kind, free_after, batch)
            check("whole stack, to the unit: " + tag, fpga.received, sent)
            check("whole stack, from the unit: " + tag, got_rx, want_rx)
            if free_after:
                check("whole stack, rejects happened: " + tag, fpga.rejects > 0, True)
            j.close()


FAKE_SIM = """
import sys
sys.path.insert(0, %r)
from test_z80dbg_jtag import FpgaLink
f = FpgaLink(3)
f.out_queue.extend(b"hello")
print("READY", flush=True)
for line in sys.stdin:
    w = line.split()
    if not w:
        continue
    if w[0] == "Q":
        break
    if w[0] == "J":
        r = f.scan([int(x, 16) for x in w[1:]])
        print("JR " + " ".join("%%03x" %% x for x in r), flush=True)
    elif w[0] == "R":
        for _ in range(int(w[1]) // 10):
            f.tick()
        print("RECV", flush=True)
"""


def test_vvp_line_protocol():
    """VvpJtagTransport against a stand-in for the simulation that speaks the
    line protocol (J, R, Q, READY)."""
    import tempfile
    here = os.path.dirname(os.path.abspath(__file__))
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "fake_sim.py")
        with open(path, "w") as f:
            f.write(FAKE_SIM % here)
        t = zb.VvpJtagTransport(path, vvp=sys.executable)
        check("sim: unit bytes through J scans", t.read(5), b"hello")
        t.write(b"0123456789" * 5)
        t.idle(0.0001)
        check("sim: buffer empty after idle", bytes(t.rx), b"")
        t.close()
        check("sim: exit status", t.proc.returncode, 0)


def main():
    test_link_model()
    test_link_cases()
    test_mpsse_bytes()
    test_whole_stack()
    test_vvp_line_protocol()
    print("%s: %d checks, JTAG link, MPSSE driver and bridge transport, no RTL"
          % ("PASS" if not fails else "FAIL", checks))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
