// RomWBW on the Icepi Zero: the full 512 KB + 512 KB map, with both halves in
// the SDRAM and the ROM half put there off the microSD card at power-up.
//
// The Nexys A7 solves the same problem the other way round, and the reason is
// arithmetic rather than taste.  There the ROM is the bank in block RAM,
// because it is the one whose contents have to exist before the first
// instruction fetch and 512 KB of block RAM is available; the RAM goes to
// DDR2, which suits it, since RAM starts undefined anyway.  Here 512 KB of
// block RAM does not exist -- a byte-wide ROM packs at 2304 bytes per EBR and
// an LFE5U-25F has 56 of them, so 126 KB is the ceiling for everything in the
// design put together -- and the bitstream cannot carry the image at all.
// Something has to fetch it.
//
// The card does, because it is already there.  This build needs the slot for
// HDSK0:/HDSK1: regardless, sd_spi is the one part of this repository that
// has been proved against a real card, and rtl/soc/rom_loader.sv is 150 lines
// on top of it.  The alternative was the SPI configuration flash, which wants
// a second SPI master and the USRMCLK primitive to reach a pin the
// configuration engine owns.
//
// The three LEDs above the LED port are the bring-up sequence, in order:
// sdram_init_done, then rom_done, and rom_failed if the card would not give
// the image up.  A board that says nothing has stopped at whichever of those
// is still dark.  Staging 512 KB at the SPI clock sd_spi settles on takes
// something under a second, so the first of them is not instant.

module top_romwbw (
    input  logic        clk,          // 50 MHz, M1
    input  logic  [1:0] button,
    output logic  [4:0] led,
    output logic        usb_tx,
    input  logic        usb_rx,

    // microSD in SPI mode.  sd_dat[2:1] are not used by SPI mode and are
    // driven high rather than left to a pull-up, the way the Nexys build
    // does it.
    output logic        sd_clk,
    output logic        sd_mosi,
    input  logic        sd_miso,
    output logic        sd_csn,
    output logic        sd_dat1,
    output logic        sd_dat2,
    input  logic        sd_det,

    output logic [12:0] sdram_a,
    inout  wire  [15:0] sdram_dq,
    output logic  [1:0] sdram_ba,
    output logic  [1:0] sdram_dqm,
    output logic        sdram_csn,
    output logic        sdram_cke,
    output logic        sdram_clk,
    output logic        sdram_wen,
    output logic        sdram_casn,
    output logic        sdram_rasn
);

  localparam int CLK_SHIFT = 1;       // 50 MHz >> 1 = 25 MHz

  // ------------------------------------------------------------ the clock
  logic [CLK_SHIFT-1:0] div = '0;
  logic                 clk_sys;

  always_ff @(posedge clk) div <= div + 1'b1;

  DCCA u_gb (.CLKI (div[CLK_SHIFT-1]), .CE (1'b1), .CLKO (clk_sys));

  ODDRX1F u_sdclk (
      .D0 (1'b0), .D1 (1'b1), .SCLK (clk_sys), .RST (1'b0), .Q (sdram_clk)
  );

  // ------------------------------------------------------------- the reset
  logic [1:0] btn0_sync;
  logic [7:0] rstcnt = 8'h00;
  logic       rst_n;

  always_ff @(posedge clk_sys) btn0_sync <= {btn0_sync[0], button[0]};

  always_ff @(posedge clk_sys) begin
    if (!btn0_sync[1])   rstcnt <= 8'h00;
    else if (!rstcnt[7]) rstcnt <= rstcnt + 8'd1;
  end

  assign rst_n = rstcnt[7];

  // --------------------------------------------------------------- the SoC
  logic [7:0]  led8;
  logic [15:0] dq_o;
  logic        dq_oe, sdram_ready, rom_done, rom_failed;

  assign sdram_dq  = dq_oe ? dq_o : 16'bz;
  assign sd_dat1   = 1'b1;
  assign sd_dat2   = 1'b1;

  z80_soc #(
      .CLK_HZ       (50_000_000 >> CLK_SHIFT),
      .CPU_DIV      (1),                  // one T-state per clock: a 25 MHz Z80
      .BAUD         (115200),
      .CONSOLE_SSER (1'b1),               // stock RomWBW drives SSER, not 0x00/0x01
      // No RTS/CTS.  The Nexys build needs it because its FT2232 will outrun
      // the receive FIFO; whether the FT231X here even exposes the same two
      // signals on L16 and L15 has not been established, and an input that
      // gates the transmitter is the wrong thing to guess at on a board that
      // has never been run.  If characters go missing, that is the first
      // thing to look at.
      .FLOW_CTRL    (1'b0),
      .USE_HDSK     (1'b1),               // HDSK0:/HDSK1: on port 0xFD
      .USE_SDRAM    (1'b1),
      .SDRAM_ROM    (1'b1),               // and the ROM half staged into it
      .ROM_LBA      (32'h0040_0000),      // the first block clear of both units
      .ROM_BLOCKS   (1024),               // 512 KB of image
      .ROM_BANKS    (16),
      .RAM_BANKS    (16),                 // common bank 0x8F, as RomWBW wants
      .UCODE_MEM    ("z80_ucode.mem"),
      .DISP_MEM     ("z80_dispatch.mem")
  ) u_soc (
      .clk        (clk_sys),
      .rst_n      (rst_n),
      .uart_rx    (usb_rx),
      .uart_tx    (usb_tx),
      .uart_cts_n (1'b0),
      .uart_rts_n (),
      .led        (led8),
      .sw         (8'h00),

      .sd_sck (sd_clk), .sd_mosi (sd_mosi), .sd_miso (sd_miso), .sd_cs (sd_csn),

      .sdram_a     (sdram_a),   .sdram_ba    (sdram_ba),  .sdram_dqm (sdram_dqm),
      .sdram_cs_n  (sdram_csn), .sdram_ras_n (sdram_rasn),
      .sdram_cas_n (sdram_casn), .sdram_we_n (sdram_wen), .sdram_cke (sdram_cke),
      .sdram_dq_o  (dq_o), .sdram_dq_oe (dq_oe), .sdram_dq_i (sdram_dq),
      .sdram_init_done (sdram_ready),
      .rom_done (rom_done), .rom_failed (rom_failed)
  );

  // The bring-up sequence, then whatever the firmware is saying.
  assign led = {rom_failed, rom_done, sdram_ready, ~sd_det, led8[0]};

endmodule
