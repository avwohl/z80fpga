// Test bench for the SingleStepTests per-opcode suite.
//
// tools/run_sst.py turns the suite's JSON into a flat vector file, runs this
// bench over it, and diffs the results.  Everything is plain file I/O so the
// flow needs no VPI and no C compiler.
//
// Vector file, all values hex, whitespace separated:
//   a f b c d e h l af' bc' de' hl' ix iy sp pc wz i r iff1 iff2 im q ioval
//   nmem   then nmem pairs of "addr val"
//   ncheck then ncheck addresses to report back
//
// Results, one block per test:
//   R <the same 23 register fields> <tstates> <io_dir> <io_addr> <io_val>
//   M <value> ...                  the ncheck bytes, in order
//   C <addr> <data> <pins> ...     one line per T-state, pins as "rwmi"
//   E

`timescale 1ns/1ps

module tb_sst;

  logic clk = 0;
  logic rst_n = 0;

  logic [15:0] a;
  logic  [7:0] din, dout;
  logic mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n, busak_n;

  logic [7:0] mem [0:65535];

  logic  [7:0] io_in_val;
  logic  [7:0] io_addr_lo, io_addr_hi, io_val;
  logic  [1:0] io_dir;              // 0 none, 1 read, 2 write

  z80_core #(
      .UCODE_MEM ("rtl/core/z80_ucode.mem"),
      .DISP_MEM  ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n), .clk_en (1'b1),
      .a (a), .din (din), .dout (dout),
      .mreq_n (mreq_n), .iorq_n (iorq_n), .rd_n (rd_n), .wr_n (wr_n),
      .m1_n (m1_n), .rfsh_n (rfsh_n), .halt_n (halt_n), .busak_n (busak_n),
      .wait_n (1'b1), .int_n (1'b1), .nmi_n (1'b1), .busrq_n (1'b1)
  );

  // combinational memory / port read, the model the suite assumes
  assign din = (!iorq_n) ? io_in_val : mem[a];

  always @(posedge clk) begin
    if (!mreq_n && !wr_n) mem[a] <= dout;
    if (!iorq_n && !wr_n) begin
      io_dir <= 2'd2; io_addr_lo <= a[7:0]; io_addr_hi <= a[15:8]; io_val <= dout;
    end
    if (!iorq_n && !rd_n && m1_n) begin
      io_dir <= 2'd1; io_addr_lo <= a[7:0]; io_addr_hi <= a[15:8];
      io_val <= io_in_val;
    end
  end

  always #5 clk = ~clk;

  // ----------------------------------------------------------------------
  // core state access
  // ----------------------------------------------------------------------
  localparam int PH_M1 = 0;

  task automatic load_state(
      input [7:0] va, vf, vb, vc, vd, ve, vh, vl,
      input [15:0] vafx, vbcx, vdex, vhlx, vix, viy, vsp, vpc, vwz,
      input [7:0] vi, vr, viff1, viff2, vim, vq);
    begin
      dut.rA = va; dut.rF = vf; dut.rB = vb; dut.rC = vc;
      dut.rD = vd; dut.rE = ve; dut.rH = vh; dut.rL = vl;
      dut.sA = vafx[15:8]; dut.sF = vafx[7:0];
      dut.sB = vbcx[15:8]; dut.sC = vbcx[7:0];
      dut.sD = vdex[15:8]; dut.sE = vdex[7:0];
      dut.sH = vhlx[15:8]; dut.sL = vhlx[7:0];
      dut.rIX = vix; dut.rIY = viy; dut.rSP = vsp;
      dut.rPC = vpc; dut.rWZ = vwz;
      dut.rI = vi; dut.rR = vr;
      dut.iff1 = viff1[0]; dut.iff2 = viff2[0]; dut.im = vim[1:0];
      dut.rQ = vq; dut.qPrev = 8'h00;
      dut.rDIN = 8'h00; dut.rTMP = 8'h00; dut.pFlag = 1'b0;
      dut.halted = 1'b0; dut.pfx_v = 1'b0; dut.pfx_iy = 1'b0;
      dut.tab_sel = 2'd0; dut.ir = 8'h00;
      dut.phase = PH_M1[2:0]; dut.tcnt = 4'd1; dut.upc = '0;
      dut.blk_rep = 1'b0; dut.first_m1 = 1'b1;
      dut.abus = vpc; dut.nmi_q = 1'b1; dut.nmi_pend = 1'b0;
    end
  endtask

  function automatic logic at_boundary();
    at_boundary = (dut.phase == PH_M1[2:0]) && (dut.tcnt == 4'd1) &&
                  dut.first_m1;
  endfunction

  // ----------------------------------------------------------------------
  // driver
  // ----------------------------------------------------------------------
  integer fin, fout, ntest, t, i, n, nmem, ncheck, tstates, code;
  integer want_cyc;
  reg     rd_prev;
  reg [7:0] din_prev;
  reg [15:0] addrs [0:15];
  reg [15:0] trace_a [0:127];
  reg [8:0]  trace_d [0:127];
  reg [3:0]  trace_p [0:127];

  reg [7:0]  va, vf, vb, vc, vd, ve, vh, vl, vi, vr, viff1, viff2, vim, vq, vio;
  reg [15:0] vafx, vbcx, vdex, vhlx, vix, viy, vsp, vpc, vwz;
  reg [15:0] ad;
  reg [7:0]  dv;
  reg [1023:0] vecfile, outfile;

  initial begin
    if (!$value$plusargs("vec=%s", vecfile)) vecfile = "vec.txt";
    if (!$value$plusargs("out=%s", outfile)) outfile = "res.txt";
    if (!$value$plusargs("cyc=%d", want_cyc)) want_cyc = 0;
    fin  = $fopen(vecfile, "r");
    fout = $fopen(outfile, "w");
    if (fin == 0) begin
      $display("cannot open %s", vecfile);
      $finish;
    end

    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    #1;                     // let the reset edge's updates settle first

    code = $fscanf(fin, "%d", ntest);
    for (t = 0; t < ntest; t = t + 1) begin
      code = $fscanf(fin,
        "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
        va, vf, vb, vc, vd, ve, vh, vl, vafx, vbcx, vdex, vhlx,
        vix, viy, vsp, vpc, vwz, vi, vr, viff1, viff2, vim, vq, vio);
      code = $fscanf(fin, "%d", nmem);
      for (i = 0; i < nmem; i = i + 1) begin
        code = $fscanf(fin, "%h %h", ad, dv);
        mem[ad] = dv;
      end
      code = $fscanf(fin, "%d", ncheck);
      for (i = 0; i < ncheck; i = i + 1) code = $fscanf(fin, "%h", addrs[i]);

      io_in_val = vio;
      io_dir    = 2'd0;
      io_addr_lo = 8'h00; io_addr_hi = 8'h00; io_val = 8'h00;

      load_state(va, vf, vb, vc, vd, ve, vh, vl, vafx, vbcx, vdex, vhlx,
                 vix, viy, vsp, vpc, vwz, vi, vr, viff1, viff2, vim, vq);

      // Run one instruction, sampling the pins during every T-state.
      tstates = 0;
      rd_prev = 1'b0;
      din_prev = 8'h00;
      forever begin
        #1;                            // settled, inside T(tstates+1)
        if (want_cyc && tstates < 128) begin
          trace_a[tstates] = a;
          // a byte read shows up on the pins in the T-state after the strobe
          trace_d[tstates] = rd_prev  ? {1'b0, din_prev}
                           : (!wr_n)  ? {1'b0, dout} : 9'h100;
          trace_p[tstates] = {~rd_n, ~wr_n, ~mreq_n, ~iorq_n};
        end
        rd_prev  = ~rd_n;
        din_prev = din;
        tstates = tstates + 1;
        @(posedge clk);
        #1;
        if (at_boundary()) break;
        if (tstates > 120) begin
          $display("test %0d: runaway", t);
          break;
        end
      end

      $fwrite(fout,
        "R %02h %02h %02h %02h %02h %02h %02h %02h %04h %04h %04h %04h %04h %04h %04h %04h %04h %02h %02h %0d %0d %0d %02h %0d %0d %04h %02h\n",
        dut.rA, dut.rF, dut.rB, dut.rC, dut.rD, dut.rE, dut.rH, dut.rL,
        {dut.sA, dut.sF}, {dut.sB, dut.sC}, {dut.sD, dut.sE}, {dut.sH, dut.sL},
        dut.rIX, dut.rIY, dut.rSP, dut.rPC, dut.rWZ, dut.rI, dut.rR,
        dut.iff1, dut.iff2, dut.im, dut.rQ, tstates,
        io_dir, {io_addr_hi, io_addr_lo}, io_val);
      $fwrite(fout, "M");
      for (i = 0; i < ncheck; i = i + 1) $fwrite(fout, " %02h", mem[addrs[i]]);
      $fwrite(fout, "\n");
      n = (tstates < 128) ? tstates : 128;
      for (i = 0; i < n; i = i + 1)
        $fwrite(fout, "C %04h %03h %01h\n", trace_a[i], trace_d[i], trace_p[i]);
      $fwrite(fout, "E\n");
    end

    $fclose(fout);
    $fclose(fin);
    $display("ran %0d tests", ntest);
    $finish;
  end

endmodule
