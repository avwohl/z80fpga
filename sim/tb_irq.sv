// Directed interrupt tests.
//
// The SingleStepTests suite does not exercise interrupt entry at all, so this
// covers it: NMI, IM 0, IM 1 and IM 2, the EI delay, the masking by IFF1, and
// waking from HALT.  Each case checks where the CPU ended up, what it pushed,
// what happened to IFF1 and IFF2, and how many T-states the entry took.

`timescale 1ns/1ps

module tb_irq;

  logic clk = 0;
  logic rst_n = 0;

  logic [15:0] a;
  logic  [7:0] din, dout;
  logic mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n, busak_n;
  logic int_n = 1, nmi_n = 1;

  logic [7:0] mem [0:65535];
  logic [7:0] irq_vec = 8'hFF;

  z80_core #(
      .UCODE_MEM ("rtl/core/z80_ucode.mem"),
      .DISP_MEM  ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n), .clk_en (1'b1),
      .a (a), .din (din), .dout (dout),
      .mreq_n (mreq_n), .iorq_n (iorq_n), .rd_n (rd_n), .wr_n (wr_n),
      .m1_n (m1_n), .rfsh_n (rfsh_n), .halt_n (halt_n), .busak_n (busak_n),
      .wait_n (1'b1), .int_n (int_n), .nmi_n (nmi_n), .busrq_n (1'b1)
  );

  // The acknowledge cycle asserts M1 and IORQ together; that is when the
  // device puts its vector on the bus.
  assign din = (!iorq_n && !m1_n) ? irq_vec : mem[a];

  always @(posedge clk) if (!mreq_n && !wr_n) mem[a] <= dout;

  always #5 clk = ~clk;

  localparam int PH_M1 = 0;

  function automatic logic at_boundary();
    at_boundary = (dut.phase == PH_M1[2:0]) && (dut.tcnt == 4'd1) &&
                  dut.first_m1;
  endfunction

  integer fails = 0;
  integer tcount;   // T-states in the whole step
  integer tirq;     // T-states from the start of the acknowledge cycle

  task automatic expect16(input [127:0] what, input [15:0] got, want);
    if (got !== want) begin
      $display("  FAIL %0s: got %04h want %04h", what, got, want);
      fails = fails + 1;
    end
  endtask

  task automatic expect1(input [127:0] what, input got, want);
    if (got !== want) begin
      $display("  FAIL %0s: got %b want %b", what, got, want);
      fails = fails + 1;
    end
  endtask

  // Run to the next opcode-fetch boundary.  An accepted interrupt is part of
  // the same step, because the entry sequence runs before the next fetch;
  // tirq counts just that part.
  task automatic step();
    logic in_irq;
    begin
      tcount = 0;
      tirq   = 0;
      in_irq = 1'b0;
      forever begin
        #1;
        if (dut.phase == 3'd4 || dut.phase == 3'd5) in_irq = 1'b1;
        tcount = tcount + 1;
        if (in_irq) tirq = tirq + 1;
        @(posedge clk);
        #1;
        if (at_boundary() || tcount > 80) break;
      end
    end
  endtask

  task automatic expect_t(input integer got, want);
    if (got != want) begin
      $display("  FAIL entry T-states: got %0d want %0d", got, want);
      fails = fails + 1;
    end
  endtask

  task automatic setup(input [15:0] pc, input [15:0] sp, input logic ei,
                       input [1:0] mode, input [7:0] ireg);
    begin
      dut.rPC = pc; dut.rSP = sp;
      dut.iff1 = ei; dut.iff2 = ei; dut.im = mode; dut.rI = ireg;
      dut.rA = 8'h00; dut.rF = 8'h00; dut.rR = 8'h00;
      dut.halted = 1'b0; dut.pfx_v = 1'b0; dut.tab_sel = 2'd0;
      dut.phase = PH_M1[2:0]; dut.tcnt = 4'd1; dut.upc = '0;
      dut.first_m1 = 1'b1; dut.abus = pc;
      dut.nmi_q = 1'b1; dut.nmi_pend = 1'b0;
    end
  endtask

  initial begin
    for (int i = 0; i < 65536; i++) mem[i] = 8'h00;   // 0x00 is NOP

    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    #1;

    // ------------------------------------------------------------- NMI, 11 T
    $display("NMI");
    setup(16'h1000, 16'hFF00, 1'b1, 2'd1, 8'h00);
    nmi_n = 0; @(posedge clk); #1; nmi_n = 1;
    step();                                   // the NOP, then the NMI entry
    expect16("pc",   dut.rPC, 16'h0066);
    expect16("sp",   dut.rSP, 16'hFEFE);
    expect16("pushed", {mem[16'hFEFF], mem[16'hFEFE]}, 16'h1001);
    expect1 ("iff1", dut.iff1, 1'b0);
    expect1 ("iff2", dut.iff2, 1'b1);          // NMI keeps IFF2 for RETN
    expect_t(tirq, 11);

    // ----------------------------------------------------------- IM 1, 13 T
    $display("INT, IM 1");
    setup(16'h2000, 16'hFF00, 1'b1, 2'd1, 8'h00);
    int_n = 0;
    step();
    int_n = 1;
    expect16("pc",   dut.rPC, 16'h0038);
    expect16("sp",   dut.rSP, 16'hFEFE);
    expect16("pushed", {mem[16'hFEFF], mem[16'hFEFE]}, 16'h2001);
    expect1 ("iff1", dut.iff1, 1'b0);
    expect1 ("iff2", dut.iff2, 1'b0);
    expect_t(tirq, 13);

    // ----------------------------------------------------------- IM 2, 19 T
    $display("INT, IM 2");
    mem[16'h3480] = 8'h34;                     // vector table entry at I:vec
    mem[16'h3481] = 8'h12;
    irq_vec = 8'h80;
    setup(16'h2000, 16'hFF00, 1'b1, 2'd2, 8'h34);
    int_n = 0;
    step();
    int_n = 1;
    expect16("pc", dut.rPC, 16'h1234);
    expect16("sp", dut.rSP, 16'hFEFE);
    expect16("pushed", {mem[16'hFEFF], mem[16'hFEFE]}, 16'h2001);
    expect_t(tirq, 19);

    // ------------------------------------------- IM 0 with RST 38h, 13 T
    $display("INT, IM 0 with RST 38h");
    irq_vec = 8'hFF;                           // RST 38h
    setup(16'h2000, 16'hFF00, 1'b1, 2'd0, 8'h00);
    int_n = 0;
    step();
    int_n = 1;
    expect16("pc", dut.rPC, 16'h0038);
    expect16("pushed", {mem[16'hFEFF], mem[16'hFEFE]}, 16'h2001);
    expect_t(tirq, 13);

    // ------------------------------------------------- masked while IFF1 = 0
    $display("INT ignored while IFF1 is clear");
    setup(16'h4000, 16'hFF00, 1'b0, 2'd1, 8'h00);
    int_n = 0;
    step();
    step();
    int_n = 1;
    expect16("pc", dut.rPC, 16'h4002);          // two NOPs, no entry
    expect16("sp", dut.rSP, 16'hFF00);
    expect_t(tirq, 0);

    // --------------------------------------------------------- the EI delay
    // EI at 5000h, NOP after it: the interrupt must not be taken at the
    // boundary between them, only at the one after.
    $display("EI delays interrupts by one instruction");
    mem[16'h5000] = 8'hFB;                      // EI
    mem[16'h5001] = 8'h00;                      // NOP
    mem[16'h5002] = 8'h00;
    setup(16'h5000, 16'hFF00, 1'b0, 2'd1, 8'h00);
    int_n = 0;
    step();                                     // EI, and no entry after it
    expect16("pc after EI", dut.rPC, 16'h5001);
    expect_t(tirq, 0);
    step();                                     // the NOP, then the entry
    int_n = 1;
    expect16("pc", dut.rPC, 16'h0038);
    expect16("pushed", {mem[16'hFEFF], mem[16'hFEFE]}, 16'h5002);
    expect_t(tirq, 13);

    // ------------------------------------------------------- HALT and wake
    $display("HALT holds, and an interrupt wakes it");
    mem[16'h6000] = 8'h76;                      // HALT
    setup(16'h6000, 16'hFF00, 1'b1, 2'd1, 8'h00);
    step();                                     // execute HALT
    expect16("pc", dut.rPC, 16'h6001);
    expect1 ("halt_n", halt_n, 1'b0);
    step(); step();                             // spins, PC does not move
    expect16("pc while halted", dut.rPC, 16'h6001);
    expect1 ("still halted", halt_n, 1'b0);
    int_n = 0;
    step();
    int_n = 1;
    expect_t(tirq, 13);
    expect1 ("woke", halt_n, 1'b1);
    expect16("pc", dut.rPC, 16'h0038);
    expect16("pushed", {mem[16'hFEFF], mem[16'hFEFE]}, 16'h6001);

    $display("");
    if (fails == 0) $display("PASS: all interrupt cases");
    else            $display("FAIL: %0d checks failed", fails);
    $finish;
  end

endmodule
