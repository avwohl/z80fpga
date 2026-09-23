// Gowin primitives a post-place-and-route netlist needs and the OSS CAD
// Suite's gowin/cells_sim.v does not provide in that shape.

// nextpnr inserts the global clock buffer during packing, so it is in the
// netlist that becomes the bitstream and not in the one yosys wrote.
module BUFG (output O, input I);
  assign O = I;
endmodule

// nextpnr names the constant drivers GOWIN_VCC / GOWIN_GND; cells_sim.v
// has them as VCC / GND.
module GOWIN_VCC (output V);
  assign V = 1'b1;
endmodule

module GOWIN_GND (output G);
  assign G = 1'b0;
endmodule

// cells_sim's RAM16SDP4, verbatim except for the CE port nextpnr connects.
// It is tied to VCC here, so it is accepted and ignored.

module RAM16SDP4 (DO, DI, WAD, RAD, WRE, CLK, CE);

parameter INIT_0 = 16'h0000;
parameter INIT_1 = 16'h0000;
parameter INIT_2 = 16'h0000;
parameter INIT_3 = 16'h0000;

input [3:0] WAD;
input [3:0] RAD;
input [3:0] DI;
output [3:0] DO;
input CLK;
input WRE;
input CE;   // nextpnr connects it, tied to VCC in this design

specify
	(RAD *> DO) = (270, 405);
	$setup(DI, posedge CLK, 62);
	$setup(WRE, posedge CLK, 62);
	$setup(WAD, posedge CLK, 62);
	(posedge CLK => (DO : 4'bx)) = (474, 565);
endspecify

reg [15:0] mem0, mem1, mem2, mem3;

initial begin
	mem0 = INIT_0;
	mem1 = INIT_1;
	mem2 = INIT_2;
	mem3 = INIT_3;
end

assign DO[0] = mem0[RAD];
assign DO[1] = mem1[RAD];
assign DO[2] = mem2[RAD];
assign DO[3] = mem3[RAD];

always @(posedge CLK) begin
	if (WRE) begin
		mem0[WAD] <= DI[0];
		mem1[WAD] <= DI[1];
		mem2[WAD] <= DI[2];
		mem3[WAD] <= DI[3];
	end
end

endmodule
