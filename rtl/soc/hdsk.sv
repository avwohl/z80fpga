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
    // Where each unit lives on the card, in 512-byte blocks. A gap of 2^21
    // blocks is 1 GiB, which is what the driver claims each unit is.
    parameter logic [31:0] UNIT_STRIDE = 32'h0020_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    // Z80 port side
    input  logic [7:0]  port_addr,
    input  logic [7:0]  port_wdata,
    input  logic        port_wr,
    input  logic        port_rd,
    output logic [7:0]  port_rdata,
    output logic        port_hit,
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
    output logic [8:0]  sd_buf_addr,
    output logic [7:0]  sd_buf_wdata,
    output logic        sd_buf_we,
    input  logic [7:0]  sd_buf_rdata
);

  localparam logic [7:0] CMD_NONE  = 8'd0;
  localparam logic [7:0] CMD_RESET = 8'd1;
  localparam logic [7:0] CMD_READ  = 8'd2;
  localparam logic [7:0] CMD_WRITE = 8'd3;

  assign port_hit = (port_addr == PORT);

  typedef enum logic [3:0] {
    H_IDLE, H_PARM, H_GO, H_SD_RD_GO, H_SD_RD, H_DMA_WR_PRE, H_DMA_WR,
    H_DMA_WR_W, H_DMA_RD, H_DMA_RD_W, H_SD_WR_GO, H_SD_WR, H_DONE
  } state_t;

  state_t      state;
  logic [7:0]  cmd, unit, sec, trk_lo, trk_hi, dma_lo, dma_hi;
  logic [2:0]  parm_i;
  logic [9:0]  cnt;
  logic [7:0]  status;
  logic        pending;

  wire [23:0] hdsk_lba = {trk_hi, trk_lo, sec};

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state       <= H_IDLE;
      cmd <= CMD_NONE; unit <= 8'd0; sec <= 8'd0;
      trk_lo <= 8'd0; trk_hi <= 8'd0; dma_lo <= 8'd0; dma_hi <= 8'd0;
      parm_i <= 3'd0; cnt <= 10'd0; status <= 8'd0; pending <= 1'b0;
      dma_req <= 1'b0; dma_we <= 1'b0; dma_addr <= 16'd0; dma_wdata <= 8'd0;
      sd_start_rd <= 1'b0; sd_start_wr <= 1'b0; sd_lba <= 32'd0;
      sd_buf_addr <= 9'd0; sd_buf_wdata <= 8'd0; sd_buf_we <= 1'b0;
      io_wait     <= 1'b0;
    end else begin
      sd_start_rd <= 1'b0;
      sd_start_wr <= 1'b0;
      sd_buf_we   <= 1'b0;

      case (state)
        // -------------------------------------------------- collect a command
        H_IDLE: begin
          io_wait <= 1'b0;
          dma_req <= 1'b0;
          if (port_wr && port_hit) begin
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
          if (port_wr && port_hit) begin
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
            status <= 8'd1;                 // no card
            state  <= H_DONE;
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
              status <= 8'd1;
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
            status <= sd_err ? 8'd1 : 8'd0;
            state  <= H_DONE;
          end
        end

        H_DONE: begin
          pending <= 1'b0;
          io_wait <= 1'b0;
          dma_req <= 1'b0;
          state   <= H_IDLE;
        end

        default: state <= H_IDLE;
      endcase

      // An IN while a command is pending starts the transfer and stalls the
      // cycle until it is done.  io_wait is registered, and the core samples
      // wait_n at the strobe T-state, so it is asserted the moment the read
      // is seen and released only in H_DONE.
      if (port_rd && port_hit && pending && state == H_IDLE) begin
        io_wait <= 1'b1;
        state   <= H_GO;
      end
    end
  end

  assign port_rdata = status;

  // Everything the DMA touches is a byte in Z80 space; the SoC maps it.
  // dma_req is dropped in H_DONE so the memory returns to the CPU.

endmodule

`endif
