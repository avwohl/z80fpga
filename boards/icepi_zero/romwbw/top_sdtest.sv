// Does the microSD card work at all?
//
// romwbw/ holds the Z80 in reset until rom_loader has staged the ROM off the
// card, so a card that never comes up gives a machine that never says
// anything -- and the only signal is a lamp. This build answers the same
// question with a console: the ROM is in the bitstream, the CPU runs at once,
// and sim/hdsk_test.z80 drives the HDSK controller and prints what the card
// said. Same pins and same LPF as romwbw/, so it is testing the same wiring.
//
// HDSK's debug port is 0xFC, and status2 reads E0 + sd_spi's state when the
// card machine is still working, which is how a stuck initialisation names
// the step it is stuck on.
//
// NOTE: hdsk_test.z80 writes a sector before reading it back. The HDSK units
// live below LBA 0x400000, well clear of the ROM image, but it is not a
// read-only test -- do not point it at a card whose contents matter.
//
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

module top_sdtest (
    input  logic        clk,          // 50 MHz, M1
    input  logic  [1:0] button,
    output logic  [4:0] led,
    output logic        usb_tx,
    input  logic        usb_rx,       // FTDI -> FPGA
    input  logic        usb_dtrn,     // FTDI DTR, low = asserted; resets

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
  // The console's DTR line resets too, so a session at the far end of a wire
  // can make the banner appear without reaching the underside of the board.
  // An edge, not a level: a terminal holding DTR asserted would otherwise
  // hold the machine in reset.  See ../README.md.
  logic [1:0] btn0_sync, dtr_sync;
  logic       dtr_prev;
  logic [7:0] rstcnt = 8'h00;
  logic       rst_n;

  always_ff @(posedge clk_sys) begin
    btn0_sync <= {btn0_sync[0], button[0]};
    dtr_sync  <= {dtr_sync[0],  usb_dtrn};
    dtr_prev  <= dtr_sync[1];
  end

  wire dtr_reset = dtr_prev && !dtr_sync[1];

  always_ff @(posedge clk_sys) begin
    if (!btn0_sync[1] || dtr_reset) rstcnt <= 8'h00;
    else if (!rstcnt[7])            rstcnt <= rstcnt + 8'd1;
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
      .CONSOLE_SSER (1'b0),               // sim/hdsk_test.z80 uses 0x00/0x01
      // No RTS/CTS.  The Nexys build needs it because its FT2232 will outrun
      // the receive FIFO; whether the FT231X here even exposes the same two
      // signals on L16 and L15 has not been established, and an input that
      // gates the transmitter is the wrong thing to guess at on a board that
      // has never been run.  If characters go missing, that is the first
      // thing to look at.
      .FLOW_CTRL    (1'b0),
      .USE_HDSK     (1'b1),               // HDSK0:/HDSK1: on port 0xFD
      .USE_SDRAM    (1'b0),               // RAM in block RAM: one thing at a time
      .SDRAM_ROM    (1'b0),               // ROM in the bitstream, so the CPU runs
      .ROM_BANKS    (1),                  // ... immediately, instead of waiting for
      .ROM_AW_P     (13),                 //     a card that is what we are testing
      .ROM_INIT     ("hdsk_test.hex"),
      .RAM_BANKS    (2),
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
  // Before the image is staged the lamps are the loader's; afterwards they are
  // the Z80's.  They cannot be both: five lamps, four loader signals and a
  // three-bit progress code from sw/boot.z80 and sw/ledchk.z80, and giving
  // the Z80 only led8[0] meant a staged-but-wedged machine looked exactly
  // like a staged-and-happy one.  led[3] stays lit once the ROM is in, so a
  // glance still says which half of the story you are reading.
  // Everything interesting comes out of the console here, so the lamps only
  // have to say the board is alive and whether it thinks a card is in.
  assign led = {1'b1, sd_det, led8[2:0]};

endmodule
