// A console beacon with no Z80 in it: a counter writes 0x55 to the UART's
// data port about 103 times a second.  It isolates pin 69, the BL616 bridge,
// the host's COM port and rtl/soc/uart.sv from everything else, so a capture
// either proves the channel alive or convicts it.
module top (
    input  logic       clk,
    output logic [5:0] led,
    output logic       uart_tx,
    input  logic       uart_rx
);

  logic [7:0] rstcnt = 8'h00;
  logic       rst_n;
  always_ff @(posedge clk) if (!rstcnt[7]) rstcnt <= rstcnt + 8'd1;
  assign rst_n = rstcnt[7];

  logic [23:0] cnt = 24'd0;
  always_ff @(posedge clk) cnt <= cnt + 24'd1;

  // one write per 2^18 clocks: 27e6 / 262144 = 103 bytes a second
  logic tick_q;
  logic wr;
  always_ff @(posedge clk) begin
    tick_q <= cnt[18];
    wr     <= (cnt[18] & ~tick_q);
  end

  uart #(.CLK_HZ (27_000_000), .BAUD (115200)) u_uart (
      .clk        (clk),
      .rst_n      (rst_n),
      .port_addr  (8'h01),
      .port_wdata (8'h55),
      .port_wr    (wr),
      .port_rd    (1'b0),
      .port_rdata (),
      .port_hit   (),
      .rx         (uart_rx),
      .tx         (uart_tx),
      .cts_n      (1'b0),
      .rts_n      ()
  );

  assign led = {cnt[23], ~rst_n, ~uart_tx, 3'b111};
endmodule
