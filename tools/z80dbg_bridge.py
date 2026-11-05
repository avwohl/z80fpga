#!/usr/bin/env python3
"""Bridge from GDB's remote serial protocol (RSP) to z80fpga's debug unit.

  python3 tools/z80dbg_bridge.py --serial /dev/cu.usbserial-XXXX --listen 1234
  python3 tools/z80dbg_bridge.py --vvp sim/tb_debug_cosim.vvp --listen 1234

The debug unit (rtl/soc/dbg_unit.sv) speaks a small binary protocol on a
serial line of its own; docs/debug_unit.md has the whole of it.  This program
turns that into the subset of RSP that cpmemu's stub offers, so GDB and udb80
connect to a z80fpga board the way they connect to cpmemu:

  ? g G p P m M c s Z0 z0 Z1 z1 vCont H T k D qSupported qXfer:features:read
  qRcmd and the byte 03H (stop a running target)

Registers are the 13 of cpmemu's target.xml, all 16 bits wide, pc included.
The unit has four hardware breakpoints, so a fifth Z0 or Z1 answers E0e.
Nothing is written into the target's memory to make a breakpoint.

`monitor` commands, the same words as romwbw_emu's stub where it has them:
  monitor bank XX|cur      show bank XX in the low 32 KB, or the CPU's own
  monitor break-bank XX|off   breakpoints below 8000H apply only in bank XX
  monitor wait-program bytes HEX... | sha256 LENGTH HEX64 | off
                           stop when a program with those bytes starts at
                           0100H in the program bank (8EH, --program-bank)
  monitor status           the unit's state

A stop reply names swbreak or hwbreak only for a client that offered it in
qSupported, and the wait-program stop is a plain T05: no debugger set that
breakpoint, and GDB continues past a swbreak it does not know.

--listen-addr puts the bridge on a network address.  The bridge has no
password, and a client can read and write the target's memory.

--vvp runs the Icarus simulation of the whole SoC as the target, one command
per line over a pipe (sim/tb_debug_cosim.sv), which is how the bridge is tested
without a board.
"""
import argparse
import hashlib
import ipaddress
import os
import select
import socket
import subprocess
import sys
import time

# ---------------------------------------------------------------- the unit

# Register numbers of the unit, and cpmemu's order for the 'g' packet.
R_AF, R_BC, R_DE, R_HL, R_AF2, R_BC2, R_DE2, R_HL2 = range(8)
R_IX, R_IY, R_SP, R_PC, R_IR, R_WZ, R_MISC, R_BANK = range(8, 16)
GDB_REGS = [R_AF, R_BC, R_DE, R_HL, R_SP, R_PC, R_IX, R_IY,
            R_AF2, R_BC2, R_DE2, R_HL2, R_IR]

ERRORS = {1: "target is running", 2: "unknown command", 3: "bad breakpoint number",
          4: "register is read only"}


class UnitError(Exception):
    def __init__(self, code):
        Exception.__init__(self, "debug unit error %02x: %s" %
                           (code, ERRORS.get(code, "?")))
        self.code = code


class Status(object):
    def __init__(self, st, nbp, rev):
        self.stopped = bool(st & 1)
        self.by_bp = bool(st & 2)
        self.by_step = bool(st & 4)
        self.by_halt = bool(st & 8)
        self.override = bool(st & 16)
        self.bp_index = st >> 5
        self.nbp = nbp
        self.rev = rev


class SerialTransport(object):
    """The board's second UART, through pyserial."""

    def __init__(self, device, baud=115200):
        try:
            import serial
        except ImportError:
            raise SystemExit("z80dbg_bridge: --serial needs pyserial (pip install pyserial)")
        self.port = serial.Serial(device, baud, timeout=1.0)

    def write(self, data):
        self.port.write(data)
        self.port.flush()

    def read(self, n):
        data = self.port.read(n)
        if len(data) != n:
            raise TimeoutError("the debug unit did not answer")
        return data

    def idle(self, seconds):
        time.sleep(seconds)
        self.port.reset_input_buffer()

    def close(self):
        self.port.close()


class VvpTransport(object):
    """The simulation of the SoC, one command per line (sim/tb_debug_cosim.sv).

    Simulated time passes only when the bridge talks: while it writes a
    command, while it waits for an answer, and during idle()."""

    CLOCK_HZ = 1000000

    def __init__(self, vvp_file, vvp="vvp", cwd=None):
        self.proc = subprocess.Popen([vvp, vvp_file], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, cwd=cwd,
                                     universal_newlines=True, bufsize=1)
        self.buf = bytearray()
        line = self.proc.stdout.readline().strip()
        if line != "READY":
            raise RuntimeError("the simulation did not start: %r" % line)

    def _command(self, text):
        self.proc.stdin.write(text + "\n")
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("the simulation ended")
            words = line.split()
            if words and words[0] == "RECV":
                self.buf.extend(int(w, 16) for w in words[1:])
                return

    def write(self, data):
        self._command("S " + " ".join("%02x" % b for b in data))

    def read(self, n):
        spins = 0
        while len(self.buf) < n:
            self._command("R 2000")
            spins += 1
            if spins > 50:
                raise TimeoutError("the debug unit did not answer")
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

    def idle(self, seconds):
        self._command("R %d" % int(seconds * self.CLOCK_HZ))
        del self.buf[:]

    def close(self):
        try:
            self.proc.stdin.write("Q\n")
            self.proc.stdin.flush()
        except (OSError, ValueError):
            pass
        self.proc.wait()


class Unit(object):
    """The unit's command set, one method each."""

    def __init__(self, transport):
        self.t = transport

    def _reply(self, op, n):
        first = self.t.read(1)
        if first == b"E":
            raise UnitError(self.t.read(1)[0])
        if first != op:
            raise IOError("debug unit answered %r to %r: out of step" % (first, op))
        return self.t.read(n - 1) if n > 1 else b""

    def sync(self):
        """Silence for longer than the unit's 10 ms timeout drops any half-sent
        command; then N must come back as N."""
        self.t.idle(0.012)
        self.t.write(b"N")
        self._reply(b"N", 1)

    def status(self):
        self.t.write(b"S")
        d = self._reply(b"S", 4)
        return Status(d[0], d[1], d[2])

    def halt(self):
        self.t.write(b"H")
        self._reply(b"H", 1)

    def cont(self):
        self.t.write(b"C")
        self._reply(b"C", 1)

    def step(self):
        self.t.write(b"T")
        self._reply(b"T", 1)

    def read_reg(self, n):
        self.t.write(b"R" + bytes([n]))
        d = self._reply(b"R", 3)
        return d[0] | (d[1] << 8)

    def write_reg(self, n, v):
        self.t.write(b"W" + bytes([n, v & 255, (v >> 8) & 255]))
        self._reply(b"W", 1)

    def read_mem(self, addr, length):
        out = bytearray()
        while length > 0:
            n = min(length, 256)
            self.t.write(b"M" + bytes([addr & 255, (addr >> 8) & 255, n & 255]))
            self._reply(b"M", 1)
            out.extend(self.t.read(n))
            addr += n
            length -= n
        return bytes(out)

    def write_mem(self, addr, data):
        data = bytes(data)
        while data:
            chunk, data = data[:256], data[256:]
            self.t.write(b"P" + bytes([addr & 255, (addr >> 8) & 255,
                                       len(chunk) & 255]) + chunk)
            self._reply(b"P", 1)
            addr += len(chunk)

    def set_bp(self, index, addr, bank=0, enabled=True, bank_q=False):
        flags = (1 if enabled else 0) | (2 if bank_q else 0)
        self.t.write(b"B" + bytes([index, addr & 255, (addr >> 8) & 255, bank, flags]))
        self._reply(b"B", 1)

    def set_override(self, enabled, bank=0):
        self.t.write(b"K" + bytes([1 if enabled else 0, bank]))
        self._reply(b"K", 1)


# ---------------------------------------------------------------------- RSP

TARGET_XML = (
    '<?xml version="1.0"?>\n'
    '<!DOCTYPE target SYSTEM "gdb-target.dtd">\n'
    '<target version="1.0">\n'
    '<architecture>z80</architecture>\n'
    '<feature name="org.gnu.gdb.z80.cpu">\n'
    '  <flags id="af_flags" size="2">\n'
    '    <field name="C" start="0" end="0"/>\n'
    '    <field name="N" start="1" end="1"/>\n'
    '    <field name="P/V" start="2" end="2"/>\n'
    '    <field name="F3" start="3" end="3"/>\n'
    '    <field name="H" start="4" end="4"/>\n'
    '    <field name="F5" start="5" end="5"/>\n'
    '    <field name="Z" start="6" end="6"/>\n'
    '    <field name="S" start="7" end="7"/>\n'
    '  </flags>\n'
    '  <reg name="af" bitsize="16" type="af_flags"/>\n'
    '  <reg name="bc" bitsize="16" type="uint16"/>\n'
    '  <reg name="de" bitsize="16" type="data_ptr"/>\n'
    '  <reg name="hl" bitsize="16" type="data_ptr"/>\n'
    '  <reg name="sp" bitsize="16" type="data_ptr" />\n'
    '  <reg name="pc" bitsize="16" type="code_ptr" />\n'
    '  <reg name="ix" bitsize="16" type="data_ptr"/>\n'
    '  <reg name="iy" bitsize="16" type="data_ptr"/>\n'
    "  <reg name=\"af'\" bitsize=\"16\" type=\"af_flags\"/>\n"
    "  <reg name=\"bc'\" bitsize=\"16\" type=\"uint16\"/>\n"
    "  <reg name=\"de'\" bitsize=\"16\" type=\"data_ptr\"/>\n"
    "  <reg name=\"hl'\" bitsize=\"16\" type=\"data_ptr\"/>\n"
    '  <reg name="ir" bitsize="16" type="uint16"/>\n'
    '</feature>\n'
    '</target>\n')

PACKET_SIZE = 0x4000


def checksum(payload):
    return sum(payload) & 255


def hex16le(v):
    return "%02x%02x" % (v & 255, (v >> 8) & 255)


def parse16le(h):
    return int(h[0:2], 16) | (int(h[2:4], 16) << 8)


class Client(object):
    """One debugger connection: packet framing."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = bytearray()
        self.last = b""
        self.closed = False

    def _fill(self, timeout):
        r, _, _ = select.select([self.sock], [], [], timeout)
        if not r:
            return False
        data = self.sock.recv(4096)
        if not data:
            self.closed = True
            return False
        self.buf.extend(data)
        return True

    def read_packet(self, timeout=None):
        """('pkt', text), ('int', None), ('closed', None) or ('none', None)."""
        while True:
            while self.buf and self.buf[0] in (ord("+"), ord("-")):
                if self.buf[0] == ord("-") and self.last:
                    self.sock.sendall(self.last)
                del self.buf[0]
            if self.buf and self.buf[0] == 3:
                del self.buf[0]
                return "int", None
            if self.buf and self.buf[0] == ord("$"):
                end = self.buf.find(b"#")
                if end >= 0 and len(self.buf) >= end + 3:
                    payload = bytes(self.buf[1:end])
                    cs = int(self.buf[end + 1:end + 3].decode("ascii"), 16)
                    del self.buf[:end + 3]
                    if cs != checksum(payload):
                        self.sock.sendall(b"-")
                        continue
                    self.sock.sendall(b"+")
                    return "pkt", payload.decode("latin-1")
            elif self.buf:
                del self.buf[0]                      # noise between packets
                continue
            if self.closed:
                return "closed", None
            if not self._fill(timeout):
                return ("closed", None) if self.closed else ("none", None)

    def send(self, text):
        payload = text.encode("latin-1")
        self.last = b"$" + payload + b"#" + ("%02x" % checksum(payload)).encode()
        self.sock.sendall(self.last)

    def interrupt_pending(self):
        """True if a ^C is waiting; other bytes stay queued."""
        self._fill(0)
        for i, b in enumerate(self.buf):
            if b == 3:
                del self.buf[i]
                return True
        return False


PROGRAM_ADDR = 0x0100


class Bridge(object):
    def __init__(self, unit, poll=0.005, program_bank=0x8E):
        self.u = unit
        self.poll = poll
        # slot -> (addr, kind): kind 'sw' or 'hw' for a debugger's breakpoint,
        # 'rule' for the slot that monitor wait-program holds
        self.slots = [None] * 8
        self.break_bank = None
        self.view_bank = None
        self.nbp = 4
        self.killed = False
        self.program_bank = program_bank
        self.wait = None                   # None, ('bytes', b) or ('sha256', n, hex)
        self.swbreak_ok = True             # until a qSupported says otherwise
        self.hwbreak_ok = True

    # ------------------------------------------------------------ breakpoints
    def program_bp(self, slot):
        entry = self.slots[slot]
        if entry is None:
            self.u.set_bp(slot, 0, 0, enabled=False)
            return
        addr, kind = entry
        if kind == "rule":
            self.u.set_bp(slot, addr, self.program_bank, True, True)
            return
        q = self.break_bank is not None and addr < 0x8000
        self.u.set_bp(slot, addr, self.break_bank if q else 0, True, q)

    def set_break(self, addr, kind):
        for i in range(self.nbp):
            if self.slots[i] and self.slots[i][1] != "rule" and self.slots[i][0] == addr:
                self.slots[i] = (addr, kind)
                return True
        for i in range(self.nbp):
            if self.slots[i] is None:
                self.slots[i] = (addr, kind)
                self.program_bp(i)
                return True
        return False

    def clear_break(self, addr):
        for i in range(self.nbp):
            if self.slots[i] and self.slots[i][1] != "rule" and self.slots[i][0] == addr:
                self.slots[i] = None
                self.program_bp(i)

    def rule_slot(self):
        for i in range(self.nbp):
            if self.slots[i] and self.slots[i][1] == "rule":
                return i
        return None

    # ----------------------------------------------------------- wait-program
    def arm_wait(self, wait):
        slot = self.rule_slot()
        if slot is None:
            for i in range(self.nbp):
                if self.slots[i] is None:
                    slot = i
                    break
        if slot is None:
            return ("wait-program: no free breakpoint; the unit has %d, and each one "
                    "is in use\n" % self.nbp)
        self.wait = wait
        self.slots[slot] = (PROGRAM_ADDR, "rule")
        self.program_bp(slot)
        return ("wait-program: armed; the next start at %04XH in bank %02X that matches stops\n"
                % (PROGRAM_ADDR, self.program_bank))

    def disarm_wait(self):
        self.wait = None
        slot = self.rule_slot()
        if slot is not None:
            self.slots[slot] = None
            self.program_bp(slot)

    def read_cpu_mem(self, addr, length):
        """Memory as the CPU sees it, whatever monitor bank shows."""
        if self.view_bank is not None:
            self.u.set_override(False)
        try:
            return self.u.read_mem(addr, length)
        finally:
            if self.view_bank is not None:
                self.u.set_override(True, self.view_bank)

    def program_matches(self):
        if self.wait is None:
            return False
        if self.wait[0] == "bytes":
            want = self.wait[1]
            return self.read_cpu_mem(PROGRAM_ADDR, len(want)) == want
        got = self.read_cpu_mem(PROGRAM_ADDR, self.wait[1])
        return hashlib.sha256(got).hexdigest() == self.wait[2]

    def user_break_at(self, pc):
        """A debugger's breakpoint at pc that applies in the CPU's bank now."""
        for i in range(self.nbp):
            e = self.slots[i]
            if e and e[1] != "rule" and e[0] == pc:
                if self.break_bank is None or pc >= 0x8000:
                    return e
                if (self.u.read_reg(R_BANK) & 255) == self.break_bank:
                    return e
        return None

    def monitor_wait_program(self, words):
        if not words:
            if self.wait is None:
                return "wait-program: not armed\n"
            if self.wait[0] == "sha256":
                return "wait-program: armed, %d bytes with SHA-256 %s\n" % (self.wait[1], self.wait[2])
            return "wait-program: armed, %d bytes\n" % len(self.wait[1])
        kind = words[0].lower()
        if kind == "off":
            self.disarm_wait()
            return "wait-program: off\n"
        if kind == "bytes":
            text = "".join(words[1:])
            if not text or len(text) % 2 or len(text) > 2 * 4096:
                return "wait-program bytes: give 1 to 4096 bytes as hex digits\n"
            try:
                want = bytes.fromhex(text)
            except ValueError:
                return "wait-program bytes: not a hex digit\n"
            return self.arm_wait(("bytes", want))
        if kind == "sha256":
            limit = 0xFE00 - PROGRAM_ADDR
            ok = (len(words) == 3 and words[1] != "" and all(ch in "0123456789" for ch in words[1])
                  and 1 <= int(words[1]) <= limit)
            sha = words[2].lower() if len(words) == 3 else ""
            ok = ok and len(sha) == 64 and all(c in "0123456789abcdef" for c in sha)
            if not ok:
                return ("wait-program sha256: give the length in decimal (1 to %d) and "
                        "64 hex digits\n" % limit)
            return self.arm_wait(("sha256", int(words[1]), sha))
        return "wait-program: bytes HEX..., sha256 LENGTH HEX64, or off\n"

    # ------------------------------------------------------------- run control
    def break_reply(self, entry):
        if entry and entry[1] == "hw":
            return "T05hwbreak:;" if self.hwbreak_ok else "T05"
        return "T05swbreak:;" if self.swbreak_ok else "T05"

    def stop_reply(self, st, interrupted):
        """The stop reply, or None: a wait-program stop on a program that does
        not match, after which the run goes on."""
        # A step that lands on a breakpoint's address is a step, not a hit.
        if st.by_bp and not st.by_step:
            entry = self.slots[st.bp_index] if st.bp_index < len(self.slots) else None
            if entry and entry[1] == "rule":
                user = self.user_break_at(PROGRAM_ADDR)
                if user:
                    return self.break_reply(user)     # the debugger's own breakpoint first
                if not self.program_matches():
                    return None
                # One shot.  The program is found, and its breakpoints belong to its bank.
                self.disarm_wait()
                self.break_bank = self.program_bank
                for i in range(self.nbp):
                    if self.slots[i]:
                        self.program_bp(i)
                sys.stderr.write("[z80dbg bridge: the program that wait-program named has "
                                 "started in bank %02X]\n" % self.program_bank)
                return "T05"
            return self.break_reply(entry)
        if interrupted:
            return "T02"
        return "T05"

    def run(self, client, step):
        if step:
            self.u.step()
        else:
            self.u.cont()
        interrupted = False
        while True:
            st = self.u.status()
            if st.stopped:
                reply = self.stop_reply(st, interrupted and not st.by_bp)
                if reply is not None:
                    return reply
                if interrupted:
                    return "T02"
                self.u.cont()                      # not the program: go on
                continue
            if not interrupted and client.interrupt_pending():
                self.u.halt()
                interrupted = True
            elif self.poll:
                time.sleep(self.poll)

    def run_range(self, client, lo, hi):
        """vCont;r: step until PC leaves [lo, hi) or something else stops us."""
        while True:
            reply = self.run(client, True)
            pc = self.u.read_reg(R_PC)
            st = self.u.status()
            if not (lo <= pc < hi) or st.by_bp or reply.startswith("T02"):
                return reply

    # ----------------------------------------------------------------- packets
    def monitor(self, text):
        words = text.split()
        if not words:
            return "\n"
        if words[0] == "bank" and len(words) == 2:
            if words[1] == "cur":
                self.view_bank = None
                self.u.set_override(False)
                return "memory view: the CPU's bank\n"
            self.view_bank = int(words[1], 16)
            self.u.set_override(True, self.view_bank)
            return "memory view: bank %02X in the low 32 KB\n" % self.view_bank
        if words[0] == "break-bank" and len(words) == 2:
            self.break_bank = None if words[1] == "off" else int(words[1], 16)
            for i in range(self.nbp):
                if self.slots[i]:
                    self.program_bp(i)
            return ("breakpoints apply in every bank\n" if self.break_bank is None
                    else "breakpoints below 8000H apply in bank %02X only\n" % self.break_bank)
        if words[0] == "wait-program":
            return self.monitor_wait_program(words[1:])
        if words[0] == "status":
            st = self.u.status()
            pc = self.u.read_reg(R_PC)
            cpu_bank = self.u.read_reg(R_BANK) & 255
            return ("%s pc=%04X cpu-bank=%02X view=%s break-bank=%s breakpoints=%d\n%s" % (
                "stopped" if st.stopped else "running", pc, cpu_bank,
                "cur" if self.view_bank is None else "%02X" % self.view_bank,
                "off" if self.break_bank is None else "%02X" % self.break_bank,
                sum(1 for s in self.slots if s and s[1] != "rule"),
                self.monitor_wait_program([])))
        return "unknown monitor command; try bank, break-bank, wait-program, status\n"

    def handle(self, client, p):
        """Answer one packet.  Returns False when the debugger has gone."""
        if p == "?":
            client.send("T05")
        elif p == "g":
            client.send("".join(hex16le(self.u.read_reg(r)) for r in GDB_REGS))
        elif p[0] == "G":
            h = p[1:]
            if len(h) != 4 * len(GDB_REGS):
                client.send("E01")
            else:
                # GDB sends all 13.  The alternate set has no write port, so a
                # register is written only if it differs from what the unit has,
                # and a changed alternate register is an error.
                for i, r in enumerate(GDB_REGS):
                    v = parse16le(h[4 * i:4 * i + 4])
                    if v != self.u.read_reg(r):
                        self.u.write_reg(r, v)
                client.send("OK")
        elif p[0] == "p":
            n = int(p[1:], 16)
            client.send(hex16le(self.u.read_reg(GDB_REGS[n])) if n < len(GDB_REGS) else "E01")
        elif p[0] == "P":
            n, _, v = p[1:].partition("=")
            n = int(n, 16)
            if n >= len(GDB_REGS) or len(v) != 4:
                client.send("E01")
            else:
                self.u.write_reg(GDB_REGS[n], parse16le(v))
                client.send("OK")
        elif p[0] == "m":
            a, _, n = p[1:].partition(",")
            a, n = int(a, 16), int(n, 16)
            if a >= 0x10000:
                client.send("E01")
            else:
                n = min(n, 0x10000 - a, PACKET_SIZE // 2 - 8)
                client.send(self.u.read_mem(a, n).hex())
        elif p[0] == "M":
            head, _, data = p[1:].partition(":")
            a, _, n = head.partition(",")
            a, n = int(a, 16), int(n, 16)
            if a + n > 0x10000 or len(data) != 2 * n:
                client.send("E01")
            else:
                self.u.write_mem(a, bytes.fromhex(data))
                client.send("OK")
        elif p == "c" or p.startswith("c") and p[1:].isalnum():
            if len(p) > 1:
                self.u.write_reg(R_PC, int(p[1:], 16))
            client.send(self.run(client, False))
        elif p[0] == "s":
            if len(p) > 1:
                self.u.write_reg(R_PC, int(p[1:], 16))
            client.send(self.run(client, True))
        elif p[0] in "Zz" and len(p) > 2 and p[1] in "01":
            kind = "sw" if p[1] == "0" else "hw"
            addr = int(p.split(",")[1], 16)
            if addr >= 0x10000:
                client.send("E01")
            elif p[0] == "Z":
                client.send("OK" if self.set_break(addr, kind) else "E0e")
            else:
                self.clear_break(addr)
                client.send("OK")
        elif p[0] in "Zz":
            client.send("")                      # watchpoints: the unit has none
        elif p == "vCont?":
            client.send("vCont;c;C;s;S;r")
        elif p.startswith("vCont;"):
            act = p[6:].split(";")[0].split(":")[0]       # drop the ":thread"
            if act[0] in "cC":
                client.send(self.run(client, False))
            elif act[0] in "sS":
                client.send(self.run(client, True))
            elif act[0] == "r":
                lo, hi = act[1:].split(",")
                client.send(self.run_range(client, int(lo, 16), int(hi, 16)))
            else:
                client.send("E01")
        elif p == "vMustReplyEmpty":
            client.send("")
        elif p[0] in "HT":
            client.send("OK")
        elif p.startswith("qSupported"):
            # A stop reason only for a client that asked for it (the RSP rule).
            self.swbreak_ok = "swbreak+" in p
            self.hwbreak_ok = "hwbreak+" in p
            client.send("PacketSize=%x;qXfer:features:read+;swbreak+;hwbreak+;vContSupported+"
                        % PACKET_SIZE)
        elif p == "qAttached":
            client.send("1")
        elif p == "qC":
            client.send("QC1")
        elif p == "qfThreadInfo":
            client.send("m1")
        elif p == "qsThreadInfo":
            client.send("l")
        elif p.startswith("qXfer:features:read:target.xml:"):
            off, _, ln = p.split(":")[-1].partition(",")
            off, ln = int(off, 16), int(ln, 16)
            if off >= len(TARGET_XML):
                client.send("l")
            else:
                chunk = TARGET_XML[off:off + min(ln, PACKET_SIZE - 16)]
                client.send(("m" if off + len(chunk) < len(TARGET_XML) else "l") + chunk)
        elif p.startswith("qRcmd,"):
            text = bytes.fromhex(p[6:]).decode("latin-1")
            client.send(self.monitor(text).encode("latin-1").hex())
        elif p == "k":
            self.killed = True
            return False
        elif p == "D":
            client.send("OK")
            if self.u.status().stopped:
                self.u.cont()
            return False
        else:
            client.send("")
        return True

    def serve(self, sock):
        client = Client(sock)
        while True:
            kind, p = client.read_packet(None)
            if kind == "closed":
                return
            if kind == "pkt":
                try:
                    if not self.handle(client, p):
                        return
                except UnitError as e:
                    sys.stderr.write("z80dbg bridge: %s\n" % e)
                    client.send("E01")
                except ValueError as e:
                    # A packet or a monitor word that does not parse (a bad hex
                    # number): an error reply, never the end of the bridge.
                    sys.stderr.write("z80dbg bridge: bad packet %r: %s\n" % (p[:40], e))
                    client.send("E01")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--serial", help="serial device of the unit's UART")
    src.add_argument("--vvp", help="simulation to drive (sim/tb_debug_cosim.vvp)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--listen", type=int, default=1234, help="TCP port (0: any)")
    ap.add_argument("--listen-addr", default="127.0.0.1",
                    help="IPv4 address to listen on: 127.0.0.1 (the default), 0.0.0.0 for "
                         "every interface, or the address of one interface.  No password: "
                         "anyone who reaches it controls the target")
    ap.add_argument("--program-bank", default="8E",
                    help="the bank in hex that monitor wait-program waits in (default 8E, "
                         "where RomWBW's CP/M 2.2 runs a program)")
    ap.add_argument("--port-file", help="write the port number here")
    a = ap.parse_args()
    try:
        addr = ipaddress.IPv4Address(a.listen_addr)
    except ValueError:
        ap.error("--listen-addr %s: the address is an IPv4 address such as 0.0.0.0 or "
                 "192.168.1.5" % a.listen_addr)
    try:
        program_bank = int(a.program_bank, 16)
        if not 0 <= program_bank <= 255:
            raise ValueError
    except ValueError:
        ap.error("--program-bank %s: a bank number in hex, 00 to FF" % a.program_bank)

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if a.vvp:
        transport = VvpTransport(a.vvp, cwd=root)
        poll = 0
    else:
        transport = SerialTransport(a.serial, a.baud)
        poll = 0.005
    unit = Unit(transport)
    unit.sync()
    bridge = Bridge(unit, poll, program_bank)

    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind((str(addr), a.listen))
    ls.listen(1)
    port = ls.getsockname()[1]
    if not addr in ipaddress.IPv4Network("127.0.0.0/8"):
        sys.stderr.write("z80dbg bridge: WARNING: listening on %s, not on 127.0.0.1.  The bridge "
                         "has no password.\nAnyone who can reach this address can read and "
                         "write the target's memory and control it.\nUse it on a network you "
                         "trust.\n" % addr)
    sys.stderr.write("z80dbg bridge listening on %s:%d\n" % (addr, port))
    if a.port_file:
        with open(a.port_file, "w") as f:
            f.write("%d\n" % port)
    try:
        while not bridge.killed:
            conn, _ = ls.accept()
            try:
                bridge.serve(conn)
            finally:
                conn.close()
    finally:
        transport.close()


if __name__ == "__main__":
    main()
