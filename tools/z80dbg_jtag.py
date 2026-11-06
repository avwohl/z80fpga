#!/usr/bin/env python3
"""A small JTAG driver over the FTDI MPSSE, for the debug unit's JTAG link.

  python3 tools/z80dbg_jtag.py --check          read IDCODE, scan USER3 once
  python3 tools/z80dbg_jtag.py --check --backend d2xx --freq 15e6

The board is the Nexys A7: an FT2232H whose channel A (interface 1) is wired
to the FPGA's TCK, TDI, TDO and TMS (ADBUS0 to ADBUS3).  The GPIO values that
Digilent's cable needs are the ones of openFPGALoader's "digilent" cable
(src/cable.hpp, FTDI_SER(0x0403, 0x6010, FTDI_INTF_A, 0xe8, 0xeb, 0x00, 0x60)).

Two back ends give the same small byte interface (open, write, read, close):
  PyftdiBackend   pyftdi over libusb: macOS and Linux
  D2xxBackend     FTDI's D2XX driver through the ftd2xx package: the Windows
                  path, which works next to the driver that Vivado uses

Jtag does the TAP state machine, an IR scan, a DR scan, and DR scans in
batches: many scans go to the device in one USB write, and their answers come
back in one USB read.  The TAP is in Run-Test/Idle between calls.
"""
import math
import argparse
import sys
import time

# Digilent's GPIO settings (openFPGALoader, cable "digilent"):
# the low byte is ADBUS7..0, the high byte ACBUS7..0.
DIGILENT = dict(vid=0x0403, pid=0x6010, interface=1,
                low_val=0xE8, low_dir=0xEB, high_val=0x00, high_dir=0x60)

# MPSSE opcodes
SET_LOW = 0x80
SET_HIGH = 0x82
LOOPBACK_OFF = 0x85
SET_DIVISOR = 0x86
SEND_NOW = 0x87
DIV5_OFF = 0x8A
THREE_PHASE_OFF = 0x8D
ADAPTIVE_OFF = 0x97
BAD_COMMAND = 0xAA
TMS_WRITE = 0x4B        # TMS, LSB first, out on the falling edge
TMS_RW = 0x6B           # the same, TDO read on the rising edge
DATA_BYTES_RW = 0x39    # TDI out on the falling edge, TDO in on the rising, LSB first
DATA_BITS_RW = 0x3B     # the same, 1 to 8 bits

IR_IDCODE = 0x09
IR_USER3 = 0x22         # 7-series, IR length 6
IR_LEN = 6
BASE_HZ = 60000000      # the clock of the FT2232H with the divide by 5 off
MAX_BATCH = 200         # scans of 10 bits per USB trip: 13 bytes out, 3 in each

DEFAULT_URL = "ftdi://0x0403:0x6010/1"


# ---------------------------------------------------------------- back ends

class PyftdiBackend(object):
    """pyftdi.  `ftdi` is for tests: an object with pyftdi's Ftdi methods."""

    def __init__(self, url=DEFAULT_URL, freq=6e6, ftdi=None, cfg=DIGILENT):
        if ftdi is None:
            try:
                from pyftdi.ftdi import Ftdi
            except ImportError:
                raise SystemExit("z80dbg_jtag: the pyftdi back end needs pyftdi "
                                 "(pip install pyftdi)")
            ftdi = Ftdi()
        self.f = ftdi
        self.f.open_mpsse_from_url(url, direction=cfg["low_dir"], initial=cfg["low_val"],
                                   frequency=freq, latency=16)

    def write(self, data):
        data = bytes(data)
        done = 0
        while done < len(data):
            n = self.f.write_data(data[done:])
            if n <= 0:
                raise IOError("USB write to the FTDI failed")
            done += n

    def read(self, n, timeout=2.0):
        out = bytearray()
        end = time.monotonic() + timeout
        while len(out) < n:
            out += self.f.read_data_bytes(n - len(out), attempt=4)
            if len(out) < n and time.monotonic() > end:
                raise TimeoutError("the FTDI returned %d of %d bytes" % (len(out), n))
        return bytes(out)

    def purge(self):
        self.f.purge_buffers()

    def close(self):
        self.f.close()


class D2xxBackend(object):
    """FTDI D2XX through the ftd2xx package.  `dev` is for tests: an object
    with the ftd2xx.FTD2XX methods."""

    FLOW_RTS_CTS = 0x0100
    BITMODE_RESET = 0x00
    BITMODE_MPSSE = 0x02

    def __init__(self, index=None, freq=6e6, dev=None):
        if dev is None:
            try:
                import ftd2xx
            except ImportError:
                raise SystemExit("z80dbg_jtag: the d2xx back end needs ftd2xx "
                                 "(pip install ftd2xx) and FTDI's D2XX driver")
            if index is None:
                index = d2xx_channel_a(ftd2xx)
            dev = ftd2xx.open(int(index))
        self.d = dev
        d = self.d
        d.resetDevice()
        d.purge()
        d.setUSBParameters(65536, 65536)
        d.setChars(0, 0, 0, 0)
        d.setTimeouts(3000, 3000)
        d.setLatencyTimer(16)
        d.setFlowControl(self.FLOW_RTS_CTS, 0, 0)
        d.setBitMode(0x00, self.BITMODE_RESET)
        d.setBitMode(DIGILENT["low_dir"], self.BITMODE_MPSSE)
        time.sleep(0.05)
        d.purge()

    def write(self, data):
        data = bytes(data)
        done = 0
        while done < len(data):
            n = self.d.write(data[done:])
            if n <= 0:
                raise IOError("USB write to the FTDI failed")
            done += n

    def read(self, n, timeout=2.0):
        out = bytearray()
        end = time.monotonic() + timeout
        while len(out) < n:
            out += self.d.read(n - len(out))
            if len(out) < n and time.monotonic() > end:
                raise TimeoutError("the FTDI returned %d of %d bytes" % (len(out), n))
        return bytes(out)

    def purge(self):
        self.d.purge()

    def close(self):
        self.d.close()


def d2xx_channel_a(ftd2xx):
    """The D2XX index of channel A of the first FT2232.  The index order is
    the driver's, not the chip's: on Windows 11 with the Digilent driver the
    Nexys A7 lists "Digilent USB Device B" (the UART) as 0 and A as 1.  The
    driver names the channels with a final A or B, in the description and the
    serial number."""
    for i in range(len(ftd2xx.listDevices() or [])):
        info = ftd2xx.getDeviceInfoDetail(i)
        if info["description"].endswith(b" A") or info["serial"].endswith(b"A"):
            return i
    raise SystemExit("z80dbg_jtag: no FTDI channel A (is the board on USB?); "
                     "--url N names a D2XX index")


def open_backend(name, url=None, freq=6e6):
    """name is pyftdi or d2xx.  url is a pyftdi URL, or for d2xx the index of
    the D2XX device; without one, d2xx takes channel A of the first FT2232."""
    if name == "pyftdi":
        return PyftdiBackend(url or DEFAULT_URL, freq)
    if name == "d2xx":
        return D2xxBackend(int(url) if url not in (None, "") else None, freq)
    raise ValueError("unknown JTAG back end %r: pyftdi or d2xx" % name)


# ---------------------------------------------------------------- the driver

def divisor_for(freq):
    """The MPSSE divisor and the clock that it gives, for the 60 MHz base."""
    if not freq > 0:
        raise ValueError("the TCK frequency must be above 0")
    # round the divisor up, so the clock never exceeds the request
    div = int(math.ceil(BASE_HZ / 2.0 / float(freq) - 1e-9)) - 1
    div = max(0, min(65535, div))
    return div, BASE_HZ / 2.0 / (div + 1)


class Jtag(object):
    """JTAG on an MPSSE.  backend has write(bytes) and read(n)."""

    def __init__(self, backend, freq=6e6, ir_len=IR_LEN, cfg=DIGILENT):
        self.b = backend
        self.ir_len = ir_len
        self.div, self.freq = divisor_for(freq)
        self.max_batch = MAX_BATCH
        b = bytearray()
        b += bytes((SET_LOW, cfg["low_val"], cfg["low_dir"]))
        b += bytes((SET_HIGH, cfg["high_val"], cfg["high_dir"]))
        b += bytes((LOOPBACK_OFF, DIV5_OFF, ADAPTIVE_OFF, THREE_PHASE_OFF))
        b += bytes((SET_DIVISOR, self.div & 0xFF, self.div >> 8))
        try:
            self._init(b)
        except BaseException:
            self.b.close()
            raise

    def _init(self, b):
        self.b.write(b)
        # A bad opcode comes back as FA and the opcode: the proof that the
        # MPSSE is awake and that the host and the chip are in step.
        self.b.write(bytes((BAD_COMMAND, SEND_NOW)))
        got = self.b.read(2)
        if got != bytes((0xFA, BAD_COMMAND)):
            raise IOError("the MPSSE did not answer the bad-command check: %s" % got.hex())
        self.reset()

    # -- command builders: each returns (bytes to send, reads to expect)
    # reads is a list of ("b", n) for n whole bytes or ("t", n) for the n
    # left-justified bits of one byte.

    @staticmethod
    def _tms(bits, tms):
        """TMS out for `bits` clocks (1 to 7), value `tms`, LSB first."""
        return bytes((TMS_WRITE, bits - 1, tms))

    @staticmethod
    def _shift(value, nbits, head):
        """Shift nbits of value (LSB first) from Run-Test/Idle: the TMS
        sequence `head` into Shift-xR, the data, and Exit1, Update, Idle."""
        out = bytearray(head)
        reads = []
        m = nbits - 1                   # all bits but the last keep TMS at 0
        nbytes, rest = m // 8, m % 8
        if nbytes:
            out += bytes((DATA_BYTES_RW, (nbytes - 1) & 0xFF, (nbytes - 1) >> 8))
            out += (value & ((1 << (8 * nbytes)) - 1)).to_bytes(nbytes, "little")
            reads.append(("b", nbytes))
        if rest:
            out += bytes((DATA_BITS_RW, rest - 1, (value >> (8 * nbytes)) & ((1 << rest) - 1)))
            reads.append(("t", rest))
        last = (value >> m) & 1
        # The last bit goes with TMS = 1 (to Exit1), then TMS 1 (Update) and
        # 0 (Idle).  TDI holds the last bit for all three clocks.
        out += bytes((TMS_RW, 2, (last << 7) | 0x03))
        reads.append(("t", 3))
        return bytes(out), reads

    def _dr_cmds(self, value, nbits):
        return self._shift(value, nbits, bytes((TMS_WRITE, 2, 0x01)))      # 1,0,0

    def _ir_cmds(self, value, nbits):
        return self._shift(value, nbits, bytes((TMS_WRITE, 3, 0x03)))      # 1,1,0,0

    @staticmethod
    def _parse(data, reads, nbits):
        value, pos, shift = 0, 0, 0
        for kind, n in reads:
            if kind == "b":
                value |= int.from_bytes(data[pos:pos + n], "little") << shift
                pos += n
                shift += 8 * n
            else:
                byte = data[pos]
                pos += 1
                if n == 3:              # the last bit and two ignored ones
                    value |= ((byte >> 5) & 1) << shift
                    shift += 1
                else:
                    value |= (byte >> (8 - n)) << shift
                    shift += n
        return value, pos

    # -- operations

    def reset(self):
        """TMS high for five clocks (Test-Logic-Reset), then low (Idle)."""
        self.b.write(self._tms(6, 0x1F) + bytes((SEND_NOW,)))

    def ir_scan(self, value, nbits=None):
        nbits = nbits or self.ir_len
        cmds, reads = self._ir_cmds(value, nbits)
        self.b.write(cmds + bytes((SEND_NOW,)))
        data = self.b.read(sum(n if k == "b" else 1 for k, n in reads))
        return self._parse(data, reads, nbits)[0]

    def dr_scan(self, value, nbits):
        return self.dr_scan_batch([value], nbits)[0]

    def dr_scan_batch(self, values, nbits=10):
        """One DR scan per value, in order, from Run-Test/Idle each time.
        Returns the captured values.  At most max_batch scans go to the device
        in one trip, so that its 4 KB FIFOs never fill."""
        out = []
        for i in range(0, len(values), self.max_batch):
            chunk = values[i:i + self.max_batch]
            blob = bytearray()
            plan = []
            for v in chunk:
                cmds, reads = self._dr_cmds(v, nbits)
                blob += cmds
                plan.append(reads)
            blob.append(SEND_NOW)
            self.b.write(blob)
            nread = sum(sum(n if k == "b" else 1 for k, n in r) for r in plan)
            data = self.b.read(nread)
            pos = 0
            for reads in plan:
                v, used = self._parse(data[pos:], reads, nbits)
                out.append(v)
                pos += used
        return out

    def idcode(self):
        """The IDCODE instruction, then 32 bits of DR."""
        self.ir_scan(IR_IDCODE)
        return self.dr_scan(0, 32)

    def close(self):
        self.b.close()


# ---------------------------------------------------------------- hardware check

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="read IDCODE, then scan USER3")
    ap.add_argument("--backend", choices=("pyftdi", "d2xx"), default="pyftdi")
    ap.add_argument("--url", help="pyftdi URL (default %s) or the d2xx device index" % DEFAULT_URL)
    ap.add_argument("--freq", type=float, default=6e6, help="TCK in Hz (default 6e6, the clock never exceeds this; at most 30e6)")
    ap.add_argument("--expect", default="0x3631093", help="the IDCODE to compare with, with or without the version nibble")
    a = ap.parse_args()
    if not a.check:
        ap.error("nothing to do: --check")
    j = Jtag(open_backend(a.backend, a.url, a.freq), a.freq)
    try:
        print("TCK %.3f MHz (divisor %d)" % (j.freq / 1e6, j.div))
        idc = j.idcode()
        want = int(a.expect, 0)
        # openFPGALoader prints the IDCODE without its 4-bit version field
        # (0x3631093 for the XC7A100T, whose IDCODE register reads 0x13631093).
        ok = idc == want or (idc & 0x0FFFFFFF) == want
        print("IDCODE 0x%08x (without the version nibble 0x%07x), expected 0x%07x: %s"
              % (idc, idc & 0x0FFFFFFF, want, "match" if ok else "MISMATCH"))
        ir = j.ir_scan(IR_USER3)
        print("IR capture on USER3 scan: 0x%02x" % ir)
        words = [0x000, 0x1A5, 0x100, 0x3FF, 0x000]
        got = j.dr_scan_batch(words, 10)
        print("USER3 DR scans (10 bits): sent " + " ".join("%03x" % w for w in words))
        print("                          got  " + " ".join("%03x" % w for w in got))
        j.reset()
        sys.exit(0 if ok else 1)
    finally:
        j.close()


if __name__ == "__main__":
    main()
