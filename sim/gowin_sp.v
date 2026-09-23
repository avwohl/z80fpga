// Behavioural Gowin single-port BSRAMs, for simulating a synthesised netlist
// rather than the RTL.
//
// The OSS CAD Suite ships both `SP` and `SPX9` as empty `(* blackbox *)`
// cells, so a post-synthesis simulation of a design with block RAM in it
// reads back zz and looks like the flow being an invalid instrument.  It is
// not; the memories were simply missing.  What it takes to get a netlist
// that runs:
//
//   * both models, not just SP.  A design can put its wide memories in SPX9
//     and everything else in SP, and modelling only SP leaves the other one
//     undriven with no error anywhere.  On the Tang Nano netlist the single
//     SPX9 is the core's dispatch table, without which nothing sequences:
//     its output goes z, the micro-PC logic goes X one clock after reset
//     releases, and the address bus follows.
//   * the x9 parameter width.  SP's INIT_RAM_00..3F are 256 bits each,
//     16384 in all.  SPX9's are **288**, for 18432 -- the block's parity
//     bits are part of the array in x9 mode, which is the whole point of it.
//     Get this wrong and the memory still elaborates, still simulates, and
//     quietly holds the wrong contents.
//   * a driver for the constant-0 net.  write_verilog aliases the constant
//     nets onto ordinary signal names and emits a driver only for the
//     constant-1 one (a VCC cell).  Here the constant-0 alias is
//     `u_soc.dma_ack`, which reaches 2010 places including every block's
//     BLKSEL and RESET, and is declared and never driven.  Run `setundef
//     -undriven -zero` before write_verilog, and tie whatever is left.
//   * the word address read from the HIGH bits of AD.  A depth-expanded
//     memory's group select is exactly what lives up there.  The netlist
//     shows it plainly: the 8 KB ROM is four BIT_WIDTH=2 blocks wired
//     `.AD({a[12:0], 1'b0})`, the dispatch table `.AD({disp_sel, 3'b000})`.
//
// Only what that netlist uses is modelled: WRITE_MODE 2 (read before write)
// and READ_MODE 0 (no output pipeline register).

module SP (DO, DI, BLKSEL, AD, WRE, CLK, CE, OCE, RESET);
  parameter READ_MODE  = 1'b0;
  parameter WRITE_MODE = 2'b00;
  parameter BIT_WIDTH  = 32;
  parameter BLK_SEL    = 3'b000;
  parameter RESET_MODE = "SYNC";
  parameter [255:0] INIT_RAM_00 = 256'h0;
  parameter [255:0] INIT_RAM_01 = 256'h0;
  parameter [255:0] INIT_RAM_02 = 256'h0;
  parameter [255:0] INIT_RAM_03 = 256'h0;
  parameter [255:0] INIT_RAM_04 = 256'h0;
  parameter [255:0] INIT_RAM_05 = 256'h0;
  parameter [255:0] INIT_RAM_06 = 256'h0;
  parameter [255:0] INIT_RAM_07 = 256'h0;
  parameter [255:0] INIT_RAM_08 = 256'h0;
  parameter [255:0] INIT_RAM_09 = 256'h0;
  parameter [255:0] INIT_RAM_0A = 256'h0;
  parameter [255:0] INIT_RAM_0B = 256'h0;
  parameter [255:0] INIT_RAM_0C = 256'h0;
  parameter [255:0] INIT_RAM_0D = 256'h0;
  parameter [255:0] INIT_RAM_0E = 256'h0;
  parameter [255:0] INIT_RAM_0F = 256'h0;
  parameter [255:0] INIT_RAM_10 = 256'h0;
  parameter [255:0] INIT_RAM_11 = 256'h0;
  parameter [255:0] INIT_RAM_12 = 256'h0;
  parameter [255:0] INIT_RAM_13 = 256'h0;
  parameter [255:0] INIT_RAM_14 = 256'h0;
  parameter [255:0] INIT_RAM_15 = 256'h0;
  parameter [255:0] INIT_RAM_16 = 256'h0;
  parameter [255:0] INIT_RAM_17 = 256'h0;
  parameter [255:0] INIT_RAM_18 = 256'h0;
  parameter [255:0] INIT_RAM_19 = 256'h0;
  parameter [255:0] INIT_RAM_1A = 256'h0;
  parameter [255:0] INIT_RAM_1B = 256'h0;
  parameter [255:0] INIT_RAM_1C = 256'h0;
  parameter [255:0] INIT_RAM_1D = 256'h0;
  parameter [255:0] INIT_RAM_1E = 256'h0;
  parameter [255:0] INIT_RAM_1F = 256'h0;
  parameter [255:0] INIT_RAM_20 = 256'h0;
  parameter [255:0] INIT_RAM_21 = 256'h0;
  parameter [255:0] INIT_RAM_22 = 256'h0;
  parameter [255:0] INIT_RAM_23 = 256'h0;
  parameter [255:0] INIT_RAM_24 = 256'h0;
  parameter [255:0] INIT_RAM_25 = 256'h0;
  parameter [255:0] INIT_RAM_26 = 256'h0;
  parameter [255:0] INIT_RAM_27 = 256'h0;
  parameter [255:0] INIT_RAM_28 = 256'h0;
  parameter [255:0] INIT_RAM_29 = 256'h0;
  parameter [255:0] INIT_RAM_2A = 256'h0;
  parameter [255:0] INIT_RAM_2B = 256'h0;
  parameter [255:0] INIT_RAM_2C = 256'h0;
  parameter [255:0] INIT_RAM_2D = 256'h0;
  parameter [255:0] INIT_RAM_2E = 256'h0;
  parameter [255:0] INIT_RAM_2F = 256'h0;
  parameter [255:0] INIT_RAM_30 = 256'h0;
  parameter [255:0] INIT_RAM_31 = 256'h0;
  parameter [255:0] INIT_RAM_32 = 256'h0;
  parameter [255:0] INIT_RAM_33 = 256'h0;
  parameter [255:0] INIT_RAM_34 = 256'h0;
  parameter [255:0] INIT_RAM_35 = 256'h0;
  parameter [255:0] INIT_RAM_36 = 256'h0;
  parameter [255:0] INIT_RAM_37 = 256'h0;
  parameter [255:0] INIT_RAM_38 = 256'h0;
  parameter [255:0] INIT_RAM_39 = 256'h0;
  parameter [255:0] INIT_RAM_3A = 256'h0;
  parameter [255:0] INIT_RAM_3B = 256'h0;
  parameter [255:0] INIT_RAM_3C = 256'h0;
  parameter [255:0] INIT_RAM_3D = 256'h0;
  parameter [255:0] INIT_RAM_3E = 256'h0;
  parameter [255:0] INIT_RAM_3F = 256'h0;

  output     [31:0] DO;
  input      [31:0] DI;
  input       [2:0] BLKSEL;
  input      [13:0] AD;
  input             WRE, CLK, CE, OCE, RESET;

  localparam integer W     = BIT_WIDTH;
  localparam integer BITS  = 16384;
  localparam integer DEPTH = BITS / W;
  localparam integer AB    = $clog2(DEPTH);

  reg [W-1:0] mem [0:DEPTH-1];
  reg [W-1:0] dout_r;
  reg [BITS-1:0] initv;
  integer i;
  initial begin
    initv = {INIT_RAM_3F, INIT_RAM_3E, INIT_RAM_3D, INIT_RAM_3C, INIT_RAM_3B, INIT_RAM_3A, INIT_RAM_39, INIT_RAM_38, INIT_RAM_37, INIT_RAM_36, INIT_RAM_35, INIT_RAM_34, INIT_RAM_33, INIT_RAM_32, INIT_RAM_31, INIT_RAM_30, INIT_RAM_2F, INIT_RAM_2E, INIT_RAM_2D, INIT_RAM_2C, INIT_RAM_2B, INIT_RAM_2A, INIT_RAM_29, INIT_RAM_28, INIT_RAM_27, INIT_RAM_26, INIT_RAM_25, INIT_RAM_24, INIT_RAM_23, INIT_RAM_22, INIT_RAM_21, INIT_RAM_20, INIT_RAM_1F, INIT_RAM_1E, INIT_RAM_1D, INIT_RAM_1C, INIT_RAM_1B, INIT_RAM_1A, INIT_RAM_19, INIT_RAM_18, INIT_RAM_17, INIT_RAM_16, INIT_RAM_15, INIT_RAM_14, INIT_RAM_13, INIT_RAM_12, INIT_RAM_11, INIT_RAM_10, INIT_RAM_0F, INIT_RAM_0E, INIT_RAM_0D, INIT_RAM_0C, INIT_RAM_0B, INIT_RAM_0A, INIT_RAM_09, INIT_RAM_08, INIT_RAM_07, INIT_RAM_06, INIT_RAM_05, INIT_RAM_04, INIT_RAM_03, INIT_RAM_02, INIT_RAM_01, INIT_RAM_00};
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
  localparam integer BITS  = 18432;
  localparam integer DEPTH = BITS / W;
  localparam integer AB    = $clog2(DEPTH);

  reg [W-1:0] mem [0:DEPTH-1];
  reg [W-1:0] dout_r;
  reg [BITS-1:0] initv;
  integer i;
  initial begin
    initv = {INIT_RAM_3F, INIT_RAM_3E, INIT_RAM_3D, INIT_RAM_3C, INIT_RAM_3B, INIT_RAM_3A, INIT_RAM_39, INIT_RAM_38, INIT_RAM_37, INIT_RAM_36, INIT_RAM_35, INIT_RAM_34, INIT_RAM_33, INIT_RAM_32, INIT_RAM_31, INIT_RAM_30, INIT_RAM_2F, INIT_RAM_2E, INIT_RAM_2D, INIT_RAM_2C, INIT_RAM_2B, INIT_RAM_2A, INIT_RAM_29, INIT_RAM_28, INIT_RAM_27, INIT_RAM_26, INIT_RAM_25, INIT_RAM_24, INIT_RAM_23, INIT_RAM_22, INIT_RAM_21, INIT_RAM_20, INIT_RAM_1F, INIT_RAM_1E, INIT_RAM_1D, INIT_RAM_1C, INIT_RAM_1B, INIT_RAM_1A, INIT_RAM_19, INIT_RAM_18, INIT_RAM_17, INIT_RAM_16, INIT_RAM_15, INIT_RAM_14, INIT_RAM_13, INIT_RAM_12, INIT_RAM_11, INIT_RAM_10, INIT_RAM_0F, INIT_RAM_0E, INIT_RAM_0D, INIT_RAM_0C, INIT_RAM_0B, INIT_RAM_0A, INIT_RAM_09, INIT_RAM_08, INIT_RAM_07, INIT_RAM_06, INIT_RAM_05, INIT_RAM_04, INIT_RAM_03, INIT_RAM_02, INIT_RAM_01, INIT_RAM_00};
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
