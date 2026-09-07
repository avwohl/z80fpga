// A byte-wide memory for the Z80, backed by a single-data-rate SDRAM.
//
// Same job as ddr2_ram.sv and the same contract on the Z80 side -- hold `req`
// for the bus cycle, pulse `ready` when the byte is there -- but against a
// chip this design drives itself rather than through a vendor controller.
// The part is a Micron MT48LC16M16 or a compatible -- the Icepi Zero has an
// MT48LC16M16A2P: 4 banks x 8192 rows x 512 columns x 16 bits, which is 32 MB,
// of which the Z80's 512 KB is a corner.
//
// The design is deliberately the simplest thing that is correct, because the
// bandwidth needed is trivial.  One access is ACTIVE, then READ or WRITE with
// auto-precharge, and that is the whole of it: no open-row tracking, no bank
// interleaving, no bursts, no read cache.  sim/tb_sdram.sv measures the cost
// and prints it: five clocks for a read and two for a write, so a three
// T-state memory cycle becomes seven or four, and nothing in the system
// notices except that it is a little slower.  ddr2_ram caches a line because
// a DDR2 beat is sixteen bytes and throwing fifteen of them away was silly.
// Here a read yields two bytes, and caching one of them would buy a fraction
// of the reads for a second copy of the invalidation logic that is easy to
// get wrong.
//
// Timing constants come from CLK_HZ, rounded up, using the -75 (PC133) grade
// numbers because they are the slowest of the family: any part on any board
// meets them.  tRAS and tWR are not counted here -- READ and WRITE are issued
// with A10 high, so the chip precharges itself when it is ready and the only
// thing this module owes it is to leave the bank alone for tRC afterwards.
//
// The chip's clock is NOT generated here.  The board top drives it, because
// how it is generated is a property of the board's fabric -- see
// boards/icepi_zero/sdram/top_sdram.sv, which sends an inverted copy out
// through an ODDR so the chip samples half a clock after this module launches.
// RD_LAT below assumes exactly that; a board that clocks the chip some other
// way has to move it.
//
// DQ is split into dq_o / dq_i / dq_oe rather than being an inout, so that
// nothing in rtl/ has a tristate in it: the board top owns the pad.

`ifndef SDRAM_RAM_SV
`define SDRAM_RAM_SV

module sdram_ram #(
    parameter int CLK_HZ = 25_000_000,
    parameter int AW     = 19,          // byte address bits the Z80 side uses
    parameter int CAS    = 2            // CAS latency, programmed into the chip
) (
    input  logic            clk,
    input  logic            rst_n,

    // Z80 side.  req is held for the whole bus cycle; ready goes high when the
    // access has completed, and stays high until req drops, so it is seen
    // whatever T-state the core's clock enable lands on.
    input  logic            req,
    input  logic            we,
    input  logic [AW-1:0]   addr,
    input  logic [7:0]      wdata,
    output logic [7:0]      rdata,
    output logic            ready,
    output logic            init_done,  // the power-up sequence has finished

    // the chip
    output logic [12:0]     sd_a,
    output logic  [1:0]     sd_ba,
    output logic  [1:0]     sd_dqm,
    output logic            sd_cs_n,
    output logic            sd_ras_n,
    output logic            sd_cas_n,
    output logic            sd_we_n,
    output logic            sd_cke,
    output logic [15:0]     sd_dq_o,
    output logic            sd_dq_oe,
    input  logic [15:0]     sd_dq_i
);

  // ------------------------------------------------------------ cycle counts
  // ceil(ns * MHz / 1000), never less than one clock.
  localparam int MHZ = CLK_HZ / 1_000_000;

  localparam int C_RCD  = (20 * MHZ + 999) / 1000 > 0 ? (20 * MHZ + 999) / 1000 : 1;
  localparam int C_RP   = (20 * MHZ + 999) / 1000 > 0 ? (20 * MHZ + 999) / 1000 : 1;
  localparam int C_RC   = (66 * MHZ + 999) / 1000 > 0 ? (66 * MHZ + 999) / 1000 : 1;
  localparam int C_MRD  = 2;
  // 100 us of NOPs before anything else, per the power-up sequence.
  localparam int C_INIT = 100 * MHZ;
  // One refresh per row per 64 ms over 8192 rows is one every 7.8 us.  Ask a
  // little more often than that so a request in flight cannot push it late.
  localparam int C_REFI = (7000 * MHZ) / 1000;
  localparam int CW     = $clog2(C_INIT + 1);

  // What actually goes into cnt.  A state loads cnt on the same edge that it
  // is entered, so the first edge on which the state sees cnt is the edge
  // *after* the load, and cnt reads zero one edge later than the number
  // suggests: loading N gives a wait of N+1 clocks.  Everything below is
  // therefore one less than the wait it wants.  It matters for exactly one of
  // them -- the read latency has to be exact, not merely sufficient -- but
  // spelling it out once beats a comment on each.
  localparam int L_RCD  = C_RCD  - 1;
  localparam int L_RP   = C_RP   - 1;
  localparam int L_RC   = C_RC   - 1;
  localparam int L_MRD  = C_MRD  - 1;
  localparam int L_INIT = C_INIT - 1;

  // The mode register: burst length 1, sequential, the programmed CAS latency,
  // standard operation, single-location writes.
  localparam logic [12:0] MODE = {3'b000, 1'b1, 2'b00, 3'(CAS), 1'b0, 3'b000};

  // -------------------------------------------------------------- commands
  // {cs_n, ras_n, cas_n, we_n}
  localparam logic [3:0] CMD_NOP     = 4'b0111;
  localparam logic [3:0] CMD_ACTIVE  = 4'b0011;
  localparam logic [3:0] CMD_READ    = 4'b0101;
  localparam logic [3:0] CMD_WRITE   = 4'b0100;
  localparam logic [3:0] CMD_PRE     = 4'b0010;
  localparam logic [3:0] CMD_REFRESH = 4'b0001;
  localparam logic [3:0] CMD_MRS     = 4'b0000;

  logic [3:0] cmd;
  assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd;

  // ------------------------------------------------------- address decoding
  // {row, bank, column} out of the word address, which is the byte address
  // without its bottom bit -- the chip is sixteen bits wide and DQM picks the
  // half that is really being written.
  localparam int WAW = AW - 1;

  logic [WAW-1:0] wa;
  logic  [8:0]    col;
  logic  [1:0]    bank;
  logic [12:0]    row;

  assign wa   = addr[AW-1:1];
  assign col  = 9'(wa);
  assign bank = 2'(wa >> 9);
  assign row  = 13'(wa >> 11);

  // --------------------------------------------------------- the state machine
  typedef enum logic [3:0] {
    S_POR, S_PRE_ALL, S_REF_INIT, S_MRS,
    S_IDLE, S_ACT, S_RDWAIT, S_WAIT, S_ACK, S_REFRESH
  } state_t;

  state_t         state;
  logic [CW-1:0]  cnt;          // clocks left in the current wait
  logic  [3:0]    ref_init;     // AUTO REFRESH commands left in the init burst
  logic [CW-1:0]  refi;         // clocks until the next refresh is due
  logic           ref_due;
  logic           seen;         // this bus cycle has already been serviced

  // The whole decode is latched on the edge that issues ACTIVE, and the column
  // command two clocks later uses the latch rather than looking at `addr`
  // again.  They would agree as long as the address really is held for the
  // whole bus cycle -- but if it ever is not, taking the row from one moment
  // and the column from another writes the right byte into the wrong row, and
  // nothing downstream can tell.
  logic  [8:0]    col_q;
  logic  [1:0]    bank_q;
  logic           byte_q;       // which half of the word this access wants
  logic           we_q;
  logic  [7:0]    wdata_q;

  // The READ command is registered onto the pins on the edge that leaves
  // S_ACT; the chip latches it half a clock later, drives the word CAS chip
  // clocks after that, and it is stable at our next rising edge.  So the word
  // is on sd_dq_i three fabric clocks after the command edge, for CAS = 2.
  // If a board ever needs a different number this is the one to move.
  localparam int RD_LAT = CAS + 1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state     <= S_POR;
      cnt       <= CW'(L_INIT);
      ref_init  <= 4'd8;
      refi      <= CW'(C_REFI);
      ref_due   <= 1'b0;
      seen      <= 1'b0;
      ready     <= 1'b0;
      init_done <= 1'b0;
      cmd       <= CMD_NOP;
      sd_cke    <= 1'b1;
      sd_a      <= 13'd0;
      sd_ba     <= 2'd0;
      sd_dqm    <= 2'b11;
      sd_dq_o   <= 16'd0;
      sd_dq_oe  <= 1'b0;
      rdata     <= 8'd0;
      col_q     <= 9'd0;
      bank_q    <= 2'd0;
      byte_q    <= 1'b0;
      we_q      <= 1'b0;
      wdata_q   <= 8'd0;
    end else begin
      // A command occupies exactly the clock it is issued in.
      cmd      <= CMD_NOP;
      sd_dq_oe <= 1'b0;
      // DQM low except while a write is masking a half-word.  It has to be low
      // well before read data arrives -- the chip's DQM read latency is two
      // clocks -- and holding it low whenever nothing is being written is the
      // easy way to guarantee that.
      sd_dqm   <= 2'b00;

      if (cnt != 0) cnt <= cnt - 1'b1;

      if (!req) begin
        seen  <= 1'b0;
        ready <= 1'b0;
      end

      case (state)
        // ------------------------------------------------------ power-up
        S_POR: if (cnt == 0) begin
          cmd   <= CMD_PRE;
          sd_a  <= 13'h400;                    // A10 high: precharge all banks
          cnt   <= CW'(L_RP);
          state <= S_PRE_ALL;
        end

        S_PRE_ALL: if (cnt == 0) begin
          cmd   <= CMD_REFRESH;
          cnt   <= CW'(L_RC);
          state <= S_REF_INIT;
        end

        // Eight AUTO REFRESH commands.  Two is the documented minimum and
        // eight is what every part's sequence recommends; they cost 2 us once.
        S_REF_INIT: if (cnt == 0) begin
          if (ref_init > 4'd1) begin
            ref_init <= ref_init - 4'd1;
            cmd      <= CMD_REFRESH;
            cnt      <= CW'(L_RC);
          end else begin
            cmd   <= CMD_MRS;
            sd_a  <= MODE;
            sd_ba <= 2'd0;
            cnt   <= CW'(L_MRD);
            state <= S_MRS;
          end
        end

        S_MRS: if (cnt == 0) begin
          init_done <= 1'b1;
          state     <= S_IDLE;
        end

        // --------------------------------------------------------- running
        S_IDLE: begin
          if (ref_due) begin
            cmd     <= CMD_REFRESH;
            ref_due <= 1'b0;
            cnt     <= CW'(L_RC);
            state   <= S_REFRESH;
          end else if (req && !seen) begin
            cmd     <= CMD_ACTIVE;
            sd_a    <= row;
            sd_ba   <= bank;
            col_q   <= col;
            bank_q  <= bank;
            byte_q  <= addr[0];
            we_q    <= we;
            wdata_q <= wdata;
            cnt     <= CW'(L_RCD);
            state   <= S_ACT;
          end
        end

        S_REFRESH: if (cnt == 0) state <= S_IDLE;

        S_ACT: if (cnt == 0) begin
          // A10 high on the column command asks for auto-precharge, so the
          // bank closes itself and nothing here has to remember it is open.
          sd_a  <= {3'b001, 1'b0, col_q};
          sd_ba <= bank_q;
          if (we_q) begin
            cmd      <= CMD_WRITE;
            sd_dq_o  <= {2{wdata_q}};           // the byte in both halves
            sd_dq_oe <= 1'b1;
            sd_dqm   <= byte_q ? 2'b01 : 2'b10;
            // The data went out with the command and the chip will latch it
            // half a clock later, so the cycle is done as far as the CPU is
            // concerned and the tRC wait overlaps with it finishing.
            ready    <= 1'b1;
            seen     <= 1'b1;
            cnt      <= CW'(L_RC);
            state    <= S_WAIT;
          end else begin
            cmd   <= CMD_READ;
            cnt   <= CW'(RD_LAT - 1);
            state <= S_RDWAIT;
          end
        end

        S_RDWAIT: if (cnt == 0) begin
          rdata <= byte_q ? sd_dq_i[15:8] : sd_dq_i[7:0];
          ready <= 1'b1;
          seen  <= 1'b1;
          // The auto-precharge started when the burst did; leave the bank
          // alone for the rest of tRC before touching it again.
          cnt   <= CW'(L_RC);
          state <= S_WAIT;
        end

        // Nothing but the rest of tRC.  ready and seen were set where the
        // access finished and are left alone here -- setting them again would
        // fight the `if (!req)` above, which has already cleared them if the
        // core has moved on, and would put ready back up under a bus cycle
        // that is over.
        S_WAIT: if (cnt == 0) state <= S_ACK;

        // Hold the answer until the core drops the cycle, so it is seen
        // whatever T-state the clock enable lands on.  `!seen` is the other
        // way out, and it is what stops this state deadlocking: it means req
        // did drop -- which is what cleared seen -- and has already gone back
        // up for a new cycle, and S_IDLE is where that one gets served.
        S_ACK: if (!req || !seen) begin
          ready <= 1'b0;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase

      // The refresh timer, deliberately after the state machine.  Both want to
      // write ref_due and can want to on the same clock; whichever is written
      // last wins, and this is the one that has to.  A tie the other way round
      // would drop the request and leave the chip unrefreshed for two
      // intervals; this way the flag stays set and the chip gets one refresh
      // more than it needed, which is always safe.
      if (refi != 0) refi <= refi - 1'b1;
      else begin
        refi    <= CW'(C_REFI);
        ref_due <= 1'b1;
      end
    end
  end

endmodule

`endif
