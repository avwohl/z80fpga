// The debug unit on a stock RomWBW ROM: tb_romwbw.sv with DEBUG_UNIT = 1 and a
// host that drives the unit over its serial line (docs/debug_unit.md).
//
// The ROM image is the same one tb_romwbw.sv needs (sim/romwbw512k.hex, see
// the Makefile target "romwbw" and tb_romwbw.sv).  The script:
//   1. The core is stopped at 0000H out of reset.  Read ROM banks through the
//      bank override and compare them with the image.  Step the first
//      instruction (JP 056CH) and check PC.
//   2. Run to a bank-qualified breakpoint in ROM bank 0 at 056CH.
//   3. Remove the breakpoint and let HBIOS run to the boot prompt, with the
//      unit present.  The console must still print the prompt.
//   4. Halt in the prompt loop.  Step twelve times and write down every PC.
//      Put a breakpoint on one of these PCs with a bank that does not match,
//      run, and see that the core does not stop.  Put the same breakpoint with
//      the right bank, run, and see the stop at that PC.  Step once more and
//      see the PC that the first walk recorded.
//
// Needs about the same time as tb_romwbw.sv.

`timescale 1ns/1ps

module tb_romwbw_dbg;

  localparam int CLK_HZ = 1_000_000;
  localparam int BAUD   = 115200;
  localparam int DIV    = CLK_HZ / BAUD;
  localparam int DBAUD  = 125_000;
  localparam int DDIV   = CLK_HZ / DBAUD;
  localparam int NBP    = 4;

  logic       clk = 0, rst_n = 0;
  logic       uart_rx = 1, uart_tx;
  logic       dbg_rx = 1, dbg_tx;
  logic [7:0] led;
  logic [7:0] sw = 8'h00;

  z80_soc #(
      .CLK_HZ       (CLK_HZ),
      .CPU_DIV      (1),
      .BAUD         (BAUD),
      .CONSOLE_SSER (1'b1),
      .ROM_BANKS    (16),
      .RAM_BANKS    (16),
      .DEBUG_UNIT   (1'b1),
      .DBG_BAUD     (DBAUD),
      .DBG_BP_N     (NBP),
      .DBG_HALT_ON_RESET (1'b1),
      .ROM_INIT     ("sim/romwbw512k.hex"),
      .UCODE_MEM    ("rtl/core/z80_ucode.mem"),
      .DISP_MEM     ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n),
      .uart_rx (uart_rx), .uart_tx (uart_tx),
      .dbg_rx (dbg_rx), .dbg_tx (dbg_tx),
      .led (led), .sw (sw)
  );

  always #500 clk = ~clk;

  `include "dbg_host.svh"

  // ------------------------------------------------------- console receiver
  integer        nrx = 0;
  reg [7:0]      ch;
  reg [8*32-1:0] tail = 0;
  reg            seen_prompt = 0;

  task automatic uart_get(output reg [7:0] c);
    integer i;
    begin
      @(negedge uart_tx);
      repeat (DIV + DIV/2) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        c[i] = uart_tx;
        repeat (DIV) @(posedge clk);
      end
    end
  endtask

  initial forever begin
    uart_get(ch);
    nrx = nrx + 1;
    tail = {tail[8*31-1:0], ch};
    if (tail[8*6-1:0] == "Boot [") seen_prompt = 1;
  end

  // ------------------------------------------------------------------ script
  logic [7:0]  rom [0:524287];
  logic [7:0]  st;
  logic [15:0] v, pcs [0:15];
  logic [7:0]  banks [0:15];
  integer      i, j, nb, bad;
  integer      tgt;
  logic [7:0]  tbank;

  // the bank PC uses: the common bank above 8000H, the CPU's selection below
  task automatic pc_bank(input logic [15:0] pc, output logic [7:0] bk);
    logic [15:0] r;
    begin
      rd_reg(15, r);
      bk = pc[15] ? 8'h8F : r[7:0];
    end
  endtask

  initial begin
    $readmemh("sim/romwbw512k.hex", rom);
    repeat (10) @(posedge clk);
    rst_n = 1;
    repeat (50) @(posedge clk);
    wait_stopped("stopped out of reset");
    chk_reg("PC at reset", 11, 16'h0000);

    // ---- 1. ROM banks through the override, against the image
    for (nb = 0; nb < 16; nb = nb + 5) begin
      set_ovr(1, nb);
      rd_mem(16'h0100, 64);
      bad = 0;
      for (i = 0; i < 64; i = i + 1)
        if (mbuf[i] !== rom[nb * 32768 + 16'h0100 + i]) bad = bad + 1;
      chk("ROM bank read through the override matches the image", bad, 0);
      rd_mem(16'h7FC0, 64);
      bad = 0;
      for (i = 0; i < 64; i = i + 1)
        if (mbuf[i] !== rom[nb * 32768 + 16'h7FC0 + i]) bad = bad + 1;
      chk("end of a ROM bank matches the image", bad, 0);
    end
    set_ovr(0, 0);
    rd_mem(16'h0000, 3);
    chk("ROM byte 0", mbuf[0], 8'hC3);
    chk("ROM byte 1", mbuf[1], 8'h6C);
    chk("ROM byte 2", mbuf[2], 8'h05);
    echo_cmd("T", "step echo"); wait_stopped("first step");
    chk_reg("PC after JP 056CH", 11, 16'h056C);
    do_status(st);
    chk("stop reason: step", st[2], 1);

    // ---- 2. run to a bank-qualified breakpoint in ROM bank 0
    wr_reg(11, 16'h0000);
    set_bp(0, 16'h056C, 8'h00, 8'h03);       // flags: enable, compare the bank
    echo_cmd("C", "continue echo");
    wait_stopped("breakpoint in ROM bank 0");
    do_status(st);
    chk("stop reason: breakpoint", st[1], 1);
    chk("breakpoint 0", st[7:5], 0);
    chk_reg("PC at the breakpoint", 11, 16'h056C);
    chk_reg("bank at the breakpoint", 15, 16'h0000);

    // ---- 3. HBIOS to the boot prompt with the unit present and idle
    set_bp(0, 16'h0000, 8'h00, 8'h00);
    echo_cmd("C", "continue echo");
    fork
      begin : watchdog
        repeat (13_000_000) @(posedge clk);
        $display("FAIL: no boot prompt after %0d characters", nrx);
        $finish;
      end
      begin : wait_prompt
        wait (seen_prompt);
        disable watchdog;
      end
    join
    chk("the console printed the boot prompt", seen_prompt, 1);
    repeat (DIV * 40) @(posedge clk);

    // ---- 4. halt in the prompt loop, walk, breakpoints
    echo_cmd("H", "halt echo");
    wait_stopped("halt at the prompt");
    do_status(st);
    chk("stop reason: halt", st[3], 1);
    for (i = 0; i < 12; i = i + 1) begin
      rd_reg(11, v);
      pcs[i] = v;
      pc_bank(v, tbank);
      banks[i] = tbank;
      echo_cmd("T", "step echo"); wait_stopped("walk step");
    end
    rd_reg(11, v);
    pcs[12] = v;
    $display("walk in the prompt loop: %h %h %h %h %h %h %h %h %h %h %h %h %h",
             pcs[0], pcs[1], pcs[2], pcs[3], pcs[4], pcs[5], pcs[6], pcs[7],
             pcs[8], pcs[9], pcs[10], pcs[11], pcs[12]);
    // pick a PC of the walk that is not the PC the walk ends at
    tgt = 5;
    for (j = 0; j < 12; j = j + 1)
      if (pcs[tgt] == pcs[12] || pcs[tgt] == pcs[tgt + 1]) tgt = (tgt + 1) % 11;
    chk("the walk moved", pcs[0] != pcs[1] || pcs[1] != pcs[2], 1);

    // a bank that cannot match: no stop
    set_bp(1, pcs[tgt], 8'h55, 8'h03);
    echo_cmd("C", "continue echo");
    repeat (60000) @(posedge clk);
    do_status(st);
    chk("breakpoint with the wrong bank: the core runs on", st[0], 0);
    echo_cmd("H", "halt echo"); wait_stopped("halt after the wrong-bank run");
    do_status(st);
    chk("that stop is the halt request", st[3], 1);
    chk("not a breakpoint", st[1], 0);

    // the right bank: stop at the PC
    set_bp(1, pcs[tgt], banks[tgt], 8'h03);
    echo_cmd("C", "continue echo");
    wait_stopped("breakpoint in the prompt loop");
    do_status(st);
    chk("stop reason: breakpoint", st[1], 1);
    chk("breakpoint index", st[7:5], 1);
    chk_reg("PC at the breakpoint in the loop", 11, pcs[tgt]);
    echo_cmd("T", "step echo"); wait_stopped("step off the breakpoint");
    chk_reg("PC one step on", 11, pcs[tgt + 1]);
    set_bp(1, 16'h0000, 8'h00, 8'h00);

    // the stack, read at this stop through the CPU's own bank
    rd_reg(10, v);
    chk("SP is not zero", v != 16'h0000, 1);
    rd_mem(v, 8);
    $display("stack at %h: %h %h %h %h %h %h %h %h", v,
             mbuf[0], mbuf[1], mbuf[2], mbuf[3], mbuf[4], mbuf[5], mbuf[6], mbuf[7]);

    $display("");
    if (fails == 0)
      $display("PASS: %0d checks, debug unit on a RomWBW ROM", checks);
    else
      $display("FAIL: %0d of %0d checks failed", fails, checks);
    $finish;
  end

endmodule
