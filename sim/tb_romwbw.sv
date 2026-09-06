// Boot a stock RomWBW ROM on the SoC and watch the console.
//
// This is the milestone test for the RomWBW work: the core, the MMU and the
// banked memory running real HBIOS rather than sw/boot.z80, far enough to
// reach the loader's boot prompt.
//
// The ROM image is not in this repository.  Build one from your own RomWBW
// checkout or emulator ROM set and convert the first 64 KB:
//
//   python tools/mkromhex.py .../SBC_simh_std.rom sim/romwbw64k.hex --size 65536
//
// 64 KB is HBIOS in bank 0 and the loader in bank 1, which is as far as this
// goes; the ROM disk in banks 2-15 is not here, so the loader's disk commands
// will find nothing.  That is the point of the milestone, not a fault.
//
// The console is RomWBW's SSER at 0x68/0x6D, so the SoC is built with
// CONSOLE_SSER = 1.  With the emulator's 0x00/0x01 ports instead this prints
// absolutely nothing, which is the whole reason the parameter exists.

`timescale 1ns/1ps

module tb_romwbw;

  localparam int CLK_HZ = 1_000_000;      // sim only: keeps the run short
  localparam int BAUD   = 115200;
  localparam int DIV    = CLK_HZ / BAUD;

  logic       clk = 0, rst_n = 0;
  logic       uart_rx = 1, uart_tx;
  logic [7:0] led;
  logic [7:0] sw = 8'h00;

  z80_soc #(
      .CLK_HZ       (CLK_HZ),
      .CPU_DIV      (1),
      .BAUD         (BAUD),
      .CONSOLE_SSER (1'b1),
      .ROM_BANKS    (2),                  // 64 KB: HBIOS + loader
      .RAM_BANKS    (16),                 // 512 KB, common bank 0x8F
      .ROM_INIT     ("sim/romwbw64k.hex"),
      .UCODE_MEM    ("rtl/core/z80_ucode.mem"),
      .DISP_MEM     ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n),
      .uart_rx (uart_rx), .uart_tx (uart_tx),
      .led (led), .sw (sw)
  );

  always #500 clk = ~clk;                 // 1 MHz

  // ------------------------------------------------------- console receiver
  integer      nrx = 0;
  reg [7:0]    ch;
  reg [8*32-1:0] tail = 0;                // rolling window, to spot the prompt
  reg          seen_prompt = 0;
  reg          seen_banner = 0;

  task automatic uart_get(output reg [7:0] c);
    integer i;
    begin
      @(negedge uart_tx);                         // start bit
      repeat (DIV + DIV/2) @(posedge clk);        // into the middle of bit 0
      for (i = 0; i < 8; i = i + 1) begin
        c[i] = uart_tx;
        repeat (DIV) @(posedge clk);
      end
    end
  endtask

  initial forever begin
    uart_get(ch);
    nrx = nrx + 1;
    if (ch == 8'h0A) $write("\n");
    else if (ch >= 8'h20 && ch < 8'h7F) $write("%c", ch);
    else if (ch != 8'h0D) $write("<%02h>", ch);
    $fflush;

    tail = {tail[8*31-1:0], ch};
    // "Boot [" is enough: the loader prints "Boot [H=Help]:"
    if (tail[8*6-1:0] == "Boot [") seen_prompt = 1;
    if (tail[8*6-1:0] == "RomWBW") seen_banner = 1;
  end

  // ------------------------------------------------------------------ drive
  initial begin
    repeat (10) @(posedge clk);
    rst_n = 1;
    $display("--- console ---");

    // HBIOS reaches the prompt around 8.6 M clocks in; allow half again.
    fork
      begin : watchdog
        repeat (13_000_000) @(posedge clk);
        $display("\n--- FAIL: no boot prompt after %0d characters", nrx);
        $finish;
      end
      begin : wait_prompt
        wait (seen_prompt);
        repeat (DIV * 40) @(posedge clk);       // let the line drain
        $display("\n---");
        $display("PASS: reached the RomWBW boot prompt after %0d characters", nrx);
        if (seen_banner) $display("      (HBIOS sign-on seen too)");
        $finish;
      end
    join
  end

endmodule
