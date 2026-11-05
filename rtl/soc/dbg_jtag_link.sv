// The debug unit's byte link over JTAG: the same byte interface as
// dbg_uart (rx_valid/rx_data, tx_start/tx_data/tx_busy), carried by one data
// register of the FPGA's TAP instead of a serial pair.  docs/debug_unit.md
// describes the bytes; this file moves them.
//
// The ports tck, sel, capture, shift, update, tdi, reset and tdo are those of
// Xilinx's BSCANE2 (rtl/soc/dbg_bscan_xilinx.sv wraps the primitive).  A
// simulation drives them from a test bench.
//
// The data register is 10 bits, shifted LSB first.
//   host to FPGA, shifted in:   [7:0] byte   [8] HV (the host sends that byte)
//                               [9] reserved, sent as 0 and ignored
//   FPGA to host, captured:     [7:0] byte   [8] FV (the byte is new)
//                               [9] RJ (reject)
// FPGA to host.  At CAPTURE-DR, if a byte is waiting, the scan captures
// {RJ, 1, byte}, and the byte counts as taken at UPDATE-DR of the same scan.
// With no byte waiting FV is 0 and bits 7:0 are undefined.  A scan that does
// not reach UPDATE-DR (a TAP reset in the middle) takes nothing.
// Host to FPGA.  RJ is 1 when the one-byte host mailbox is still full (the
// unit's clock has not taken the last byte) or the sticky reject flag is set.
// At UPDATE-DR, HV = 1 with RJ = 0 puts the byte in the mailbox; HV = 1 with
// RJ = 1 drops the byte and sets the sticky flag; HV = 0 clears the flag.  So
// in a batch the bytes from the first rejected one on are all rejected, in
// order, and the host sends one scan with HV = 0 and starts again there.
//
// Clock domains.  tck and clk are asynchronous and either can be the faster.
// Each direction is a one-byte mailbox with a toggle handshake: the writer
// loads the data and flips a toggle, the reader sees the toggle through two
// flip-flops, takes the data and flips its acknowledge, and the writer sees
// that through two flip-flops.  The mailbox is full while toggle and
// acknowledge differ.  The data does not move while the mailbox is full.
// The toggles are never reset (a half-finished handshake would otherwise
// invent a byte); they and the other flip-flops have initial values so a
// simulation does not start with X.  rst_n empties the host mailbox.  The
// TAP reset (reset) clears the TCK-domain flags: sticky, the captured RJ and
// FV, and the shift register.
//
// tx_busy is high while the FPGA-to-host mailbox holds a byte the host has
// not taken, and rises on the clock after tx_start as dbg_uart's does.

`ifndef DBG_JTAG_LINK_SV
`define DBG_JTAG_LINK_SV

module dbg_jtag_link (
    // the clock domain of the debug unit
    input  logic       clk,
    input  logic       rst_n,
    output logic       rx_valid,
    output logic [7:0] rx_data,
    input  logic       tx_start,
    input  logic [7:0] tx_data,
    output logic       tx_busy,

    // the TAP, as BSCANE2 gives it
    input  logic       tck,
    input  logic       sel,
    input  logic       capture,
    input  logic       shift,
    input  logic       update,
    input  logic       tdi,
    input  logic       reset,
    output logic       tdo
);

  // ------------------------------------------------- clk domain (the unit)
  logic       h_seen;          // host mailbox: toggle taken so far
  (* ASYNC_REG = "TRUE" *) logic [1:0] h_sync;         // h_tog from the TCK domain
  logic       f_tog;          // FPGA mailbox: flips when loaded
  logic [7:0] f_data;
  (* ASYNC_REG = "TRUE" *) logic [1:0] fa_sync;        // f_ack from the TCK domain

  // ------------------------------------------------------- TCK domain
  logic       h_tog;          // host mailbox: flips when loaded
  logic [7:0] h_data;
  (* ASYNC_REG = "TRUE" *) logic [1:0] ha_sync;        // h_seen from the clk domain
  logic       f_ack;          // FPGA mailbox: flips when taken
  (* ASYNC_REG = "TRUE" *) logic [1:0] f_sync;         // f_tog from the clk domain
  logic [9:0] sr;
  logic       sticky;
  logic       rj_cap;          // RJ this scan captured
  logic       fv_cap;          // FV this scan captured

  // Initial values, so a simulation does not start with X, and so the toggles
  // start equal.  Vivado takes them as the flip-flops' power-up state.
  initial begin
    h_seen = 1'b0;
    h_sync = 2'b00;
    f_tog = 1'b0;
    f_data = 8'h00;
    fa_sync = 2'b00;
    h_tog = 1'b0;
    h_data = 8'h00;
    ha_sync = 2'b00;
    f_ack = 1'b0;
    f_sync = 2'b00;
    sr = 10'h000;
    sticky = 1'b0;
    rj_cap = 1'b0;
    fv_cap = 1'b0;
  end

  // ------------------------------------------------------------------ clk
  assign tx_busy = (f_tog != fa_sync[1]);

  always_ff @(posedge clk) begin
    h_sync  <= {h_sync[0], h_tog};
    fa_sync <= {fa_sync[0], f_ack};
    rx_valid <= 1'b0;
    if (!rst_n) begin
      h_seen <= h_sync[1];                       // drop a byte still in the mailbox
    end else begin
      if (h_sync[1] != h_seen) begin
        h_seen   <= h_sync[1];
        rx_data  <= h_data;
        rx_valid <= 1'b1;
      end
      if (tx_start && !tx_busy) begin
        f_data <= tx_data;
        f_tog  <= ~f_tog;
      end
    end
  end

  // ------------------------------------------------------------------ TCK
  logic h_full, f_full;
  assign h_full = (h_tog != ha_sync[1]);
  assign f_full = (f_sync[1] != f_ack);

  always_ff @(posedge tck) begin
    f_sync  <= {f_sync[0], f_tog};
    ha_sync <= {ha_sync[0], h_seen};
    if (reset) begin
      sr     <= 10'h000;
      sticky <= 1'b0;
      rj_cap <= 1'b0;
      fv_cap <= 1'b0;
    end else if (sel) begin
      if (capture) begin
        sr     <= {h_full | sticky, f_full, f_data};
        rj_cap <= h_full | sticky;
        fv_cap <= f_full;
      end else if (shift) begin
        sr <= {tdi, sr[9:1]};
      end else if (update) begin
        if (sr[8]) begin
          if (!rj_cap) begin
            h_data <= sr[7:0];
            h_tog  <= ~h_tog;
          end else begin
            sticky <= 1'b1;
          end
        end else begin
          sticky <= 1'b0;
        end
        if (fv_cap) f_ack <= ~f_ack;
        fv_cap <= 1'b0;
      end
    end
  end

  assign tdo = sr[0];

endmodule

`endif
