// Icepi Zero with its RAM banks in the board's SDRAM: the full 512 KB RomWBW
// RAM map instead of the two banks that fit in block RAM.
//
// The split is the one the part forces, and it is the mirror image of the
// Nexys A7's.  There, the ROM had to be the one in block RAM because it is
// the only bank whose contents must survive to the first instruction fetch,
// and 512 KB of it just fitted.  Here 512 KB of anything does not fit -- a
// byte-wide ROM packs at 2304 bytes per EBR and the part has 56 of them, so
// 126 KB is the ceiling for everything together.  So the ROM is one 32 KB
// bank, and all sixteen RAM banks are in the MT48LC16M16, of whose 32 MB the
// Z80 uses the bottom 512 KB.
//
// Nothing holds the CPU in reset while the chip powers up.  It does not need
// to: sdram_ram ignores requests until its 100 us initialisation has finished,
// so the first stack push -- which is the first RAM access the monitor makes,
// two instructions in -- simply holds wait_n low until the chip is there.
// led[4] shows that it got there, and is the first thing to look at if the
// console is silent.
//
// The chip's clock is an inverted copy of the fabric clock, sent out through
// an ODDRX1F rather than routed to a pad, so it leaves from an IO register
// with a defined delay.  Inverted means the chip's rising edge is half a
// fabric clock after the one that launched the command -- 20 ns of setup at
// 25 MHz, against the 1.5 ns the part asks for -- and read data comes back
// half a clock before it is sampled.  That margin is why this build needs no
// PLL, no phase shift and no output delay constraint, which is fortunate,
// because nextpnr-ecp5 has nowhere to write an output delay constraint down.

module top_sdram (
    input  logic        clk,          // 50 MHz, M1
    input  logic  [1:0] button,       // pulled up: 0 when pressed
    output logic  [4:0] led,
    output logic        usb_tx,       // FPGA -> FTDI
    input  logic        usb_rx,       // FTDI -> FPGA

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

  // D0 goes out while SCLK is high and D1 while it is low, so 0 then 1 is an
  // inverted copy of clk_sys.
  ODDRX1F u_sdclk (
      .D0 (1'b0), .D1 (1'b1), .SCLK (clk_sys), .RST (1'b0), .Q (sdram_clk)
  );

  // ------------------------------------------------------------- the reset
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
  logic [7:0]  led8;
  logic [15:0] dq_o;
  logic        dq_oe, sdram_ready;

  assign sdram_dq = dq_oe ? dq_o : 16'bz;

  z80_soc #(
      .CLK_HZ    (50_000_000 >> CLK_SHIFT),
      .CPU_DIV   (1),                 // one T-state per clock: a 25 MHz Z80
      .BAUD      (115200),
      .USE_SDRAM (1'b1),
      .ROM_BANKS (1),                 // 32 KB of block RAM
      .RAM_BANKS (16),                // 512 KB of SDRAM, common bank 0x8F
      .ROM_INIT  ("boot.hex"),
      .UCODE_MEM ("z80_ucode.mem"),
      .DISP_MEM  ("z80_dispatch.mem")
  ) u_soc (
      .clk        (clk_sys),
      .rst_n      (rst_n),
      .uart_rx    (usb_rx),
      .uart_tx    (usb_tx),
      .uart_cts_n (1'b0),
      .uart_rts_n (),
      .led        (led8),
      .sw         ({7'd0, ~btn1_sync[1]}),

      .sdram_a     (sdram_a),   .sdram_ba   (sdram_ba),  .sdram_dqm (sdram_dqm),
      .sdram_cs_n  (sdram_csn), .sdram_ras_n (sdram_rasn),
      .sdram_cas_n (sdram_casn), .sdram_we_n (sdram_wen), .sdram_cke (sdram_cke),
      .sdram_dq_o  (dq_o), .sdram_dq_oe (dq_oe), .sdram_dq_i (sdram_dq),
      .sdram_init_done (sdram_ready)
  );

  assign led = {sdram_ready, led8[3:0]};

endmodule
