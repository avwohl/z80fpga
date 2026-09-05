// Z80 8-bit ALU and flag unit.
//
// Purely combinational.  Operand A is the accumulator, operand B is whatever
// the micro-op selected.  The undocumented X (bit 3) and Y (bit 5) flags are
// modelled, including the SCF/CCF rule that mixes in the previous
// instruction's flag output (Q).
//
// Flag layout: 7 S | 6 Z | 5 Y | 4 H | 3 X | 2 P/V | 1 N | 0 C

`ifndef Z80_ALU_SV
`define Z80_ALU_SV

module z80_alu #(
    parameter int OPW = 6
) (
    input  logic [OPW-1:0] op,
    input  logic     [7:0] a,      // accumulator
    input  logic     [7:0] b,      // operand
    input  logic     [7:0] f,      // current flags
    input  logic     [7:0] q,      // flags written by the previous instruction, else 0
    input  logic     [2:0] bsel,   // bit index for BIT / RES / SET
    input  logic           iff2,   // P/V source for LD A,I and LD A,R
    input  logic     [7:0] wreg,   // MEMPTR high byte, for BIT b,(HL)
    output logic     [7:0] res,
    output logic     [7:0] fo
);

`include "z80_defs.svh"

  localparam int FC = 0, FN = 1, FV = 2, FX = 3, FH = 4, FY = 5, FZ = 6, FS = 7;

  // ---------------------------------------------------------------- helpers
  logic       cin;
  logic [7:0] arg_a;
  logic [8:0] addr_, subr_;
  logic       add_h, sub_h, add_v, sub_v;

  always_comb begin
    // ADC / SBC take the carry in; NEG computes 0 - b.
    cin   = (op == ALU_ADC || op == ALU_SBC) ? f[FC] : 1'b0;
    arg_a = (op == ALU_NEG) ? 8'h00 : a;
  end

  assign addr_ = {1'b0, arg_a} + {1'b0, b} + {8'b0, cin};
  assign subr_ = {1'b0, arg_a} - {1'b0, b} - {8'b0, cin};
  // the half-carry is the carry into bit 4, not bit 3
  assign add_h = arg_a[4] ^ b[4] ^ addr_[4];
  assign sub_h = arg_a[4] ^ b[4] ^ subr_[4];
  assign add_v = (~(arg_a[7] ^ b[7])) & (arg_a[7] ^ addr_[7]);
  assign sub_v = ( (arg_a[7] ^ b[7])) & (arg_a[7] ^ subr_[7]);

  logic [7:0] logic_r;
  always_comb begin
    unique case (op)
      ALU_AND: logic_r = a & b;
      ALU_XOR: logic_r = a ^ b;
      default: logic_r = a | b;
    endcase
  end

  // rotates and shifts (the CB-prefix forms)
  logic [7:0] shift_r;
  logic       shift_c;
  always_comb begin
    unique case (op)
      ALU_RLC, ALU_RLCA: begin shift_r = {b[6:0], b[7]};  shift_c = b[7]; end
      ALU_RRC, ALU_RRCA: begin shift_r = {b[0], b[7:1]};  shift_c = b[0]; end
      ALU_RL,  ALU_RLA:  begin shift_r = {b[6:0], f[FC]}; shift_c = b[7]; end
      ALU_RR,  ALU_RRA:  begin shift_r = {f[FC], b[7:1]}; shift_c = b[0]; end
      ALU_SLA:           begin shift_r = {b[6:0], 1'b0};  shift_c = b[7]; end
      ALU_SRA:           begin shift_r = {b[7], b[7:1]};  shift_c = b[0]; end
      ALU_SLL:           begin shift_r = {b[6:0], 1'b1};  shift_c = b[7]; end
      default:           begin shift_r = {1'b0, b[7:1]};  shift_c = b[0]; end  // SRL
    endcase
  end

  // DAA, following the correction table the NMOS part actually implements
  logic [7:0] daa_r;
  logic       daa_c, daa_h;
  logic [1:0] daa_t;
  always_comb begin
    daa_t    = 2'b00;
    if (f[FH] || (a[3:0] > 4'd9)) daa_t[0] = 1'b1;
    if (f[FC] || (a > 8'h99))     daa_t[1] = 1'b1;
    daa_c = f[FC] | daa_t[1];
    if (f[FN])
      daa_h = f[FH] && (a[3:0] < 4'd6);
    else
      daa_h = (a[3:0] > 4'd9);
    unique case (daa_t)
      2'b01:   daa_r = a + (f[FN] ? 8'hFA : 8'h06);
      2'b10:   daa_r = a + (f[FN] ? 8'hA0 : 8'h60);
      2'b11:   daa_r = a + (f[FN] ? 8'h9A : 8'h66);
      default: daa_r = a;
    endcase
  end

  // the accumulator's X/Y contribution to SCF and CCF
  logic [7:0] scf_yx;
  assign scf_yx = (a | (q ^ f)) & 8'h28;

  logic bit_v;
  assign bit_v = b[bsel];

  // ------------------------------------------------------------ result mux
  always_comb begin
    unique case (op)
      ALU_ADD, ALU_ADC:              res = addr_[7:0];
      ALU_SUB, ALU_SBC, ALU_NEG:     res = subr_[7:0];
      ALU_CP:                        res = a;
      ALU_AND, ALU_XOR, ALU_OR:      res = logic_r;
      ALU_INC:                       res = b + 8'd1;
      ALU_DEC:                       res = b - 8'd1;
      ALU_RLC, ALU_RRC, ALU_RL, ALU_RR,
      ALU_SLA, ALU_SRA, ALU_SLL, ALU_SRL,
      ALU_RLCA, ALU_RRCA, ALU_RLA, ALU_RRA: res = shift_r;
      ALU_RES:                       res = b & ~(8'd1 << bsel);
      ALU_SET:                       res = b |  (8'd1 << bsel);
      ALU_DAA:                       res = daa_r;
      ALU_CPL:                       res = ~a;
      ALU_RLDM:                      res = {b[3:0], a[3:0]};
      ALU_RLDA:                      res = {a[7:4], b[7:4]};
      ALU_RRDM:                      res = {a[3:0], b[7:4]};
      ALU_RRDA:                      res = {a[7:4], b[3:0]};
      default:                       res = b;   // NOP, BIT, INF, LDAIR, SCF, CCF
    endcase
  end

  // ------------------------------------------------------------- flag mux
  logic par;
  assign par = ~^res;          // even parity of the result

  always_comb begin
    fo = f;
    unique case (op)
      ALU_ADD, ALU_ADC: begin
        fo = {res[7], res == 8'h00, res[5], add_h, res[3], add_v, 1'b0, addr_[8]};
      end
      ALU_SUB, ALU_SBC, ALU_NEG: begin
        fo = {res[7], res == 8'h00, res[5], sub_h, res[3], sub_v, 1'b1, subr_[8]};
      end
      ALU_CP: begin
        // CP keeps the result, so X and Y come from the operand instead
        fo = {subr_[7], subr_[7:0] == 8'h00, b[5], sub_h, b[3], sub_v, 1'b1, subr_[8]};
      end
      ALU_AND: fo = {res[7], res == 8'h00, res[5], 1'b1, res[3], par, 1'b0, 1'b0};
      ALU_XOR,
      ALU_OR:  fo = {res[7], res == 8'h00, res[5], 1'b0, res[3], par, 1'b0, 1'b0};
      ALU_INC: fo = {res[7], res == 8'h00, res[5], res[3:0] == 4'h0,
                     res[3], b == 8'h7F, 1'b0, f[FC]};
      ALU_DEC: fo = {res[7], res == 8'h00, res[5], b[3:0] == 4'h0,
                     res[3], b == 8'h80, 1'b1, f[FC]};
      ALU_RLC, ALU_RRC, ALU_RL, ALU_RR,
      ALU_SLA, ALU_SRA, ALU_SLL, ALU_SRL:
               fo = {res[7], res == 8'h00, res[5], 1'b0, res[3], par, 1'b0, shift_c};
      ALU_RLCA, ALU_RRCA, ALU_RLA, ALU_RRA:
               fo = {f[FS], f[FZ], res[5], 1'b0, res[3], f[FV], 1'b0, shift_c};
      ALU_BIT: fo = {bit_v & (bsel == 3'd7), ~bit_v, b[5], 1'b1, b[3],
                     ~bit_v, 1'b0, f[FC]};
      ALU_BITM:fo = {bit_v & (bsel == 3'd7), ~bit_v, wreg[5], 1'b1, wreg[3],
                     ~bit_v, 1'b0, f[FC]};
      ALU_RES, ALU_SET: fo = f;
      ALU_DAA: fo = {res[7], res == 8'h00, res[5], daa_h, res[3], par, f[FN], daa_c};
      ALU_CPL: fo = {f[FS], f[FZ], res[5], 1'b1, res[3], f[FV], 1'b1, f[FC]};
      ALU_SCF: fo = {f[FS], f[FZ], scf_yx[5], 1'b0, scf_yx[3], f[FV], 1'b0, 1'b1};
      ALU_CCF: fo = {f[FS], f[FZ], scf_yx[5], f[FC], scf_yx[3], f[FV], 1'b0, ~f[FC]};
      ALU_INF: fo = {res[7], res == 8'h00, res[5], 1'b0, res[3], par, 1'b0, f[FC]};
      ALU_LDAIR:
               fo = {res[7], res == 8'h00, res[5], 1'b0, res[3], iff2, 1'b0, f[FC]};
      ALU_RLDA, ALU_RRDA:
               fo = {res[7], res == 8'h00, res[5], 1'b0, res[3], par, 1'b0, f[FC]};
      default: fo = f;
    endcase
  end

endmodule

`endif
