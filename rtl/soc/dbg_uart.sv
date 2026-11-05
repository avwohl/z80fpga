// A bare 8N1 UART for the debug unit: no FIFO, no ports, no flow control.
//
// The debug protocol is half duplex and the unit finishes a command before the
// host sends the next, so one byte of receive buffering is enough: rx_valid
// pulses for one clock when a byte is in rx_data, and the unit takes it then.
// tx_start is honoured only while tx_busy is low.

`ifndef DBG_UART_SV
`define DBG_UART_SV

module dbg_uart #(
    parameter int CLK_HZ = 50_000_000,
    parameter int BAUD   = 115200
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       rx,
    output logic       tx,

    output logic       rx_valid,
    output logic [7:0] rx_data,

    input  logic       tx_start,
    input  logic [7:0] tx_data,
    output logic       tx_busy
);

  localparam int DIV = CLK_HZ / BAUD;
  localparam int DW  = $clog2(DIV) + 1;

  // ------------------------------------------------------------ transmitter
  logic [DW-1:0] tx_div;
  logic    [3:0] tx_bit;
  logic    [9:0] tx_sr;

  assign tx = tx_sr[0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tx_sr   <= 10'h3FF;
      tx_busy <= 1'b0;
      tx_div  <= '0;
      tx_bit  <= 4'd0;
    end else if (!tx_busy) begin
      if (tx_start) begin
        tx_sr   <= {1'b1, tx_data, 1'b0};      // stop, data, start
        tx_busy <= 1'b1;
        tx_div  <= '0;
        tx_bit  <= 4'd0;
      end
    end else if (tx_div == DW'(DIV - 1)) begin
      tx_div <= '0;
      tx_sr  <= {1'b1, tx_sr[9:1]};
      tx_bit <= tx_bit + 4'd1;
      if (tx_bit == 4'd9) tx_busy <= 1'b0;
    end else begin
      tx_div <= tx_div + 1'b1;
    end
  end

  // --------------------------------------------------------------- receiver
  logic [1:0]  rx_sync;
  logic [DW:0] rx_div;                 // holds 1.5 bit times
  logic  [3:0] rx_bit;
  logic  [7:0] rx_sr;
  logic        rx_busy;

  always_ff @(posedge clk) rx_sync <= {rx_sync[0], rx};

  always_ff @(posedge clk) begin
    rx_valid <= 1'b0;
    if (!rst_n) begin
      rx_busy <= 1'b0;
      rx_div  <= '0;
      rx_bit  <= 4'd0;
      rx_data <= 8'h00;
    end else if (!rx_busy) begin
      if (!rx_sync[1]) begin                       // start bit edge
        rx_busy <= 1'b1;
        rx_div  <= (DW+1)'(DIV + DIV / 2 - 1);     // to the middle of bit 0
        rx_bit  <= 4'd0;
      end
    end else if (rx_div == 0) begin
      rx_div <= (DW+1)'(DIV - 1);
      if (rx_bit == 4'd8) begin                    // this sample is the stop bit
        rx_busy <= 1'b0;
        if (rx_sync[1]) begin
          rx_data  <= rx_sr;
          rx_valid <= 1'b1;
        end
      end else begin
        rx_sr  <= {rx_sync[1], rx_sr[7:1]};
        rx_bit <= rx_bit + 4'd1;
      end
    end else begin
      rx_div <= rx_div - 1'b1;
    end
  end

endmodule

`endif
