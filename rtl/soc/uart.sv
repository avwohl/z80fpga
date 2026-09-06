// 8N1 UART with one of two port interfaces, chosen by CONSOLE_SSER.
//
// CONSOLE_SSER = 0, the interface the avwohl Z80 emulators present:
//
//   port 0x00  read   bit 0 = a received byte is waiting, bit 1 = TX is idle
//   port 0x01  read   take the received byte
//              write  send a byte
//
// CONSOLE_SSER = 1, RomWBW's SSER device, which is what a stock RomWBW ROM
// drives.  The driver in SBC_simh_std.rom tests the status with `E6 01` for
// receive and `E6 20` for transmit, so the ready bits are 0 and 5 rather than
// 0 and 1, and the data port moves:
//
//   port 0x6D  read   bit 0 = a received byte is waiting, bit 5 = TX is idle
//   port 0x68  read   take the received byte
//              write  send a byte
//
// The two are deliberately exclusive rather than aliased.  HBIOS probes port
// 0x00 while hunting for devices and treats a stable non-0xFF answer as one
// being present, so leaving the emulator ports decoded in a RomWBW build
// invents a console that is not there.
//
// RX_DEPTH bytes of receive buffering.  A single byte is not enough: a Z80
// echo loop that has to wait for its own transmitter can be a couple of
// character times behind the line.  An overrun drops the newest byte and is
// not reported, which is what the emulated console does.

`ifndef UART_SV
`define UART_SV

module uart #(
    parameter int CLK_HZ       = 50_000_000,
    parameter int BAUD         = 115200,
    parameter int RX_DEPTH     = 16,
    parameter bit CONSOLE_SSER = 1'b0    // 1: RomWBW SSER at 0x68/0x6D
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic [7:0] port_addr,
    input  logic [7:0] port_wdata,
    input  logic       port_wr,
    input  logic       port_rd,
    output logic [7:0] port_rdata,
    output logic       port_hit,

    input  logic       rx,
    output logic       tx
);

  localparam logic [7:0] STAT_PORT = CONSOLE_SSER ? 8'h6D : 8'h00;
  localparam logic [7:0] DATA_PORT = CONSOLE_SSER ? 8'h68 : 8'h01;

  localparam int DIV = CLK_HZ / BAUD;
  localparam int DW  = $clog2(DIV);
  localparam int FW  = $clog2(RX_DEPTH);

  // ------------------------------------------------------------ transmitter
  logic [DW-1:0] tx_div;
  logic    [3:0] tx_bit;
  logic    [9:0] tx_sr;
  logic          tx_busy;

  assign tx = tx_sr[0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tx_sr   <= 10'h3FF;
      tx_busy <= 1'b0;
      tx_div  <= '0;
      tx_bit  <= 4'd0;
    end else if (!tx_busy) begin
      if (port_wr && port_addr == DATA_PORT) begin
        tx_sr   <= {1'b1, port_wdata, 1'b0};   // stop, data, start
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
  logic [DW:0] rx_div;      // holds 1.5 bit times
  logic [3:0]    rx_bit;
  logic  [7:0] rx_sr;
  logic        rx_busy;

  logic  [7:0] fifo [0:RX_DEPTH-1];
  logic [FW:0] wptr, rptr;
  logic        rx_ready, fifo_full;

  assign rx_ready  = (wptr != rptr);
  assign fifo_full = (wptr[FW-1:0] == rptr[FW-1:0]) && (wptr[FW] != rptr[FW]);

  always_ff @(posedge clk) rx_sync <= {rx_sync[0], rx};

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rx_busy <= 1'b0;
      rx_div  <= '0;
      rx_bit  <= 4'd0;
      wptr    <= '0;
      rptr    <= '0;
    end else begin
      if (port_rd && port_addr == DATA_PORT && rx_ready) rptr <= rptr + 1'b1;

      if (!rx_busy) begin
        if (!rx_sync[1]) begin                 // start bit edge
          rx_busy <= 1'b1;
          rx_div  <= (DW+1)'(DIV + DIV / 2 - 1);   // to the middle of bit 0
          rx_bit  <= 4'd0;
        end
      end else if (rx_div == 0) begin
        rx_div <= (DW+1)'(DIV - 1);
        if (rx_bit == 4'd8) begin              // this sample is the stop bit
          rx_busy <= 1'b0;
          if (rx_sync[1] && !fifo_full) begin
            fifo[wptr[FW-1:0]] <= rx_sr;
            wptr <= wptr + 1'b1;
          end
        end else begin
          rx_sr  <= {rx_sync[1], rx_sr[7:1]};
          rx_bit <= rx_bit + 4'd1;
        end
      end else begin
        rx_div <= rx_div - 1'b1;
      end
    end
  end

  // ------------------------------------------------------------------ ports
  assign port_hit   = (port_addr == STAT_PORT) || (port_addr == DATA_PORT);
  assign port_rdata = (port_addr == STAT_PORT)
                    ? (CONSOLE_SSER ? {2'd0, ~tx_busy, 4'd0, rx_ready}
                                    : {6'd0, ~tx_busy, rx_ready})
                    : fifo[rptr[FW-1:0]];

endmodule

`endif
