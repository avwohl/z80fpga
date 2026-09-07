// A behavioural microSD card in SPI mode, for the benches that drive
// rtl/soc/sd_spi.sv.
//
// It is deliberately fussy in the ways a real card is, because those are the
// ways that cost hardware runs to find: it answers a command only after all
// six bytes have arrived, holds MISO high while deselected, sends R1 before a
// data token rather than with it, starts a read block with 0xFE, and goes busy
// for a few bytes after a write.  The initialisation sequence it answers is
// the one a real 128 GB SDXC card was measured giving -- CMD0, CMD8, CMD55 +
// ACMD41, CMD58 with CCS set -- so a controller that works here is working
// against the same shape of answer.
//
// Addresses wrap inside BYTES, and BASE_LBA says which block sits at offset
// zero.  Leaving BASE_LBA at 0 gives the plain wrapping window the HDSK
// benches want.  Setting it makes the model strict about *where* on the card
// something is: a controller that reads the right number of blocks from the
// wrong place gets wrapped nonsense instead of quietly getting away with it,
// which is what sim/tb_romload.sv is checking.

`timescale 1ns/1ps

module sd_card #(
    parameter int          BYTES     = 2048,   // the modelled window
    parameter logic [31:0] BASE_LBA  = 32'd0,  // the block at offset zero
    parameter              INIT_FILE = "",     // $readmemh into that window
    parameter bit          STRICT    = 1'b0,   // stop on a block outside it
    parameter bit          VERBOSE   = 1'b0
) (
    input  logic sck,
    input  logic mosi,
    input  logic cs,
    output logic miso
);

  logic  [7:0] card [0:BYTES-1];
  logic  [7:0] shift_out = 8'hFF, shift_in;
  integer      bitc = 0, cn = 0, resp_n = 0, resp_i = 0;
  logic  [7:0] cbuf [0:5], resp [0:7];
  integer      data_n = 0, data_i = 0, wr_expect = 0, wr_i = 0, busy_n = 0;
  logic [31:0] lba = 0;
  logic        sending_data = 0, wr_active = 0;
  integer      k;

  initial begin
    for (k = 0; k < BYTES; k = k + 1) card[k] = 8'h00;
    if (INIT_FILE != "") $readmemh(INIT_FILE, card);
  end

  // Where a byte of a block lands in the modelled window.
  //
  // STRICT is what makes BASE_LBA mean anything.  Wrapping is benign to the
  // point of being useless as a check: a controller that asked for block 0
  // when it should have asked for BASE_LBA gets (0 - BASE_LBA) * 512, which
  // is a multiple of the window size for any sane BASE_LBA, so the modulo
  // hands back exactly the bytes it wanted and the bug is invisible.  With
  // STRICT the same mistake stops the simulation.
  function automatic integer at(input [31:0] l, input integer i);
    integer off;
    begin
      off = (l - BASE_LBA) * 512 + i;
      if (STRICT && (l < BASE_LBA || off >= BYTES)) begin
        $display("FAIL: sd_card: block %08h is outside the window (base %08h, %0d bytes)",
                 l, BASE_LBA, BYTES);
        $finish;
      end
      at = off % BYTES;
    end
  endfunction

  // SPI mode 0: MOSI sampled on the rising edge, MISO changed on the falling.
  always @(posedge sck) if (!cs) begin
    shift_in = {shift_in[6:0], mosi};
    bitc = bitc + 1;
  end

  always @(negedge sck) if (!cs) begin
    if (bitc == 8) begin
      bitc = 0;
      if (wr_active) begin
        if (wr_expect == 0 && shift_in == 8'hFE) begin
          wr_expect = 512; wr_i = 0;
        end else if (wr_expect > 0) begin
          card[at(lba, wr_i)] = shift_in;
          wr_i = wr_i + 1; wr_expect = wr_expect - 1;
          if (wr_expect == 0) begin
            resp[0] = 8'hFF; resp[1] = 8'h05; resp_n = 2; resp_i = 0;
            busy_n = 4; wr_active = 0;
          end
        end
      end else if (cn > 0 || shift_in[7:6] == 2'b01) begin
        cbuf[cn] = shift_in; cn = cn + 1;
        if (cn == 6) begin
          cn = 0;
          case (cbuf[0][5:0])
            6'd0:  begin resp[0]=8'h01; resp_n=1; resp_i=0; end
            6'd8:  begin resp[0]=8'h01; resp[1]=8'h00; resp[2]=8'h00;
                         resp[3]=8'h01; resp[4]=8'hAA; resp_n=5; resp_i=0; end
            6'd55: begin resp[0]=8'h01; resp_n=1; resp_i=0; end
            6'd41: begin resp[0]=8'h00; resp_n=1; resp_i=0; end
            6'd58: begin resp[0]=8'h00; resp[1]=8'hC0; resp[2]=8'hFF;
                         resp[3]=8'h80; resp[4]=8'h00; resp_n=5; resp_i=0; end
            6'd17: begin resp[0]=8'h00; resp_n=1; resp_i=0; data_n=512; data_i=0;
                         lba={cbuf[1],cbuf[2],cbuf[3],cbuf[4]};
                         if (VERBOSE) $display("[sd] READ  lba=%08h", lba); end
            6'd24: begin resp[0]=8'h00; resp_n=1; resp_i=0; wr_active=1; wr_expect=0;
                         lba={cbuf[1],cbuf[2],cbuf[3],cbuf[4]};
                         if (VERBOSE) $display("[sd] WRITE lba=%08h", lba); end
            default: begin resp[0]=8'h00; resp_n=1; resp_i=0; end
          endcase
        end
      end

      if (busy_n > 0)      begin shift_out = 8'h00; busy_n = busy_n - 1; end
      else if (resp_n > 0) begin
        shift_out = resp[resp_i]; resp_i = resp_i + 1; resp_n = resp_n - 1;
        if (resp_n == 0 && data_n > 0) sending_data = 1;
      end else if (sending_data) begin
        if (data_i == 0) begin shift_out = 8'hFE; data_i = 1; end
        else if (data_i <= 512) begin
          shift_out = card[at(lba, data_i - 1)]; data_i = data_i + 1;
        end else begin shift_out = 8'hFF; sending_data = 0; data_n = 0; end
      end else shift_out = 8'hFF;
    end
  end

  assign miso = cs ? 1'b1 : shift_out[7 - (bitc % 8)];

endmodule
