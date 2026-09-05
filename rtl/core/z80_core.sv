// Zilog Z80 CPU core.
//
// Microcoded: tools/gen_z80.py builds z80_ucode.mem (the micro-programs) and
// z80_dispatch.mem (opcode -> entry point) from a Python description of the
// instruction set.  This module is the engine that runs them - the fetch and
// prefix unit, the T-state sequencer, the register file, and the glue that
// applies each micro-op's action.
//
// Execution model (tools/z80_enc.py carries the full note): a micro-op is
// {action, bus cycle}.  The action is applied on the clock edge that enters
// the micro-op, which is the same edge on which the previous bus cycle
// retires, so an action can consume the byte that cycle just read.  A
// zero-length micro-op's bus cycle is the *next* micro-op's, which is why the
// generator refuses to let that next micro-op carry an action of its own.
//
// Bus timing follows the "simplified memory access" model the SingleStepTests
// suite uses: MREQ/RD/WR pulse for one T-state - T2 for memory, T3 for I/O -
// and the refresh address appears during T3-T4 of M1.  Set STROBE_1T = 0 for
// an external bus that needs the strobes held the way the real part drives
// them.
//
// One `clk_en` tick is one T-state; tie it high to run at the clock rate.

`ifndef Z80_CORE_SV
`define Z80_CORE_SV

module z80_core #(
    parameter bit STROBE_1T = 1'b1,
    parameter     UCODE_MEM = "z80_ucode.mem",
    parameter     DISP_MEM  = "z80_dispatch.mem"
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clk_en,

    output logic [15:0] a,
    input  logic  [7:0] din,
    output logic  [7:0] dout,

    output logic        mreq_n,
    output logic        iorq_n,
    output logic        rd_n,
    output logic        wr_n,
    output logic        m1_n,
    output logic        rfsh_n,
    output logic        halt_n,
    output logic        busak_n,

    input  logic        wait_n,
    input  logic        int_n,
    input  logic        nmi_n,
    input  logic        busrq_n
);

`include "z80_defs.svh"

`define UF(w, f) w[UFL_``f +: UFW_``f]

  // ======================================================================
  // microcode and dispatch ROMs
  // ======================================================================
  localparam int TAB_BASE = 0;
  localparam int TAB_DDFD = 256;
  localparam int TAB_CB   = 512;
  localparam int TAB_DDCB = 768;
  localparam int TAB_ED   = 1024;

  logic [UW-1:0]   urom [0:UROM_N-1];
  logic [UPCW-1:0] drom [0:1279];        // five 256-entry tables

  initial begin
    $readmemh(UCODE_MEM, urom);
    $readmemh(DISP_MEM,  drom);
  end

  // ======================================================================
  // architectural state
  // ======================================================================
  logic  [7:0] rB, rC, rD, rE, rH, rL, rA, rF;
  logic  [7:0] sB, sC, sD, sE, sH, sL, sA, sF;   // the alternate set
  logic [15:0] rIX, rIY, rSP, rPC, rWZ;
  logic  [7:0] rI, rR;
  logic  [7:0] rDIN, rTMP;
  logic  [7:0] rQ, qPrev;         // Q, and the value SCF/CCF get to see
  logic        pFlag;             // "LD A,I or LD A,R was the last instruction"
  logic        iff1, iff2;
  logic  [1:0] im;
  logic        halted;
  logic  [7:0] ir;                // the opcode being executed

  logic        pfx_v, pfx_iy;     // DD / FD substitution active
  logic  [1:0] tab_sel;           // 0 base or DD/FD, 1 CB, 2 ED

  logic  [2:0] phase;
  logic [UPCW-1:0] upc;
  logic  [3:0] tcnt;
  logic        blk_rep;
  logic        nmi_q, nmi_pend;
  logic        first_m1;
  logic [15:0] abus;

  localparam logic [2:0] PH_M1   = 3'd0;
  localparam logic [2:0] PH_XD   = 3'd1;   // DD CB displacement byte
  localparam logic [2:0] PH_XOP  = 3'd2;   // DD CB opcode byte
  localparam logic [2:0] PH_EXEC = 3'd3;
  localparam logic [2:0] PH_ACK  = 3'd4;   // INT acknowledge
  localparam logic [2:0] PH_NMIA = 3'd5;   // NMI acknowledge

  // ======================================================================
  // forward-declared combinational nets
  // ======================================================================
  logic [UW-1:0]   uw_cur, uw_ent, uw_run, uw_alu, uw_bus;
  logic [UPCW-1:0] ent_upc, run_upc, disp_entry;
  logic            do_enter, chained, ent_go, nx_go, act_valid;
  logic            is_prefix_byte, starts_ddcb;
  logic  [7:0]     opcode, alu_res, alu_fo, alu_b;
  logic [15:0]     hl_star, asrc_val, eff_addr, rp_val;
  logic            blk_more_c;

  logic  [7:0] ir_x;     // `ir` as the action edge sees it
  logic [15:0] pc_x;     // likewise PC: the fetch bumps it on that same edge
  logic [15:0] wz_x;     // and WZ, which DD CB fills with IX+d there
  logic [15:0] ddcb_addr;
  logic  [7:0] q_x;      // Q, handed over on the fetch edge
  logic  [7:0] r_x;      // R, which the fetch bumps on that edge too
  logic [15:0] bc_x;     // BC, whose B the OUTx group decrements first


  assign uw_cur = urom[upc];
  assign uw_ent = urom[ent_upc];
  assign uw_run = urom[run_upc];
  assign opcode = rDIN;
  assign hl_star = pfx_v ? (pfx_iy ? rIY : rIX) : {rH, rL};
  // DD CB d op: the displacement was parked in Z, DIN now holds the opcode
  assign ddcb_addr = hl_star + {{8{rWZ[7]}}, rWZ[7:0]};

  // ======================================================================
  // register selector resolution
  // ======================================================================
  function automatic logic [4:0] raw8(input logic [2:0] i);
    case (i)
      3'd4:    raw8 = DAT_HRAW;
      3'd5:    raw8 = DAT_LRAW;
      default: raw8 = {2'd0, i};
    endcase
  endfunction

  function automatic logic [4:0] resolve(input logic [4:0] sel);
    case (sel)
      DAT_RLO:  resolve = {2'd0, ir_x[2:0]};
      DAT_RHI:  resolve = {2'd0, ir_x[5:3]};
      DAT_RLOR: resolve = raw8(ir_x[2:0]);
      DAT_RHIR: resolve = raw8(ir_x[5:3]);
      DAT_RLOT: resolve = (ir_x[2:0] == 3'd6) ? DAT_TMP : raw8(ir_x[2:0]);
      DAT_RPH:  case (ir_x[5:4])
                  2'd0:    resolve = DAT_B;
                  2'd1:    resolve = DAT_D;
                  2'd2:    resolve = DAT_H;
                  default: resolve = DAT_SPH;
                endcase
      DAT_RPL:  case (ir_x[5:4])
                  2'd0:    resolve = DAT_C;
                  2'd1:    resolve = DAT_E;
                  2'd2:    resolve = DAT_L;
                  default: resolve = DAT_SPL;
                endcase
      DAT_RQH:  case (ir_x[5:4])
                  2'd0:    resolve = DAT_B;
                  2'd1:    resolve = DAT_D;
                  2'd2:    resolve = DAT_H;
                  default: resolve = DAT_A;
                endcase
      DAT_RQL:  case (ir_x[5:4])
                  2'd0:    resolve = DAT_C;
                  2'd1:    resolve = DAT_E;
                  2'd2:    resolve = DAT_L;
                  default: resolve = DAT_F;
                endcase
      default:  resolve = sel;
    endcase
  endfunction

  function automatic logic [7:0] rd8(input logic [4:0] s);
    case (s)
      DAT_B:    rd8 = rB;
      DAT_C:    rd8 = rC;
      DAT_D:    rd8 = rD;
      DAT_E:    rd8 = rE;
      DAT_H:    rd8 = hl_star[15:8];
      DAT_L:    rd8 = hl_star[7:0];
      DAT_DIN:  rd8 = rDIN;
      DAT_A:    rd8 = rA;
      DAT_F:    rd8 = rF;
      DAT_W:    rd8 = rWZ[15:8];
      DAT_Z:    rd8 = rWZ[7:0];
      DAT_I:    rd8 = rI;
      DAT_R:    rd8 = r_x;
      DAT_SPH:  rd8 = rSP[15:8];
      DAT_SPL:  rd8 = rSP[7:0];
      DAT_PCH:  rd8 = rPC[15:8];
      DAT_PCL:  rd8 = rPC[7:0];
      DAT_HRAW: rd8 = rH;
      DAT_LRAW: rd8 = rL;
      DAT_TMP:  rd8 = rTMP;
      default:  rd8 = 8'h00;                    // ZERO, NONE
    endcase
  endfunction

  // ======================================================================
  // ALU
  // ======================================================================
  assign uw_alu = do_enter ? uw_ent : uw_cur;
  assign alu_b  = rd8(resolve(`UF(uw_alu, DS)));

  z80_alu u_alu (
      .op   (`UF(uw_alu, ALU)),
      .a    (rA),
      .b    (alu_b),
      .f    (rF),
      .q    (q_x),
      .bsel (ir_x[5:3]),
      .iff2 (iff2),
      .wreg (rWZ[15:8]),
      .res  (alu_res),
      .fo   (alu_fo)
  );

  // ======================================================================
  // address generation for the bus cycle that is starting or running
  // ======================================================================
  assign uw_bus = do_enter ? uw_run : uw_cur;

  always_comb begin
    case (ir_x[5:4])
      2'd0:    rp_val = {rB, rC};
      2'd1:    rp_val = {rD, rE};
      2'd2:    rp_val = hl_star;
      default: rp_val = rSP;
    endcase
  end

  always_comb begin
    case (`UF(uw_bus, ASRC))
      ASRC_PC:   asrc_val = pc_x;
      ASRC_SP:   asrc_val = rSP;
      ASRC_HL:   asrc_val = hl_star;
      ASRC_BC:   asrc_val = bc_x;
      ASRC_DE:   asrc_val = {rD, rE};
      ASRC_WZ:   asrc_val = wz_x;
      ASRC_RP:   asrc_val = rp_val;
      ASRC_AZ:   asrc_val = {rA, rWZ[7:0]};
      ASRC_HLR:  asrc_val = {rH, rL};
      ASRC_DER:  asrc_val = {rD, rE};
      ASRC_BCR:  asrc_val = bc_x;
      ASRC_RST:  asrc_val = {10'd0, ir_x[5:3], 3'd0};
      ASRC_SPP1: asrc_val = rSP + 16'd1;
      default:   asrc_val = pc_x;
    endcase
  end

  assign eff_addr = (`UF(uw_bus, AINC) == AINC_PREDEC) ? asrc_val - 16'd1
                                                       : asrc_val;

  // ======================================================================
  // T-state sequencing
  // ======================================================================
  logic [3:0] tlen, strobe_t;
  logic       is_m1, is_io, is_write, is_read, in_exec;
  logic [2:0] cur_bus;

  assign in_exec = (phase == PH_EXEC);
  assign cur_bus = `UF(uw_cur, BUS);
  assign is_m1   = (phase == PH_M1);
  assign is_io   = in_exec && ((cur_bus == BUS_IOR) || (cur_bus == BUS_IOW));
  assign is_write= in_exec && ((cur_bus == BUS_MW)  || (cur_bus == BUS_IOW));
  assign is_read = !in_exec || (cur_bus == BUS_MR)  || (cur_bus == BUS_IOR);

  always_comb begin
    case (phase)
      PH_M1:   tlen = 4'd4;
      PH_XD:   tlen = 4'd3;
      PH_XOP:  tlen = 4'd5;
      PH_ACK:  tlen = 4'd6;
      PH_NMIA: tlen = 4'd5;
      default: case (cur_bus)
                 BUS_INT: tlen = 4'd1 + {1'b0, `UF(uw_cur, TX)};
                 BUS_MR,
                 BUS_MW:  tlen = 4'd3 + {1'b0, `UF(uw_cur, TX)};
                 BUS_IOR,
                 BUS_IOW: tlen = 4'd4 + {1'b0, `UF(uw_cur, TX)};
                 default: tlen = 4'd0;
               endcase
    endcase
  end

  // I/O and interrupt acknowledge strobe in T3, memory in T2
  assign strobe_t = (is_io || phase == PH_ACK || phase == PH_NMIA) ? 4'd3 : 4'd2;

  logic waiting, latch_now, cyc_done, has_bus;
  assign has_bus   = (tlen != 4'd0);
  assign waiting   = has_bus && (tcnt == strobe_t) && !wait_n &&
                     (phase != PH_NMIA) && (in_exec ? (cur_bus != BUS_INT) : 1'b1);
  assign latch_now = clk_en && has_bus && !waiting && (tcnt == strobe_t) &&
                     is_read && (!in_exec || cur_bus == BUS_MR ||
                                 cur_bus == BUS_IOR);
  assign cyc_done  = !has_bus || ((tcnt >= tlen) && !waiting);

  // ======================================================================
  // bus pins
  // ======================================================================
  logic strobe_win, mem_cycle, io_cycle;

  assign mem_cycle = has_bus && (!in_exec ? (phase != PH_ACK && phase != PH_NMIA)
                                          : (cur_bus == BUS_MR || cur_bus == BUS_MW));
  assign io_cycle  = is_io || (phase == PH_ACK);
  assign strobe_win = STROBE_1T
                    ? (tcnt == strobe_t)
                    : ((tcnt >= (io_cycle ? 4'd2 : 4'd1)) && (tcnt <= strobe_t));

  always_comb begin
    if (is_m1)
      a = (tcnt >= 3) ? {rI, rR} : rPC;
    else if (phase == PH_XD || phase == PH_XOP ||
             phase == PH_ACK || phase == PH_NMIA)
      a = rPC;
    else
      a = abus;
  end

  assign m1_n    = !((is_m1 && tcnt <= 2) || phase == PH_ACK || phase == PH_NMIA);
  assign rfsh_n  = !(is_m1 && tcnt >= 3);
  assign halt_n  = !halted;
  assign busak_n = busrq_n;
  assign dout    = rd8(resolve(`UF(uw_cur, WSRC)));

  assign mreq_n = !(strobe_win && mem_cycle);
  assign iorq_n = !(strobe_win && io_cycle);
  assign rd_n   = !(strobe_win && is_read && has_bus && (phase != PH_NMIA) &&
                    (!in_exec || cur_bus == BUS_MR || cur_bus == BUS_IOR));
  assign wr_n   = !(strobe_win && is_write);

  // ======================================================================
  // condition codes and the next-micro-op decision
  // ======================================================================
  function automatic logic cond(input logic [2:0] c);
    case (c)
      3'd0:    cond = !rF[6];        // NZ
      3'd1:    cond =  rF[6];        // Z
      3'd2:    cond = !rF[0];        // NC
      3'd3:    cond =  rF[0];        // C
      3'd4:    cond = !rF[2];        // PO
      3'd5:    cond =  rF[2];        // PE
      3'd6:    cond = !rF[7];        // P
      default: cond =  rF[7];        // M
    endcase
  endfunction

  function automatic logic nx_ok(input logic [2:0] n, input logic blk);
    case (n)
      NX_NEXT: nx_ok = 1'b1;
      NX_END:  nx_ok = 1'b0;
      NX_CC:   nx_ok = cond(ir_x[5:3]);
      NX_CCJ:  nx_ok = cond({1'b0, ir_x[4:3]});
      NX_NZ_B: nx_ok = (rB != 8'h00);
      default: nx_ok = blk;                     // NX_BLK
    endcase
  endfunction

  // The block-repeat test.  A zero-length micro-op evaluates it on the same
  // edge that produces the values, so compute it from what the EOP is about
  // to write; the CPxR form tests it 5 T-states later, off the registers.
  logic [15:0] bc_dec;
  logic  [7:0] b_dec, cp_res;
  assign bc_dec = {rB, rC} - 16'd1;
  assign b_dec  = rB - 8'd1;

  always_comb begin
    case (`UF(uw_ent, EOP))
      EOP_LDI, EOP_LDD:   blk_more_c = (bc_dec != 16'd0);
      EOP_CPI, EOP_CPD:   blk_more_c = (bc_dec != 16'd0) && (cp_res != 8'h00);
      EOP_INI, EOP_IND:   blk_more_c = (b_dec != 8'h00);
      EOP_OUTI, EOP_OUTD: blk_more_c = (rB != 8'h00);
      default:            blk_more_c = blk_rep;
    endcase
  end

  assign nx_go     = nx_ok(`UF(uw_cur, NX), blk_rep);
  // True through the T-state in which a micro-op's action will be applied,
  // so the combinational views above switch to the micro-op being entered.
  assign do_enter  = cyc_done && (phase != PH_XD) &&
                     !(is_m1 && (is_prefix_byte || starts_ddcb)) &&
                     !(in_exec && !nx_go);
  assign ir_x      = ((is_m1 || phase == PH_XOP || phase == PH_ACK) && cyc_done)
                     ? opcode : ir;
  assign pc_x      = (cyc_done && ((is_m1 && !halted) || phase == PH_XD ||
                                   phase == PH_XOP)) ? rPC + 16'd1 : rPC;
  assign wz_x      = (cyc_done && phase == PH_XOP) ? ddcb_addr : rWZ;
  assign q_x       = (cyc_done && is_m1) ? rQ : qPrev;
  assign r_x       = (cyc_done && is_m1) ? {rR[7], rR[6:0] + 7'd1} : rR;
  // OUTI/OUTD put the *decremented* B on the port address
  assign bc_x      = {(do_enter && (`UF(uw_ent, EOP) == EOP_DEC_B)) ? b_dec : rB,
                      rC};
  assign act_valid = !in_exec || nx_go;
  assign ent_go    = nx_ok(`UF(uw_ent, NX), blk_more_c);
  assign chained   = (`UF(uw_ent, BUS) == BUS_NONE) && ent_go;
  assign run_upc   = chained ? (ent_upc + 1'b1) : ent_upc;

  always_comb begin
    if (phase == PH_M1 || phase == PH_XOP)
      ent_upc = disp_entry;
    else if (phase == PH_ACK)
      ent_upc = (im == 2'd0) ? disp_entry
              : (im == 2'd2) ? UPCW'(UENT_IM2) : UPCW'(UENT_IM1);
    else if (phase == PH_NMIA)
      ent_upc = UPCW'(UENT_NMI);
    else
      ent_upc = upc + 1'b1;
  end

  // ======================================================================
  // opcode dispatch
  // ======================================================================
  // The dispatch ROM is read when the opcode byte is latched, which is at
  // least one T-state before the entry edge that needs the answer.  Reading
  // it synchronously keeps it in block RAM instead of spending a thousand
  // LUTs on a 1280-entry mux.
  logic [10:0] disp_sel;

  always_comb begin
    if (phase == PH_XOP)         disp_sel = 11'(TAB_DDCB) + {3'd0, din};
    else if (phase == PH_ACK)    disp_sel = 11'(TAB_BASE) + {3'd0, din}; // IM 0
    else if (halted)             disp_sel = 11'(TAB_BASE);              // NOPs
    else if (tab_sel == 2'd1)    disp_sel = 11'(TAB_CB)   + {3'd0, din};
    else if (tab_sel == 2'd2)    disp_sel = 11'(TAB_ED)   + {3'd0, din};
    else if (pfx_v)              disp_sel = 11'(TAB_DDFD) + {3'd0, din};
    else                         disp_sel = 11'(TAB_BASE) + {3'd0, din};
  end

  always_ff @(posedge clk) begin
    if (clk_en && latch_now) disp_entry <= drom[disp_sel];
  end

  assign is_prefix_byte = is_m1 && (tab_sel == 2'd0) && !halted &&
                          ((opcode == 8'hDD) || (opcode == 8'hFD) ||
                           (opcode == 8'hED) ||
                           ((opcode == 8'hCB) && !pfx_v));
  assign starts_ddcb    = is_m1 && (tab_sel == 2'd0) && !halted &&
                          (opcode == 8'hCB) && pfx_v;

  // ======================================================================
  // datapath helpers for the composite operations
  // ======================================================================
  logic [16:0] hl_sum, hl_dif;
  logic [12:0] hl_sum12, hl_dif12;
  logic        adc_c;

  assign adc_c    = (`UF(uw_ent, EOP) == EOP_ADC_HL) ? rF[0] : 1'b0;
  assign hl_sum   = {1'b0, hl_star} + {1'b0, rp_val} + {16'd0, adc_c};
  assign hl_sum12 = {1'b0, hl_star[11:0]} + {1'b0, rp_val[11:0]} + {12'd0, adc_c};
  assign hl_dif   = {1'b0, hl_star} - {1'b0, rp_val} - {16'd0, rF[0]};
  assign hl_dif12 = {1'b0, hl_star[11:0]} - {1'b0, rp_val[11:0]} - {12'd0, rF[0]};

  logic [15:0] sext_din;
  logic  [7:0] rep_pch;
  assign sext_din = {{8{rDIN[7]}}, rDIN};
  assign rep_pch  = rPC[15:8] - {7'd0, (rPC[7:0] < 8'd2)};

  // A repeating block I/O instruction corrects H and P/V again, using the
  // already-decremented B and the N and C the INx/OUTx step just produced.
  logic [7:0] rep_k;
  logic       rep_pf, rep_hf, rep_io;
  assign rep_io = ir_x[1];                       // ED block: z 2 = IN, 3 = OUT
  assign rep_k  = rF[0] ? (rF[1] ? rB - 8'd1 : rB + 8'd1) : rB;
  assign rep_pf = rF[2] ^ (^rep_k[2:0]);
  assign rep_hf = rF[0] ? (rF[1] ? (rB[3:0] == 4'h0) : (rB[3:0] == 4'hF))
                        : rF[4];

  logic [7:0] blk_n, cp_n2;
  logic       cp_h;
  assign blk_n  = rDIN + rA;
  assign cp_res = rA - rDIN;
  assign cp_h   = (rA[3:0] < rDIN[3:0]);
  assign cp_n2  = cp_res - {7'd0, cp_h};

  logic [8:0] io_k;
  logic [7:0] io_l;
  logic       io_dec, io_is_in;
  assign io_dec   = (`UF(uw_ent, EOP) == EOP_IND) || (`UF(uw_ent, EOP) == EOP_OUTD);
  assign io_is_in = (`UF(uw_ent, EOP) == EOP_INI) || (`UF(uw_ent, EOP) == EOP_IND);
  // INI/IND add C+-1; OUTI/OUTD add L after the pointer has moved
  assign io_l = io_is_in ? (io_dec ? rC - 8'd1 : rC + 8'd1)
                         : (io_dec ? rL - 8'd1 : rL + 8'd1);
  assign io_k = {1'b0, rDIN} + {1'b0, io_l};

  function automatic logic [7:0] blk_io_flags(input logic [7:0] bv);
    blk_io_flags = {bv[7], bv == 8'h00, bv[5], io_k[8], bv[3],
                    ~^({5'd0, io_k[2:0]} ^ bv), rDIN[7], io_k[8]};
  endfunction

  // ======================================================================
  // write helpers
  // ======================================================================
  // A read cycle retires its byte at the strobe T-state and a micro-op's
  // action lands on the retire edge, so the two never coincide; sharing one
  // write port saves a whole register-file decoder.
  logic       wr8_en;
  logic [4:0] wr8_sel;
  logic [7:0] wr8_val;

  always_comb begin
    wr8_en  = 1'b0;
    wr8_sel = DAT_NONE;
    wr8_val = din;
    if (latch_now && in_exec) begin
      wr8_en  = 1'b1;
      wr8_sel = resolve(`UF(uw_cur, PD));
    end else if (do_enter && (`UF(uw_ent, DD) != DAT_NONE)) begin
      wr8_en  = 1'b1;
      wr8_sel = resolve(`UF(uw_ent, DD));
      wr8_val = (`UF(uw_ent, ALU) == ALU_NOP) ? alu_b : alu_res;
    end
  end

  task automatic wreg(input logic [4:0] s, input logic [7:0] v);
    case (s)
      DAT_B:    rB <= v;
      DAT_C:    rC <= v;
      DAT_D:    rD <= v;
      DAT_E:    rE <= v;
      DAT_H:    if (pfx_v) begin
                  if (pfx_iy) rIY[15:8] <= v; else rIX[15:8] <= v;
                end else rH <= v;
      DAT_L:    if (pfx_v) begin
                  if (pfx_iy) rIY[7:0] <= v; else rIX[7:0] <= v;
                end else rL <= v;
      DAT_A:    rA <= v;
      DAT_F:    rF <= v;
      DAT_W:    rWZ[15:8] <= v;
      DAT_Z:    rWZ[7:0] <= v;
      DAT_I:    rI <= v;
      DAT_R:    rR <= v;
      DAT_SPH:  rSP[15:8] <= v;
      DAT_SPL:  rSP[7:0] <= v;
      DAT_PCH:  rPC[15:8] <= v;
      DAT_PCL:  rPC[7:0] <= v;
      DAT_HRAW: rH <= v;
      DAT_LRAW: rL <= v;
      DAT_TMP:  rTMP <= v;
      default:  ;                       // DIN, ZERO, ALU, NONE: discarded
    endcase
  endtask

  task automatic wr_hl(input logic [15:0] v);
    if (pfx_v) begin
      if (pfx_iy) rIY <= v; else rIX <= v;
    end else begin
      rH <= v[15:8];
      rL <= v[7:0];
    end
  endtask

  task automatic wr_rp(input logic [15:0] v);
    case (ir_x[5:4])
      2'd0:    {rB, rC} <= v;
      2'd1:    {rD, rE} <= v;
      2'd2:    wr_hl(v);
      default: rSP <= v;
    endcase
  endtask

  // ----------------------------------------------------------------------
  // the entered micro-op's action
  // ----------------------------------------------------------------------
  task automatic apply_action();
    logic [7:0] fnew;
    logic       fwrite;
    begin
      fnew   = alu_fo;
      fwrite = (`UF(uw_ent, FW) == FW_ALU);

      case (`UF(uw_ent, EOP))
        EOP_INC_RP: wr_rp(rp_val + 16'd1);
        EOP_DEC_RP: wr_rp(rp_val - 16'd1);
        EOP_ADD_HL: begin
          wr_hl(hl_sum[15:0]);
          rWZ    <= hl_star + 16'd1;
          fnew   = {rF[7], rF[6], hl_sum[13], hl_sum12[12], hl_sum[11],
                    rF[2], 1'b0, hl_sum[16]};
          fwrite = 1'b1;
        end
        EOP_ADC_HL: begin
          wr_hl(hl_sum[15:0]);
          rWZ    <= hl_star + 16'd1;
          fnew   = {hl_sum[15], hl_sum[15:0] == 16'd0, hl_sum[13],
                    hl_sum12[12], hl_sum[11],
                    (~(hl_star[15] ^ rp_val[15])) & (hl_star[15] ^ hl_sum[15]),
                    1'b0, hl_sum[16]};
          fwrite = 1'b1;
        end
        EOP_SBC_HL: begin
          wr_hl(hl_dif[15:0]);
          rWZ    <= hl_star + 16'd1;
          fnew   = {hl_dif[15], hl_dif[15:0] == 16'd0, hl_dif[13],
                    hl_dif12[12], hl_dif[11],
                    (hl_star[15] ^ rp_val[15]) & (hl_star[15] ^ hl_dif[15]),
                    1'b1, hl_dif[16]};
          fwrite = 1'b1;
        end
        EOP_JR: begin
          rPC <= rPC + sext_din;
          rWZ <= rPC + sext_din;
        end
        EOP_DISP:   rWZ <= hl_star + sext_din;
        EOP_HL_WZ:  wr_hl(rWZ);
        EOP_PC_WZ:  rPC <= rWZ;
        EOP_PC_HL:  rPC <= hl_star;
        EOP_SP_HL:  rSP <= hl_star;
        EOP_PC_RST: begin
          rPC <= {10'd0, ir_x[5:3], 3'd0};
          rWZ <= {10'd0, ir_x[5:3], 3'd0};
        end
        EOP_LDI, EOP_LDD: begin
          if (`UF(uw_ent, EOP) == EOP_LDI) begin
            {rH, rL} <= {rH, rL} + 16'd1;
            {rD, rE} <= {rD, rE} + 16'd1;
          end else begin
            {rH, rL} <= {rH, rL} - 16'd1;
            {rD, rE} <= {rD, rE} - 16'd1;
          end
          {rB, rC} <= bc_dec;
          fnew   = {rF[7], rF[6], blk_n[1], 1'b0, blk_n[3],
                    bc_dec != 16'd0, 1'b0, rF[0]};
          fwrite = 1'b1;
        end
        EOP_CPI, EOP_CPD: begin
          if (`UF(uw_ent, EOP) == EOP_CPI) begin
            {rH, rL} <= {rH, rL} + 16'd1;
            rWZ      <= rWZ + 16'd1;
          end else begin
            {rH, rL} <= {rH, rL} - 16'd1;
            rWZ      <= rWZ - 16'd1;
          end
          {rB, rC} <= bc_dec;
          fnew   = {cp_res[7], cp_res == 8'h00, cp_n2[1], cp_h, cp_n2[3],
                    bc_dec != 16'd0, 1'b1, rF[0]};
          fwrite = 1'b1;
        end
        EOP_INI, EOP_IND: begin
          rB <= b_dec;
          if (`UF(uw_ent, EOP) == EOP_INI) begin
            {rH, rL} <= {rH, rL} + 16'd1;
            rWZ      <= {rB, rC} + 16'd1;
          end else begin
            {rH, rL} <= {rH, rL} - 16'd1;
            rWZ      <= {rB, rC} - 16'd1;
          end
          fnew   = blk_io_flags(b_dec);
          fwrite = 1'b1;
        end
        EOP_OUTI, EOP_OUTD: begin
          // B was already decremented by the DEC_B on the I/O write micro-op
          if (`UF(uw_ent, EOP) == EOP_OUTI) begin
            {rH, rL} <= {rH, rL} + 16'd1;
            rWZ      <= {rB, rC} + 16'd1;
          end else begin
            {rH, rL} <= {rH, rL} - 16'd1;
            rWZ      <= {rB, rC} - 16'd1;
          end
          fnew   = blk_io_flags(rB);
          fwrite = 1'b1;
        end
        EOP_REPEAT: begin
          rPC    <= rPC - 16'd2;
          rWZ    <= rPC - 16'd1;
          // a repeating block instruction takes X and Y from PC instead
          fnew   = rep_io
                 ? {rF[7:6], rep_pch[5], rep_hf, rep_pch[3], rep_pf, rF[1:0]}
                 : {rF[7:6], rep_pch[5], rF[4],  rep_pch[3], rF[2:0]};
          fwrite = 1'b1;
        end
        EOP_WZ_BC_INC: rWZ <= {rB, rC} + 16'd1;
        EOP_WZ_A1:     rWZ <= eff_addr + 16'd1;
        EOP_WZ_WRA:    rWZ <= {rA, eff_addr[7:0] + 8'd1};
        EOP_WZ_HL1:    rWZ <= hl_star + 16'd1;
        EOP_DEC_B:     rB  <= b_dec;
        default: ;
      endcase

      case (`UF(uw_ent, EOP))
        EOP_LDI, EOP_LDD, EOP_CPI, EOP_CPD,
        EOP_INI, EOP_IND, EOP_OUTI, EOP_OUTD: blk_rep <= blk_more_c;
        default: ;
      endcase

      case (`UF(uw_ent, CTL))
        CTL_EX_DE_HL: begin
          rD <= rH; rE <= rL; rH <= rD; rL <= rE;
        end
        CTL_EXX: begin
          rB <= sB; rC <= sC; rD <= sD; rE <= sE; rH <= sH; rL <= sL;
          sB <= rB; sC <= rC; sD <= rD; sE <= rE; sH <= rH; sL <= rL;
        end
        CTL_EX_AF: begin
          rA <= sA; rF <= sF; sA <= rA; sF <= rF;
        end
        CTL_DI:     begin iff1 <= 1'b0; iff2 <= 1'b0; end
        CTL_EI:     begin iff1 <= 1'b1; iff2 <= 1'b1; end
        CTL_SET_IM: case (ir_x[5:3])
                      3'd0, 3'd1, 3'd4, 3'd5: im <= 2'd0;
                      3'd2, 3'd6:             im <= 2'd1;
                      default:                im <= 2'd2;
                    endcase
        CTL_HALT:   halted <= 1'b1;
        CTL_RETN:   iff1   <= iff2;
        CTL_SET_P:  pFlag  <= 1'b1;
        default: ;
      endcase

      if (fwrite) begin
        rF <= fnew;
        rQ <= fnew;
      end
    end
  endtask

  // ----------------------------------------------------------------------
  // address register side effects for the cycle that is starting
  // ----------------------------------------------------------------------
  task automatic apply_ainc();
    logic [15:0] nv;
    begin
      nv = (`UF(uw_run, AINC) == AINC_POSTINC) ? asrc_val + 16'd1
                                               : asrc_val - 16'd1;
      if (`UF(uw_run, AINC) != AINC_NONE) begin
        case (`UF(uw_run, ASRC))
          ASRC_PC:  rPC <= nv;
          ASRC_SP:  rSP <= nv;
          ASRC_HL:  wr_hl(nv);
          ASRC_BC:  {rB, rC} <= nv;
          ASRC_DE:  {rD, rE} <= nv;
          ASRC_WZ:  rWZ <= nv;
          ASRC_RP:  wr_rp(nv);
          ASRC_HLR: {rH, rL} <= nv;
          ASRC_DER: {rD, rE} <= nv;
          ASRC_BCR: {rB, rC} <= nv;
          default: ;
        endcase
      end
    end
  endtask

  // ----------------------------------------------------------------------
  // instruction boundary
  // ----------------------------------------------------------------------
  logic accept_nmi, accept_int;
  assign accept_nmi = nmi_pend;
  // iff1 is read before the edge, so EI's own boundary is naturally blocked
  // and the instruction after EI is the first one that can be interrupted.
  assign accept_int = !int_n && iff1 && !accept_nmi;

  task automatic go_instr_end();
    begin
      pfx_v    <= 1'b0;
      tab_sel  <= 2'd0;
      first_m1 <= 1'b1;
      blk_rep  <= 1'b0;
      phase    <= accept_nmi ? PH_NMIA : accept_int ? PH_ACK : PH_M1;
    end
  endtask

  // ======================================================================
  // main sequential process
  // ======================================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rB <= 8'h00; rC <= 8'h00; rD <= 8'h00; rE <= 8'h00;
      rH <= 8'h00; rL <= 8'h00; rA <= 8'hFF; rF <= 8'hFF;
      sB <= 8'h00; sC <= 8'h00; sD <= 8'h00; sE <= 8'h00;
      sH <= 8'h00; sL <= 8'h00; sA <= 8'hFF; sF <= 8'hFF;
      rIX <= 16'hFFFF; rIY <= 16'hFFFF; rSP <= 16'hFFFF;
      rPC <= 16'h0000; rWZ <= 16'h0000;
      rI  <= 8'h00; rR <= 8'h00; rDIN <= 8'h00; rTMP <= 8'h00;
      rQ  <= 8'h00; qPrev <= 8'h00; pFlag <= 1'b0;
      iff1 <= 1'b0; iff2 <= 1'b0; im <= 2'd0; halted <= 1'b0;
      ir <= 8'h00; pfx_v <= 1'b0; pfx_iy <= 1'b0; tab_sel <= 2'd0;
      phase <= PH_M1; upc <= '0; tcnt <= 4'd1; abus <= 16'h0000;
      blk_rep <= 1'b0; first_m1 <= 1'b1;
      nmi_q <= 1'b1; nmi_pend <= 1'b0;
    end else begin
      nmi_q <= nmi_n;
      if (nmi_q && !nmi_n) nmi_pend <= 1'b1;

      if (clk_en) begin
        // The refresh address stays on the pins through any internal cycle
        // that follows the fetch, which is what the bus traces show.
        if (is_m1 && (tcnt == strobe_t) && !waiting) abus <= {rI, rR};

        if (latch_now) begin
          rDIN <= din;
          if (phase == PH_XD) rWZ[7:0] <= din;
        end
        if (wr8_en) wreg(wr8_sel, wr8_val);

        if (!cyc_done) begin
          if (!waiting) tcnt <= tcnt + 4'd1;
        end else begin
          tcnt <= 4'd1;

          if (is_m1) begin
            // LD R,A retires on the same edge as the second fetch's refresh
            // increment, and the instruction wins
            rR    <= (wr8_en && wr8_sel == DAT_R) ? wr8_val
                                                  : {rR[7], rR[6:0] + 7'd1};
            qPrev <= rQ;
            rQ    <= 8'h00;
            if (!halted) rPC <= rPC + 16'd1;
            if (first_m1) begin
              pFlag    <= 1'b0;
              first_m1 <= 1'b0;
            end
          end

          if (is_m1 && is_prefix_byte) begin
            case (opcode)
              8'hDD:   begin pfx_v <= 1'b1; pfx_iy <= 1'b0; end
              8'hFD:   begin pfx_v <= 1'b1; pfx_iy <= 1'b1; end
              8'hED:   begin pfx_v <= 1'b0; tab_sel <= 2'd2; end
              default: tab_sel <= 2'd1;                       // CB
            endcase
          end else if (is_m1 && starts_ddcb) begin
            phase <= PH_XD;
          end else if (phase == PH_XD) begin
            rPC   <= rPC + 16'd1;
            phase <= PH_XOP;
          end else begin
            if (is_m1 || phase == PH_XOP || phase == PH_ACK) ir <= opcode;
            if (phase == PH_XOP) begin
              rPC <= rPC + 16'd1;
              rWZ <= ddcb_addr;
            end
            if (phase == PH_ACK || phase == PH_NMIA) begin
              halted <= 1'b0;
              iff1   <= 1'b0;
              if (phase == PH_NMIA) begin
                nmi_pend <= 1'b0;
                rWZ      <= 16'h0066;
              end else begin
                iff2 <= 1'b0;
                if (im == 2'd2)      rWZ <= {rI, rDIN};
                else if (im == 2'd1) rWZ <= 16'h0038;
              end
            end

            if (in_exec && !nx_go) begin
              go_instr_end();
            end else begin
              apply_action();
              if (!chained && (`UF(uw_ent, BUS) == BUS_NONE)) begin
                go_instr_end();
              end else begin
                upc   <= run_upc;
                phase <= PH_EXEC;
                if (`UF(uw_run, BUS) != BUS_INT) abus <= eff_addr;
                apply_ainc();
              end
            end
          end
        end
      end
    end
  end

`undef UF

endmodule

`endif
