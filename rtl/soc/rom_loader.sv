// Copy the ROM image off the microSD card into memory, once, before the CPU
// is let go.
//
// This exists because of an inequality.  A RomWBW build wants 512 KB of ROM,
// and the ROM is the one bank whose contents have to be there for the very
// first instruction fetch -- which on the Nexys means block RAM, because
// block RAM comes out of the bitstream already full.  On an ECP5 LFE5U-25F
// the most byte-wide ROM block RAM can hold is 126 KB, so that route is shut
// whatever else is given up, and the image has to arrive from somewhere at
// power-up instead.
//
// The card is that somewhere, and it is nearly free: the board has a slot,
// the design already instantiates sd_spi for HDSK, and sd_spi is the only
// part of this repository that has been proved against a real card.  The
// alternative was the SPI configuration flash, which would need a second SPI
// master and the USRMCLK primitive to drive a pin the configuration engine
// owns.  This needs neither.
//
// The handshake with sd_spi is copied from hdsk.sv rather than reinvented,
// including the part that looks redundant: start_rd is a one-cycle pulse and
// "finished" is !busy, so a pulse issued while the card layer is not looking
// would read as an instantly-finished transfer that never happened.  Waiting
// for busy to rise before waiting for it to fall is what stops that, and it
// cost a hardware run to find the first time.
//
// Failure is reported rather than retried forever.  A card that is absent
// never raises ready and the loader sits in its first state with done and
// failed both low; a card that answers but errors gets RETRIES attempts per
// block and then latches failed.  Either way the CPU stays in reset, because
// releasing it into a half-written ROM would be worse than a mute board, and
// the two flags are meant for two LEDs.

`ifndef ROM_LOADER_SV
`define ROM_LOADER_SV

module rom_loader #(
    parameter int          BLOCKS  = 1024,           // 512-byte blocks to stage
    parameter logic [31:0] LBA     = 32'h0040_0000,  // where they are on the card
    parameter int          AW      = 20,             // destination address width
    parameter int          RETRIES = 3
) (
    input  logic          clk,
    input  logic          rst_n,

    output logic          done,      // the image is in memory
    output logic          failed,    // it is not, and will not be

    // the card, through sd_spi's buffer port
    output logic          sd_start_rd,
    output logic [31:0]   sd_lba,
    input  logic          sd_busy,
    input  logic          sd_err,
    input  logic          sd_ready,
    output logic  [8:0]   sd_buf_addr,
    input  logic  [7:0]   sd_buf_rdata,

    // the memory, on the same req/ready contract sdram_ram presents
    output logic          mem_req,
    output logic          mem_we,
    output logic [AW-1:0] mem_addr,
    output logic  [7:0]   mem_wdata,
    input  logic          mem_ready
);

  localparam int BCW = $clog2(BLOCKS + 1);

  typedef enum logic [3:0] {
    L_CARD, L_CMD, L_GO, L_BUSY, L_PRE, L_WR, L_WR_W, L_WR_D, L_NEXT,
    L_DONE, L_FAIL
  } state_t;

  state_t         state;
  logic [BCW-1:0] blk;             // blocks staged so far
  logic     [9:0] cnt;             // bytes of this block
  logic [AW-1:0]  dst;
  logic     [1:0] tries;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state       <= L_CARD;
      blk         <= '0;
      cnt         <= 10'd0;
      dst         <= '0;
      tries       <= 2'd0;
      done        <= 1'b0;
      failed      <= 1'b0;
      sd_start_rd <= 1'b0;
      sd_lba      <= 32'd0;
      sd_buf_addr <= 9'd0;
      mem_req     <= 1'b0;
      mem_we      <= 1'b0;
      mem_addr    <= '0;
      mem_wdata   <= 8'd0;
    end else begin
      sd_start_rd <= 1'b0;                  // a one-cycle pulse, always

      case (state)
        // Nothing to do until sd_spi has the card initialised.  With no card
        // this is where it stays, which is deliberate -- see the header.
        L_CARD: if (sd_ready) state <= L_CMD;

        L_CMD: begin
          sd_lba      <= LBA + 32'(blk);
          sd_start_rd <= 1'b1;
          state       <= L_GO;
        end

        L_GO: if (sd_busy) state <= L_BUSY;

        L_BUSY: if (!sd_busy) begin
          if (sd_err) begin
            if (tries == 2'(RETRIES - 1)) begin
              failed <= 1'b1;
              state  <= L_FAIL;
            end else begin
              tries <= tries + 1'b1;
              state <= L_CMD;
            end
          end else begin
            tries       <= 2'd0;
            cnt         <= 10'd0;
            sd_buf_addr <= 9'd0;
            state       <= L_PRE;
          end
        end

        // sd_spi's buffer read is registered, so the address needs a whole
        // clock to become data.  Sampling it the cycle the address is set
        // reads the byte before, which shifts the image by one and boots
        // something that is almost the firmware.
        L_PRE: state <= L_WR;

        L_WR: begin
          mem_addr  <= dst;
          mem_wdata <= sd_buf_rdata;
          mem_we    <= 1'b1;
          mem_req   <= 1'b1;
          state     <= L_WR_W;
        end

        L_WR_W: if (mem_ready) begin
          mem_req <= 1'b0;
          mem_we  <= 1'b0;
          state   <= L_WR_D;
        end

        // The memory holds ready up until req drops.  Waiting for it to go
        // away before starting the next byte is what stops the next request
        // being answered by the last one's acknowledgement.
        L_WR_D: if (!mem_ready) begin
          dst <= dst + 1'b1;
          if (cnt == 10'd511) begin
            state <= L_NEXT;
          end else begin
            cnt         <= cnt + 1'b1;
            sd_buf_addr <= 9'(cnt + 10'd1);
            state       <= L_PRE;
          end
        end

        L_NEXT: begin
          if (blk == BCW'(BLOCKS - 1)) begin
            done  <= 1'b1;
            state <= L_DONE;
          end else begin
            blk   <= blk + 1'b1;
            state <= L_CMD;
          end
        end

        L_DONE: ;                            // the CPU has the memory now
        L_FAIL: ;

        default: state <= L_FAIL;
      endcase
    end
  end

endmodule

`endif
