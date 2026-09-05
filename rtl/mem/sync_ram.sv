// Single-port synchronous memory, one clock of read latency.
//
// The core drives the address through T1 and latches the byte at the end of
// T2, so one clock of latency is exactly what it wants when clk_en marks
// T-states.  Both Vivado and yosys infer block RAM from this shape; on an
// iCE40 the RAM banks are better served by z80fpga's SPRAM wrapper, which
// this module falls back to only when SPRAM is not available.

`ifndef SYNC_RAM_SV
`define SYNC_RAM_SV

module sync_ram #(
    parameter int  AW        = 15,
    parameter bit  READ_ONLY = 1'b0,
    parameter      INIT_FILE = ""
) (
    input  logic          clk,
    input  logic          en,
    input  logic [AW-1:0] addr,
    input  logic    [7:0] wdata,
    input  logic          we,
    output logic    [7:0] rdata
);

  logic [7:0] mem [0:(1 << AW) - 1];

  initial begin
    // Zero first, so a short init file leaves defined bytes above it in
    // simulation the way an FPGA's block RAM does on the real part.  Hidden
    // from synthesis: unrolling it over a 256 KB array is minutes of work for
    // a result the tools already give for free.
    // synthesis translate_off
    for (int i = 0; i < (1 << AW); i++) mem[i] = 8'h00;
    // synthesis translate_on
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  always_ff @(posedge clk) begin
    if (en) begin
      if (we && !READ_ONLY) mem[addr] <= wdata;
      rdata <= mem[addr];
    end
  end

endmodule

`endif
