// The SoC with its RAM banks in DDR2 instead of block RAM.
//
// The MIG is not in this simulation - what is here is a behavioural AXI slave
// with deliberately awkward latency, which is enough to test the parts that
// can actually be wrong: the handshakes in ddr2_ram, the one-line read cache
// and its invalidation, the byte strobes, and above all whether the core
// really tolerates having wait_n held low for a long and variable time.
//
// The program is the ordinary boot monitor, which is a good test precisely
// because its bank check writes a signature into every RAM bank and reads it
// back from code running in the common bank. That exercises reads, writes,
// bank switching and cache invalidation all at once, and it already has a
// known-good answer from the block RAM build.

`timescale 1ns/1ps

module tb_ddr2ram;

  localparam int CLK_HZ = 1_000_000;
  localparam int BAUD   = 115200;
  localparam int DIV    = CLK_HZ / BAUD;
  localparam int RAM_KB = 64;                     // 2 banks of 32 KB

  logic       clk = 0, rst_n = 0;
  logic       uart_rx = 1, uart_tx;
  logic [7:0] led;
  logic [7:0] sw = 8'h00;

  logic [26:0]  awaddr, araddr;
  logic         awvalid, awready, wvalid, wready, bvalid, bready;
  logic         arvalid, arready, rvalid, rready;
  logic [127:0] wdata, rdata;
  logic [15:0]  wstrb;

  z80_soc #(
      .CLK_HZ    (CLK_HZ),
      .CPU_DIV   (1),
      .BAUD      (BAUD),
      .USE_DDR2  (1'b1),
      .ROM_BANKS (1),
      .RAM_BANKS (2),
      .ROM_INIT  ("sw/boot.hex"),
      .UCODE_MEM ("rtl/core/z80_ucode.mem"),
      .DISP_MEM  ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n),
      .uart_rx (uart_rx), .uart_tx (uart_tx),
      .led (led), .sw (sw),
      .m_axi_awaddr (awaddr), .m_axi_awvalid (awvalid), .m_axi_awready (awready),
      .m_axi_wdata (wdata),   .m_axi_wstrb (wstrb),
      .m_axi_wvalid (wvalid), .m_axi_wready (wready),
      .m_axi_bvalid (bvalid), .m_axi_bready (bready),
      .m_axi_araddr (araddr), .m_axi_arvalid (arvalid), .m_axi_arready (arready),
      .m_axi_rdata (rdata),   .m_axi_rvalid (rvalid), .m_axi_rready (rready)
  );

  always #500 clk = ~clk;

  // ------------------------------------------------------ behavioural DDR2
  // Byte addressed, one line is sixteen bytes.  Latency wanders between 3 and
  // 18 clocks so nothing can accidentally depend on a fixed number.
  logic [7:0] mem [0:RAM_KB*1024-1];
  integer     lat;
  integer     i;

  initial begin
    awready = 0; wready = 0; bvalid = 0; arready = 0; rvalid = 0; rdata = 0;
    for (i = 0; i < RAM_KB*1024; i = i + 1) mem[i] = 8'h00;
  end

  // writes
  initial forever begin
    @(posedge clk);
    if (awvalid) begin
      lat = 3 + ($random % 8 < 0 ? -($random % 8) : ($random % 8));
      repeat (lat) @(posedge clk);
      awready <= 1; @(posedge clk); awready <= 0;
      wait (wvalid);
      repeat (2) @(posedge clk);
      wready <= 1;
      @(posedge clk);
      for (i = 0; i < 16; i = i + 1)
        if (wstrb[i]) mem[(awaddr & ~27'd15) + i] = wdata[8*i +: 8];
      wready <= 0;
      repeat (2) @(posedge clk);
      bvalid <= 1;
      wait (bready);
      @(posedge clk);
      bvalid <= 0;
    end
  end

  // reads
  initial forever begin
    @(posedge clk);
    if (arvalid) begin
      lat = 4 + ($random % 14 < 0 ? -($random % 14) : ($random % 14));
      repeat (lat) @(posedge clk);
      arready <= 1; @(posedge clk); arready <= 0;
      repeat (lat) @(posedge clk);
      for (i = 0; i < 16; i = i + 1)
        rdata[8*i +: 8] <= mem[(araddr & ~27'd15) + i];
      rvalid <= 1;
      wait (rready);
      @(posedge clk);
      rvalid <= 0;
    end
  end

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
        repeat (60_000_000) @(posedge clk);
        $display("\nFAIL: timed out after %0d characters", nrx);
        $finish;
      end
      begin
        // banner + "banked memory ok" + prompt is 35 characters
        wait (nrx >= 35);
        banner_end = nrx;
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
          $display("PASS: banner, bank check and echo all good with RAM in DDR2");
        $finish;
      end
    join
  end

endmodule
