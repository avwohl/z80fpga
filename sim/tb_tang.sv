// The Tang Nano 20K's SoC parameters exactly, running sw/diag.z80: does a
// bare probe copied to C000h execute?  The board says no while a data read
// of the same address returns the copied byte; this asks whether the RTL
// does the same thing, or whether the fault is below it.
`timescale 1ns/1ps

module tb_tang;
  logic clk = 0, rst_n = 0;
  logic [7:0] led;
  logic uart_tx;

  z80_soc #(
      .CLK_HZ    (27_000_000),
      .CPU_DIV   (1),
      .BAUD      (115200),
      .ROM_BANKS (1),
      .ROM_AW_P  (13),
      .RAM_BANKS (2),
      .ROM_INIT  ("sw/diagsim.hex"),
      .UCODE_MEM ("rtl/core/z80_ucode.mem"),
      .DISP_MEM  ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n),
      .uart_rx (1'b1), .uart_tx (uart_tx),
      .uart_cts_n (1'b0), .uart_rts_n (),
      .led (led), .sw (8'h00)
  );

  always #18 clk = ~clk;                       // ~27 MHz

  // every write to the LED port, which is how the board reports
  always @(posedge clk)
    if (!dut.iorq_n && dut.m1_n && !dut.wr_n && dut.a[7:0] == 8'hFF)
      $display("[%0t] LED <- %02h", $time, dut.dout);

  // every M1 fetch from the common bank, with what the mux handed the core
  integer trace;
  initial if (!$value$plusargs("trace=%d", trace)) trace = 0;
  always @(posedge clk)
    if (trace && !dut.m1_n && !dut.mreq_n && !dut.rd_n && dut.a >= 16'hBFF0 && dut.a < 16'hC010)
      $display("[%0t] M1 a=%04h sel_rom=%b bank_valid=%b rom=%02h ram=%02h din=%02h",
               $time, dut.a, dut.sel_rom, dut.bank_valid,
               dut.rom_rdata, dut.ram_rdata, dut.din);

  initial begin
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (2_000_000) @(posedge clk);
    $display("-- timeout");
    $finish;
  end
endmodule
