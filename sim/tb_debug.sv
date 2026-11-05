// The debug unit (rtl/soc/dbg_unit.sv) driven over its serial line, against
// the whole SoC and a small program (sim/dbg_prog.z80).
//
// The bench plays the host: it sends the protocol's command bytes bit by bit
// on dbg_rx, collects the replies from dbg_tx, and checks every answer
// against a value worked out by hand from the program's listing.  It covers
// halt, the register file in both directions, memory in both directions
// (RAM, ROM, another bank through the override), a PC breakpoint, a
// bank-qualified breakpoint that must miss and then hit, single steps
// including a prefixed instruction, a halt request on a running core, the
// error replies, and the timeout that abandons a half-sent command.
//
// Parameters pick the variant, and the Makefile builds three:
//   CPU_DIV  1 is the plain case; 3 puts clk_en ticks between the clocks, so
//            the stop has to land on an enable tick and not on a clock.
//   DDR2     1 puts the RAM in DDR2 behind a behavioural AXI slave with
//            wandering latency.  The program's stack is then in DDR2, and the
//            unit reads and writes it through the same wait-state path the
//            CPU uses.
//   HOR      1 is DBG_HALT_ON_RESET: stopped at 0000H out of reset.  0 lets
//            the boot monitor run first and halts it in flight.

`timescale 1ns/1ps

// The variants are chosen on the iverilog command line, -DDBG_CPU_DIV=3 and so
// on, because Icarus 13 does not take -P for a parameter of this module.
`ifndef DBG_CPU_DIV
`define DBG_CPU_DIV 1
`endif
`ifndef DBG_DDR2
`define DBG_DDR2 0
`endif
`ifndef DBG_HOR
`define DBG_HOR 1
`endif

module tb_debug #(
    parameter int CPU_DIV = `DBG_CPU_DIV,
    parameter int DDR2    = `DBG_DDR2,
    parameter int HOR     = `DBG_HOR
);

  localparam int CLK_HZ  = 1_000_000;
  localparam int DBAUD   = 125_000;                // 8 clocks per bit
  localparam int DDIV    = CLK_HZ / DBAUD;

  logic       clk = 0, rst_n = 0;
  logic       uart_rx = 1, uart_tx;
  logic       dbg_rx = 1, dbg_tx;
  logic [7:0] led;
  logic [7:0] sw = 8'h00;

  logic [26:0]  awaddr, araddr;
  logic         awvalid, awready, wvalid, wready, bvalid, bready;
  logic         arvalid, arready, rvalid, rready;
  logic [127:0] wdata, rdata;
  logic [15:0]  wstrb;

  z80_soc #(
      .CLK_HZ    (CLK_HZ),
      .CPU_DIV   (CPU_DIV),
      .BAUD      (115200),
      .USE_DDR2  (DDR2 != 0),
      .ROM_BANKS (1),
      .RAM_BANKS (2),
      .DEBUG_UNIT (1'b1),
      .DBG_BAUD  (DBAUD),
      .DBG_BP_N  (4),
      .DBG_HALT_ON_RESET (HOR != 0),
      .ROM_INIT  ("sw/boot.hex"),
      .UCODE_MEM ("rtl/core/z80_ucode.mem"),
      .DISP_MEM  ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n),
      .uart_rx (uart_rx), .uart_tx (uart_tx),
      .dbg_rx (dbg_rx), .dbg_tx (dbg_tx),
      .led (led), .sw (sw),
      .m_axi_awaddr (awaddr), .m_axi_awvalid (awvalid), .m_axi_awready (awready),
      .m_axi_wdata (wdata),   .m_axi_wstrb (wstrb),
      .m_axi_wvalid (wvalid), .m_axi_wready (wready),
      .m_axi_bvalid (bvalid), .m_axi_bready (bready),
      .m_axi_araddr (araddr), .m_axi_arvalid (arvalid), .m_axi_arready (arready),
      .m_axi_rdata (rdata),   .m_axi_rvalid (rvalid), .m_axi_rready (rready)
  );

  always #500 clk = ~clk;

  // ------------------------------------------------------ behavioural DDR2
  // The same slave as tb_ddr2ram.sv: latency between 3 and 18 clocks.
  logic [7:0] ddr [0:65535];
  integer     lat, k;

  initial begin
    awready = 0; wready = 0; bvalid = 0; arready = 0; rvalid = 0; rdata = 0;
    for (k = 0; k < 65536; k = k + 1) ddr[k] = 8'h00;
  end

  initial forever begin
    @(posedge clk);
    if (awvalid) begin
      lat = 3 + ($random % 8 < 0 ? -($random % 8) : ($random % 8));
      repeat (lat) @(posedge clk);
      awready <= 1; @(posedge clk); awready <= 0;
      wait (wvalid);
      repeat (2) @(posedge clk);
      wready <= 1;
      @(posedge clk);
      for (k = 0; k < 16; k = k + 1)
        if (wstrb[k]) ddr[(awaddr & ~27'd15) + k] = wdata[8*k +: 8];
      wready <= 0;
      repeat (2) @(posedge clk);
      bvalid <= 1;
      wait (bready);
      @(posedge clk);
      bvalid <= 0;
    end
  end

  initial forever begin
    @(posedge clk);
    if (arvalid) begin
      lat = 4 + ($random % 14 < 0 ? -($random % 14) : ($random % 14));
      repeat (lat) @(posedge clk);
      arready <= 1; @(posedge clk); arready <= 0;
      repeat (lat) @(posedge clk);
      for (k = 0; k < 16; k = k + 1)
        rdata[8*k +: 8] <= ddr[(araddr & ~27'd15) + k];
      rvalid <= 1;
      wait (rready);
      @(posedge clk);
      rvalid <= 0;
    end
  end

  // The host side of the protocol (rx_one, put, get, chk, rd_reg, ...) is in
  // sim/dbg_host.svh, which tb_romwbw_dbg.sv includes too.
  localparam int NBP = 4;
`include "dbg_host.svh"

  // ------------------------------------------------------------ the script
  logic [7:0]  st;
  logic [15:0] v;
  logic [7:0]  img [0:32808];
  integer      i, plen;
  logic [15:0] aout;

  initial begin
    $readmemh("sim/dbg_prog.hex", img);
    plen = 16'h8029 - 16'h8000;

    repeat (10) @(posedge clk);
    rst_n = 1;

    if (HOR) begin
      repeat (50) @(posedge clk);
    end else begin
      // let the boot monitor get going, then stop it wherever it is
      repeat (6000) @(posedge clk);
      do_status(st);
      chk("boot monitor runs: not stopped", st[0], 0);
      echo_cmd("H", "halt echo");
    end
    wait_stopped("first stop");
    do_status(st);
    chk("stop reason: halt request", st[3], 1);

    // ---- the registers, in both directions
    if (HOR) begin
      chk_reg("PC at reset", 11, 16'h0000);
      chk_reg("AF at reset", 0, 16'hFFFF);
      chk_reg("SP at reset", 10, 16'hFFFF);
      chk_reg("IX at reset", 8, 16'hFFFF);
    end
    chk_reg("CPU bank", 15, 16'h0000);
    for (i = 0; i < 14; i = i + 1) if (i < 4 || i > 7) wr_reg(i, 16'h1000 + 16'h0111 * i);
    for (i = 0; i < 14; i = i + 1)
      if (i < 4 || i > 7)
        chk_reg("register round trip", i, 16'h1000 + 16'h0111 * i);
    put("W"); put(8'd5); put(8'd0); put(8'd0);
    get(b0); get(b1);
    chk("write to the alternate set is refused", {b0, b1}, {"E", 8'h04});
    wr_reg(14, 16'h0000);
    chk_reg("misc register", 14, 16'h0000);
    put("W"); put(8'd15); put(8'd0); put(8'd0);
    get(b0); get(b1);
    chk("write to the bank register is refused", {b0, b1}, {"E", 8'h04});

    // ---- memory: ROM, RAM, and another bank through the override
    rd_mem(16'h0000, 4);
    chk("ROM byte 0 is boot.hex's", mbuf[0], 8'hF3);        // di
    chk("ROM byte 1", mbuf[1], 8'h31);                       // ld sp,
    mbuf[0] = 8'h55;
    wr_mem(16'h0000, 1);
    chk_byte("a write to ROM changes nothing", 16'h0000, 8'hF3);

    for (i = 0; i < plen; i = i + 1) mbuf[i] = img[16'h8000 + i];
    wr_mem(16'h8000, plen);
    rd_mem(16'h8000, plen);
    for (i = 0; i < plen; i = i + 1)
      if (mbuf[i] !== img[16'h8000 + i]) begin
        $display("FAIL: program byte %0h reads back %0h, wrote %0h",
                 16'h8000 + i, mbuf[i], img[16'h8000 + i]);
        fails = fails + 1;
      end
    checks = checks + 1;

    set_ovr(1, 8'h80);
    mbuf[0] = 8'h06; mbuf[1] = 8'h5A; mbuf[2] = 8'hC9;      // ld b,5Ah; ret
    wr_mem(16'h0100, 3);
    rd_mem(16'h0100, 3);
    chk("bank 80 routine, byte 0", mbuf[0], 8'h06);
    chk("bank 80 routine, byte 1", mbuf[1], 8'h5A);
    chk("bank 80 routine, byte 2", mbuf[2], 8'hC9);
    set_ovr(1, 8'h00);
    rd_mem(16'h0100, 1);
    checks = checks + 1;
    if (mbuf[0] === 8'h06 && mbuf[1] === 8'h5A) begin
      $display("FAIL: bank 0 shows the bank 80 routine");
      fails = fails + 1;
    end
    set_ovr(0, 8'h00);
    chk_reg("CPU bank is untouched by the override", 15, 16'h0000);
    // the high window ignores the override
    set_ovr(1, 8'h80);
    chk_byte("high window is the common bank whatever the override", 16'h8000, 8'h3E);
    set_ovr(0, 8'h00);

    // ---- a 256-byte read (length 0) and the error replies
    rd_mem(16'h8000, 0);
    chk("256-byte read, first byte", mbuf[0], 8'h3E);
    put("Q");
    get(b0); get(b1);
    chk("unknown command", {b0, b1}, {"E", 8'h02});
    put("B"); put(8'd4); put(8'd0); put(8'd0); put(8'd0); put(8'd0);
    get(b0); get(b1);
    chk("breakpoint index out of range", {b0, b1}, {"E", 8'h03});

    // ---- the timeout: half a command, silence, then a clean one
    put("M"); put(8'h00);
    repeat (12000) @(posedge clk);
    echo_cmd("N", "after the timeout");

    // ---- run to the first breakpoint
    wr_reg(11, 16'h8000);
    set_bp(0, 16'h800F, 8'h00, 8'h01);
    echo_cmd("C", "continue echo");
    wait_stopped("breakpoint 0");
    do_status(st);
    chk("stop reason: breakpoint", st[1], 1);
    chk("stop reason: not a step", st[2], 0);
    chk("stop reason: not a halt", st[3], 0);
    chk("breakpoint index", st[7:5], 0);
    chk_reg("PC at breakpoint 0", 11, 16'h800F);
    rd_reg(0, v);
    chk("A at the breakpoint", v[15:8], 8'h11);
    chk_reg("BC", 1, 16'h2233);
    chk_reg("DE", 2, 16'h4455);
    chk_reg("HL", 3, 16'h9000);
    chk_reg("SP", 10, 16'hF000);
    chk_byte("[9000] was written", 16'h9000, 8'h11);

    // ---- single steps
    echo_cmd("T", "step echo");
    wait_stopped("step 1");
    do_status(st);
    chk("stop reason: step", st[2], 1);
    chk("stop reason: not a breakpoint", st[1], 0);
    chk_reg("PC after inc a", 11, 16'h8010);
    rd_reg(0, v);
    chk("A after inc a", v[15:8], 8'h12);

    echo_cmd("T", "step echo"); wait_stopped("step 2");           // inc hl
    chk_reg("PC after inc hl", 11, 16'h8011);
    chk_reg("HL after inc hl", 3, 16'h9001);
    echo_cmd("T", "step echo"); wait_stopped("step 3");           // ld (hl),a
    chk_reg("PC after ld (hl),a", 11, 16'h8012);
    chk_byte("[9001]", 16'h9001, 8'h12);
    echo_cmd("T", "step echo"); wait_stopped("step 4");           // push bc
    chk_reg("PC after push", 11, 16'h8013);
    chk_reg("SP after push", 10, 16'hEFFE);
    chk_byte("stack low byte", 16'hEFFE, 8'h33);
    chk_byte("stack high byte", 16'hEFFF, 8'h22);
    if (DDR2) begin
      chk("stack low byte, in the DDR2 model", ddr[16'hEFFE], 8'h33);
      chk("stack high byte, in the DDR2 model", ddr[16'hEFFF], 8'h22);
    end else begin
      chk("stack low byte, in block RAM", dut.g_bram.u_ram.mem[16'hEFFE], 8'h33);
      chk("stack high byte, in block RAM", dut.g_bram.u_ram.mem[16'hEFFF], 8'h22);
    end
    echo_cmd("T", "step echo"); wait_stopped("step 5");           // ld a,77h
    chk_reg("PC after ld a,77h", 11, 16'h8015);
    rd_reg(0, v);
    chk("A after ld a,77h", v[15:8], 8'h77);
    echo_cmd("T", "step echo"); wait_stopped("step 6");           // ld ix,1234h
    chk_reg("PC after a prefixed instruction", 11, 16'h8019);
    chk_reg("IX", 8, 16'h1234);

    // ---- errors while stopped / running, then a breakpoint that must miss
    //      (wrong bank), one that must be skipped (the current PC), and one
    //      that stops the run
    wr_reg(11, 16'h800F);                       // back onto breakpoint 0
    set_bp(2, 16'h0100, 8'h00, 8'h03);          // bank 00, and the CPU will be in 80
    set_bp(3, 16'h8026, 8'h00, 8'h01);
    echo_cmd("C", "continue echo");
    wait_stopped("breakpoint 3");
    do_status(st);
    chk("breakpoint 3 index", st[7:5], 3);
    chk("breakpoint 3 reason", st[1], 1);
    chk_reg("PC at breakpoint 3", 11, 16'h8026);
    chk_reg("BC': the bank 80 routine ran (bank-qualified bp missed)", 5, 16'h5A33);
    chk_reg("DE'", 6, 16'h4455);
    chk_reg("HL'", 7, 16'h9002);
    rd_reg(4, v);
    chk("A'", v[15:8], 8'h00);
    chk_reg("CPU bank back to ROM", 15, 16'h0000);

    // ---- a bank-qualified breakpoint that hits
    wr_reg(11, 16'h8019);
    set_bp(2, 16'h0100, 8'h80, 8'h03);
    echo_cmd("C", "continue echo");
    wait_stopped("breakpoint 2");
    do_status(st);
    chk("breakpoint 2 index", st[7:5], 2);
    chk_reg("PC at the bank-qualified breakpoint", 11, 16'h0100);
    chk_reg("CPU bank inside the routine", 15, 16'h0080);
    echo_cmd("T", "step echo"); wait_stopped("routine step 1");   // ld b,5Ah
    chk_reg("PC in the routine", 11, 16'h0102);
    echo_cmd("T", "step echo"); wait_stopped("routine step 2");   // ret
    chk_reg("PC after ret", 11, 16'h8020);
    chk_reg("SP after ret", 10, 16'hEFFC);      // the second pass through push bc

    // ---- a halt request on a running core, and the errors while running
    set_bp(0, 16'h0000, 8'h00, 8'h00);
    set_bp(2, 16'h0000, 8'h00, 8'h00);
    set_bp(3, 16'h0000, 8'h00, 8'h00);
    echo_cmd("C", "continue echo");
    repeat (3000) @(posedge clk);
    do_status(st);
    chk("running: not stopped", st[0], 0);
    put("R"); put(8'd0);
    get(b0); get(b1);
    chk("register read while running", {b0, b1}, {"E", 8'h01});
    put("T");
    get(b0); get(b1);
    chk("step while running", {b0, b1}, {"E", 8'h01});
    echo_cmd("H", "halt echo");
    wait_stopped("halt request");
    do_status(st);
    chk("halt reason", st[3], 1);
    chk("halt reason: not a breakpoint", st[1], 0);
    chk_reg("PC in the spin loop", 11, 16'h8026);
    rd_reg(0, v);
    chk("A at the end", v[15:8], 8'h00);

    // ---- the core goes on from where it stopped: write PC to the start,
    //      run again to the end, and see the same result
    wr_reg(3, 16'h0000);
    wr_reg(1, 16'h0000);
    wr_reg(11, 16'h8000);
    set_bp(3, 16'h8026, 8'h00, 8'h01);
    echo_cmd("C", "continue echo");
    wait_stopped("second run");
    chk_reg("second run: PC", 11, 16'h8026);
    chk_reg("second run: BC'", 5, 16'h5A33);
    chk_reg("second run: IX", 8, 16'h1234);

    // ---- a program that ends in HALT: the unit stops it, and a write to PC
    //      ends the HALT state so the core runs the code again
    mbuf[0] = 8'h3C; mbuf[1] = 8'h3C; mbuf[2] = 8'h76;       // inc a; inc a; halt
    wr_mem(16'h8040, 3);
    wr_reg(0, 16'h0000);
    wr_reg(11, 16'h8040);
    echo_cmd("C", "continue echo");
    repeat (3000) @(posedge clk);
    echo_cmd("H", "halt echo");
    wait_stopped("stop on a halted core");
    rd_reg(0, v);
    chk("HALT program: A", v[15:8], 8'h02);
    chk_reg("HALT program: PC after the halt", 11, 16'h8043);
    rd_reg(14, v);
    chk("HALT program: halted flag set", v[4], 1);
    wr_reg(0, 16'h0000);
    wr_reg(11, 16'h8040);
    rd_reg(14, v);
    chk("a write to PC clears the halted flag", v[4], 0);
    echo_cmd("C", "continue echo");
    repeat (3000) @(posedge clk);
    echo_cmd("H", "halt echo");
    wait_stopped("stop after the PC write");
    rd_reg(0, v);
    chk("HALT program after a PC write: A", v[15:8], 8'h02);
    chk_reg("HALT program after a PC write: PC", 11, 16'h8043);
    rd_reg(14, v);
    chk("HALT program after a PC write: halted again", v[4], 1);

    $display("");
    if (fails == 0)
      $display("PASS: %0d checks, debug unit over its serial line (CPU_DIV=%0d, %s, halt-on-reset=%0d)",
               checks, CPU_DIV, DDR2 ? "RAM in DDR2" : "RAM in block RAM", HOR);
    else
      $display("FAIL: %0d of %0d checks failed", fails, checks);
    $finish;
  end

  initial begin
    #3000000000;
    $display("FAIL: bench timed out");
    $finish;
  end

endmodule
