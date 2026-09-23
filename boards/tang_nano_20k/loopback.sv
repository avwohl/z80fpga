// The whole design: the console's receive pin wired to its transmit pin.
// If bytes sent from the host come back, the link is alive in both
// directions and nothing about the FPGA's logic is involved.
module top (
    input  logic       clk,
    output logic [5:0] led,
    output logic       uart_tx,
    input  logic       uart_rx
);
  logic [23:0] hb = 24'd0;
  always_ff @(posedge clk) hb <= hb + 24'd1;
  assign uart_tx = uart_rx;
  assign led = {hb[23], ~uart_rx, ~uart_tx, 3'b111};
endmodule
