// Sipeed Tang Nano 20K (Gowin GW2AR-LV18QN88C8/I7): the core, the UART and
// sw/boot.z80 in the part's block RAM.  Tier (a) -- no SDRAM, no microSD.
// ../../docs/porting.md says what the two tiers are, and README.md here is
// the plan for getting to tier (b).
//
// The memory map is not the Icepi's, and it cannot be.  This part has 46
// BSRAM blocks where an LFE5U-25F has 56, and a byte-granular RAM packs at
// 2048 bytes to a block because byte-wide writes rule out the wider mode a
// read-only image can use.  Measured, by building all three:
//
//   32 KB ROM + 64 KB RAM   48 of 46   nextpnr: "no BELs remaining ... 'SP'"
//   16 KB ROM + 64 KB RAM   41 of 46   89%
//    8 KB ROM + 64 KB RAM   37 of 46   80%
//
// 8 KB it is.  The monitor assembles to a few hundred bytes, so the smaller
// image costs nothing, and 9 spare blocks is room for the next thing rather
// than a cliff.  ROM_AW_P mirrors it across the 32 KB bank, which is the
// trick boards/c0_microsd already uses.
//
// There is no reset button, deliberately.  Pins 87 and 88 are MODE1 and
// MODE0, the configuration straps, and Sipeed's own constraint files disagree
// about whether to pull them up or down -- so the polarity is not something
// to guess at on a board that has never run this design.  A reset held the
// wrong way round gives a mute board, which is exactly what a broken
// toolchain looks like, and this build exists to tell those two apart.  The
// counter below is what boards/icepi_zero and boards/c0_microsd both do, and
// S1 already power-cycles the configuration if a reset is wanted.

module top (
    input  logic       clk,           // 27 MHz, pin 4
    output logic [5:0] led,           // active low
    output logic       uart_tx,       // to the on-board bridge
    input  logic       uart_rx        // from it
);

  // ------------------------------------------------------- the system clock
  // Half the board's 27 MHz, on a global buffer, with CPU_DIV = 1.  That is
  // the Icepi Zero's arrangement and it is the only one available here: see
  // the SoC note below for why CPU_DIV must be 1 on a nextpnr board, and
  // ../../boards/icepi_zero/README.md for the same reasoning on an ECP5.
  //
  // 13.5 MHz rather than 27 doubles the margin on the one path the bank
  // check exercises and nothing else does -- the MMU's cur_bank register
  // through phys_addr into the block RAM's address pins.  nextpnr's Gowin
  // timing model is not something this repository has ever checked against
  // silicon, so where a path is only exercised by the thing that fails, the
  // clock is the cheap variable to move.
  logic clk_div = 1'b0;
  logic clk_sys;

  always_ff @(posedge clk) clk_div <= ~clk_div;

  BUFG u_bufg (.I (clk_div), .O (clk_sys));

  // ------------------------------------------------------------- the reset
  // 128 clocks after configuration, which is 9.5 us at 13.5 MHz.
  logic [7:0] rstcnt = 8'h00;
  logic       rst_n;

  always_ff @(posedge clk_sys) if (!rstcnt[7]) rstcnt <= rstcnt + 8'd1;
  assign rst_n = rstcnt[7];

  // --------------------------------------------------------------- the SoC
  // CPU_DIV is 1, and the fabric clock is the halved one made above.
  //
  // CPU_DIV = 2 was tried first and the board would not run: the banner never
  // appeared, and every throwaway image that touched data memory failed while
  // instruction fetch and both I/O directions worked.  CPU_DIV > 1 makes the
  // core advance on a clk_en tick, which turns the memory paths into
  // multi-cycle ones -- and CLAUDE.md records that nextpnr accepts a
  // MULTICYCLE constraint in total silence and does nothing with it.  That is
  // why both of the other nextpnr boards use CPU_DIV = 1, and it is why this
  // one does.  A Vivado board can have CPU_DIV > 1 because an XDC can say so.
  //
  // The fabric clock is halved above, so the Z80 runs at 13.5 MHz -- still
  // faster than the 8 MHz Nexys that boots CP/M today.
  logic [7:0] led8;

  z80_soc #(
      .CLK_HZ    (13_500_000),
      .CPU_DIV   (1),                 // a 13.5 MHz Z80; see above
      .BAUD      (115200),
      .ROM_BANKS (1),                 // a 32 KB bank ...
      .ROM_AW_P  (13),                // ... holding an 8 KB image, mirrored
      .RAM_BANKS (2),                 // 64 KB; sw/boot.z80's RAM_N matches
      .ROM_INIT  ("boot.hex"),
      .UCODE_MEM ("z80_ucode.mem"),
      .DISP_MEM  ("z80_dispatch.mem")
  ) u_soc (
      .clk        (clk_sys),
      .rst_n      (rst_n),
      .uart_rx    (uart_rx),
      .uart_tx    (uart_tx),
      .uart_cts_n (1'b0),             // no flow control on this build
      .uart_rts_n (),
      .led        (led8),
      .sw         (8'h00)
  );

  // -------------------------------------------------------------- the LEDs
  // Three of the six are the LED port at 0xFF, as on the other boards.  The
  // monitor never writes it, so those three stay dark until something loaded
  // does -- and a board nobody has run this on wants the other three more:
  //
  //   led[5]  a heartbeat off the oscillator.  Blinking is configured and
  //           clocked; lit and still is configured and not clocked, because
  //           the counter is then stuck at the 0 it starts from; dark is not
  //           configured at all.  Three states, one lamp.
  //   led[4]  out of reset.
  //   led[3]  the UART has pulled its line low since reset, latched.  That is
  //           ROM, core, monitor and port write in one lamp, and it stays lit
  //           even if the host end of the link is misconfigured.
  logic [23:0] hb = '0;
  logic        tx_seen;

  always_ff @(posedge clk_sys) hb <= hb + 1'b1;

  always_ff @(posedge clk_sys) begin
    if (!rst_n)        tx_seen <= 1'b0;
    else if (!uart_tx) tx_seen <= 1'b1;
  end

  // A 0 lights a lamp.  hb[23] is the one bit deliberately not inverted, so
  // that a counter which never moves reads as lit rather than dark -- dark is
  // what a part that never configured looks like, and those two want telling
  // apart.
  assign led = {hb[23], ~rst_n, ~tx_seen, ~led8[2:0]};

endmodule
