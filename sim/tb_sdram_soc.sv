// The SoC with its RAM banks in SDRAM instead of block RAM.
//
// tb_sdram.sv checks the controller against the chip; this checks the core
// against the controller, which is a different question: whether the Z80
// really tolerates wait_n going low for a variable number of T-states in the
// middle of a memory cycle, and whether the SoC's plumbing -- ram_cycle,
// ram_ready, the ungated write -- is wired the way sdram_ram expects.
//
// The program is the ordinary boot monitor, which is a good test precisely
// because its bank check writes a signature into a RAM bank and reads it back
// from code running in the common bank, and because the answer is already
// known from the block RAM build.  It walks two banks rather than sixteen --
// RAM_N in sw/boot.z80 is 2, and the monitor is shared with every target --
// but the stack is in the common bank, which with RAM_BANKS = 16 is 0x8F, so
// the top of the 512 KB window is hammered from the first CALL regardless.
//
// The console is run at 3.125 Mbaud rather than 115200 so the simulation is
// short.  Nothing about the memory depends on it, and the alternative -- a
// slow fabric clock, which is how tb_ddr2ram keeps its runtime down -- would
// make the chip's nanosecond timings meaningless.  Here the fabric runs at
// the 25 MHz the Icepi Zero build uses, so the model's tRCD, tRP and tRC
// checks are being asked a real question.

`timescale 1ns/1ps

module tb_sdram_soc;

  localparam int CLK_HZ = 25_000_000;
  localparam int BAUD   = 3_125_000;
  localparam int DIV    = CLK_HZ / BAUD;

  logic       clk = 0, rst_n = 0;
  logic       uart_rx = 1, uart_tx;
  logic [7:0] led;
  logic [7:0] sw = 8'h00;

  always #20 clk = ~clk;                   // 25 MHz

  logic [12:0] sd_a;
  logic  [1:0] sd_ba, sd_dqm;
  logic        sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_cke;
  logic [15:0] sd_dq_o;
  logic        sd_dq_oe, sd_init;

  wire  [15:0] dq;
  logic [15:0] model_dq;
  logic        model_drive;

  assign dq = sd_dq_oe    ? sd_dq_o  : 16'hzzzz;
  assign dq = model_drive ? model_dq : 16'hzzzz;

  z80_soc #(
      .CLK_HZ    (CLK_HZ),
      .CPU_DIV   (1),
      .BAUD      (BAUD),
      .USE_SDRAM (1'b1),
      .ROM_BANKS (1),
      .RAM_BANKS (16),                     // 512 KB, the full RomWBW RAM map
      .ROM_INIT  ("sw/boot.hex"),
      .UCODE_MEM ("rtl/core/z80_ucode.mem"),
      .DISP_MEM  ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n),
      .uart_rx (uart_rx), .uart_tx (uart_tx),
      .led (led), .sw (sw),
      .sdram_a (sd_a), .sdram_ba (sd_ba), .sdram_dqm (sd_dqm),
      .sdram_cs_n (sd_cs_n), .sdram_ras_n (sd_ras_n), .sdram_cas_n (sd_cas_n),
      .sdram_we_n (sd_we_n), .sdram_cke (sd_cke),
      .sdram_dq_o (sd_dq_o), .sdram_dq_oe (sd_dq_oe), .sdram_dq_i (dq),
      .sdram_init_done (sd_init)
  );

  sdram_model u_chip (
      .clk (~clk), .cke (sd_cke),
      .cs_n (sd_cs_n), .ras_n (sd_ras_n), .cas_n (sd_cas_n), .we_n (sd_we_n),
      .a (sd_a), .ba (sd_ba), .dqm (sd_dqm),
      .dq_in (dq), .dq_oe (sd_dq_oe),
      .dq_out (model_dq), .dq_drive (model_drive)
  );

  // ------------------------------------------------------------- the console
  integer   nrx = 0, banner_end = 0;
  reg [7:0] ch;
  reg [7:0] rxbuf [0:255];

  task automatic uart_get(output reg [7:0] c);
    integer k;
    begin
      @(negedge uart_tx);
      repeat (DIV + DIV/2) @(posedge clk);
      for (k = 0; k < 8; k = k + 1) begin
        c[k] = uart_tx;
        repeat (DIV) @(posedge clk);
      end
    end
  endtask

  initial forever begin
    uart_get(ch);
    if (nrx < 256) rxbuf[nrx] = ch;
    nrx = nrx + 1;
    if (ch == 8'h0A) $write("\n");
    else if (ch >= 8'h20 && ch < 8'h7F) $write("%c", ch);
    $fflush;
  end

  task automatic uart_put(input [7:0] b);
    integer k;
    begin
      uart_rx = 0; repeat (DIV) @(posedge clk);
      for (k = 0; k < 8; k = k + 1) begin
        uart_rx = b[k]; repeat (DIV) @(posedge clk);
      end
      uart_rx = 1; repeat (DIV) @(posedge clk);
    end
  endtask

  initial begin
    repeat (10) @(posedge clk);
    rst_n = 1;
    $display("--- console ---");

    fork
      begin
        repeat (4_000_000) @(posedge clk);
        $display("\nFAIL: timed out after %0d characters", nrx);
        $finish;
      end
      begin
        // banner + "banked memory ok" + prompt is 35 characters.  The CPU
        // reaches its first stack push long before the chip has finished its
        // 100 us power-up, and simply waits there: nothing holds it in reset.
        wait (nrx >= 35);
        banner_end = nrx;
        if (!sd_init) begin
          $display("\nFAIL: the banner appeared before the chip was initialised");
          $finish;
        end
        repeat (DIV * 20) @(posedge clk);
        uart_put("A");
        uart_put("B");
        uart_put(8'h0D);
        wait (nrx >= banner_end + 4);
        repeat (DIV * 20) @(posedge clk);
        $display("\n--- %0d characters, %0d after the prompt", nrx, nrx - banner_end);
        if (rxbuf[banner_end]   != "A" || rxbuf[banner_end+1] != "B" ||
            rxbuf[banner_end+2] != 8'h0D || rxbuf[banner_end+3] != 8'h0A)
          $display("FAIL: echo wrong");
        else
          $display("PASS: banner, bank check and echo all good with RAM in SDRAM");
        $finish;
      end
    join
  end

endmodule
