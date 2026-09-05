// SoC test bench: boots sw/boot.z80 out of ROM bank 0, watches the serial
// line, and types at it.
//
// The clock is deliberately slow (1 MHz) so a 115200-baud bit is 8 clocks and
// a whole character costs under a hundred cycles of simulation.  The UART is
// exercised for real - the bench decodes uart_tx and drives uart_rx - so this
// covers the serialiser as well as the CPU and the bank switching.

`timescale 1ns/1ps

module tb_soc;

  localparam int CLK_HZ = 1_000_000;
  localparam int BAUD   = 115200;
  localparam int DIV    = CLK_HZ / BAUD;      // clocks per bit

  logic clk = 0;
  logic rst_n = 0;
  logic uart_rx = 1;
  logic uart_tx;
  logic [7:0] led;
  logic [7:0] sw = 8'h00;

  z80_soc #(
      .CLK_HZ    (CLK_HZ),
      .CPU_DIV   (1),
      .BAUD      (BAUD),
      .ROM_BANKS (1),
      .RAM_BANKS (2),
      .ROM_INIT  ("sw/boot.hex"),
      .UCODE_MEM ("rtl/core/z80_ucode.mem"),
      .DISP_MEM  ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n),
      .uart_rx (uart_rx), .uart_tx (uart_tx),
      .led (led), .sw (sw)
  );

  always #500 clk = ~clk;                      // 1 MHz

  // +trace_io logs the CPU's console port traffic, which is how you tell a
  // byte lost in the UART from one the program never read
  integer trace_io;
  initial if (!$value$plusargs("trace_io=%d", trace_io)) trace_io = 0;

  always @(posedge clk) begin
    if (trace_io && !dut.iorq_n && dut.m1_n && dut.a[7:0] == 8'h01) begin
      if (!dut.wr_n) $display("[%0t] out 01 <- %02h", $time, dut.dout);
      if (!dut.rd_n) $display("[%0t] in  01 -> %02h", $time, dut.din);
    end
  end

  // ---------------------------------------------------------------- receive
  integer nrx = 0;
  reg [7:0] rxbuf [0:255];

  task automatic uart_get(output reg [7:0] ch);
    integer i;
    begin
      @(negedge uart_tx);
      repeat (DIV + DIV / 2) @(posedge clk);   // into the middle of bit 0
      for (i = 0; i < 8; i = i + 1) begin
        ch[i] = uart_tx;
        repeat (DIV) @(posedge clk);
      end
    end
  endtask

  reg [7:0] ch;
  initial begin
    forever begin
      uart_get(ch);
      if (nrx < 256) rxbuf[nrx] = ch;
      nrx = nrx + 1;
      $write("%c", ch);
      $fflush();
    end
  end

  // ----------------------------------------------------------------- send
  task automatic uart_put(input [7:0] b);
    integer i;
    begin
      uart_rx = 0;
      repeat (DIV) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        uart_rx = b[i];
        repeat (DIV) @(posedge clk);
      end
      uart_rx = 1;
      repeat (DIV * 2) @(posedge clk);
    end
  endtask

  // ---------------------------------------------------------------- driver
  integer i;
  integer banner_end;
  initial begin
    repeat (10) @(posedge clk);
    rst_n = 1;

    // let the banner, the bank check and the prompt come out
    wait (nrx >= 35);
    banner_end = nrx;

    uart_put("A");
    uart_put("B");
    uart_put(8'h0D);
    repeat (DIV * 200) @(posedge clk);

    $display("");
    $display("--- %0d characters received, %0d after the prompt ---",
             nrx, nrx - banner_end);
    for (i = banner_end; i < nrx; i = i + 1)
      $display("  echoed[%0d] = %02h", i - banner_end, rxbuf[i]);
    if (nrx - banner_end != 4)
      $display("FAIL: expected A B CR LF echoed back, got %0d bytes",
               nrx - banner_end);
    else if (rxbuf[banner_end]   != "A" || rxbuf[banner_end+1] != "B" ||
             rxbuf[banner_end+2] != 8'h0D || rxbuf[banner_end+3] != 8'h0A)
      $display("FAIL: echo mismatch");
    else
      $display("PASS: banner, bank check and echo all good");
    $finish;
  end

  initial begin
    #40_000_000;
    $display("");
    $display("FAIL: timed out after %0d characters", nrx);
    $finish;
  end

endmodule
