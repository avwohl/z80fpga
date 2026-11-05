// Debug unit: halts the Z80 at an instruction boundary, steps it, compares PC
// against breakpoints, reads and writes its registers and memory, and takes
// commands from a host over a serial line.  docs/debug_unit.md is the manual;
// this header is the shape of it.
//
// It owns four things in z80_soc.sv:
//
//   * core_clk_en, the core's clock enable, which it holds low when stopped.
//     The core stops at the first T-state of an opcode fetch (dbg_at_boundary),
//     so every register is whole and no bus cycle is half done.
//   * the register hooks of z80_core.sv.
//   * the memory port, while stopped.  The request goes through the same mux
//     that hdsk's DMA uses, so it reaches block RAM, DDR2 and SDRAM through the
//     MMU exactly as the CPU's own cycles do.  bank_ovr_en/bank_ovr make the
//     MMU show a chosen bank in the low window, without touching the CPU's.
//   * a serial line, on its own pins, so the console stays the guest's.
//
// Resources: LUTs and flip-flops only.  The block RAM of the Nexys RomWBW
// build is 94.81% used, and nothing here may add a tile.  The five command
// arguments are five registers, and the breakpoints are a generate loop of
// registers, so that no tool turns either into a RAM.
//
// Protocol: the host sends a command byte and its arguments; the unit answers
// with the command byte again (or 'E' and an error code).  Multi-byte values
// are little endian.  A command that stops half way is abandoned after
// TIMEOUT_CLKS without a byte (10 ms), so the host can always resynchronise by
// keeping quiet for that long.
//
//   'N'                      reply 'N'
//   'S'                      reply 'S' st nbp rev    st: see below
//   'H'                      ask for a halt at the next boundary; reply 'H'
//   'C'                      run; reply 'C'                 (E 01 if running)
//   'T'                      run one instruction; reply 'T' (E 01 if running)
//   'R' n                    reply 'R' lo hi                (E 01 if running)
//   'W' n lo hi              reply 'W'                      (E 01, E 04)
//   'M' alo ahi len          reply 'M' then len bytes (0 = 256)
//   'P' alo ahi len d0 ...   write len bytes; reply 'P' at the end
//   'B' i alo ahi bank flg   set breakpoint i; flg bit 0 enable, bit 1 bank
//                            matters; reply 'B'              (E 03 bad i)
//   'K' flg bank             flg bit 0: memory commands use `bank` in the low
//                            window; reply 'K'
//   anything else            reply 'E' 02
//
// st = {bp index[2:0], override on, stop was halt, stop was step,
//       stop was breakpoint, stopped}.
// Register numbers: 0 AF 1 BC 2 DE 3 HL 4 AF' 5 BC' 6 DE' 7 HL' 8 IX 9 IY
// 10 SP 11 PC 12 IR 13 WZ 14 {halted, IM, IFF2, IFF1} 15 the CPU's bank.
// 4 to 7 and 15 can be read and not written (E 04): the alternate set has no
// write port in the core, and the bank is the MMU's.

`ifndef DBG_UNIT_SV
`define DBG_UNIT_SV

module dbg_unit #(
    parameter int CLK_HZ        = 50_000_000,
    parameter int BAUD          = 115200,
    parameter int BP_N          = 4,            // 1 to 8
    parameter bit HALT_ON_RESET = 1'b0,         // 1: stopped at 0000H out of reset
    parameter logic [7:0] COMMON_BANK = 8'h8F,  // the MMU's high-window bank
    parameter int TIMEOUT_CLKS  = CLK_HZ / 100
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        rx,
    output logic        tx,

    // the core's clock enable, and the hooks of z80_core.sv
    input  logic        clk_en,
    output logic        core_clk_en,
    input  logic        at_boundary,
    input  logic [15:0] core_pc,
    output logic  [4:0] reg_sel,
    output logic        reg_hi,
    input  logic  [7:0] reg_rdata,
    output logic        reg_wr_en,
    output logic  [4:0] reg_wr_sel,
    output logic        reg_wr_hi,
    output logic  [7:0] reg_wr_data,

    // the MMU
    input  logic  [7:0] cur_bank,
    output logic        ovr_en,
    output logic  [7:0] ovr_bank,

    // the memory port, only used while stopped
    output logic        mem_req,
    output logic        mem_we,
    output logic [15:0] mem_addr,
    output logic  [7:0] mem_wdata,
    input  logic  [7:0] mem_rdata,
    input  logic        mem_ack,

    output logic        stopped
);

  // ----------------------------------------------------------------- serial
  logic       rx_valid, tx_busy, tx_go;
  logic [7:0] rx_data, tx_byte;

  dbg_uart #(.CLK_HZ (CLK_HZ), .BAUD (BAUD)) u_uart (
      .clk (clk), .rst_n (rst_n), .rx (rx), .tx (tx),
      .rx_valid (rx_valid), .rx_data (rx_data),
      .tx_start (tx_go), .tx_data (tx_byte), .tx_busy (tx_busy)
  );

  // ------------------------------------------------------------ breakpoints
  logic [BP_N-1:0] bp_hit;
  logic            bp_we;
  logic      [2:0] bp_wi;          // index being written
  logic      [7:0] arg0, arg1, arg2, arg3, arg4;

  logic [7:0] eff_bank;
  assign eff_bank = core_pc[15] ? COMMON_BANK : cur_bank;

  generate
    for (genvar i = 0; i < BP_N; i++) begin : g_bp
      logic [15:0] addr;
      logic  [7:0] bank;
      logic        en, bq;
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          en <= 1'b0; bq <= 1'b0; addr <= 16'h0000; bank <= 8'h00;
        end else if (bp_we && bp_wi == 3'(i)) begin
          addr <= {arg2, arg1};
          bank <= arg3;
          en   <= arg4[0];
          bq   <= arg4[1];
        end
      end
      assign bp_hit[i] = en && (core_pc == addr) && (!bq || eff_bank == bank);
    end
  endgenerate

  logic       any_hit;
  logic [2:0] hit_idx;
  always_comb begin
    any_hit = at_boundary && (|bp_hit);
    hit_idx = 3'd0;
    for (int i = BP_N - 1; i >= 0; i--)
      if (bp_hit[i]) hit_idx = 3'(i);
  end

  // ----------------------------------------------------- stop and run control
  // `skip` is set when the core is released from a boundary and cleared by its
  // first tick, which takes it off the boundary.  Without it, a breakpoint at
  // the current PC would stop the core again before it moved.
  logic skip, stepping, halt_req;
  logic why_bp, why_step, why_halt;
  logic [2:0] why_idx;
  logic stop_now;

  assign stop_now    = at_boundary && !skip && (halt_req || stepping || any_hit);
  assign core_clk_en = clk_en && !stopped && !stop_now;

  // --------------------------------------------------------- command decoder
  typedef enum logic [3:0] {
    S_OP, S_ARG, S_DISP, S_REPLY, S_RWAIT, S_RWAIT2, S_WHI,
    S_MSET, S_MREQ, S_MWAIT, S_PDATA, S_PREQ, S_PWAIT
  } state_t;

  state_t state, after;
  logic [7:0] op;
  logic [2:0] argn;
  logic [7:0] rq0, rq1, rq2, rq3;
  logic [1:0] rqn, rqi;
  logic [15:0] maddr;
  logic  [8:0] mrem;
  localparam int TW = $clog2(TIMEOUT_CLKS + 1);
  logic [TW-1:0] tmo;

  function automatic logic [2:0] nargs(input logic [7:0] c);
    case (c)
      "R":     nargs = 3'd1;
      "W":     nargs = 3'd3;
      "M":     nargs = 3'd3;
      "P":     nargs = 3'd3;
      "B":     nargs = 3'd5;
      "K":     nargs = 3'd2;
      default: nargs = 3'd0;
    endcase
  endfunction

  // register 15 is the MMU's bank, which the core does not have
  logic [7:0] regbyte;
  assign regbyte = (reg_sel == 5'd15) ? (reg_hi ? 8'h00 : cur_bank) : reg_rdata;

  always_ff @(posedge clk) begin
    // one-clock pulses
    reg_wr_en <= 1'b0;
    bp_we     <= 1'b0;
    tx_go     <= 1'b0;

    if (!rst_n) begin
      state <= S_OP;  after <= S_OP;  op <= 8'h00;  argn <= 3'd0;
      stopped <= HALT_ON_RESET;
      skip <= 1'b0;  stepping <= 1'b0;  halt_req <= 1'b0;
      why_bp <= 1'b0;  why_step <= 1'b0;  why_halt <= HALT_ON_RESET;
      why_idx <= 3'd0;
      ovr_en <= 1'b0;  ovr_bank <= 8'h00;
      mem_req <= 1'b0;  mem_we <= 1'b0;  mem_addr <= 16'h0000;  mem_wdata <= 8'h00;
      reg_sel <= 5'd0;  reg_hi <= 1'b0;  reg_wr_sel <= 5'd0;  reg_wr_hi <= 1'b0;  reg_wr_data <= 8'h00;
      rqn <= 2'd0;  rqi <= 2'd0;  tmo <= '0;
      maddr <= 16'h0000;  mrem <= 9'd0;  bp_wi <= 3'd0;
      {arg0, arg1, arg2, arg3, arg4} <= '0;
      {rq0, rq1, rq2, rq3} <= '0;
      tx_byte <= 8'h00;
    end else begin
      // the core's first tick away from the boundary ends `skip`
      if (core_clk_en) skip <= 1'b0;

      // reaching a boundary with a reason to stop
      if (!stopped && stop_now) begin
        stopped  <= 1'b1;
        why_bp   <= any_hit;
        why_step <= stepping;
        why_halt <= halt_req;
        why_idx  <= hit_idx;
        halt_req <= 1'b0;
        stepping <= 1'b0;
      end

      // a byte timeout abandons a command that stopped half way
      if (state == S_ARG || state == S_PDATA) begin
        if (rx_valid)                   tmo <= '0;
        else if (tmo == TW'(TIMEOUT_CLKS)) begin
          tmo   <= '0;
          state <= S_OP;
          mem_req <= 1'b0;
        end else                        tmo <= tmo + 1'b1;
      end else tmo <= '0;

      case (state)
        S_OP: if (rx_valid) begin
          op   <= rx_data;
          argn <= 3'd0;
          state <= state_t'((nargs(rx_data) == 3'd0) ? S_DISP : S_ARG);
        end

        S_ARG: if (rx_valid) begin
          case (argn)
            3'd0: arg0 <= rx_data;
            3'd1: arg1 <= rx_data;
            3'd2: arg2 <= rx_data;
            3'd3: arg3 <= rx_data;
            default: arg4 <= rx_data;
          endcase
          argn <= argn + 3'd1;
          if (argn + 3'd1 == nargs(op)) state <= S_DISP;
        end

        S_DISP: begin
          // default reply: the command byte
          rq0 <= op;  rqn <= 2'd1;  rqi <= 2'd0;  after <= S_OP;
          state <= S_REPLY;
          case (op)
            "N": ;
            "S": begin
              rq1 <= {why_idx, ovr_en, why_halt, why_step, why_bp, stopped};
              rq2 <= 8'(BP_N);
              rq3 <= 8'd1;                         // protocol revision
              rqn <= 2'd0;                         // four bytes: see S_REPLY
            end
            "H": if (!stopped) halt_req <= 1'b1;
            "C", "T": begin
              if (!stopped) begin
                rq0 <= "E";  rq1 <= 8'h01;  rqn <= 2'd2;
              end else begin
                stopped  <= 1'b0;
                skip     <= 1'b1;
                stepping <= (op == "T");
                halt_req <= 1'b0;
                why_bp <= 1'b0;  why_step <= 1'b0;  why_halt <= 1'b0;
              end
            end
            "R": begin
              if (!stopped) begin
                rq0 <= "E";  rq1 <= 8'h01;  rqn <= 2'd2;
              end else begin
                reg_sel <= arg0[4:0];
                reg_hi  <= 1'b0;
                state   <= S_RWAIT;
              end
            end
            "W": begin
              if (!stopped) begin
                rq0 <= "E";  rq1 <= 8'h01;  rqn <= 2'd2;
              end else if (arg0[4:0] > 5'd14 || (arg0[4:0] >= 5'd4 && arg0[4:0] <= 5'd7)) begin
                // 15 is the bank, 4 to 7 the alternate set: no write port
                rq0 <= "E";  rq1 <= 8'h04;  rqn <= 2'd2;
              end else begin
                reg_wr_en   <= 1'b1;
                reg_wr_sel  <= arg0[4:0];
                reg_wr_hi   <= 1'b0;
                reg_wr_data <= arg1;
                state       <= S_WHI;             // the high byte next
              end
            end
            "M", "P": begin
              if (!stopped) begin
                rq0 <= "E";  rq1 <= 8'h01;  rqn <= 2'd2;
              end else begin
                maddr <= {arg1, arg0};
                mrem  <= (arg2 == 8'h00) ? 9'd256 : {1'b0, arg2};
                if (op == "M") begin
                  after <= S_MSET;                 // header 'M', then the data
                end else begin
                  state <= S_PDATA;                // no reply until the end
                end
              end
            end
            "B": begin
              if (arg0 >= 8'(BP_N)) begin
                rq0 <= "E";  rq1 <= 8'h03;  rqn <= 2'd2;
              end else begin
                bp_we <= 1'b1;
                bp_wi <= arg0[2:0];
              end
            end
            "K": begin
              ovr_en   <= arg0[0];
              ovr_bank <= arg1;
            end
            default: begin
              rq0 <= "E";  rq1 <= 8'h02;  rqn <= 2'd2;
            end
          endcase
        end

        S_RWAIT: begin                       // reg_sel has settled: low byte
          rq1    <= regbyte;
          reg_hi <= 1'b1;
          state  <= S_RWAIT2;
        end
        S_RWAIT2: begin                      // and the high byte
          rq0 <= "R";  rq2 <= regbyte;
          rqn <= 2'd3;  rqi <= 2'd0;  after <= S_OP;
          state <= S_REPLY;
        end
        S_WHI: begin
          reg_wr_en   <= 1'b1;
          reg_wr_hi   <= 1'b1;
          reg_wr_data <= arg2;
          state       <= S_REPLY;                // rq0 = 'W' was set by S_DISP
        end

        // ---- sending.  rqn is the count of bytes in rq0..rq3, with 0 meaning
        // four.  tx_go is a pulse; tx_busy rises on the clock after it.
        S_REPLY: begin
          if (tx_go) begin
            rqi <= rqi + 2'd1;
            if (rqi + 2'd1 == rqn) state <= after;
          end else if (!tx_busy) begin
            tx_go   <= 1'b1;
            tx_byte <= (rqi == 2'd0) ? rq0 : (rqi == 2'd1) ? rq1
                     : (rqi == 2'd2) ? rq2 : rq3;
          end
        end

        // ---- memory read: set the address, raise the request a clock later
        S_MSET: begin
          mem_addr <= maddr;
          mem_we   <= 1'b0;
          state    <= S_MREQ;
        end
        S_MREQ: begin
          mem_req <= 1'b1;
          state   <= S_MWAIT;
        end
        S_MWAIT: if (mem_ack) begin
          mem_req <= 1'b0;
          rq0     <= mem_rdata;
          rqn     <= 2'd1;  rqi <= 2'd0;
          maddr   <= maddr + 16'd1;
          mrem    <= mrem - 9'd1;
          after   <= state_t'((mrem == 9'd1) ? S_OP : S_MSET);
          state   <= S_REPLY;
        end

        // ---- memory write, one byte per received byte
        S_PDATA: if (rx_valid) begin
          mem_addr  <= maddr;
          mem_wdata <= rx_data;
          mem_we    <= 1'b1;
          state     <= S_PREQ;
        end
        S_PREQ: begin
          mem_req <= 1'b1;
          state   <= S_PWAIT;
        end
        S_PWAIT: if (mem_ack) begin
          mem_req <= 1'b0;
          mem_we  <= 1'b0;
          maddr   <= maddr + 16'd1;
          mrem    <= mrem - 9'd1;
          if (mrem == 9'd1) begin
            rq0 <= "P";  rqn <= 2'd1;  rqi <= 2'd0;  after <= S_OP;
            state <= S_REPLY;
          end else state <= S_PDATA;
        end

        default: state <= S_OP;
      endcase
    end
  end

endmodule

`endif
