// The SIMH AltairZ80 hard disk controller on port $FD, backed by a microSD
// card. This is what makes RomWBW's HDSK0:/HDSK1: real, and it needs no
// firmware change at all: the driver is already in a stock SBC_simh_std ROM,
// enabled by HDSKENABLE, and it has been sitting there enumerating two units
// that nothing answered for.
//
// The protocol, from RomWBW's hdsk.asm and SIMH's altairz80_hdsk.c:
//
//   OUT ($FD),1  x32                 reset. No parameter block, no IN.
//   OTIR of 7 bytes to $FD           cmd, drive, sector, trk-lo, trk-hi,
//                                    dma-lo, dma-hi
//   IN A,($FD)                       status; 0 = success
//
// with cmd 2 = read and 3 = write. RomWBW splits its LBA as sector = LBA[7:0]
// and track = LBA[23:8].
//
// The hard part is that **the data never crosses the port**. Those last two
// bytes are a sixteen-bit Z80 *memory* address, and the simulator moves all
// 512 bytes itself before it answers the IN. So this has to be a bus master.
// The core has no BUSRQ -- z80_core.sv is `assign busak_n = busrq_n;` -- but
// it does not need one: I/O strobes in T3, `waiting` freezes tcnt there, and
// `mem_cycle` excludes I/O so mreq_n stays high and the memory port is idle
// for the whole stretched cycle. So the IN is stalled with wait_n and the
// transfer happens underneath it.
//
// Framing follows SIMH deliberately, including its sloppiness: a byte is only
// taken as a command when the state machine is idle, and an unrecognised
// command byte silently resets rather than erroring. Diverging here turns a
// desync into silent data loss instead of a visible failure.
//
// Under HBIOS every transaction is exactly one 512-byte sector: HB_DSKFN sets
// E=1 before every driver call, so hdsk.asm's multi-sector loop never
// iterates.

`ifndef HDSK_SV
`define HDSK_SV

module hdsk #(
    parameter logic [7:0]  PORT      = 8'hFD,
    // A window on the strobe counters, for finding out where a byte of a
    // parameter block went.  Write the index, read the counter.
    parameter logic [7:0]  DBG_PORT  = 8'hFC,
    // Where each unit lives on the card, in 512-byte blocks. A gap of 2^21
    // blocks is 1 GiB, which is what the driver claims each unit is.
    parameter logic [31:0] UNIT_STRIDE = 32'h0020_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    // Z80 port side
    input  logic [7:0]  port_addr,
    input  logic [7:0]  port_wdata,
    input  logic        port_wr,     // strobe, gated by clk_en
    input  logic        port_active, // the same cycle, ungated: high all of it
    input  logic        port_rd,        // strobe, gated by clk_en
    input  logic        port_rd_active, // the same cycle, ungated
    output logic [7:0]  port_rdata,
    output logic        port_hit,
    // Held for the whole read cycle, combinationally.  It cannot be registered
    // off the clk_en-gated strobe: clk_en is high only in the last clock of a
    // T-state, which is the very edge on which the core tests wait_n, latches
    // the data bus and leaves the strobe T-state.  A registered reply rises
    // one clock after that, too late to stall the cycle it belongs to -- the
    // core takes the previous contents of the status register and runs on, and
    // the stall lands on the next bus cycle instead, freezing an M1 fetch with
    // mreq_n low while the DMA moves mem_addr out from under it.
    output logic        io_wait,          // hold the I/O cycle

    // memory master, in Z80 address space; the MMU maps it
    output logic        dma_req,
    output logic        dma_we,
    output logic [15:0] dma_addr,
    output logic [7:0]  dma_wdata,
    input  logic [7:0]  dma_rdata,
    input  logic        dma_ack,

    // the card
    output logic        sd_start_rd,
    output logic        sd_start_wr,
    output logic [31:0] sd_lba,
    input  logic        sd_busy,
    input  logic        sd_err,
    input  logic        sd_ready,
    input  logic [7:0]  sd_dbg,
    input  logic [4:0]  sd_dbg_state,
    output logic [8:0]  sd_buf_addr,
    output logic [7:0]  sd_buf_wdata,
    output logic        sd_buf_we,
    input  logic [7:0]  sd_buf_rdata
);

  localparam logic [7:0] CMD_NONE  = 8'd0;
  localparam logic [7:0] CMD_RESET = 8'd1;
  localparam logic [7:0] CMD_READ  = 8'd2;
  localparam logic [7:0] CMD_WRITE = 8'd3;

  assign port_hit = (port_addr == PORT) || (port_addr == DBG_PORT);

  typedef enum logic [3:0] {
    H_IDLE, H_PARM, H_GO, H_SD_RD_GO, H_SD_RD, H_DMA_WR_PRE, H_DMA_WR,
    H_DMA_WR_W, H_DMA_RD, H_DMA_RD_W, H_SD_WR_GO, H_SD_WR, H_DONE
  } state_t;

  state_t      state;
  logic [7:0]  cmd, unit, sec, trk_lo, trk_hi, dma_lo, dma_hi;
  logic [2:0]  parm_i;
  // One byte per OUT.  The core is built with STROBE_1T so the strobe is a
  // single T-state and this is belt and braces -- but this counts bytes, and a
  // held strobe would be seen once per clk_en tick and frame the seven-byte
  // block wrongly, which is a bad way to find out that the parameter changed.
  logic        taken;
  // A watchdog over the whole command.  Every wait here is on something
  // outside this module -- the card coming up, the card answering, the DMA,
  // the memory -- and any of them failing to answer leaves io_wait asserted
  // and the CPU frozen with nothing on the console to say why.  Time the
  // command out instead and report where it was waiting.  ~1.3 s at 100 MHz,
  // which is long enough for a card that takes most of a second to finish
  // ACMD41 and far longer than any transfer.
  logic [26:0] tmo;
  logic [9:0]  cnt;
  logic [7:0]  status;
  // A second status, for the state of the card machine at the moment this one
  // gave up.  One byte cannot say both where this controller was waiting and
  // what the card machine was doing, and both are needed: the first says which
  // wait expired, the second what it was waiting on.  A second status read,
  // with nothing outstanding, returns it.
  logic [7:0]  status2;
  logic        pending;

  // Counters that split the lost-byte question three ways.  A byte of a
  // parameter block goes missing under RomWBW and not under a bare-metal
  // probe, and there are only three places it can go: the strobe arrived and
  // 'taken' swallowed it, the strobe arrived while this machine was busy
  // elsewhere and no case arm was listening, or it never arrived at all.
  // These say which, and successive status reads hand them back.
  logic [7:0]  n_drop;      // seen, but taken was still set
  logic [7:0]  n_busy;      // seen, but not in a state that collects bytes
  logic [7:0]  n_ok;        // accepted
  // They are read from their own port, DBG_PORT, rather than from the command
  // port: a read of the command port runs through the state machine, and the
  // extra reads needed to walk four counters disturbed the very thing being
  // measured.  This port is combinational and touches nothing.
  logic [1:0]  dbg_i;
  logic        rd_seen;    // this read cycle has been acted on
  logic        rd_done;    // ... and the answer is in `status`
  // A backstop on the stall itself.  The command watchdog bounds how long the
  // state machine may take, but it only helps if every path out of it reaches
  // H_DONE and sets rd_done; if any does not, the CPU is frozen for good with
  // nothing to show for it.  Nothing this module does may be able to do that,
  // so time out the stall independently of the state machine.
  logic [27:0] wait_tmo;

  wire [23:0] hdsk_lba = {trk_hi, trk_lo, sec};

  wire cmd_hit = (port_addr == PORT);
  wire dbg_hit = (port_addr == DBG_PORT);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state       <= H_IDLE;
      cmd <= CMD_NONE; unit <= 8'd0; sec <= 8'd0;
      trk_lo <= 8'd0; trk_hi <= 8'd0; dma_lo <= 8'd0; dma_hi <= 8'd0;
      parm_i <= 3'd0; cnt <= 10'd0; status <= 8'd0; pending <= 1'b0; taken <= 1'b0;
      status2 <= 8'h8E;
      n_drop <= 8'd0; n_busy <= 8'd0; n_ok <= 8'd0; dbg_i <= 2'd0;
      rd_seen <= 1'b0; rd_done <= 1'b0; wait_tmo <= 28'd0;
      tmo <= 27'd0;
      dma_req <= 1'b0; dma_we <= 1'b0; dma_addr <= 16'd0; dma_wdata <= 8'd0;
      sd_start_rd <= 1'b0; sd_start_wr <= 1'b0; sd_lba <= 32'd0;
      sd_buf_addr <= 9'd0; sd_buf_wdata <= 8'd0; sd_buf_we <= 1'b0;
    end else begin
      sd_start_rd <= 1'b0;
      sd_start_wr <= 1'b0;
      sd_buf_we   <= 1'b0;
      if (!port_active) taken <= 1'b0;
      // Selected by writing the index, not by advancing on read: an index that
      // advances on each read drifts the moment a read is seen twice, which is
      // exactly the sort of fault being measured, and then every counter is
      // read from the wrong place.
      if (port_wr && dbg_hit) dbg_i <= port_wdata[1:0];

      // Count every strobe aimed at this port, by what became of it.
      if (port_wr && cmd_hit) begin
        if (taken)                                     n_drop <= n_drop + 1'b1;
        else if (state != H_IDLE && state != H_PARM)   n_busy <= n_busy + 1'b1;
        else                                           n_ok   <= n_ok   + 1'b1;
      end

      case (state)
        // -------------------------------------------------- collect a command
        H_IDLE: begin
          dma_req <= 1'b0;
          tmo     <= 27'h7FF_FFFF;    // reloaded here, spent by the command
          if (port_wr && cmd_hit && !taken) begin
            taken <= 1'b1;
            case (port_wdata)
              CMD_READ, CMD_WRITE: begin
                cmd    <= port_wdata;
                parm_i <= 3'd0;
                state  <= H_PARM;
              end
              // reset, and anything unrecognised, per SIMH
              default: begin
                cmd     <= CMD_NONE;
                pending <= 1'b0;
                status  <= 8'd0;
              end
            endcase
          end
        end

        H_PARM: begin
          if (port_wr && cmd_hit && !taken) begin
            taken <= 1'b1;
            case (parm_i)
              3'd0: unit   <= port_wdata;
              3'd1: sec    <= port_wdata;
              3'd2: trk_lo <= port_wdata;
              3'd3: trk_hi <= port_wdata;
              3'd4: dma_lo <= port_wdata;
              default: dma_hi <= port_wdata;
            endcase
            if (parm_i == 3'd5) begin
              pending <= 1'b1;
              state   <= H_IDLE;
            end else begin
              parm_i <= parm_i + 1'b1;
            end
          end
        end

        // The IN is where SIMH does the work, so it is where we do it too.
        H_GO: begin
          if (!sd_ready) begin
            // Not up yet.  Hold the I/O cycle -- io_wait is already asserted --
            // and let the card finish coming up.  The watchdog below ends it
            // if the card never does.
            state <= H_GO;
          end else if (cmd == CMD_READ) begin
            sd_lba      <= UNIT_STRIDE * 32'(unit[0]) + 32'(hdsk_lba);
            sd_start_rd <= 1'b1;
            state       <= H_SD_RD_GO;
          end else begin
            cnt      <= 10'd0;
            dma_addr <= {dma_hi, dma_lo};
            dma_we   <= 1'b0;
            state    <= H_DMA_RD;
          end
        end

        // Wait for the card layer to actually pick the request up before
        // waiting for it to finish.  start_* is a one-cycle pulse, and
        // "finished" was written as !busy -- so a pulse arriving while the
        // card layer was not looking meant the transfer never happened and
        // the status came back 0 anyway.  Silent success, no data.
        H_SD_RD_GO: if (sd_busy) state <= H_SD_RD;

        // ------------------------------------------- read: card then memory
        H_SD_RD: begin
          if (!sd_busy) begin
            if (sd_err) begin
              status <= sd_dbg;             // Cx = the card's R1 on CMD17
              state  <= H_DONE;
            end else begin
              cnt         <= 10'd0;
              sd_buf_addr <= 9'd0;
              dma_addr    <= {dma_hi, dma_lo};
              state       <= H_DMA_WR_PRE;
            end
          end
        end
        // sd_buf_rdata is registered inside sd_spi, so the address needs a
        // whole cycle to turn into data.  Sampling it the cycle after setting
        // the address reads the *previous* byte, which shifts the entire
        // sector by one and is the sort of thing that looks like working.
        H_DMA_WR_PRE: state <= H_DMA_WR;

        H_DMA_WR: begin
          dma_wdata <= sd_buf_rdata;
          dma_we    <= 1'b1;
          dma_req   <= 1'b1;
          state     <= H_DMA_WR_W;
        end
        H_DMA_WR_W: begin
          if (dma_ack) begin
            dma_req <= 1'b0;
            if (cnt == 10'd511) begin
              status <= 8'd0;
              state  <= H_DONE;
            end else begin
              cnt         <= cnt + 1'b1;
              dma_addr    <= dma_addr + 16'd1;
              sd_buf_addr <= 9'(cnt + 10'd1);
              state       <= H_DMA_WR_PRE;
            end
          end
        end

        // ------------------------------------------ write: memory then card
        // Assert and wait are separate states so dma_req always falls between
        // bytes.  Holding it high across an address change would let the ack
        // for the previous byte count as the ack for the next one.
        H_DMA_RD: begin
          dma_req <= 1'b1;
          state   <= H_DMA_RD_W;
        end
        H_DMA_RD_W: begin
          if (dma_ack) begin
            dma_req      <= 1'b0;
            sd_buf_addr  <= cnt[8:0];
            sd_buf_wdata <= dma_rdata;
            sd_buf_we    <= 1'b1;
            if (cnt == 10'd511) begin
              sd_lba      <= UNIT_STRIDE * 32'(unit[0]) + 32'(hdsk_lba);
              sd_start_wr <= 1'b1;
              state       <= H_SD_WR_GO;
            end else begin
              cnt      <= cnt + 1'b1;
              dma_addr <= dma_addr + 16'd1;
              state    <= H_DMA_RD;
            end
          end
        end
        H_SD_WR_GO: if (sd_busy) state <= H_SD_WR;

        H_SD_WR: begin
          if (!sd_busy) begin
            // On failure hand back what the card actually said rather than a
            // bare 1: RomWBW only cares that it is non-zero, and it is the
            // difference between guessing and knowing.
            status <= sd_err ? sd_dbg : 8'd0;
            state  <= H_DONE;
          end
        end

        H_DONE: begin
          pending <= 1'b0;
          rd_done <= 1'b1;              // the answer is in `status` now
          dma_req <= 1'b0;
          state   <= H_IDLE;
        end

        default: state <= H_IDLE;
      endcase

      // The watchdog.  After the case so that it wins: whatever the command
      // was about to do next, it has run out of time.  The status says where.
      // Waiting on the card reports sd_spi's state (E0+state) because that is
      // the part that did not answer; anything else reports this machine's
      // (80+state), and the two ranges do not overlap.
      if (state != H_IDLE && state != H_DONE) begin
        if (tmo == 27'd0) begin
          status  <= {4'h8, 4'(state)};        // where this controller stopped
          status2 <= {3'b111, sd_dbg_state};   // what the card machine was doing
          state   <= H_DONE;
        end else begin
          tmo <= tmo - 1'b1;
        end
      end

      // A read of the command port.  The whole cycle is stalled, from its
      // first clock until there is something true to hand back, so that the
      // core samples the answer to *this* read rather than the previous one.
      if (!port_rd_active) begin
        rd_seen  <= 1'b0;
        rd_done  <= 1'b0;
        wait_tmo <= 28'h7FF_FFFF;       // ~1.6 s at 81.25 MHz
      end else if (io_wait) begin
        // Stalling.  If this ever runs out, some path out of the state machine
        // failed to answer; say so rather than leave the machine dead.
        if (wait_tmo == 28'd0) begin
          status  <= 8'h8D;
          status2 <= {4'h8, 4'(state)};
          rd_done <= 1'b1;
        end else begin
          wait_tmo <= wait_tmo - 1'b1;
        end
      end

      if (port_rd_active && cmd_hit && !rd_seen) begin
        rd_seen <= 1'b1;
        if (pending && state == H_IDLE) begin
          state <= H_GO;                // rd_done follows in H_DONE
        end else if (state == H_PARM) begin
          // A status read part way through a parameter block: one of its seven
          // bytes never arrived.  Abort what was collected rather than leave
          // the machine half fed, where the next command's first byte would
          // finish this one and every command after it would be assembled from
          // bytes belonging to the one before.
          status  <= 8'h8F;
          pending <= 1'b0;
          rd_done <= 1'b1;
          state   <= H_IDLE;
        end else if (state == H_IDLE) begin
          // Nothing outstanding.  Answering from the status register would
          // hand back the previous command's result, which is how an operation
          // that never framed reports success.
          status  <= status2;
          rd_done <= 1'b1;
        end
      end

      // The watchdog.  After the case so that it wins: whatever the command
      // was about to do next, it has run out of time.  The status says where.
      // Waiting on the card reports sd_spi's state (E0+state) because that is
      // the part that did not answer; anything else reports this machine's
      // (80+state), and the two ranges do not overlap.
      if (state != H_IDLE && state != H_DONE) begin
        if (tmo == 27'd0) begin
          status  <= {4'h8, 4'(state)};        // where this controller stopped
          status2 <= {3'b111, sd_dbg_state};   // what the card machine was doing
          state   <= H_DONE;
        end else begin
          tmo <= tmo - 1'b1;
        end
      end

    end
  end

  // The command port hands back the status; the debug port walks the counters,
  // so four reads of it give: strobes accepted, strobes dropped because 'taken'
  // was still set, strobes seen while no case arm was collecting, and the
  // controller's own state.  Between them those say where a missing byte went.
  logic [7:0] dbg_val;
  always_comb begin
    case (dbg_i)
      2'd0:    dbg_val = n_ok;
      2'd1:    dbg_val = n_drop;
      2'd2:    dbg_val = n_busy;
      default: dbg_val = {4'h0, 4'(state)};
    endcase
  end

  assign port_rdata = (port_addr == DBG_PORT) ? dbg_val : status;

  // Combinational, and asserted for the whole of the read cycle: see the port
  // declaration for why this cannot be a register.
  assign io_wait = port_rd_active && cmd_hit && !rd_done;

  // Everything the DMA touches is a byte in Z80 space; the SoC maps it.
  // dma_req is dropped in H_DONE so the memory returns to the CPU.

endmodule

`endif
