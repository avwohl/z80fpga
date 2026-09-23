// Behavioural Gowin single-port BSRAMs, for simulating a synthesised or a
// placed-and-routed netlist rather than the RTL.
//
// The OSS CAD Suite ships `SP` and `SPX9` as empty `(* blackbox *)` cells, so
// a netlist with block RAM in it reads back zz and looks like the flow being
// an invalid instrument.  It is not; the memories were simply missing.  What
// it takes to get a netlist that runs:
//
//   * both models.  Model only SP and a design's x9 memory stays undriven
//     with no error anywhere -- on the Tang Nano that is the core's dispatch
//     table, and without it nothing sequences: its output goes z, the
//     micro-PC logic goes X one clock after reset releases, and the address
//     bus follows.
//   * the x9 parameter width, which is the trap.  An ordinary block's
//     INIT_RAM_00..3F rows are 256 bits, 16384 in all.  An x9 block's are
//     **288**, for 18432, because in that mode the block's parity bits are
//     part of the array.  Get it wrong and the memory still elaborates,
//     still simulates, and quietly holds the wrong contents.  The rows are
//     declared 288 bits wide here and sliced to whichever width the
//     BIT_WIDTH implies, so one model serves both -- which matters because
//     nextpnr re-types SPX9 to SP and carries the distinction in a
//     BSRAM_SUBTYPE attribute that a Verilog netlist does not keep.
//   * a driver for the constant-0 net.  write_verilog aliases the constant
//     nets onto ordinary signal names and emits a driver only for the
//     constant-1 one (a VCC cell).  Run `setundef -undriven -zero` and then
//     tools/tie_undriven.py for whatever is left.
//   * the word address read from the HIGH bits of AD.  A depth-expanded
//     memory's group select is exactly what lives up there.
//
// Only what these netlists use is modelled: WRITE_MODE 2 (read before write)
// and READ_MODE 0 (no output pipeline register).

module SP (DO, DI, BLKSEL, AD, WRE, CLK, CE, OCE, RESET);
  parameter READ_MODE  = 1'b0;
  parameter WRITE_MODE = 2'b00;
  parameter BIT_WIDTH  = 32;
  parameter BLK_SEL    = 3'b000;
  parameter RESET_MODE = "SYNC";
  parameter [287:0] INIT_RAM_00 = 288'h0;
  parameter [287:0] INIT_RAM_01 = 288'h0;
  parameter [287:0] INIT_RAM_02 = 288'h0;
  parameter [287:0] INIT_RAM_03 = 288'h0;
  parameter [287:0] INIT_RAM_04 = 288'h0;
  parameter [287:0] INIT_RAM_05 = 288'h0;
  parameter [287:0] INIT_RAM_06 = 288'h0;
  parameter [287:0] INIT_RAM_07 = 288'h0;
  parameter [287:0] INIT_RAM_08 = 288'h0;
  parameter [287:0] INIT_RAM_09 = 288'h0;
  parameter [287:0] INIT_RAM_0A = 288'h0;
  parameter [287:0] INIT_RAM_0B = 288'h0;
  parameter [287:0] INIT_RAM_0C = 288'h0;
  parameter [287:0] INIT_RAM_0D = 288'h0;
  parameter [287:0] INIT_RAM_0E = 288'h0;
  parameter [287:0] INIT_RAM_0F = 288'h0;
  parameter [287:0] INIT_RAM_10 = 288'h0;
  parameter [287:0] INIT_RAM_11 = 288'h0;
  parameter [287:0] INIT_RAM_12 = 288'h0;
  parameter [287:0] INIT_RAM_13 = 288'h0;
  parameter [287:0] INIT_RAM_14 = 288'h0;
  parameter [287:0] INIT_RAM_15 = 288'h0;
  parameter [287:0] INIT_RAM_16 = 288'h0;
  parameter [287:0] INIT_RAM_17 = 288'h0;
  parameter [287:0] INIT_RAM_18 = 288'h0;
  parameter [287:0] INIT_RAM_19 = 288'h0;
  parameter [287:0] INIT_RAM_1A = 288'h0;
  parameter [287:0] INIT_RAM_1B = 288'h0;
  parameter [287:0] INIT_RAM_1C = 288'h0;
  parameter [287:0] INIT_RAM_1D = 288'h0;
  parameter [287:0] INIT_RAM_1E = 288'h0;
  parameter [287:0] INIT_RAM_1F = 288'h0;
  parameter [287:0] INIT_RAM_20 = 288'h0;
  parameter [287:0] INIT_RAM_21 = 288'h0;
  parameter [287:0] INIT_RAM_22 = 288'h0;
  parameter [287:0] INIT_RAM_23 = 288'h0;
  parameter [287:0] INIT_RAM_24 = 288'h0;
  parameter [287:0] INIT_RAM_25 = 288'h0;
  parameter [287:0] INIT_RAM_26 = 288'h0;
  parameter [287:0] INIT_RAM_27 = 288'h0;
  parameter [287:0] INIT_RAM_28 = 288'h0;
  parameter [287:0] INIT_RAM_29 = 288'h0;
  parameter [287:0] INIT_RAM_2A = 288'h0;
  parameter [287:0] INIT_RAM_2B = 288'h0;
  parameter [287:0] INIT_RAM_2C = 288'h0;
  parameter [287:0] INIT_RAM_2D = 288'h0;
  parameter [287:0] INIT_RAM_2E = 288'h0;
  parameter [287:0] INIT_RAM_2F = 288'h0;
  parameter [287:0] INIT_RAM_30 = 288'h0;
  parameter [287:0] INIT_RAM_31 = 288'h0;
  parameter [287:0] INIT_RAM_32 = 288'h0;
  parameter [287:0] INIT_RAM_33 = 288'h0;
  parameter [287:0] INIT_RAM_34 = 288'h0;
  parameter [287:0] INIT_RAM_35 = 288'h0;
  parameter [287:0] INIT_RAM_36 = 288'h0;
  parameter [287:0] INIT_RAM_37 = 288'h0;
  parameter [287:0] INIT_RAM_38 = 288'h0;
  parameter [287:0] INIT_RAM_39 = 288'h0;
  parameter [287:0] INIT_RAM_3A = 288'h0;
  parameter [287:0] INIT_RAM_3B = 288'h0;
  parameter [287:0] INIT_RAM_3C = 288'h0;
  parameter [287:0] INIT_RAM_3D = 288'h0;
  parameter [287:0] INIT_RAM_3E = 288'h0;
  parameter [287:0] INIT_RAM_3F = 288'h0;

  output     [35:0] DO;
  input      [35:0] DI;
  input       [2:0] BLKSEL;
  input      [13:0] AD;
  input             WRE, CLK, CE, OCE, RESET;

  localparam integer W     = BIT_WIDTH;
  // x9 widths carry the parity bits as data, so their rows are 288 bits
  localparam integer PW    = (W==9 || W==18 || W==36) ? 288 : 256;
  localparam integer BITS  = 64 * PW;
  localparam integer DEPTH = BITS / W;
  localparam integer AB    = $clog2(DEPTH);

  reg [W-1:0] mem [0:DEPTH-1];
  reg [W-1:0] dout_r;
  reg [BITS-1:0] initv;
  integer i;
  initial begin
    initv = {INIT_RAM_3F[PW-1:0], INIT_RAM_3E[PW-1:0], INIT_RAM_3D[PW-1:0], INIT_RAM_3C[PW-1:0], INIT_RAM_3B[PW-1:0], INIT_RAM_3A[PW-1:0], INIT_RAM_39[PW-1:0], INIT_RAM_38[PW-1:0], INIT_RAM_37[PW-1:0], INIT_RAM_36[PW-1:0], INIT_RAM_35[PW-1:0], INIT_RAM_34[PW-1:0], INIT_RAM_33[PW-1:0], INIT_RAM_32[PW-1:0], INIT_RAM_31[PW-1:0], INIT_RAM_30[PW-1:0], INIT_RAM_2F[PW-1:0], INIT_RAM_2E[PW-1:0], INIT_RAM_2D[PW-1:0], INIT_RAM_2C[PW-1:0], INIT_RAM_2B[PW-1:0], INIT_RAM_2A[PW-1:0], INIT_RAM_29[PW-1:0], INIT_RAM_28[PW-1:0], INIT_RAM_27[PW-1:0], INIT_RAM_26[PW-1:0], INIT_RAM_25[PW-1:0], INIT_RAM_24[PW-1:0], INIT_RAM_23[PW-1:0], INIT_RAM_22[PW-1:0], INIT_RAM_21[PW-1:0], INIT_RAM_20[PW-1:0], INIT_RAM_1F[PW-1:0], INIT_RAM_1E[PW-1:0], INIT_RAM_1D[PW-1:0], INIT_RAM_1C[PW-1:0], INIT_RAM_1B[PW-1:0], INIT_RAM_1A[PW-1:0], INIT_RAM_19[PW-1:0], INIT_RAM_18[PW-1:0], INIT_RAM_17[PW-1:0], INIT_RAM_16[PW-1:0], INIT_RAM_15[PW-1:0], INIT_RAM_14[PW-1:0], INIT_RAM_13[PW-1:0], INIT_RAM_12[PW-1:0], INIT_RAM_11[PW-1:0], INIT_RAM_10[PW-1:0], INIT_RAM_0F[PW-1:0], INIT_RAM_0E[PW-1:0], INIT_RAM_0D[PW-1:0], INIT_RAM_0C[PW-1:0], INIT_RAM_0B[PW-1:0], INIT_RAM_0A[PW-1:0], INIT_RAM_09[PW-1:0], INIT_RAM_08[PW-1:0], INIT_RAM_07[PW-1:0], INIT_RAM_06[PW-1:0], INIT_RAM_05[PW-1:0], INIT_RAM_04[PW-1:0], INIT_RAM_03[PW-1:0], INIT_RAM_02[PW-1:0], INIT_RAM_01[PW-1:0], INIT_RAM_00[PW-1:0]};
    for (i = 0; i < DEPTH; i = i + 1) mem[i] = initv[i*W +: W];
    dout_r = {W{1'b0}};
  end

  assign DO[W-1:0] = dout_r;          // the rest stays undriven, not zero

  wire [AB-1:0] a = AD[13 -: AB];

  always @(posedge CLK) begin
    if (CE && (BLKSEL == BLK_SEL)) begin
      if (WRE === 1'b1) begin         // === : an unconnected WRE is z, not a write
        mem[a] <= DI[W-1:0];
        if      (WRITE_MODE == 2) dout_r <= mem[a];       // read before write
        else if (WRITE_MODE == 1) dout_r <= DI[W-1:0];    // write through
      end else begin
        dout_r <= mem[a];
      end
    end
  end
endmodule

module SPX9 (DO, DI, BLKSEL, AD, WRE, CLK, CE, OCE, RESET);
  parameter READ_MODE  = 1'b0;
  parameter WRITE_MODE = 2'b00;
  parameter BIT_WIDTH  = 36;
  parameter BLK_SEL    = 3'b000;
  parameter RESET_MODE = "SYNC";
  parameter [287:0] INIT_RAM_00 = 288'h0;
  parameter [287:0] INIT_RAM_01 = 288'h0;
  parameter [287:0] INIT_RAM_02 = 288'h0;
  parameter [287:0] INIT_RAM_03 = 288'h0;
  parameter [287:0] INIT_RAM_04 = 288'h0;
  parameter [287:0] INIT_RAM_05 = 288'h0;
  parameter [287:0] INIT_RAM_06 = 288'h0;
  parameter [287:0] INIT_RAM_07 = 288'h0;
  parameter [287:0] INIT_RAM_08 = 288'h0;
  parameter [287:0] INIT_RAM_09 = 288'h0;
  parameter [287:0] INIT_RAM_0A = 288'h0;
  parameter [287:0] INIT_RAM_0B = 288'h0;
  parameter [287:0] INIT_RAM_0C = 288'h0;
  parameter [287:0] INIT_RAM_0D = 288'h0;
  parameter [287:0] INIT_RAM_0E = 288'h0;
  parameter [287:0] INIT_RAM_0F = 288'h0;
  parameter [287:0] INIT_RAM_10 = 288'h0;
  parameter [287:0] INIT_RAM_11 = 288'h0;
  parameter [287:0] INIT_RAM_12 = 288'h0;
  parameter [287:0] INIT_RAM_13 = 288'h0;
  parameter [287:0] INIT_RAM_14 = 288'h0;
  parameter [287:0] INIT_RAM_15 = 288'h0;
  parameter [287:0] INIT_RAM_16 = 288'h0;
  parameter [287:0] INIT_RAM_17 = 288'h0;
  parameter [287:0] INIT_RAM_18 = 288'h0;
  parameter [287:0] INIT_RAM_19 = 288'h0;
  parameter [287:0] INIT_RAM_1A = 288'h0;
  parameter [287:0] INIT_RAM_1B = 288'h0;
  parameter [287:0] INIT_RAM_1C = 288'h0;
  parameter [287:0] INIT_RAM_1D = 288'h0;
  parameter [287:0] INIT_RAM_1E = 288'h0;
  parameter [287:0] INIT_RAM_1F = 288'h0;
  parameter [287:0] INIT_RAM_20 = 288'h0;
  parameter [287:0] INIT_RAM_21 = 288'h0;
  parameter [287:0] INIT_RAM_22 = 288'h0;
  parameter [287:0] INIT_RAM_23 = 288'h0;
  parameter [287:0] INIT_RAM_24 = 288'h0;
  parameter [287:0] INIT_RAM_25 = 288'h0;
  parameter [287:0] INIT_RAM_26 = 288'h0;
  parameter [287:0] INIT_RAM_27 = 288'h0;
  parameter [287:0] INIT_RAM_28 = 288'h0;
  parameter [287:0] INIT_RAM_29 = 288'h0;
  parameter [287:0] INIT_RAM_2A = 288'h0;
  parameter [287:0] INIT_RAM_2B = 288'h0;
  parameter [287:0] INIT_RAM_2C = 288'h0;
  parameter [287:0] INIT_RAM_2D = 288'h0;
  parameter [287:0] INIT_RAM_2E = 288'h0;
  parameter [287:0] INIT_RAM_2F = 288'h0;
  parameter [287:0] INIT_RAM_30 = 288'h0;
  parameter [287:0] INIT_RAM_31 = 288'h0;
  parameter [287:0] INIT_RAM_32 = 288'h0;
  parameter [287:0] INIT_RAM_33 = 288'h0;
  parameter [287:0] INIT_RAM_34 = 288'h0;
  parameter [287:0] INIT_RAM_35 = 288'h0;
  parameter [287:0] INIT_RAM_36 = 288'h0;
  parameter [287:0] INIT_RAM_37 = 288'h0;
  parameter [287:0] INIT_RAM_38 = 288'h0;
  parameter [287:0] INIT_RAM_39 = 288'h0;
  parameter [287:0] INIT_RAM_3A = 288'h0;
  parameter [287:0] INIT_RAM_3B = 288'h0;
  parameter [287:0] INIT_RAM_3C = 288'h0;
  parameter [287:0] INIT_RAM_3D = 288'h0;
  parameter [287:0] INIT_RAM_3E = 288'h0;
  parameter [287:0] INIT_RAM_3F = 288'h0;

  output     [35:0] DO;
  input      [35:0] DI;
  input       [2:0] BLKSEL;
  input      [13:0] AD;
  input             WRE, CLK, CE, OCE, RESET;

  localparam integer W     = BIT_WIDTH;
  // x9 widths carry the parity bits as data, so their rows are 288 bits
  localparam integer PW    = (W==9 || W==18 || W==36) ? 288 : 256;
  localparam integer BITS  = 64 * PW;
  localparam integer DEPTH = BITS / W;
  localparam integer AB    = $clog2(DEPTH);

  reg [W-1:0] mem [0:DEPTH-1];
  reg [W-1:0] dout_r;
  reg [BITS-1:0] initv;
  integer i;
  initial begin
    initv = {INIT_RAM_3F[PW-1:0], INIT_RAM_3E[PW-1:0], INIT_RAM_3D[PW-1:0], INIT_RAM_3C[PW-1:0], INIT_RAM_3B[PW-1:0], INIT_RAM_3A[PW-1:0], INIT_RAM_39[PW-1:0], INIT_RAM_38[PW-1:0], INIT_RAM_37[PW-1:0], INIT_RAM_36[PW-1:0], INIT_RAM_35[PW-1:0], INIT_RAM_34[PW-1:0], INIT_RAM_33[PW-1:0], INIT_RAM_32[PW-1:0], INIT_RAM_31[PW-1:0], INIT_RAM_30[PW-1:0], INIT_RAM_2F[PW-1:0], INIT_RAM_2E[PW-1:0], INIT_RAM_2D[PW-1:0], INIT_RAM_2C[PW-1:0], INIT_RAM_2B[PW-1:0], INIT_RAM_2A[PW-1:0], INIT_RAM_29[PW-1:0], INIT_RAM_28[PW-1:0], INIT_RAM_27[PW-1:0], INIT_RAM_26[PW-1:0], INIT_RAM_25[PW-1:0], INIT_RAM_24[PW-1:0], INIT_RAM_23[PW-1:0], INIT_RAM_22[PW-1:0], INIT_RAM_21[PW-1:0], INIT_RAM_20[PW-1:0], INIT_RAM_1F[PW-1:0], INIT_RAM_1E[PW-1:0], INIT_RAM_1D[PW-1:0], INIT_RAM_1C[PW-1:0], INIT_RAM_1B[PW-1:0], INIT_RAM_1A[PW-1:0], INIT_RAM_19[PW-1:0], INIT_RAM_18[PW-1:0], INIT_RAM_17[PW-1:0], INIT_RAM_16[PW-1:0], INIT_RAM_15[PW-1:0], INIT_RAM_14[PW-1:0], INIT_RAM_13[PW-1:0], INIT_RAM_12[PW-1:0], INIT_RAM_11[PW-1:0], INIT_RAM_10[PW-1:0], INIT_RAM_0F[PW-1:0], INIT_RAM_0E[PW-1:0], INIT_RAM_0D[PW-1:0], INIT_RAM_0C[PW-1:0], INIT_RAM_0B[PW-1:0], INIT_RAM_0A[PW-1:0], INIT_RAM_09[PW-1:0], INIT_RAM_08[PW-1:0], INIT_RAM_07[PW-1:0], INIT_RAM_06[PW-1:0], INIT_RAM_05[PW-1:0], INIT_RAM_04[PW-1:0], INIT_RAM_03[PW-1:0], INIT_RAM_02[PW-1:0], INIT_RAM_01[PW-1:0], INIT_RAM_00[PW-1:0]};
    for (i = 0; i < DEPTH; i = i + 1) mem[i] = initv[i*W +: W];
    dout_r = {W{1'b0}};
  end

  assign DO[W-1:0] = dout_r;          // the rest stays undriven, not zero

  wire [AB-1:0] a = AD[13 -: AB];

  always @(posedge CLK) begin
    if (CE && (BLKSEL == BLK_SEL)) begin
      if (WRE === 1'b1) begin         // === : an unconnected WRE is z, not a write
        mem[a] <= DI[W-1:0];
        if      (WRITE_MODE == 2) dout_r <= mem[a];       // read before write
        else if (WRITE_MODE == 1) dout_r <= DI[W-1:0];    // write through
      end else begin
        dout_r <= mem[a];
      end
    end
  end
endmodule
