// A behavioural Gowin SP (single-port BSRAM), for simulating a synthesised
// netlist rather than the RTL.
//
// The OSS CAD Suite ships this primitive as an empty `(* blackbox *)`, so a
// post-synthesis simulation of a design with block RAM in it reads back zz --
// which is easy to mistake for the flow being an invalid instrument.  It is
// not invalid; the memory was simply missing.  Two things are needed:
//
//   * this model, and
//   * a driver for the constant-0 net.  write_verilog aliases the constant
//     nets onto ordinary signal names and emits a driver only for the
//     constant-1 one (a VCC cell).  On the Tang Nano netlist the constant-0
//     alias is `u_soc.dma_ack`, which reaches 2010 places including every
//     block's BLKSEL and RESET, and is declared and never driven.  Tie every
//     undriven net low, or run `setundef -undriven -zero` before writing.
//
// The word address sits in the HIGH bits of AD, which is the detail that
// matters most here: a depth-expanded memory's group select is exactly what
// lives up there.  The netlist proves it -- the Tang Nano's 8 KB ROM is four
// BIT_WIDTH=2 blocks wired `.AD({a[12:0], 1'b0})`.
//
// Only what that netlist needs is modelled: WRITE_MODE 2 (read before write)
// and READ_MODE 0 (no output pipeline register).
//
// How far this gets, measured rather than assumed: the Tang Nano netlist
// comes out of reset correctly, holds the address bus at 0 for all 128 reset
// clocks, and fetches 0F3h -- `di`, sw/boot.z80's first instruction -- out of
// the ROM.  So the model, the ROM's INIT and the netlist are right that far.
// One clock after reset releases, the CPU's address-ALU carry chain goes X
// and stays X.  The netlist has no x constants, no undriven nets and no
// uninitialised flip-flops left at that point, and driving all 32 DO bits
// instead of only the used ones changes nothing, so the cause is still open.
// Anyone picking this up starts there.
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
  localparam integer DEPTH = (W==9) ? 2048 : (W==18) ? 1024 : (W==36) ? 512
                                           : (16384/W);
  localparam integer AB    = $clog2(DEPTH);

  reg [W-1:0] mem [0:DEPTH-1];
  reg [W-1:0] dout_r;
  reg [16383:0] initv;
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
      if (WRE) begin
        mem[a] <= DI[W-1:0];
        if      (WRITE_MODE == 2) dout_r <= mem[a];       // read before write
        else if (WRITE_MODE == 1) dout_r <= DI[W-1:0];    // write through
      end else begin
        dout_r <= mem[a];
      end
    end
  end
endmodule
