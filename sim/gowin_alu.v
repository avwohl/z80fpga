// cells_sim.v's ALU, verbatim except for the I2 port.
//
// nextpnr connects I2 on every ALU it emits; the suite's own model does not
// declare it, so a post-place-and-route netlist will not elaborate against
// the library it came with.  None of the modes this design uses reads I2 --
// they are all ADDSUB -- so the port is accepted and ignored.

module ALU (SUM, COUT, I0, I1, I2, I3, CIN);

input I0;
input I1;
input I2;   // connected by nextpnr, unused by every mode here
input I3;
(* abc9_carry *) input CIN;
output SUM;
(* abc9_carry *) output COUT;

localparam ADD = 0;
localparam SUB = 1;
localparam ADDSUB = 2;
localparam NE = 3;
localparam GE = 4;
localparam LE = 5;
localparam CUP = 6;
localparam CDN = 7;
localparam CUPCDN = 8;
localparam MULT = 9;

parameter ALU_MODE = 0;

reg S, C;

specify
	(I0 => SUM) = (1043, 1432);
	(I1 => SUM) = (775, 1049);
	(I3 => SUM) = (751, 1010);
	(CIN => SUM) = (694, 811);
	(I0  => COUT) = (1010, 1380);
	(I1  => COUT) = (1021, 1505);
	(I3  => COUT) = (483, 792);
	(CIN => COUT) = (49, 82);
endspecify

assign SUM = S ^ CIN;
assign COUT = S? CIN : C;

always @* begin
	case (ALU_MODE)
		ADD: begin
			S = I0 ^ I1;
			C = I0;
		end
		SUB: begin
			S = I0 ^ ~I1;
			C = I0;
		end
		ADDSUB: begin
			S = I3? I0 ^ I1 : I0 ^ ~I1;
			C = I0;
		end
		NE: begin
			S = I0 ^ ~I1;
			C = 1'b1;
		end
		GE: begin
			S = I0 ^ ~I1;
			C = I0;
		end
		LE: begin
			S = ~I0 ^ I1;
			C = I1;
		end
		CUP: begin
			S = I0;
			C = 1'b0;
		end
		CDN: begin
			S = ~I0;
			C = 1'b1;
		end
		CUPCDN: begin
			S = I3? I0 : ~I0;
			C = I0;
		end
		MULT: begin
			S = (I0 & I1) ^ I3;
			C = I0 & I1;
		end
	endcase
end

endmodule

// The three helper cells nextpnr's packer inserts around a carry chain.  The
// suite's ALU has no default in its `case (ALU_MODE)`, so a string mode
// latches S and C and the netlist simulates as X.  Their meanings come from
// apicula's chipdb, which names the LUT patterns:
//
//   C2L    "CIN->LOGIC ... side effect: clears the carry"  -> SUM = CIN, COUT = 0
//   ONE2C  "1->CIN"                                        -> COUT = 1
//   (none) the chain head, named *_HEAD_ALULC              -> COUT = 0
//
// Written in the same shape as the ALU above, where SUM = S ^ CIN and
// COUT = S ? CIN : C, so each is just a choice of S and C.
module ALU_C2L (output SUM, output COUT, input I0, I1, I2, I3, CIN);
  assign SUM  = CIN;        // S = 0
  assign COUT = 1'b0;       // C = 0: the carry is cleared
endmodule

module ALU_ONE2C (output SUM, output COUT, input I0, I1, I2, I3, CIN);
  assign SUM  = CIN;        // S = 0
  assign COUT = 1'b1;       // C = 1: a one into the chain
endmodule

module ALU_HEAD (output SUM, output COUT, input I0, I1, I2, I3, CIN);
  assign SUM  = CIN;
  assign COUT = 1'b0;       // a chain that starts with no carry
endmodule
