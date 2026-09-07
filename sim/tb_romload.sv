// The whole of the Icepi Zero's memory story, end to end: a ROM image sitting
// on a microSD card, staged into SDRAM by rtl/soc/rom_loader.sv while the core
// is held in reset, and then executed out of the chip it was staged into.
//
// This is the one bench where nothing in the memory path comes out of the
// bitstream.  The ROM is not block RAM initialised by $readmemh -- it is
// bytes that travelled over SPI into a memory model, and the first
// instruction the Z80 fetches is one of them.  If the loader is off by a byte,
// or stages to the wrong address, or lets the core go too early, or the
// address decode puts the ROM window on top of the RAM window, the monitor
// does not print.
//
// Two checks, deliberately: the image is compared against the chip's contents
// byte for byte, and then the CPU is asked to run it.  The first catches a
// staging bug that the second might survive -- most of a 2 KB image is
// padding, and a monitor whose text is intact will happily print a banner out
// of a ROM whose top half is wrong.

`timescale 1ns/1ps

module tb_romload;

  localparam int          CLK_HZ    = 25_000_000;
  localparam int          BAUD      = 3_125_000;
  localparam int          DIV       = CLK_HZ / BAUD;
  localparam int          BLOCKS    = 4;                  // 2 KB of image
  localparam int          IMG       = BLOCKS * 512;
  localparam logic [31:0] LBA       = 32'h0040_0000;      // clear of both HDSK units
  localparam              IMG_FILE  = "sim/boot2k.hex";

  logic       clk = 0, rst_n = 0;
  logic       uart_rx = 1, uart_tx;
  logic [7:0] led;

  always #20 clk = ~clk;                                  // 25 MHz

  logic [12:0] sd_a;
  logic  [1:0] sd_ba, sd_dqm;
  logic        sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_cke;
  logic [15:0] sd_dq_o;
  logic        sd_dq_oe, sd_init, rom_done, rom_failed;
  logic        sck, mosi, miso, ss_n;

  wire  [15:0] dq;
  logic [15:0] model_dq;
  logic        model_drive;

  assign dq = sd_dq_oe    ? sd_dq_o  : 16'hzzzz;
  assign dq = model_drive ? model_dq : 16'hzzzz;

  z80_soc #(
      .CLK_HZ     (CLK_HZ),
      .CPU_DIV    (1),
      .BAUD       (BAUD),
      .USE_SDRAM  (1'b1),
      .USE_HDSK   (1'b1),
      .SDRAM_ROM  (1'b1),
      .ROM_LBA    (LBA),
      .ROM_BLOCKS (BLOCKS),
      .ROM_BANKS  (16),
      .RAM_BANKS  (16),
      .UCODE_MEM  ("rtl/core/z80_ucode.mem"),
      .DISP_MEM   ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n),
      .uart_rx (uart_rx), .uart_tx (uart_tx),
      .led (led), .sw (8'h00),
      .sd_sck (sck), .sd_mosi (mosi), .sd_miso (miso), .sd_cs (ss_n),
      .sdram_a (sd_a), .sdram_ba (sd_ba), .sdram_dqm (sd_dqm),
      .sdram_cs_n (sd_cs_n), .sdram_ras_n (sd_ras_n), .sdram_cas_n (sd_cas_n),
      .sdram_we_n (sd_we_n), .sdram_cke (sd_cke),
      .sdram_dq_o (sd_dq_o), .sdram_dq_oe (sd_dq_oe), .sdram_dq_i (dq),
      .sdram_init_done (sd_init),
      .rom_done (rom_done), .rom_failed (rom_failed)
  );

  // 256 rows is the whole megabyte the design can address: 512 KB of ROM at
  // the bottom and 512 KB of RAM at the top.  A loader or a decode that went
  // outside it stops the model rather than aliasing onto something.
  sdram_model #(.ROWS (256)) u_chip (
      .clk (~clk), .cke (sd_cke),
      .cs_n (sd_cs_n), .ras_n (sd_ras_n), .cas_n (sd_cas_n), .we_n (sd_we_n),
      .a (sd_a), .ba (sd_ba), .dqm (sd_dqm),
      .dq_in (dq), .dq_oe (sd_dq_oe),
      .dq_out (model_dq), .dq_drive (model_drive)
  );

  // BASE_LBA means the image is only at LBA; a loader that read from block 0
  // would get the wrap, not the firmware.
  sd_card #(.BYTES (IMG), .BASE_LBA (LBA), .INIT_FILE (IMG_FILE), .STRICT (1'b1)) u_card (
      .sck (sck), .mosi (mosi), .cs (ss_n), .miso (miso)
  );

  // Did the core ever touch memory before the image was there?  Waiting for
  // the console to stay quiet does not answer that -- a core let go early
  // fetches zeros, which are NOPs, wanders the whole 64 KB and arrives back
  // at 0000 to run the monitor properly, printing a perfectly good banner
  // some milliseconds late.  mreq_n is the core's own signal and says so
  // directly.
  logic early = 1'b0;
  always @(posedge clk) if (!rom_done && !dut.mreq_n) early <= 1'b1;

  // ------------------------------------------------- reading the chip back
  // The same arithmetic sdram_ram does, so a byte can be looked up the way
  // the CPU would see it.
  function automatic [7:0] chip_byte(input [19:0] addr);
    logic [18:0] wa;
    logic  [8:0] col;
    logic  [1:0] bank;
    logic [12:0] row;
    integer      widx;
    begin
      wa   = addr[19:1];
      col  = wa[8:0];
      bank = wa[10:9];
      row  = 13'(wa >> 11);
      widx = ((bank * 256) + row) * 512 + col;
      chip_byte = addr[0] ? u_chip.mem[widx][15:8] : u_chip.mem[widx][7:0];
    end
  endfunction

  logic [7:0] want [0:IMG-1];
  integer     i, bad;

  // ------------------------------------------------------------- the console
  integer   nrx = 0, banner_end = 0;
  reg [7:0] ch;
  reg [7:0] rxbuf [0:255];

  task automatic uart_get(output reg [7:0] c);
    integer k;
    begin
      @(negedge uart_tx);
      repeat (DIV + DIV/2) @(posedge clk);
      for (k = 0; k < 8; k = k + 1) begin
        c[k] = uart_tx;
        repeat (DIV) @(posedge clk);
      end
    end
  endtask

  initial forever begin
    uart_get(ch);
    if (nrx < 256) rxbuf[nrx] = ch;
    nrx = nrx + 1;
    if (ch == 8'h0A) $write("\n");
    else if (ch >= 8'h20 && ch < 8'h7F) $write("%c", ch);
    $fflush;
  end

  initial begin
    $readmemh(IMG_FILE, want);
    repeat (10) @(posedge clk);
    rst_n = 1;

    fork
      begin
        repeat (4_000_000) @(posedge clk);
        $display("FAIL: timed out with rom_done=%b rom_failed=%b after %0d characters",
                 rom_done, rom_failed, nrx);
        $finish;
      end
      begin
        // Nothing should have come out of the UART yet: the core is in reset
        // until the image is there, and a core that ran early would have been
        // fetching zeros out of an empty chip.
        wait (rom_done || rom_failed);
        if (rom_failed) begin
          $display("FAIL: the loader gave up on the card");
          $finish;
        end
        if (nrx != 0) begin
          $display("FAIL: %0d characters appeared before the ROM was staged", nrx);
          $finish;
        end
        if (early) begin
          $display("FAIL: the core drove mreq_n before the ROM was staged");
          $finish;
        end
        $display("staged %0d bytes at %0t", IMG, $time);

        bad = 0;
        for (i = 0; i < IMG; i = i + 1)
          if (chip_byte(20'(i)) !== want[i]) begin
            if (bad < 4)
              $display("  %05h: chip %02h, image %02h", i, chip_byte(20'(i)), want[i]);
            bad = bad + 1;
          end
        if (bad != 0) begin
          $display("FAIL: %0d of %0d staged bytes are wrong", bad, IMG);
          $finish;
        end
        $display("the image in the chip matches the one on the card");

        $display("--- console ---");
        wait (nrx >= 35);
        banner_end = nrx;
        repeat (DIV * 20) @(posedge clk);
        uart_put("A");
        uart_put("B");
        uart_put(8'h0D);
        wait (nrx >= banner_end + 4);
        repeat (DIV * 20) @(posedge clk);
        $display("\n--- %0d characters, %0d after the prompt", nrx, nrx - banner_end);
        if (rxbuf[banner_end]   != "A" || rxbuf[banner_end+1] != "B" ||
            rxbuf[banner_end+2] != 8'h0D || rxbuf[banner_end+3] != 8'h0A)
          $display("FAIL: echo wrong");
        else begin
          // And the two windows really are two.  The monitor's bank check
          // wrote its signature into RAM banks 0x80 and 0x81 at offset 0x4000
          // -- if the ROM window and the RAM window were the same megabyte,
          // those bytes would be sitting in the ROM half instead, and this is
          // the only thing in the bench that would notice: the monitor's own
          // code and stack are nowhere near the addresses its bank check uses.
          bad = 0;
          if (chip_byte(20'h84000) !== 8'h80) bad = bad + 1;
          if (chip_byte(20'h84001) !== 8'h7F) bad = bad + 1;
          if (chip_byte(20'h8C000) !== 8'h81) bad = bad + 1;
          if (chip_byte(20'h8C001) !== 8'h7E) bad = bad + 1;
          if (bad != 0)
            $display("FAIL: the bank check's signature is not in the RAM window (%02h %02h %02h %02h)",
                     chip_byte(20'h84000), chip_byte(20'h84001),
                     chip_byte(20'h8C000), chip_byte(20'h8C001));
          else
            $display("PASS: ROM staged off the card into SDRAM, and the Z80 ran it");
        end
        $finish;
      end
    join
  end

  task automatic uart_put(input [7:0] b);
    integer k;
    begin
      uart_rx = 0; repeat (DIV) @(posedge clk);
      for (k = 0; k < 8; k = k + 1) begin
        uart_rx = b[k]; repeat (DIV) @(posedge clk);
      end
      uart_rx = 1; repeat (DIV) @(posedge clk);
    end
  endtask

endmodule
