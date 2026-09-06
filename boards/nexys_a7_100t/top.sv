// Digilent Nexys A7-100T top level.
//
// The same XC7A100T-CSG324 as the Arty A7-100T, and the same 100 MHz clock on
// E3 -- which is exactly why an Arty bitstream loads here, asserts DONE and
// then says nothing at all.  Every other pin differs.  The console is on C4
// and D4 rather than A9 and D10, and the LEDs are H17/K15/J13/N14 rather than
// H5/J5/T9/T10, where the Arty's LED pins land on this board's seven-segment
// display instead.
//
// Reset is CPU_RESETN, the dedicated active-low button, not one of btn[].

module top (
    input  logic       CLK100MHZ,
    input  logic       CPU_RESETN,      // active low
    input  logic [3:0] sw,
    output logic [3:0] led,
    input  logic       uart_txd_in,     // host -> FPGA
    output logic       uart_rxd_out     // FPGA -> host
);

  logic [7:0] led8;
  logic [3:0] rst_sync;

  // CPU_RESETN is already the polarity the SoC wants; synchronise the release
  always_ff @(posedge CLK100MHZ) rst_sync <= {rst_sync[2:0], CPU_RESETN};

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
      .uart_cts_n (1'b0),               // no flow control on this build
      .uart_rts_n (),
      .led     (led8),
      .sw      ({4'd0, sw})
  );

  assign led = led8[3:0];

endmodule
