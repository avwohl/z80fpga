// Icepi Zero top level (Lattice ECP5 LFE5U-25F, CABGA256).
//
// The board's 50 MHz oscillator is halved and the whole design runs from the
// 25 MHz that comes out, one T-state per clock: a 25 MHz Z80, three times the
// Nexys A7 build's.  The halving is not a preference.  nextpnr-ecp5 has no
// multicycle exception and no false path -- set_multicycle_path is a hard
// error even through --sdc -- so the trick the Vivado boards use, running the
// fabric at 100 MHz and telling the tools that a core register only moves one
// clock in twelve, has nowhere to be written down here.  What is left is to
// run the fabric at a rate the core really closes at.  Routed, this design
// reports 27.9 to 29.5 MHz across placement seeds, so 25 MHz passes and 50 MHz
// does not.  If a board ever turns out to be marginal, change CLK_SHIFT to 2
// for 12.5 MHz and FREQUENCY NET in the .lpf to match.
//
// Memory: 32 KB of ROM and two 32 KB RAM banks, all in the part's 56 EBRs.
// That is 48 of them -- a byte-wide ROM packs at 2304 bytes per block and a
// byte-wide RAM at 2048 -- and it is close to the ceiling.  A third RAM bank
// does not fit.  For 512 KB of RAM the board's SDRAM is right there and the
// build in sdram/ uses it.
//
// Console at 115200 8N1 on the FT231X, which is the same USB-C socket the
// bitstream is loaded through, so there is no second cable.

module top (
    input  logic       clk,           // 50 MHz, M1
    input  logic [1:0] button,        // pulled up: 0 when pressed
    output logic [4:0] led,
    output logic       usb_tx,        // FPGA -> FTDI
    input  logic       usb_rx         // FTDI -> FPGA
);

  localparam int CLK_SHIFT = 1;       // 50 MHz >> 1 = 25 MHz

  // ------------------------------------------------------------ the clock
  // A counter and a global buffer, not a PLL: the ratio is a power of two, so
  // a PLL would buy nothing but a way to fail to lock.
  logic [CLK_SHIFT-1:0] div = '0;
  logic                 clk_sys;

  always_ff @(posedge clk) div <= div + 1'b1;

  DCCA u_gb (.CLKI (div[CLK_SHIFT-1]), .CE (1'b1), .CLKO (clk_sys));

  // ------------------------------------------------------------- the reset
  // 128 clocks after configuration, and again 128 clocks after the button is
  // let go, which debounces it for free.  The synchroniser is not decorative:
  // the button is asynchronous to a clock this design derives itself.
  logic [1:0] btn0_sync, btn1_sync;
  logic [7:0] rstcnt = 8'h00;
  logic       rst_n;

  always_ff @(posedge clk_sys) begin
    btn0_sync <= {btn0_sync[0], button[0]};
    btn1_sync <= {btn1_sync[0], button[1]};
  end

  always_ff @(posedge clk_sys) begin
    if (!btn0_sync[1])   rstcnt <= 8'h00;
    else if (!rstcnt[7]) rstcnt <= rstcnt + 8'd1;
  end

  assign rst_n = rstcnt[7];

  // --------------------------------------------------------------- the SoC
  logic [7:0] led8;

  z80_soc #(
      .CLK_HZ    (50_000_000 >> CLK_SHIFT),
      .CPU_DIV   (1),                 // one T-state per clock: a 25 MHz Z80
      .BAUD      (115200),
      .ROM_BANKS (1),                 // 32 KB
      .RAM_BANKS (2),                 // 64 KB
      .ROM_INIT  ("boot.hex"),
      .UCODE_MEM ("z80_ucode.mem"),
      .DISP_MEM  ("z80_dispatch.mem")
  ) u_soc (
      .clk        (clk_sys),
      .rst_n      (rst_n),
      .uart_rx    (usb_rx),
      .uart_tx    (usb_tx),
      .uart_cts_n (1'b0),             // no flow control on this build
      .uart_rts_n (),
      .led        (led8),
      .sw         ({7'd0, ~btn1_sync[1]})   // button 1 reads as switch 0
  );

  assign led = led8[4:0];

endmodule
