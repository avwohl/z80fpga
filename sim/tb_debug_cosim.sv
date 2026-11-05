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
      .ROM_INIT  ("sw/boot.hex"),
      .UCODE_MEM ("rtl/core/z80_ucode.mem"),
      .DISP_MEM  ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n),
      .uart_rx (uart_rx), .uart_tx (uart_tx),
      .dbg_rx (dbg_rx), .dbg_tx (dbg_tx),
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
  initial forever begin
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
  integer fd, ch, val, have;
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
    repeat (50) @(posedge clk);
    $write("READY\n");
    $fflush();

    forever begin
      ch = $fgetc(fd);
      while (ch == " " || ch == "\n" || ch == "\r") ch = $fgetc(fd);
      if (ch == -1 || ch == "Q") $finish;
      cmd = ch;
      if (cmd == "S") begin
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
