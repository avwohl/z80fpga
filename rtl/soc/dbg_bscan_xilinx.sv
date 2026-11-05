// The Xilinx 7-series BSCANE2 for the debug unit's JTAG link, and nothing
// else.  Synthesis only: Icarus Verilog and Verilator have no BSCANE2, so the
// benches drive dbg_jtag_link's TAP ports themselves and lint gets
// sim/bscane2_stub.v.  A board's top level instantiates this module and wires
// it to z80_soc's dbg_jt* ports.
//
// JTAG_CHAIN = 3 selects the instruction USER3 (6'b100010, 0x22, IR length 6
// on 7-series), so the Vivado debug hub, which takes USER1 and USER2, and
// this unit do not collide.  The pins are the configuration JTAG pins; the
// board needs no constraint for them.
//
// TCK goes through a BUFG, as the Vivado debug hub's does.  No Vivado has run
// this file.

`ifndef DBG_BSCAN_XILINX_SV
`define DBG_BSCAN_XILINX_SV

module dbg_bscan_xilinx (
    output logic tck,
    output logic sel,
    output logic capture,
    output logic shift,
    output logic update,
    output logic tdi,
    output logic reset,
    input  logic tdo
);

  logic tck_raw, drck_nc, runtest_nc, tms_nc;

  BSCANE2 #(.JTAG_CHAIN (3)) u_bscan (
      .CAPTURE (capture), .DRCK (drck_nc), .RESET (reset), .RUNTEST (runtest_nc),
      .SEL (sel), .SHIFT (shift), .TCK (tck_raw), .TDI (tdi), .TMS (tms_nc),
      .UPDATE (update), .TDO (tdo)
  );

  BUFG u_tck_buf (.I (tck_raw), .O (tck));

  logic unused;
  assign unused = &{1'b0, drck_nc, runtest_nc, tms_nc};

endmodule

`endif
