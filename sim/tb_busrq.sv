// BUSREQ = 1 against a core that never gives the bus away.
//
// Two cores run sim/busrq_prog.z80, each with its own memory.  One has
// busrq_n tied high and no wait states (`gold` in the code).  `dut` is built with BUSREQ and gets
// bus requests and wait states at random.  The bench checks, on every T-state
// of `dut`:
//
//   - while busak_n is low, no strobe, /M1 or /RFSH is active, and bus_float
//     is high;
//   - busak_n goes low exactly when the T-state before it was the last of an
//     M-cycle (bus_last) and busrq_n was low at the rising edge that began
//     that T-state;
//   - busak_n goes high exactly after a T-state that began with busrq_n high
//     (bus_resume marks that T-state);
//   - bus_t starts at 1 after the last T-state of an M-cycle and otherwise
//     counts up or, in a wait state, stays.
//
// At the HALT, the two cores must have made the same opcode fetches, reads and
// writes in the same order, written the same memory, and hold the same
// registers.
//
// Build with -Ptb_busrq.LATE_READ=1 to run both cores with LATE_READ.

`timescale 1ns/1ps

module tb_busrq #(
    parameter bit LATE_READ = 1'b0
);

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // ----------------------------------------------------------------------
  // one core and its memory
  // ----------------------------------------------------------------------
  logic [15:0] a     [0:1];
  logic  [7:0] din   [0:1];
  logic  [7:0] dout  [0:1];
  logic        mreq_n[0:1], iorq_n[0:1], rd_n[0:1], wr_n[0:1];
  logic        m1_n  [0:1], rfsh_n[0:1], halt_n[0:1], busak_n[0:1];
  logic  [3:0] bus_t [0:1];
  logic  [2:0] bus_cyc[0:1];
  logic        bus_last[0:1], bus_float[0:1], bus_resume[0:1];
  logic        wait_n, busrq_n;

  logic [7:0] mem0 [0:65535];
  logic [7:0] mem1 [0:65535];

  // a port returns a byte made from its whole address
  function automatic logic [7:0] port_val(input logic [15:0] p);
    port_val = p[7:0] ^ {p[14:8], p[15]} ^ 8'h5A;
  endfunction

  assign din[0] = (bus_cyc[0] == 3'd4) ? port_val(a[0]) : mem0[a[0]];
  assign din[1] = (bus_cyc[1] == 3'd4) ? port_val(a[1]) : mem1[a[1]];

  always @(posedge clk) begin
    if (!mreq_n[0] && !wr_n[0]) mem0[a[0]] <= dout[0];
    if (!mreq_n[1] && !wr_n[1]) mem1[a[1]] <= dout[1];
  end

  z80_core #(
      .LATE_READ (LATE_READ),
      .UCODE_MEM ("rtl/core/z80_ucode.mem"),
      .DISP_MEM  ("rtl/core/z80_dispatch.mem")
  ) gold (
      .clk (clk), .rst_n (rst_n), .clk_en (1'b1),
      .a (a[0]), .din (din[0]), .dout (dout[0]),
      .mreq_n (mreq_n[0]), .iorq_n (iorq_n[0]), .rd_n (rd_n[0]), .wr_n (wr_n[0]),
      .m1_n (m1_n[0]), .rfsh_n (rfsh_n[0]), .halt_n (halt_n[0]), .busak_n (busak_n[0]),
      .wait_n (1'b1), .int_n (1'b1), .nmi_n (1'b1), .busrq_n (1'b1),
      .bus_t (bus_t[0]), .bus_cyc (bus_cyc[0]), .bus_last (bus_last[0]),
      .bus_float (bus_float[0]), .bus_resume (bus_resume[0])
  );

  z80_core #(
      .LATE_READ (LATE_READ),
      .BUSREQ    (1'b1),
      .UCODE_MEM ("rtl/core/z80_ucode.mem"),
      .DISP_MEM  ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n), .clk_en (1'b1),
      .a (a[1]), .din (din[1]), .dout (dout[1]),
      .mreq_n (mreq_n[1]), .iorq_n (iorq_n[1]), .rd_n (rd_n[1]), .wr_n (wr_n[1]),
      .m1_n (m1_n[1]), .rfsh_n (rfsh_n[1]), .halt_n (halt_n[1]), .busak_n (busak_n[1]),
      .wait_n (wait_n), .int_n (1'b1), .nmi_n (1'b1), .busrq_n (busrq_n),
      .bus_t (bus_t[1]), .bus_cyc (bus_cyc[1]), .bus_last (bus_last[1]),
      .bus_float (bus_float[1]), .bus_resume (bus_resume[1])
  );

  // ----------------------------------------------------------------------
  // transaction logs: one entry when a strobe goes active
  // ----------------------------------------------------------------------
  localparam int LOGN = 8192;
  logic [27:0] tlog [0:1][0:LOGN-1];   // {kind, address, data}
  integer      nlog [0:1];
  logic        p_m1 [0:1], p_rd [0:1], p_wr [0:1];

  task automatic note(input integer c, input logic [3:0] kind,
                      input logic [15:0] ad, input logic [7:0] dv);
    if (nlog[c] < LOGN) tlog[c][nlog[c]] = {kind, ad, dv};
    nlog[c] = nlog[c] + 1;
  endtask

  integer c;
  always @(negedge clk) if (rst_n) begin
    for (c = 0; c < 2; c = c + 1) begin
      if (halt_n[c]) begin
        if (!m1_n[c] && !mreq_n[c] && p_m1[c])        note(c, 4'd1, a[c], 8'h00);
        if (!rd_n[c] && m1_n[c] && p_rd[c])           note(c, mreq_n[c] ? 4'd4 : 4'd2, a[c], 8'h00);
        if (!wr_n[c] && p_wr[c])                      note(c, mreq_n[c] ? 4'd5 : 4'd3, a[c], dout[c]);
      end
      p_m1[c] = m1_n[c] || mreq_n[c];
      p_rd[c] = rd_n[c];
      p_wr[c] = wr_n[c];
    end
  end

  // ----------------------------------------------------------------------
  // protocol checks on dut, in the middle of each T-state
  // ----------------------------------------------------------------------
  integer fails = 0, holds = 0, grants = 0, waits = 0, tstates = 0;
  logic   brq_k;                  // busrq_n at the edge that began this T-state
  logic   q_busak_n, q_last, q_brq, q_valid;
  logic   [3:0] q_t;

  always @(posedge clk) brq_k <= busrq_n;

  task automatic fail(input string what);
    if (fails < 20) $display("  FAIL at T-state %0d: %0s", tstates, what);
    fails = fails + 1;
  endtask

  always @(negedge clk) if (rst_n) begin
    tstates = tstates + 1;
    if (!busak_n[1]) begin
      holds = holds + 1;
      if (!bus_float[1]) fail("bus_float low while busak_n is low");
      if (!(mreq_n[1] && iorq_n[1] && rd_n[1] && wr_n[1] && m1_n[1] && rfsh_n[1]))
        fail("a strobe, /M1 or /RFSH is active while busak_n is low");
      if (bus_resume[1] !== brq_k) fail("bus_resume is not busrq_n as the edge saw it");
    end else begin
      if (bus_float[1]) fail("bus_float high while busak_n is high");
      if (bus_resume[1]) fail("bus_resume high while busak_n is high");
    end
    if (q_valid) begin
      if (q_busak_n) begin
        if (!busak_n[1] !== (q_last && !q_brq))
          fail(busak_n[1] ? "no grant after a last T-state that began with busrq_n low"
                          : "a grant that the previous T-state did not ask for");
        if (!busak_n[1]) grants = grants + 1;
        if (busak_n[1]) begin
          if (q_last && bus_t[1] != 4'd1) fail("bus_t is not 1 after the last T-state");
          if (!q_last && bus_t[1] != q_t + 4'd1 && bus_t[1] != q_t)
            fail("bus_t does not count");
          if (!q_last && bus_t[1] == q_t) waits = waits + 1;
        end
      end else begin
        if (busak_n[1] !== q_brq)
          fail(busak_n[1] ? "released after a T-state that began with busrq_n low"
                          : "not released after a T-state that began with busrq_n high");
        if (busak_n[1] && bus_t[1] != 4'd1)
          fail("the core did not start a new M-cycle after the hold");
      end
    end
    q_valid   = 1'b1;
    q_busak_n = busak_n[1];
    q_last    = bus_last[1];
    q_brq     = brq_k;
    q_t       = bus_t[1];
  end

  // ----------------------------------------------------------------------
  // stimulus: busrq_n and wait_n change at the falling edge
  // ----------------------------------------------------------------------
  integer seed = 32'h1234;
  always @(negedge clk) begin
    wait_n <= (($random(seed) & 32'h7fffffff) % 100) >= 25;
    if (busrq_n) begin
      if ((($random(seed) & 32'h7fffffff) % 100) < 8)  busrq_n <= 1'b0;
    end else begin
      if ((($random(seed) & 32'h7fffffff) % 100) < 35) busrq_n <= 1'b1;
    end
  end

  // ----------------------------------------------------------------------
  // run, then compare
  // ----------------------------------------------------------------------
  integer i, n, bad_mem;
  initial begin
    $readmemh("sim/busrq_prog.hex", mem0, 0, 32767);
    $readmemh("sim/busrq_prog.hex", mem1, 0, 32767);
    nlog[0] = 0; nlog[1] = 0;
    for (c = 0; c < 2; c = c + 1) begin p_m1[c] = 1; p_rd[c] = 1; p_wr[c] = 1; end
    q_valid = 1'b0;
    wait_n  = 1'b1;
    busrq_n = 1'b1;
    repeat (4) @(posedge clk);
    rst_n = 1;

    fork
      begin
        wait (!halt_n[0] && !halt_n[1]);
        repeat (200) @(posedge clk);    // bus requests during HALT, too
      end
      begin
        repeat (400000) @(posedge clk);
        fail("timeout: the cores did not both reach HALT");
      end
    join_any
    disable fork;

    if (nlog[0] != nlog[1]) fail("the two cores made a different number of bus cycles");
    n = (nlog[0] < nlog[1]) ? nlog[0] : nlog[1];
    if (n > LOGN) n = LOGN;
    for (i = 0; i < n; i = i + 1)
      if (tlog[0][i] !== tlog[1][i]) begin
        $display("  bus cycle %0d: gold %07h dut %07h", i, tlog[0][i], tlog[1][i]);
        fail("bus cycles differ");
        i = n;
      end

    bad_mem = 0;
    for (i = 16'h8000; i < 16'hFFFF; i = i + 1)
      if (mem0[i] !== mem1[i]) bad_mem = bad_mem + 1;
    if (bad_mem) fail("memory differs");
    if ({gold.rA, gold.rF, gold.rB, gold.rC, gold.rD, gold.rE, gold.rH, gold.rL,
         gold.rIX, gold.rIY, gold.rSP, gold.rPC, gold.rWZ} !==
        {dut.rA, dut.rF, dut.rB, dut.rC, dut.rD, dut.rE, dut.rH, dut.rL,
         dut.rIX, dut.rIY, dut.rSP, dut.rPC, dut.rWZ})
      fail("registers differ");
    if (mem0[16'h9200] !== 8'h55) fail("the program did not reach its end");
    if (grants < 50) fail("too few bus grants to mean anything");

    $display("tb_busrq LATE_READ=%0d: %0d bus cycles, %0d grants, %0d T-states held, %0d wait states, %0d failures",
             LATE_READ, nlog[0], grants, holds, waits, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
  end

endmodule
