// rtl/mem/sdram_ram.sv against the behavioural chip in sdram_model.sv.
//
// This is the unit test: no Z80, just the req/ready contract driven directly,
// so a failure says which part of the controller is wrong rather than "the
// monitor did not print".  What it is really looking for is the two things
// that are easy to get wrong and invisible on a bench -- whether the byte
// that comes back is the byte that was asked for once the address has moved
// across a column, a bank and a row boundary, and whether the read is latched
// on the right clock.  The model refuses anything illegal on its own, so the
// power-up sequence, tRCD, tRP, tRC and the refresh interval are checked
// whether this file mentions them or not.
//
// The chip's clock is the inverted fabric clock, which is what the board top
// sends out through an ODDR.  Modelling that here rather than clocking the
// model off the same edge is the whole point of the read-latency arithmetic
// in sdram_ram.sv: get it wrong by one and this test fails.

`timescale 1ns/1ps

// CLK_HZ is a parameter rather than a localparam so the whole thing can be
// re-run at another fabric clock without editing it -- the controller derives
// its cycle counts from it, and rounding them the wrong way is exactly the
// sort of thing that only shows up at a frequency nobody tried:
//
//   iverilog -g2012 -Ptb_sdram.CLK_HZ=100000000 -o t.vvp
//            sim/tb_sdram.sv sim/sdram_model.sv rtl/mem/sdram_ram.sv
//
// It passes at 25, 50 and 100 MHz.
module tb_sdram #(
    parameter int CLK_HZ = 25_000_000
);

  localparam int AW     = 19;              // 512 KB, the RomWBW RAM window
  localparam int HALF   = 500_000_000 / CLK_HZ;   // half a period, in ns

  logic clk = 0, rst_n = 0;

  always #(HALF) clk = ~clk;

  logic          req = 0, we = 0;
  logic [AW-1:0] addr = 0;
  logic  [7:0]   wdata = 0, rdata;
  logic          ready, init_done;

  logic [12:0] sd_a;
  logic  [1:0] sd_ba, sd_dqm;
  logic        sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_cke;
  logic [15:0] sd_dq_o;
  logic        sd_dq_oe;

  wire  [15:0] dq;
  logic [15:0] model_dq;
  logic        model_drive;

  assign dq = sd_dq_oe    ? sd_dq_o  : 16'hzzzz;
  assign dq = model_drive ? model_dq : 16'hzzzz;

  sdram_ram #(.CLK_HZ (CLK_HZ), .AW (AW)) dut (
      .clk (clk), .rst_n (rst_n),
      .req (req), .we (we), .addr (addr), .wdata (wdata),
      .rdata (rdata), .ready (ready), .init_done (init_done),
      .sd_a (sd_a), .sd_ba (sd_ba), .sd_dqm (sd_dqm),
      .sd_cs_n (sd_cs_n), .sd_ras_n (sd_ras_n), .sd_cas_n (sd_cas_n),
      .sd_we_n (sd_we_n), .sd_cke (sd_cke),
      .sd_dq_o (sd_dq_o), .sd_dq_oe (sd_dq_oe), .sd_dq_i (dq)
  );

  sdram_model u_chip (
      .clk (~clk), .cke (sd_cke),
      .cs_n (sd_cs_n), .ras_n (sd_ras_n), .cas_n (sd_cas_n), .we_n (sd_we_n),
      .a (sd_a), .ba (sd_ba), .dqm (sd_dqm),
      .dq_in (dq), .dq_oe (sd_dq_oe),
      .dq_out (model_dq), .dq_drive (model_drive)
  );

  // ------------------------------------------------------------- the driver
  // One bus cycle, shaped the way z80_soc shapes it: req goes up and stays up
  // until ready has been seen, then drops.  Stimulus changes on the falling
  // edge so the controller samples something settled, and the next cycle does
  // not start until ready has gone away again -- the controller holds it high
  // until req drops, and a driver that took the leftover for its own answer
  // would read the previous byte and never notice.
  int fails = 0;

  int last_lat;

  task automatic bus(input logic wr, input logic [AW-1:0] ad,
                     input logic [7:0] d, output logic [7:0] q);
    begin
      @(negedge clk);
      addr = ad; wdata = d; we = wr; req = 1'b1;
      last_lat = 0;
      @(posedge clk);
      while (!ready) begin
        last_lat = last_lat + 1;
        @(posedge clk);
      end
      q = rdata;
      @(negedge clk);
      req = 1'b0; we = 1'b0;
      @(posedge clk);
      while (ready) @(posedge clk);
    end
  endtask

  task automatic wr(input logic [AW-1:0] ad, input logic [7:0] d);
    logic [7:0] junk;
    begin bus(1'b1, ad, d, junk); end
  endtask

  task automatic rd_chk(input logic [AW-1:0] ad, input logic [7:0] want);
    logic [7:0] got;
    begin
      bus(1'b0, ad, 8'h00, got);
      if (got !== want) begin
        $display("FAIL: %05h read %02h, wanted %02h", ad, got, want);
        fails = fails + 1;
      end
    end
  endtask

  // Addresses chosen to move every field of the decode independently: the two
  // halves of a word, adjacent columns, a column carry, both bank bits, and
  // rows near the top of the 512 KB window.
  localparam int N = 12;
  logic [AW-1:0] probe [0:N-1];
  logic  [7:0]   value [0:N-1];

  integer i;

  initial begin
    probe[0]  = 19'h00000; probe[1]  = 19'h00001;   // both bytes of word 0
    probe[2]  = 19'h00002; probe[3]  = 19'h003FE;   // next word, last column
    probe[4]  = 19'h00400; probe[5]  = 19'h00401;   // column carry into bank 1
    probe[6]  = 19'h00800; probe[7]  = 19'h00C00;   // banks 2 and 3
    probe[8]  = 19'h01000; probe[9]  = 19'h3FFFE;   // row 1, and the last word
    probe[10] = 19'h3FFFF; probe[11] = 19'h2AAAA;   // and a walking pattern
    for (i = 0; i < N; i++) value[i] = 8'hA0 + 8'(i);
  end

  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1;

    wait (init_done);
    $display("chip initialised at %0t", $time);

    // Write every probe, then read them all back afterwards rather than one
    // at a time: a controller that answered out of a stale latch instead of
    // the chip would pass a write-then-read pair and fail this.
    for (i = 0; i < N; i++) wr(probe[i], value[i]);
    for (i = 0; i < N; i++) rd_chk(probe[i], value[i]);

    // The other half of each word must not have been disturbed by the byte
    // write: 00000 and 00001 share a word, and so do 3FFFE and 3FFFF.
    rd_chk(19'h00000, value[0]);
    rd_chk(19'h00001, value[1]);

    // Sit idle for well over a refresh interval, then read again.  The model
    // stops the simulation if the refresh never came; this proves the data
    // survived it, and that an idle controller comes back to service a
    // request afterwards.
    repeat (600) @(posedge clk);
    for (i = 0; i < N; i++) rd_chk(probe[i], value[i]);

    // How long the core is actually held.  Printed rather than asserted: it is
    // a cost, not a contract, and it is the number the board README quotes.
    wr(19'h00010, 8'h5A);
    $display("write takes %0d clocks from req to ready", last_lat);
    rd_chk(19'h00010, 8'h5A);
    $display("read  takes %0d clocks from req to ready", last_lat);

    if (fails == 0)
      $display("PASS: %0d bytes through the SDRAM controller, across banks and rows", N);
    else
      $display("FAIL: %0d reads came back wrong", fails);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FAIL: timed out");
    $finish;
  end

endmodule
