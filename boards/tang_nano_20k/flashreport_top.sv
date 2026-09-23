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
    output logic       mspi_clk,      // the configuration flash, handed to
    output logic       mspi_cs_n,     // user logic by gowin_pack
    output logic       mspi_mosi,     // --mspi_as_gpio
    output logic       uart_tx,       // to the on-board bridge
    input  logic       uart_rx        // from it
);

  // ------------------------------------------------------------- the reset
  // 128 clocks after configuration, which is 4.7 us at 27 MHz.
  logic [7:0] rstcnt = 8'h00;
  logic       rst_n;

  always_ff @(posedge clk) if (!rstcnt[7]) rstcnt <= rstcnt + 8'd1;
  assign rst_n = rstcnt[7];

  // --------------------------------------------------------------- the SoC
  // The 27 MHz board clock goes in undivided, and CPU_DIV is 1.
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
  // It costs nothing here: the design routes at 40.6 MHz, so the Z80 runs at
  // the full 27 MHz -- faster than the Nexys that boots CP/M today.
  //
  // Halving the clock to 13.5 MHz through a BUFG was tried too, on the theory
  // that the bank check's cur_bank -> phys_addr -> block-RAM-address path was
  // marginal and only that test drives it.  It is not marginal: a flash-booted
  // 13.5 MHz build printed 4411 banners and never reached "banked memory ok",
  // exactly as the 27 MHz one does.  The slower clock bought nothing, so it is
  // not kept -- but do not spend the idea twice.
  logic [7:0] led8;

  z80_soc #(
      .CLK_HZ    (27_000_000),
      .CPU_DIV   (1),                 // a 27 MHz Z80; see above
      .BAUD      (115200),
      .ROM_BANKS (1),                 // a 32 KB bank ...
      .ROM_AW_P  (13),                // ... holding an 8 KB image, mirrored
      .RAM_BANKS (2),                 // 64 KB; sw/boot.z80's RAM_N matches
      .ROM_INIT  ("report.hex"),
      .UCODE_MEM ("z80_ucode.mem"),
      .DISP_MEM  ("z80_dispatch.mem")
  ) u_soc (
      .clk        (clk),
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

  always_ff @(posedge clk) hb <= hb + 1'b1;

  always_ff @(posedge clk) begin
    if (!rst_n)        tx_seen <= 1'b0;
    else if (!uart_tx) tx_seen <= 1'b1;
  end

  // A 0 lights a lamp.  hb[23] is the one bit deliberately not inverted, so
  // that a counter which never moves reads as lit rather than dark -- dark is
  // what a part that never configured looks like, and those two want telling
  // apart.
  assign led = {hb[23], ~rst_n, ~tx_seen, ~led8[2:0]};

  // The console is dead and the LEDs need eyes, so answers go into the
  // configuration flash, where openFPGALoader --dump-flash reads them back.
  // A Z80 program writes F0h|n to the LED port at 0FFh; each distinct n is
  // programmed once, at 7F0000h + (n << 8), so a single run can report every
  // marker it reached rather than only the first.  A page program can only
  // clear bits, which is why each n gets its own page.
  logic [15:0] seen;
  logic        fw_go, fw_busy;
  logic  [3:0] fw_n;

  always_ff @(posedge clk)
    if (!rst_n) begin
      seen  <= 16'h0;
      fw_go <= 1'b0;
      fw_n  <= 4'h0;
    end else begin
      fw_go <= 1'b0;
      if (led8[7:4] == 4'hF && !seen[led8[3:0]] && !fw_busy && !fw_go) begin
        fw_go       <= 1'b1;
        fw_n        <= led8[3:0];
        seen[led8[3:0]] <= 1'b1;
      end
    end

  flash_wr u_fw (
      .clk (clk), .rst_n (rst_n), .start (fw_go),
      .addr ({8'h7F, fw_n, 12'h000}), .data ({4'hF, fw_n}),
      .cs_n (mspi_cs_n), .sclk (mspi_clk), .mosi (mspi_mosi), .busy (fw_busy)
  );
endmodule
