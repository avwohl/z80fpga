// The whole SoC driving the HDSK controller, with a real Z80 issuing the
// OTIR and IN that RomWBW's driver issues.
//
// tb_hdsk tests the controller in isolation and passes; the hardware does not
// write. The difference is everything this testbench adds and that one cannot:
// the MMU translating the DMA address into a bank, the memory actually behind
// that translation, and OTIR, which drives the decrementing B on the high half
// of the address bus while it runs.
//
// The program is sim/hdsk_test.z80. It writes a 512-byte pattern from 9000h to
// sector 0, reads it back to A000h, and prints the two status bytes, the first
// four bytes read back, and OK or BAD.

`timescale 1ns/1ps

module tb_hdsk_soc;

  localparam int CLK_HZ = 2_000_000;      // sim only
  localparam int BAUD   = 115200;
  localparam int DIV    = CLK_HZ / BAUD;

  logic clk = 0, rst_n = 0;
  always #250 clk = ~clk;                 // 2 MHz

  logic       uart_rx = 1, uart_tx;
  logic [7:0] led;
  logic       sd_sck, sd_mosi, sd_miso, sd_cs;

  logic [26:0]  awaddr, araddr;
  logic         awvalid, awready, wvalid, wready, bvalid, bready;
  logic         arvalid, arready, rvalid, rready;
  logic [127:0] wdata_axi, rdata_axi;
  logic [15:0]  wstrb;

  z80_soc #(
      .CLK_HZ    (CLK_HZ),
      .CPU_DIV   (1),
      .BAUD      (BAUD),
      .USE_HDSK  (1'b1),
      .USE_DDR2  (1'b1),
      .ROM_BANKS (1),
      .RAM_BANKS (2),
      .ROM_INIT  ("sim/hdsk_test.hex"),
      .UCODE_MEM ("rtl/core/z80_ucode.mem"),
      .DISP_MEM  ("rtl/core/z80_dispatch.mem")
  ) dut (
      .clk (clk), .rst_n (rst_n),
      .uart_rx (uart_rx), .uart_tx (uart_tx),
      .uart_cts_n (1'b0), .uart_rts_n (),
      .led (led), .sw (8'h00),
      .sd_sck (sd_sck), .sd_mosi (sd_mosi), .sd_miso (sd_miso), .sd_cs (sd_cs),
      .m_axi_awaddr (awaddr), .m_axi_awvalid (awvalid), .m_axi_awready (awready),
      .m_axi_wdata (wdata_axi), .m_axi_wstrb (wstrb),
      .m_axi_wvalid (wvalid), .m_axi_wready (wready),
      .m_axi_bvalid (bvalid), .m_axi_bready (bready),
      .m_axi_araddr (araddr), .m_axi_arvalid (arvalid), .m_axi_arready (arready),
      .m_axi_rdata (rdata_axi), .m_axi_rvalid (rvalid), .m_axi_rready (rready)
  );

  // --------------------------------------------------------- the DDR2 model
  logic [7:0] mem [0:262143];
  integer     mi;
  initial begin
    awready=0; wready=0; bvalid=0; arready=0; rvalid=0; rdata_axi=0;
    for (mi = 0; mi < 262144; mi = mi + 1) mem[mi] = 8'h00;
  end

  always begin
    @(posedge clk);
    if (awvalid) begin
      repeat (3) @(posedge clk); awready <= 1; @(posedge clk); awready <= 0;
      wait (wvalid); repeat (2) @(posedge clk); wready <= 1; @(posedge clk);
      for (mi = 0; mi < 16; mi = mi + 1)
        if (wstrb[mi]) mem[(awaddr & ~27'd15) + mi] = wdata_axi[8*mi +: 8];
      wready <= 0; repeat (2) @(posedge clk); bvalid <= 1;
      wait (bready); @(posedge clk); bvalid <= 0;
    end
  end

  always begin
    @(posedge clk);
    if (arvalid) begin
      repeat (4) @(posedge clk); arready <= 1; @(posedge clk); arready <= 0;
      repeat (4) @(posedge clk);
      for (mi = 0; mi < 16; mi = mi + 1)
        rdata_axi[8*mi +: 8] <= mem[(araddr & ~27'd15) + mi];
      rvalid <= 1; wait (rready); @(posedge clk); rvalid <= 0;
    end
  end

  // ------------------------------------------------------------- the card
  logic [7:0] card [0:2047];
  logic [7:0] shift_out = 8'hFF, shift_in;
  integer bitc = 0, cn = 0, resp_n = 0, resp_i = 0;
  logic [7:0] cbuf [0:5], resp [0:7];
  integer data_n = 0, data_i = 0, wr_expect = 0, wr_i = 0, busy_n = 0;
  logic [31:0] lba = 0;
  logic sending_data = 0, wr_active = 0;

  always @(posedge sd_sck) if (!sd_cs) begin
    shift_in = {shift_in[6:0], sd_mosi}; bitc = bitc + 1;
  end

  always @(negedge sd_sck) if (!sd_cs) begin
    if (bitc == 8) begin
      bitc = 0;
      if (wr_active) begin
        if (wr_expect == 0 && shift_in == 8'hFE) begin wr_expect = 512; wr_i = 0; end
        else if (wr_expect > 0) begin
          card[(lba*512 + wr_i) % 2048] = shift_in;
          wr_i = wr_i + 1; wr_expect = wr_expect - 1;
          if (wr_expect == 0) begin
            resp[0]=8'hFF; resp[1]=8'h05; resp_n=2; resp_i=0;
            busy_n = 4; wr_active = 0;
          end
        end
      end else if (cn > 0 || shift_in[7:6] == 2'b01) begin
        cbuf[cn] = shift_in; cn = cn + 1;
        if (cn == 6) begin
          cn = 0;
          case (cbuf[0][5:0])
            6'd0:  begin resp[0]=8'h01; resp_n=1; resp_i=0; end
            6'd8:  begin resp[0]=8'h01; resp[1]=8'h00; resp[2]=8'h00;
                         resp[3]=8'h01; resp[4]=8'hAA; resp_n=5; resp_i=0; end
            6'd55: begin resp[0]=8'h01; resp_n=1; resp_i=0; end
            6'd41: begin resp[0]=8'h00; resp_n=1; resp_i=0; end
            6'd58: begin resp[0]=8'h00; resp[1]=8'hC0; resp[2]=8'hFF;
                         resp[3]=8'h80; resp[4]=8'h00; resp_n=5; resp_i=0; end
            6'd17: begin resp[0]=8'h00; resp_n=1; resp_i=0; data_n=512; data_i=0;
                         lba={cbuf[1],cbuf[2],cbuf[3],cbuf[4]}; end
            6'd24: begin resp[0]=8'h00; resp_n=1; resp_i=0; wr_active=1; wr_expect=0;
                         lba={cbuf[1],cbuf[2],cbuf[3],cbuf[4]}; end
            default: begin resp[0]=8'h00; resp_n=1; resp_i=0; end
          endcase
        end
      end
      if (busy_n > 0)      begin shift_out = 8'h00; busy_n = busy_n - 1; end
      else if (resp_n > 0) begin
        shift_out = resp[resp_i]; resp_i = resp_i + 1; resp_n = resp_n - 1;
        if (resp_n == 0 && data_n > 0) sending_data = 1;
      end else if (sending_data) begin
        if (data_i == 0) begin shift_out = 8'hFE; data_i = 1; end
        else if (data_i <= 512) begin
          shift_out = card[(lba*512 + data_i - 1) % 2048]; data_i = data_i + 1;
        end else begin shift_out = 8'hFF; sending_data = 0; data_n = 0; end
      end else shift_out = 8'hFF;
    end
  end

  assign sd_miso = sd_cs ? 1'b1 : shift_out[7 - (bitc % 8)];

  // ------------------------------------------------------------- console
  integer nrx = 0;
  reg [7:0] ch;
  task automatic uart_get(output reg [7:0] c);
    integer k;
    begin
      @(negedge uart_tx);
      repeat (DIV + DIV/2) @(posedge clk);
      for (k = 0; k < 8; k = k + 1) begin c[k] = uart_tx; repeat (DIV) @(posedge clk); end
    end
  endtask

  initial forever begin
    uart_get(ch);
    nrx = nrx + 1;
    if (ch == 8'h0A) $write("\n");
    else if (ch >= 8'h20 && ch < 8'h7F) $write("%c", ch);
    $fflush;
  end

  // what LBA did the controller actually ask the card for?
  always @(posedge clk) if (dut.g_hdsk.u_sd.start_rd || dut.g_hdsk.u_sd.start_wr)
    $display("[sd] %s lba=%08h", dut.g_hdsk.u_sd.start_wr ? "WRITE" : "READ ",
             dut.g_hdsk.u_sd.lba);

  initial begin
    repeat (10) @(posedge clk);
    rst_n = 1;
    $display("--- console ---");
    fork
      begin
        repeat (40_000_000) @(posedge clk);
        $display("\nFAIL: timed out after %0d characters", nrx);
        $finish;
      end
      begin
        wait (nrx >= 20);                 // W..R.. + 8 hex + " OK"/" BAD" + CRLF
        repeat (DIV * 40) @(posedge clk);
        $display("\n---");
        $finish;
      end
    join
  end

endmodule
