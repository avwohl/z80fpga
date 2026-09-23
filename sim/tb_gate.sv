`timescale 1ns/1ps
// Console bench for a SYNTHESISED netlist, not the RTL.
//
// It instantiates `top` -- the board's own top level, as yosys flattened it --
// so the only stimulus is the board clock, and everything else (reset counter,
// block RAM contents, the LED port) comes from the netlist itself.  Build it
// with the netlist, sim/gowin_sp.v and the suite's cells_sim.v with its SP and
// SPX9 blackboxes removed; `make gatesim` in a board directory does all of it.
//
// What it prints is what the bitstream's logic would put on the UART pin.
module tb_gate;
  logic clk = 0;
  wire [5:0] led;
  wire uart_tx;

  // 27 MHz.  A board with a different clock wants a different half period.
  always #18.5 clk = ~clk;

  top dut (.clk(clk), .led(led), .uart_tx(uart_tx), .uart_rx(1'b1));

  // The three low LED-port bits, as boards wire them to the three rightmost
  // LEDs: sw/ledchk.z80 reports its progress here when the console is dead.
  wire [2:0] stage = ~led[2:0];
  logic [2:0] prev = 3'bxxx;
  always @(posedge clk)
    if (stage !== prev) begin
      $display("[led stage %0d @ %0t ps]", stage, $time);
      prev = stage;
    end

  localparam real BIT_NS = 1000000000.0/115200.0;
  integer nch = 0;
  initial begin : rx
    logic [7:0] ch;
    int i;
    forever begin
      @(negedge uart_tx);
      #(BIT_NS*1.5);
      for (i = 0; i < 8; i++) begin ch[i] = uart_tx; #(BIT_NS); end
      $write("%c", ch);
      $fflush;
      nch++;
    end
  end

  integer run_ns;
  initial begin
    if (!$value$plusargs("run_ns=%d", run_ns)) run_ns = 7000000;   // 7 ms
    #(run_ns);
    $display("\n--- %0d characters off the pin, final led stage %0d", nch, ~led[2:0]);
    $finish;
  end
endmodule
