// Digilent Arty A7-100T top level.
//
// 100 MHz board clock, Z80 at 100/12 = 8.33 MHz, console on the on-board
// USB-UART at 115200 baud.  BTN0 resets.
//
// Memory: 2 ROM banks (64 KB) and 8 RAM banks (256 KB) out of block RAM,
// which is about half of what the -100T has.  RAM_BANKS = 16 also fits, at
// around 95% of the block RAM, and gives the RomWBW common bank id 0x8F;
// the whole 512 KB + 512 KB map wants the board's DDR3 instead.

module top (
    input  logic       CLK100MHZ,
    input  logic [3:0] btn,
    input  logic [3:0] sw,
    output logic [3:0] led,
    input  logic       uart_txd_in,     // host -> FPGA
    output logic       uart_rxd_out     // FPGA -> host
);

  logic [7:0] led8;
  logic [3:0] rst_sync;

  // BTN0 resets; the release is synchronised to the board clock
  always_ff @(posedge CLK100MHZ) rst_sync <= {rst_sync[2:0], ~btn[0]};

  z80_soc #(
      .CLK_HZ    (100_000_000),
      .CPU_DIV   (12),                  // 8.33 MHz Z80
      .BAUD      (115200),
      .ROM_BANKS (2),
      .RAM_BANKS (8),
      .ROM_INIT  ("boot.hex"),
      .UCODE_MEM ("z80_ucode.mem"),
      .DISP_MEM  ("z80_dispatch.mem")
  ) u_soc (
      .clk     (CLK100MHZ),
      .rst_n   (rst_sync[3]),
      .uart_rx (uart_txd_in),
      .uart_tx (uart_rxd_out),
      .led     (led8),
      .sw      ({4'd0, sw})
  );

  assign led = led8[3:0];

endmodule
