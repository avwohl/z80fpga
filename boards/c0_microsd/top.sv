// Signaloid C0-microSD top level (iCE40UP5K-UWG30).
//
// The board's 12 MHz clock is halved to 6 MHz and the whole system runs from
// that: at 94% of the UP5K's logic the core closes at about 8.7 MHz, and the
// iCE40 PLL cannot synthesise anything below 16 MHz, so a divider on a global
// buffer is the way down.  One T-state per clock, so the Z80 runs at 6 MHz.
//
// Console at 115200 baud on the SD breakout pins: TX on SD_CMD (A4), RX on
// SD_DAT0 (A1).  The board's clock pin B3 doubles as SD_CLK, so the receive
// line has to come from a data pin rather than from LiteX's "serial" entry.
//
// Memory: the four SPRAM blocks give exactly four 32 KB RAM banks (128 KB).
// Block RAM cannot hold a whole bank, so the boot ROM is 8 KB and the rest
// of ROM bank 0 mirrors it.  There is no reset button, so the design comes
// out of reset on a counter.

module top (
    input  logic clk12,
    output logic led_red,
    output logic led_green,
    output logic sd_cmd,          // UART TX
    input  logic sd_dat0          // UART RX
);

  // 12 MHz -> 6 MHz on a global buffer
  logic clk_div = 1'b0;
  logic clk_sys;

  always_ff @(posedge clk12) clk_div <= ~clk_div;

  SB_GB u_gb (.USER_SIGNAL_TO_GLOBAL_BUFFER (clk_div), .GLOBAL_BUFFER_OUTPUT (clk_sys));

  logic [7:0] rstcnt = 8'h00;
  logic       rst_n;

  always_ff @(posedge clk_sys) if (!rstcnt[7]) rstcnt <= rstcnt + 8'd1;
  assign rst_n = rstcnt[7];

  logic [7:0] led8;

  z80_soc #(
      .CLK_HZ    (6_000_000),
      .CPU_DIV   (1),             // one T-state per clock: a 6 MHz Z80
      .BAUD      (115200),
      .ROM_BANKS (1),
      .RAM_BANKS (4),
      .ROM_AW_P  (13),            // 8 KB boot ROM, mirrored across the bank
      .RAM_AW_P  (17),            // 128 KB of SPRAM
      .USE_SPRAM (1'b1),
      .ROM_INIT  ("boot.hex"),
      .UCODE_MEM ("z80_ucode.mem"),
      .DISP_MEM  ("z80_dispatch.mem")
  ) u_soc (
      .clk     (clk_sys),
      .rst_n   (rst_n),
      .uart_rx (sd_dat0),
      .uart_tx (sd_cmd),
      .led     (led8),
      .sw      (8'h00)
  );

  assign led_red   = led8[0];
  assign led_green = led8[1];

endmodule
