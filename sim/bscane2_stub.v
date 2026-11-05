// Stand-ins for the Xilinx primitives that rtl/soc/dbg_bscan_xilinx.sv
// instantiates, so Verilator can lint that file.  Lint only: no simulation
// and no board build reads this file.
module BSCANE2 #(parameter integer JTAG_CHAIN = 1) (
    output CAPTURE, output DRCK, output RESET, output RUNTEST, output SEL,
    output SHIFT, output TCK, output TDI, output TMS, output UPDATE,
    input TDO
);
  assign CAPTURE = TDO;
  assign DRCK = 1'b0;
  assign RESET = 1'b0;
  assign RUNTEST = 1'b0;
  assign SEL = 1'b0;
  assign SHIFT = 1'b0;
  assign TCK = 1'b0;
  assign TDI = 1'b0;
  assign TMS = 1'b0;
  assign UPDATE = 1'b0;
endmodule

module BUFG (input I, output O);
  assign O = I;
endmodule
