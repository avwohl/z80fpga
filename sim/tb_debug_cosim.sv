// The debug unit's SoC as a co-simulation server: the simulation reads
// commands on standard input, runs the RTL, and prints what the debug unit
// sent on standard output.  tools/z80dbg_bridge.py drives this to prove the
// bridge against the real RTL, not against a model of it (test_z80dbg_bridge.py).
//
// Input, one command per line, bytes in hex:
//   S b0 b1 ...    drive the bytes into dbg_rx, then run until dbg_tx has been
//                  quiet for QUIET clocks, so a whole reply has come out
//   R n            run n clocks (decimal); the target runs meanwhile
//   Q              stop
// Output, after each command:
//   RECV b0 b1 ... every byte dbg_tx sent meanwhile, in hex, possibly none
//
// With -DDBG_JTAG (sim/tb_debug_cosim_jtag.vvp) the debug unit's bytes travel
// over the JTAG link of rtl/soc/dbg_jtag_link.sv instead of the serial pair:
//   J w0 w1 ...    one DR scan per word, back to back: Select-DR, Capture-DR,
//                  10 x Shift-DR, Exit1-DR, Update-DR, one Run-Test/Idle, bit 0
//                  first.  wi is the 10-bit word shifted in, in hex, 1 to 3
//                  digits ({reserved, HV, byte}).
//   X              a TAP reset (five TCK cycles with the TAP reset signal
//                  high): clears the link's sticky flag and captured flags.
//                  The answer is "XR".
// and the answer to J is one line
//   JR r0 r1 ...   the 10-bit word each scan captured, 3 hex digits each
//                  ({RJ, FV, byte}); FV = 1 means the scan took that byte.
// S is not supported in that build: the serial pair does not exist, and the
// answer is "ERR S needs the serial build" after the rest of the line is read.
// R n still answers RECV with no bytes.  The scans assume the instruction USER3
// is already loaded (sel is 1 from the start); a TAP reset is applied before
// READY.
// Clocks: the unit runs at 1 MHz (period 1000 ns) and runs on during the scans;
// TCK has a period of 13700 ns (73 kHz), which is not a multiple of the unit's
// and is 13.7 unit clocks, about the board's ratio (6 MHz TCK to 81.25 MHz).  One
// scan is 15 TCK cycles, 205.5 us, 205.5 unit clocks.
//
// Time stands still between commands, so the host can think as long as it
// likes without the target running on.  The SoC is the one of tb_debug.sv with
// RAM in block RAM and DBG_HALT_ON_RESET set, so the target is stopped at 0000H
// when the first command arrives.

`timescale 1ns/1ps

module tb_debug_cosim;

  localparam int CLK_HZ = 1_000_000;
  localparam int DBAUD  = 125_000;
  localparam int DDIV   = CLK_HZ / DBAUD;
  localparam int QUIET  = 600;

  logic       clk = 0, rst_n = 0;
  logic       dbg_rx = 1, dbg_tx;
`ifdef DBG_JTAG
  localparam bit JTAG = 1'b1;
`else
  localparam bit JTAG = 1'b0;
`endif
  localparam int TCKP = 13700;           // ns
  logic       jt_tck = 0, jt_sel = 1, jt_capture = 0, jt_shift = 0;
  logic       jt_update = 0, jt_tdi = 0, jt_reset = 0, jt_tdo;
  logic       uart_rx = 1, uart_tx;
  logic [7:0] led;

  z80_soc #(
      .CLK_HZ    (CLK_HZ),
      .CPU_DIV   (1),
      .ROM_BANKS (1),
      .RAM_BANKS (2),
      .DEBUG_UNIT (1'b1),
      .DBG_BAUD  (DBAUD),
      .DBG_BP_N  (4),
      .DBG_HALT_ON_RESET (1'b1),
      .DBG_JTAG  (JTAG),
      .ROM_INIT  ("sw/boot.hex"),
      .UCODE_MEM ("rtl/core/z80_ucode.mem"),
      .DISP_MEM  ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n),
      .uart_rx (uart_rx), .uart_tx (uart_tx),
      .dbg_rx (dbg_rx), .dbg_tx (dbg_tx),
      .dbg_jt_tck (jt_tck), .dbg_jt_sel (jt_sel),
      .dbg_jt_capture (jt_capture), .dbg_jt_shift (jt_shift),
      .dbg_jt_update (jt_update), .dbg_jt_tdi (jt_tdi),
      .dbg_jt_reset (jt_reset), .dbg_jt_tdo (jt_tdo),
      .led (led), .sw (8'h00)
  );

  always #500 clk = ~clk;

  // bytes from the unit
  logic [7:0] q [0:4095];
  integer     nq = 0;

  task automatic rx_one(output logic [7:0] c);
    integer i;
    begin
      @(negedge dbg_tx);
      repeat (DDIV + DDIV / 2) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        c[i] = dbg_tx;
        repeat (DDIV) @(posedge clk);
      end
    end
  endtask

  logic [7:0] rch;
  initial if (!JTAG) forever begin
    rx_one(rch);
    if (nq < 4096) q[nq] = rch;
    nq = nq + 1;
  end

  // clocks since dbg_tx last moved
  integer idle = 0;
  logic   tx_prev = 1;
  always @(posedge clk) begin
    if (dbg_tx !== tx_prev) idle <= 0;
    else                    idle <= idle + 1;
    tx_prev <= dbg_tx;
  end

  task automatic put(input logic [7:0] b);
    integer i;
    begin
      dbg_rx = 0;
      repeat (DDIV) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        dbg_rx = b[i];
        repeat (DDIV) @(posedge clk);
      end
      dbg_rx = 1;
      repeat (DDIV) @(posedge clk);
    end
  endtask

  // ------------------------------------------------------------- the TAP
  // The host changes the TAP state and tdi while TCK is low and reads tdo just
  // before the rising edge, as the TAP clocks it out on the falling one.
  task automatic jcyc(input logic c, input logic s, input logic u,
                      input logic r, input logic td, output logic b);
    begin
      jt_capture = c; jt_shift = s; jt_update = u; jt_reset = r; jt_tdi = td;
      #(TCKP / 2);
      b = jt_tdo;
      jt_tck = 1;
      #(TCKP - TCKP / 2);
      jt_tck = 0;
    end
  endtask

  task automatic jscan(input logic [9:0] w, output logic [9:0] r);
    logic b;
    integer i;
    begin
      jcyc(0, 0, 0, 0, 0, b);                       // Select-DR
      jcyc(1, 0, 0, 0, 0, b);                       // Capture-DR
      for (i = 0; i < 10; i = i + 1) begin
        jcyc(0, 1, 0, 0, w[i], b);                  // Shift-DR
        r[i] = b;
      end
      jcyc(0, 0, 0, 0, 0, b);                       // Exit1-DR
      jcyc(0, 0, 1, 0, 0, b);                       // Update-DR
      jcyc(0, 0, 0, 0, 0, b);                       // Run-Test/Idle
    end
  endtask

  task automatic jreset;
    logic b;
    integer i;
    begin
      for (i = 0; i < 5; i = i + 1) jcyc(0, 0, 0, 1, 0, b);
    end
  endtask

  task automatic report;
    integer i;
    begin
      $write("RECV");
      for (i = 0; i < nq; i = i + 1) $write(" %02x", q[i]);
      $write("\n");
      $fflush();
      nq = 0;
    end
  endtask

  // ---------------------------------------------------------- the commands
  integer fd, ch, val, have, nw, wi;
  logic [9:0] jw [0:4095];
  logic [9:0] jr [0:4095];
  logic [7:0] cmd;

  function automatic integer hexval(input integer c);
    begin
      if (c >= "0" && c <= "9")      hexval = c - "0";
      else if (c >= "a" && c <= "f") hexval = c - "a" + 10;
      else if (c >= "A" && c <= "F") hexval = c - "A" + 10;
      else                           hexval = -1;
    end
  endfunction

  task automatic quiet_wait;
    begin
      repeat (50) @(posedge clk);
      while (idle < QUIET) @(posedge clk);
    end
  endtask

  initial begin
    // Icarus's descriptor for standard input.  "/dev/stdin" does not exist on
    // a native Windows build of vvp.
    fd = 32'h8000_0000;
    repeat (10) @(posedge clk);
    rst_n = 1;
    if (JTAG) jreset;
    repeat (50) @(posedge clk);
    $write("READY\n");
    $fflush();

    forever begin
      ch = $fgetc(fd);
      while (ch == " " || ch == "\n" || ch == "\r") ch = $fgetc(fd);
      if (ch == -1 || ch == "Q") $finish;
      cmd = ch;
      if (cmd == "J" || cmd == "X" || (cmd == "S" && JTAG)) begin
        // the rest of the line: hex words for J, ignored for the others
        nw = 0;
        ch = $fgetc(fd);
        while (ch != "\n" && ch != -1) begin
          while (ch == " " || ch == "\r") ch = $fgetc(fd);
          have = 0; val = 0;
          while (hexval(ch) >= 0) begin
            val = val * 16 + hexval(ch);
            have = 1;
            ch = $fgetc(fd);
          end
          if (have) begin
            if (nw < 4096) jw[nw] = val[9:0];
            nw = nw + 1;
          end else if (ch != "\n" && ch != -1) ch = $fgetc(fd);
        end
        if (cmd == "J") begin
          for (wi = 0; wi < nw && wi < 4096; wi = wi + 1) jscan(jw[wi], jr[wi]);
          $write("JR");
          for (wi = 0; wi < nw && wi < 4096; wi = wi + 1) $write(" %03x", jr[wi]);
          $write("\n");
        end else if (cmd == "X") begin
          jreset;
          $write("XR\n");
        end else begin
          $write("ERR S needs the serial build\n");
        end
        $fflush();
      end else if (cmd == "S") begin
        // hex bytes to the end of the line
        ch = $fgetc(fd);
        while (ch != "\n" && ch != -1) begin
          while (ch == " " || ch == "\r") ch = $fgetc(fd);
          have = 0; val = 0;
          while (hexval(ch) >= 0) begin
            val = val * 16 + hexval(ch);
            have = 1;
            ch = $fgetc(fd);
          end
          if (have) put(val[7:0]);
          else if (ch != "\n" && ch != -1) ch = $fgetc(fd);
        end
        quiet_wait;
        report;
      end else if (cmd == "R") begin
        val = 0;
        ch = $fgetc(fd);
        while (ch == " ") ch = $fgetc(fd);
        while (ch >= "0" && ch <= "9") begin
          val = val * 10 + (ch - "0");
          ch = $fgetc(fd);
        end
        repeat (val) @(posedge clk);
        report;
      end else begin
        $write("ERR unknown command %c\n", cmd);
        $fflush();
      end
    end
  end

endmodule
