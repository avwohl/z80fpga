// The HDSK controller and the SD block layer, against a behavioural card.
//
// This tests the parts that are cheap to get wrong and expensive to debug on
// hardware: the seven-byte command framing on port 0xFD, the DMA sequencing in
// and out of Z80 memory, the SPI command/response handshake, and that a sector
// written and read back survives the round trip.
//
// The card model is deliberately fussy in the ways a real card is - it answers
// R1 only after a delay, holds MISO high in between, and reports busy after a
// write - because those are exactly the behaviours the driver has to tolerate.

`timescale 1ns/1ps

module tb_hdsk;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;                    // 100 MHz

  // ------------------------------------------------------------- the card
  logic sck, mosi, miso, cs;

  logic [7:0] card [0:1023];               // two blocks is plenty
  logic [7:0] shift_out = 8'hFF;
  logic [7:0] shift_in;
  integer     bitc = 0;

  // command assembly
  logic [7:0] cbuf [0:5];
  integer     cn = 0;
  integer     resp_n = 0;                  // bytes of response still to send
  logic [7:0] resp [0:7];
  integer     resp_i = 0;
  integer     data_n = 0;                  // data block bytes to send
  integer     data_i = 0;
  logic       sending_data = 0;
  integer     wr_expect = 0;               // bytes of a write block still due
  integer     wr_i = 0;
  logic [31:0] wr_lba = 0;
  logic       wr_active = 0;
  integer     busy_n = 0;

  task automatic queue(input [7:0] b0, input int n);
    begin resp[0] = b0; resp_n = n; resp_i = 0; end
  endtask

  // SPI slave, mode 0: sample MOSI on rising, change MISO on falling
  always @(posedge sck) if (!cs) begin
    shift_in = {shift_in[6:0], mosi};
    bitc = bitc + 1;
  end

  always @(negedge sck) if (!cs) begin
    if (bitc == 8) begin
      bitc = 0;
      // a whole byte arrived in shift_in; decide what to say next
      if (wr_active) begin
        if (wr_expect == 0 && shift_in == 8'hFE) begin
          wr_expect = 512; wr_i = 0;
        end else if (wr_expect > 0) begin
          card[(wr_lba*512 + wr_i) % 1024] = shift_in;
          wr_i = wr_i + 1;
          wr_expect = wr_expect - 1;
          if (wr_expect == 0) begin
            resp[0] = 8'hFF; resp[1] = 8'h05; resp_n = 2; resp_i = 0;
            busy_n = 4; wr_active = 0;
          end
        end
      end else if (cn > 0 || shift_in[7:6] == 2'b01) begin
        cbuf[cn] = shift_in; cn = cn + 1;
        if (cn == 6) begin
          cn = 0;
          case (cbuf[0][5:0])
            6'd0:  queue(8'h01, 1);
            6'd8:  begin resp[0]=8'h01; resp[1]=8'h00; resp[2]=8'h00;
                         resp[3]=8'h01; resp[4]=8'hAA; resp_n=5; resp_i=0; end
            6'd55: queue(8'h01, 1);
            6'd41: queue(8'h00, 1);
            6'd58: begin resp[0]=8'h00; resp[1]=8'hC0; resp[2]=8'hFF;
                         resp[3]=8'h80; resp[4]=8'h00; resp_n=5; resp_i=0; end
            6'd17: begin
                     resp[0]=8'h00; resp_n=1; resp_i=0;
                     data_n = 512; data_i = 0;
                     wr_lba = {cbuf[1],cbuf[2],cbuf[3],cbuf[4]};
                   end
            6'd24: begin
                     resp[0]=8'h00; resp_n=1; resp_i=0;
                     wr_active = 1; wr_expect = 0;
                     wr_lba = {cbuf[1],cbuf[2],cbuf[3],cbuf[4]};
                   end
            default: queue(8'h00, 1);
          endcase
        end
      end

      // pick the byte to shift out next
      if (busy_n > 0) begin
        shift_out = 8'h00; busy_n = busy_n - 1;
      end else if (resp_n > 0) begin
        shift_out = resp[resp_i]; resp_i = resp_i + 1; resp_n = resp_n - 1;
        if (resp_n == 0 && data_n > 0) sending_data = 1;
      end else if (sending_data) begin
        if (data_i == 0) begin shift_out = 8'hFE; data_i = 1; end
        else if (data_i <= 512) begin
          shift_out = card[(wr_lba*512 + data_i - 1) % 1024];
          data_i = data_i + 1;
        end else begin
          shift_out = 8'hFF; sending_data = 0; data_n = 0;
        end
      end else begin
        shift_out = 8'hFF;
      end
    end
  end

  assign miso = cs ? 1'b1 : shift_out[7 - (bitc % 8)];

  // ------------------------------------------------------- the memory model
  logic [7:0] mem [0:65535];
  logic [7:0] dma_rdata;
  logic       dma_ack;
  logic        dma_req, dma_we;
  logic [15:0] dma_addr;
  logic [7:0]  dma_wdata;

  // answers in one clock, like block RAM
  logic dma_req_d;
  always_ff @(posedge clk) begin
    dma_req_d <= dma_req;
    if (dma_req && dma_we) mem[dma_addr] <= dma_wdata;
    dma_rdata <= mem[dma_addr];
  end
  assign dma_ack = dma_req && dma_req_d;

  // ------------------------------------------------------------ the modules
  logic [7:0] port_rdata, port_wdata;
  logic       port_wr, port_rd, port_hit, io_wait;
  logic [8:0] sdb_addr;
  logic [7:0] sdb_wdata, sdb_rdata;
  logic       sdb_we, sd_rd, sd_wr, sd_busy, sd_err, sd_rdy;
  logic [31:0] sd_lba;

  hdsk u_hdsk (
      .clk (clk), .rst_n (rst_n),
      .port_addr (8'hFD), .port_wdata (port_wdata),
      .port_wr (port_wr), .port_rd (port_rd),
      .port_rdata (port_rdata), .port_hit (port_hit), .io_wait (io_wait),
      .dma_req (dma_req), .dma_we (dma_we), .dma_addr (dma_addr),
      .dma_wdata (dma_wdata), .dma_rdata (dma_rdata), .dma_ack (dma_ack),
      .sd_start_rd (sd_rd), .sd_start_wr (sd_wr), .sd_lba (sd_lba),
      .sd_busy (sd_busy), .sd_err (sd_err), .sd_ready (sd_rdy),
      .sd_buf_addr (sdb_addr), .sd_buf_wdata (sdb_wdata),
      .sd_buf_we (sdb_we), .sd_buf_rdata (sdb_rdata)
  );

  sd_spi #(.CLK_HZ (100_000_000), .INIT_HZ (2_000_000), .FAST_HZ (12_500_000)) u_sd (
      .clk (clk), .rst_n (rst_n),
      .start_rd (sd_rd), .start_wr (sd_wr), .lba (sd_lba),
      .busy (sd_busy), .err (sd_err), .ready (sd_rdy),
      .buf_addr (sdb_addr), .buf_wdata (sdb_wdata), .buf_we (sdb_we),
      .buf_rdata (sdb_rdata),
      .sd_sck (sck), .sd_mosi (mosi), .sd_miso (miso), .sd_cs (cs)
  );

  // ------------------------------------------------------------- the script
  // Stimulus is driven on the falling edge.  Driving it at the same instant as
  // the rising edge races with the DUT's always_ff: whether the strobe is seen
  // once or twice depends on scheduling order, and seeing it twice makes the
  // controller eat an extra byte and then treat the next one as a fresh
  // command -- which clears pending and looks exactly like the read never
  // arriving.
  task automatic out_fd(input [7:0] b);
    begin
      @(negedge clk); port_wdata = b; port_wr = 1;
      @(negedge clk); port_wr = 0;
    end
  endtask

  task automatic in_fd(output [7:0] b);
    begin
      @(negedge clk); port_rd = 1;
      // hold the read while the controller stalls, as the core would
      wait (io_wait == 1);
      wait (io_wait == 0);
      @(negedge clk); b = port_rdata; port_rd = 0;
    end
  endtask

  integer i, errors;
  logic [7:0] st;

  initial begin
    port_wr = 0; port_rd = 0; port_wdata = 0; errors = 0;
    for (i = 0; i < 1024; i = i + 1) card[i] = 8'h00;
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    // a recognisable pattern to write out
    for (i = 0; i < 512; i = i + 1) mem[16'h9000 + i] = i[7:0] ^ 8'h5A;

    repeat (10) @(posedge clk);
    rst_n = 1;

    $display("waiting for the card to initialise...");
    wait (sd_rdy == 1);
    $display("card ready");

    // ---- write sector 0 from 0x9000
    out_fd(8'd3);              // write
    out_fd(8'd0);              // unit 0
    out_fd(8'd0);              // sector
    out_fd(8'd0);              // track lo
    out_fd(8'd0);              // track hi
    out_fd(8'h00);             // dma lo
    out_fd(8'h90);             // dma hi
    in_fd(st);
    $display("write status = %02h", st);
    if (st != 8'h00) begin $display("FAIL: write status"); errors = errors + 1; end

    // ---- read it back to 0xA000
    out_fd(8'd2);              // read
    out_fd(8'd0);
    out_fd(8'd0);
    out_fd(8'd0);
    out_fd(8'd0);
    out_fd(8'h00);
    out_fd(8'hA0);
    in_fd(st);
    $display("read status = %02h", st);
    if (st != 8'h00) begin $display("FAIL: read status"); errors = errors + 1; end

    for (i = 0; i < 512; i = i + 1)
      if (mem[16'hA000 + i] !== mem[16'h9000 + i]) begin
        if (errors < 8)
          $display("FAIL: byte %0d wrote %02h read %02h",
                   i, mem[16'h9000 + i], mem[16'hA000 + i]);
        errors = errors + 1;
      end

    if (errors == 0) $display("PASS: 512 bytes through port 0xFD and the card, round trip");
    else             $display("FAIL: %0d errors", errors);
    $finish;
  end

  initial begin
    #200_000_000;
    $display("FAIL: timed out");
    $finish;
  end

endmodule
