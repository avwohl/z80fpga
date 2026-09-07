// microSD in SPI mode: initialise the card, then read and write 512-byte
// blocks through an internal buffer.
//
// The buffer is the point of the design. The card wants its 512 bytes as one
// uninterrupted SPI burst, and the Z80 side wants them one at a time whenever
// its bus happens to be free; putting a block of dual-ported memory between
// the two means neither has to wait on the other's timing. Read fills the
// buffer and then the DMA drains it; write fills it from memory and then the
// card takes it.
//
// The initialisation sequence is the one verified on hardware against a
// 128 GB SDXC card (which does answer in SPI mode, despite SPI being optional
// for SDXC in the spec):
//
//   CMD0  -> 01        idle
//   CMD8  -> 01 01AA   v2, 2.7-3.6 V accepted
//   ACMD41-> 00        (CMD55 then CMD41 with HCS, until it stops saying 01)
//   CMD58 -> C0FF8000  OCR bit 30 = CCS = block addressing
//
// Two things cost three hardware runs to find and are worth not rediscovering.
// The byte assembled at the end of a transfer must be the shift register as
// it stands, not the shift register plus one more sample of MISO -- doing the
// latter drops the first bit and appends a ninth, and reads R1 = 0x01 back as
// 0x03. And a command must be followed by one idle byte before the next one's
// reply is polled, or the card is still releasing the line and the first byte
// read comes back straddling a byte boundary: CMD8 answering 0x7F.
//
// CCS is assumed, i.e. the LBA is passed to the card as a block number. Every
// SDHC and SDXC card works this way; a plain SDSC card would need the address
// multiplied by 512, and is not supported here.

`ifndef SD_SPI_SV
`define SD_SPI_SV

module sd_spi #(
    parameter int CLK_HZ    = 81_250_000,
    parameter int INIT_HZ   = 390_000,     // slow clock for initialisation
    parameter int FAST_HZ   = 6_000_000,   // once the card is up
    // How the sector buffer is shaped.  A tool question rather than a design
    // one; the long comment at the buffer says why, and why the default is
    // the portable answer while one board pins it to the other.
    parameter bit BUF_MUX   = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,

    // control
    input  logic        start_rd,
    input  logic        start_wr,
    input  logic [31:0] lba,
    output logic        busy,
    output logic        err,
    output logic [7:0]  dbg,               // last thing the card said, for diagnosis
    output logic [4:0]  dbg_state,         // where the state machine is
    output logic        ready,             // card initialised

    // 512-byte buffer, byte addressed, for whoever is moving the data
    input  logic [8:0]  buf_addr,
    input  logic [7:0]  buf_wdata,
    input  logic        buf_we,
    output logic [7:0]  buf_rdata,

    // the card
    output logic        sd_sck,
    output logic        sd_mosi,
    input  logic        sd_miso,
    output logic        sd_cs
);

  localparam int DIV_SLOW = (CLK_HZ / (2 * INIT_HZ)) - 1;
  localparam int DIV_FAST = (CLK_HZ / (2 * FAST_HZ)) - 1;
  localparam int DW       = $clog2(DIV_SLOW + 1);

  // ------------------------------------------------------------- the buffer
  //
  // BUF_MUX picks between two spellings of the same 512 bytes, and the choice
  // is forced by the tools rather than by the design.
  //
  // Written the plain way -- two write ports, which is what BUF_MUX = 0 is --
  // **no** memory on either family can hold it, and both tools fail at it
  // silently.  yosys says "using FF mapping for memory", and forcing the issue
  // with a ram_style attribute says "no valid mapping found".  Vivado says
  // nothing at all: the Nexys RomWBW build's utilisation report shows zero
  // RAMB18s and carries the 512 bytes as 4096 flip-flops, which on a part with
  // 126,800 registers nobody noticed.  On an ECP5 with 24,288 LUT4s the
  // identical code made this module alone **17,687 LUT4s**, three quarters of
  // an LFE5U-25F before the Z80 was placed at all.
  //
  // BUF_MUX = 1 muxes the two writers onto one port, which both tools can then
  // infer a real memory for -- two EBRs and 641 LUT4s on an ECP5.  The mux
  // costs nothing, because the writers are already exclusive in time: sd_bufw
  // fills the buffer from the card during a read and buf_we fills it from
  // memory before a write, and whoever is not driving is waiting on busy.
  // Should they collide anyway sd_bufw wins, which is what the two-port form
  // did -- its second assignment was the later one in the same block.
  //
  // So why is 0 still here?  Because the Nexys RomWBW build is the only thing
  // in this repository that has run on hardware, and it sits at 94.81% of that
  // part's block RAM -- 128 of 135 RAMB36 tiles, for a 512 KB ROM that Vivado
  // cascades in pairs.  Switching this buffer to the muxed form makes its
  // place_design fail with sixty-four REQP-1962 "cascade ADDR15 pin check"
  // errors.  Not because of the block RAM it adds: asking for the muxed form
  // as distributed RAM keeps the tile count at exactly the baseline's 128 and
  // it fails the same way.  Something about that build is simply delicate, and
  // the way to keep a verified bitstream verified is not to perturb it.
  // boards/nexys_a7_100t/romwbw/ therefore pins BUF_MUX to 0 and gets the
  // netlist it was proved with; everything else takes the default.
  //
  // blkbuf stays at module scope rather than going inside a generate, so that
  // the 0 case is not merely equivalent to the old code but is spelled the
  // same, down to the cell names.
  logic [7:0] blkbuf [0:511];
  logic [8:0] sd_bufa;
  logic [7:0] sd_bufd;
  logic       sd_bufw;
  logic [7:0] buf_rdata_sd;

  logic [8:0] bw_addr;
  logic [7:0] bw_data;
  logic       bw_en;

  assign bw_en   = buf_we | sd_bufw;
  assign bw_addr = sd_bufw ? sd_bufa : buf_addr;
  assign bw_data = sd_bufw ? sd_bufd : buf_wdata;

  always_ff @(posedge clk) begin
    if (BUF_MUX) begin
      if (bw_en) blkbuf[bw_addr] <= bw_data;
    end else begin
      if (buf_we) blkbuf[buf_addr] <= buf_wdata;
    end
    // The read is of the memory as it stands before this clock's write, which
    // is what hdsk relies on either way.
    buf_rdata <= blkbuf[buf_addr];
    if (!BUF_MUX && sd_bufw) blkbuf[sd_bufa] <= sd_bufd;
  end

  // A second read port for the SPI side, so the card can stream out of the
  // buffer while whoever owns buf_addr is doing something else.
  always_ff @(posedge clk) buf_rdata_sd <= blkbuf[sd_bufa];

  // ---------------------------------------------------------- SPI byte engine
  logic [DW-1:0] divcnt, divmax;
  logic          tick;

  assign tick = (divcnt == divmax);
  // Reset it.  Without this the counter is X in simulation forever, because
  // tick depends on divcnt and divcnt depends on tick -- and hardware hides
  // the bug, since the FPGA powers registers up at 0.
  always_ff @(posedge clk) begin
    if (!rst_n)   divcnt <= '0;
    else if (tick) divcnt <= '0;
    else           divcnt <= divcnt + 1'b1;
  end

  logic [7:0] mosi_byte, miso_byte, shift_in;
  logic [2:0] bitno;
  logic       spi_go, spi_busy, phase;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sd_sck <= 1'b0; sd_mosi <= 1'b1; spi_busy <= 1'b0;
      bitno <= 3'd0; phase <= 1'b0; shift_in <= 8'h00; miso_byte <= 8'hFF;
    end else if (!spi_busy) begin
      sd_sck <= 1'b0;
      if (spi_go) begin
        spi_busy <= 1'b1; bitno <= 3'd0; phase <= 1'b0;
        sd_mosi  <= mosi_byte[7];
      end
    end else if (tick) begin
      if (!phase) begin
        sd_sck   <= 1'b1;
        shift_in <= {shift_in[6:0], sd_miso};
        phase    <= 1'b1;
      end else begin
        sd_sck <= 1'b0;
        phase  <= 1'b0;
        if (bitno == 3'd7) begin
          spi_busy  <= 1'b0;
          miso_byte <= shift_in;        // NOT {shift_in[6:0], sd_miso}
        end else begin
          bitno   <= bitno + 1'b1;
          sd_mosi <= mosi_byte[6 - bitno];
        end
      end
    end
  end

  // ------------------------------------------------------------- the script
  typedef enum logic [4:0] {
    S_RESET, S_WARM, S_CMD, S_CMD_ARG, S_R1, S_R1_WAIT, S_OCR, S_GAP,
    S_SEQ, S_ACMD_CHK, S_IDLE,
    S_RD_TOKEN, S_RD_DATA, S_RD_CRC,
    S_WR_TOKEN, S_WR_DATA, S_WR_CRC, S_WR_RESP, S_WR_BUSY,
    S_FINISH, S_ERR
  } state_t;

  state_t      state, after_cmd;
  assign dbg_state = 5'(state);
  // No state here may wait forever.  Every wait is on the card answering, and
  // a card that stops answering -- in the middle of a write especially --
  // would hold busy high for good, and the CPU is stalled behind that with
  // nothing on the console to say why.  Give any single state a bounded life
  // and fail the command instead.  2^25 clocks is about 400 ms at 81.25 MHz,
  // longer than the 250 ms a card may take to program a block and far longer
  // than any other wait here.  S_IDLE is exempt: waiting there is its job.
  logic [24:0] stall;
  state_t      state_q;
  // dbg follows whatever most recently explained a failure: the R1 of the last
  // command, or the data-response token of a write.
  logic [7:0]  cmd_idx, cmd_crc, r1;
  logic [31:0] cmd_arg, ocr;
  logic [2:0]  frame_i, ocr_i;
  logic        want_ocr;
  logic [15:0] retry;
  logic [9:0]  cnt;
  logic [4:0]  seq;
  logic [7:0]  gap_i;
  logic        is_write;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= S_RESET; spi_go <= 1'b0; sd_cs <= 1'b1; mosi_byte <= 8'hFF; dbg <= 8'h00;
      stall <= 25'd0; state_q <= S_RESET;
      divmax <= DW'(DIV_SLOW); busy <= 1'b1; err <= 1'b0; ready <= 1'b0;
      seq <= 5'd0; gap_i <= 8'd0; retry <= 16'd0; cnt <= 10'd0;
      cmd_idx <= 8'd0; cmd_arg <= 32'd0; cmd_crc <= 8'h95; frame_i <= 3'd0;
      r1 <= 8'hFF; ocr <= 32'd0; ocr_i <= 3'd0; want_ocr <= 1'b0;
      sd_bufa <= 9'd0; sd_bufd <= 8'd0; sd_bufw <= 1'b0;
      after_cmd <= S_RESET; is_write <= 1'b0;
    end else begin
      spi_go <= 1'b0;
      sd_bufw <= 1'b0;

      case (state)
        // ---------------------------------------------------- power-up clocks
        S_RESET: begin
          sd_cs <= 1'b1; mosi_byte <= 8'hFF; gap_i <= 8'd0;
          divmax <= DW'(DIV_SLOW); busy <= 1'b1; ready <= 1'b0;
          state <= S_WARM;
        end
        S_WARM: begin
          if (!spi_busy && !spi_go) begin
            if (gap_i == 8'd12) begin
              sd_cs <= 1'b0; gap_i <= 8'd0; seq <= 5'd0; state <= S_SEQ;
            end else begin
              gap_i <= gap_i + 1'b1; spi_go <= 1'b1;
            end
          end
        end

        // ------------------------------------------------------ send command
        S_CMD: begin
          frame_i   <= 3'd0;
          mosi_byte <= {2'b01, cmd_idx[5:0]};
          spi_go    <= 1'b1;
          state     <= S_CMD_ARG;
        end
        S_CMD_ARG: begin
          if (!spi_busy && !spi_go) begin
            case (frame_i)
              3'd0: mosi_byte <= cmd_arg[31:24];
              3'd1: mosi_byte <= cmd_arg[23:16];
              3'd2: mosi_byte <= cmd_arg[15:8];
              3'd3: mosi_byte <= cmd_arg[7:0];
              3'd4: mosi_byte <= cmd_crc;
              default: mosi_byte <= 8'hFF;
            endcase
            if (frame_i == 3'd5) begin
              retry <= 16'd0;
              state <= S_R1;
            end else begin
              frame_i <= frame_i + 1'b1;
              spi_go  <= 1'b1;
            end
          end
        end
        S_R1: begin
          mosi_byte <= 8'hFF; spi_go <= 1'b1; state <= S_R1_WAIT;
        end
        S_R1_WAIT: begin
          if (!spi_busy && !spi_go) begin
            if (!miso_byte[7]) begin
              r1    <= miso_byte;
              ocr_i <= 3'd0;
              if (want_ocr) state <= S_OCR; else state <= S_GAP;
            end else if (retry == 16'd5000) begin
              r1 <= 8'hFF; state <= S_GAP;
            end else begin
              retry <= retry + 1'b1; spi_go <= 1'b1;
            end
          end
        end
        S_OCR: begin
          if (!spi_busy && !spi_go) begin
            if (ocr_i != 3'd0) ocr <= {ocr[23:0], miso_byte};
            if (ocr_i == 3'd4) state <= S_GAP;
            else begin ocr_i <= ocr_i + 1'b1; spi_go <= 1'b1; end
          end
        end
        // one idle byte before anything else touches the card
        S_GAP: begin
          if (!spi_busy && !spi_go) begin
            if (gap_i == 8'd1) begin gap_i <= 8'd0; state <= after_cmd; end
            else begin gap_i <= gap_i + 1'b1; mosi_byte <= 8'hFF; spi_go <= 1'b1; end
          end
        end

        // -------------------------------------------- initialisation script
        S_SEQ: begin
          seq <= seq + 1'b1;
          case (seq)
            5'd0: begin cmd_idx<=8'd0;  cmd_arg<=32'h0000_0000; cmd_crc<=8'h95;
                        want_ocr<=1'b0; after_cmd<=S_SEQ; state<=S_CMD; end
            5'd1: begin if (r1 != 8'h01) state <= S_ERR;
                        else begin cmd_idx<=8'd8; cmd_arg<=32'h0000_01AA; cmd_crc<=8'h87;
                                   want_ocr<=1'b1; after_cmd<=S_SEQ; state<=S_CMD; end end
            5'd2: begin if (r1 != 8'h01 || ocr[15:0] != 16'h01AA) state <= S_ERR; end
            5'd3: begin cmd_idx<=8'd55; cmd_arg<=32'h0000_0000; cmd_crc<=8'h65;
                        want_ocr<=1'b0; after_cmd<=S_SEQ; state<=S_CMD; end
            5'd4: begin cmd_idx<=8'd41; cmd_arg<=32'h4000_0000; cmd_crc<=8'h77;
                        want_ocr<=1'b0; after_cmd<=S_ACMD_CHK; state<=S_CMD; end
            5'd5: begin cmd_idx<=8'd58; cmd_arg<=32'h0000_0000; cmd_crc<=8'hFD;
                        want_ocr<=1'b1; after_cmd<=S_SEQ; state<=S_CMD; end
            default: begin
              // OCR bit 30 is CCS; this driver only does block addressing
              if (!ocr[30]) state <= S_ERR;
              else begin
                divmax <= DW'(DIV_FAST);
                ready  <= 1'b1;
                busy   <= 1'b0;
                state  <= S_IDLE;
              end
            end
          endcase
        end
        S_ACMD_CHK: begin
          if (r1 == 8'h00) begin seq <= 5'd5; state <= S_SEQ; end
          else if (r1 == 8'hFF) state <= S_ERR;
          else begin seq <= 5'd3; state <= S_SEQ; end   // round again
        end

        // ------------------------------------------------------------- idle
        S_IDLE: begin
          busy <= 1'b0;
          if (start_rd || start_wr) begin
            busy     <= 1'b1;
            err      <= 1'b0;
            is_write <= start_wr;
            cmd_idx  <= start_wr ? 8'd24 : 8'd17;
            cmd_arg  <= lba;
            cmd_crc  <= 8'hFF;
            want_ocr <= 1'b0;
            if (start_wr) after_cmd <= S_WR_TOKEN;
            else          after_cmd <= S_RD_TOKEN;
            state    <= S_CMD;
          end
        end

        // ------------------------------------------------------------- read
        S_RD_TOKEN: begin
          if (r1 != 8'h00) begin dbg <= {4'h4, r1[3:0]}; state <= S_ERR; end
          else if (!spi_busy && !spi_go) begin
            if (miso_byte == 8'hFE) begin
              cnt <= 10'd0; sd_bufa <= 9'd0; mosi_byte <= 8'hFF;
              spi_go <= 1'b1; state <= S_RD_DATA;
            end else if (retry == 16'd20000) state <= S_ERR;
            else begin
              retry <= retry + 1'b1; mosi_byte <= 8'hFF; spi_go <= 1'b1;
            end
          end
        end
        S_RD_DATA: begin
          if (!spi_busy && !spi_go) begin
            sd_bufa <= cnt[8:0];
            sd_bufd <= miso_byte;
            sd_bufw <= 1'b1;
            if (cnt == 10'd511) begin
              cnt <= 10'd0; state <= S_RD_CRC;
            end else begin
              cnt <= cnt + 1'b1;
            end
            mosi_byte <= 8'hFF; spi_go <= 1'b1;
          end
        end
        S_RD_CRC: begin                       // two CRC bytes, discarded
          if (!spi_busy && !spi_go) begin
            if (cnt == 10'd1) begin gap_i <= 8'd0; after_cmd <= S_FINISH; state <= S_GAP; end
            else begin cnt <= cnt + 1'b1; mosi_byte <= 8'hFF; spi_go <= 1'b1; end
          end
        end

        // ------------------------------------------------------------ write
        S_WR_TOKEN: begin
          if (r1 != 8'h00) begin dbg <= {4'hA, r1[3:0]}; state <= S_ERR; end
          else if (!spi_busy && !spi_go) begin
            mosi_byte <= 8'hFE;               // start block token
            spi_go    <= 1'b1;
            cnt       <= 10'd0;
            sd_bufa   <= 9'd0;
            state     <= S_WR_DATA;
          end
        end
        S_WR_DATA: begin
          if (!spi_busy && !spi_go) begin
            // blkbuf read is registered, so sd_bufa was set a cycle earlier
            mosi_byte <= buf_rdata_sd;
            spi_go    <= 1'b1;
            if (cnt == 10'd511) begin cnt <= 10'd0; state <= S_WR_CRC; end
            else begin cnt <= cnt + 1'b1; sd_bufa <= cnt[8:0] + 9'd1; end
          end
        end
        // Two CRC bytes, not one.  The read side gets away with the count
        // being short because a stray byte there is just another idle poll,
        // but on a write the card is still counting CRC when the response is
        // looked for, and everything after that is a byte out of step.
        S_WR_CRC: begin
          if (!spi_busy && !spi_go) begin
            if (cnt == 10'd2) begin retry <= 16'd0; state <= S_WR_RESP; end
            else begin cnt <= cnt + 1'b1; mosi_byte <= 8'hFF; spi_go <= 1'b1; end
          end
        end
        S_WR_RESP: begin
          if (!spi_busy && !spi_go) begin
            if ((miso_byte & 8'h11) == 8'h01) begin      // xxx0sss1
              if ((miso_byte & 8'h0E) != 8'h04) begin
                dbg <= {4'hB, miso_byte[3:0]}; state <= S_ERR;   // 010 = accepted
              end
              else begin retry <= 16'd0; gap_i <= 8'd0; mosi_byte <= 8'hFF;
                         spi_go <= 1'b1; state <= S_WR_BUSY; end
            end else if (retry == 16'd5000) begin
              dbg <= 8'hBF; state <= S_ERR;          // no data response at all
            end
            else begin retry <= retry + 1'b1; mosi_byte <= 8'hFF; spi_go <= 1'b1; end
          end
        end
        // The card pulls DO low while it programs, but not necessarily by the
        // very next byte.  Checking for 0xFF straight away can therefore see
        // the idle line before the card has taken it low, declare the write
        // finished, and issue the next command into a card that is still
        // writing -- which answers nothing, so the following command fails
        // while the write itself reports success.
        //
        // So poll a minimum number of byte times before 0xFF is allowed to
        // mean anything.  This was reasoned from the specification rather than
        // measured: a behavioural card model that asserts busy immediately
        // cannot show the difference, and no failure has been traced to it.
        S_WR_BUSY: begin
          if (!spi_busy && !spi_go) begin
            if (gap_i >= 8'd8 && miso_byte == 8'hFF) begin
              gap_i <= 8'd0; after_cmd <= S_FINISH; state <= S_GAP;
            end else begin
              if (gap_i < 8'd255) gap_i <= gap_i + 1'b1;
              mosi_byte <= 8'hFF; spi_go <= 1'b1;
            end
          end
        end

        S_FINISH: begin busy <= 1'b0; state <= S_IDLE; end
        S_ERR:    begin err  <= 1'b1; busy <= 1'b0; state <= S_IDLE; end

        default: state <= S_RESET;
      endcase

      // The stall watchdog, after the case so that it wins.  A state that has
      // not changed for its whole life has stopped waiting on the card and
      // started hanging on it; report where and let the caller retry.  The
      // code is the same E0+state the HDSK controller uses, so one encoding
      // covers both layers.
      state_q <= state;
      if (state != state_q) begin
        stall <= 25'd0;
      end else if (state != S_IDLE) begin
        if (stall == 25'h1FF_FFFF) begin
          // C0+state, distinct from the E0+state the HDSK controller reports.
          // The difference matters: this one means the state genuinely stopped
          // changing, where E0 only means the controller's own timer expired
          // while the card machine happened to be passing through here.
          dbg   <= {3'b110, 5'(state)};
          state <= S_ERR;
        end else begin
          stall <= stall + 1'b1;
        end
      end
    end
  end

endmodule

`endif
