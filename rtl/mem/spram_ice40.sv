// 128 KB byte-addressed memory built from the four SB_SPRAM256KA blocks in an
// iCE40 UltraPlus.  That is exactly four 32 KB banks, which is what makes the
// UP5K parts usable for banked-memory Z80 systems at all - their block RAM
// cannot hold even one bank.
//
// Each SPRAM is 16384 x 16.  Address bit 0 picks the byte lane, the next 14
// bits address inside an SPRAM, and the top two pick which SPRAM.  Reads take
// one clock, matching rtl/mem/sync_ram.sv.
//
// Define SPRAM_BEHAVIOURAL to get a plain array instead, for simulation on a
// tool without the SB_SPRAM256KA model.

`ifndef SPRAM_ICE40_SV
`define SPRAM_ICE40_SV

module spram_ice40 (
    input  logic        clk,
    input  logic [16:0] addr,
    input  logic  [7:0] wdata,
    input  logic        we,
    output logic  [7:0] rdata
);

`ifdef SPRAM_BEHAVIOURAL

  logic [7:0] mem [0:131071];
  always_ff @(posedge clk) begin
    if (we) mem[addr] <= wdata;
    rdata <= mem[addr];
  end

`else

  logic [15:0] word_addr;
  logic  [1:0] blk;
  logic        lane;

  assign word_addr = addr[16:1];
  assign blk       = word_addr[15:14];
  assign lane      = addr[0];

  logic [15:0] dout [0:3];
  logic  [1:0] blk_q;
  logic        lane_q;

  always_ff @(posedge clk) begin
    blk_q  <= blk;
    lane_q <= lane;
  end

  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : g_spram
      SB_SPRAM256KA u_spram (
          .ADDRESS    (word_addr[13:0]),
          .DATAIN     ({wdata, wdata}),
          .MASKWREN   (lane ? 4'b1100 : 4'b0011),
          .WREN       (we && (blk == i[1:0])),
          .CHIPSELECT (1'b1),
          .CLOCK      (clk),
          .STANDBY    (1'b0),
          .SLEEP      (1'b0),
          .POWEROFF   (1'b1),          // active low: 1 means powered up
          .DATAOUT    (dout[i])
      );
    end
  endgenerate

  assign rdata = lane_q ? dout[blk_q][15:8] : dout[blk_q][7:0];

`endif

endmodule

`endif
