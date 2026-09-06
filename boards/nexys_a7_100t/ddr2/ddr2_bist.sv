// DDR2 built-in self test: an AXI4 master that writes a pattern across the
// SDRAM, reads it back, and reports over the console.
//
// The MIG's AXI slave is 128 bits wide and refuses narrow bursts
// (C0_S_AXI_SUPPORTS_NARROW_BURST = 0 in Digilent's mig.prj), so every
// transaction here is a single beat of sixteen bytes with AWSIZE = 4.  That is
// also exactly one cache line if this ever grows into the memory path for the
// Z80, which is why the test is written around 16-byte lines rather than bytes.
//
// The report is deliberately terse - single characters rather than a string
// ROM - because the point is to see it on a terminal, not to be pretty:
//
//     C        calibration finished
//     W        the write pass finished
//     P 0000   read pass finished, no mismatches
//     F 0037   read pass finished, 0x37 lines did not match
//
// The address pattern steps by 4 KB so consecutive lines land in different
// DDR2 rows, which exercises activate/precharge rather than sitting in one
// open row.  The data includes the line index, so a read that returns the
// right bytes from the wrong address still fails.

`ifndef DDR2_BIST_SV
`define DDR2_BIST_SV

module ddr2_bist #(
    parameter int NLINES     = 1024,        // 16-byte lines to test
    parameter int ADDR_STEP  = 4096,        // bytes between lines
    parameter int ADDR_BITS  = 27
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 calib_done,

    // AXI4 write
    output logic [ADDR_BITS-1:0] awaddr,
    output logic                 awvalid,
    input  logic                 awready,
    output logic [127:0]         wdata,
    output logic                 wvalid,
    input  logic                 wready,
    input  logic                 bvalid,
    output logic                 bready,

    // AXI4 read
    output logic [ADDR_BITS-1:0] araddr,
    output logic                 arvalid,
    input  logic                 arready,
    input  logic [127:0]         rdata,
    input  logic                 rvalid,
    output logic                 rready,

    // console: hold ch_wr for one clock with the byte on ch
    output logic [7:0]           ch,
    output logic                 ch_wr,
    output logic                 ch_status_sel,   // 1 = ask the UART for status
    input  logic                 ch_ready,

    output logic [3:0]           led
);

  localparam int IW = (NLINES <= 1) ? 1 : $clog2(NLINES);

  typedef enum logic [4:0] {
    S_CALIB, S_PUT_C,
    S_WR_ADDR, S_WR_DATA, S_WR_RESP, S_WR_NEXT, S_PUT_W,
    S_RD_ADDR, S_RD_DATA, S_RD_NEXT, S_PUT_PF,
    S_HEX, S_CR, S_LF, S_DONE,
    S_PUTC_CHK, S_PUTC_WR
  } state_t;

  state_t      state, ret_state;
  logic [IW:0] idx;
  logic [15:0] errors;
  logic [7:0]  pend;
  logic [1:0]  nib;

  // The pattern for a line: the index appears twice plainly and twice
  // inverted, so neither a stuck-at bus nor a wrong address reads back clean.
  function automatic logic [127:0] pattern(input logic [IW:0] i);
    logic [31:0] w;
    w = {16'(i), ~16'(i)};
    return {w, ~w, {w[15:0], w[31:16]}, ~{w[15:0], w[31:16]}};
  endfunction

  function automatic logic [7:0] hexdigit(input logic [3:0] v);
    return (v < 10) ? (8'h30 + 8'(v)) : (8'h41 + 8'(v) - 8'd10);
  endfunction

  assign awaddr = ADDR_BITS'(idx * ADDR_STEP);
  assign araddr = ADDR_BITS'(idx * ADDR_STEP);
  assign wdata  = pattern(idx);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state         <= S_CALIB;
      ret_state     <= S_CALIB;
      idx           <= '0;
      errors        <= '0;
      pend          <= 8'h00;
      nib           <= 2'd0;
      awvalid       <= 1'b0;
      wvalid        <= 1'b0;
      bready        <= 1'b0;
      arvalid       <= 1'b0;
      rready        <= 1'b0;
      ch            <= 8'h00;
      ch_wr         <= 1'b0;
      ch_status_sel <= 1'b1;
      led           <= 4'b0000;
    end else begin
      ch_wr <= 1'b0;

      case (state)
        // ---------------------------------------------------------- calibrate
        S_CALIB: begin
          if (calib_done) begin
            led[0]    <= 1'b1;
            pend      <= "C";
            ret_state <= S_PUT_C;
            state     <= S_PUTC_CHK;
          end
        end
        S_PUT_C: begin
          idx   <= '0;
          state <= S_WR_ADDR;
        end

        // -------------------------------------------------------- write pass
        S_WR_ADDR: begin
          awvalid <= 1'b1;
          if (awvalid && awready) begin
            awvalid <= 1'b0;
            wvalid  <= 1'b1;
            state   <= S_WR_DATA;
          end
        end
        S_WR_DATA: begin
          if (wvalid && wready) begin
            wvalid <= 1'b0;
            bready <= 1'b1;
            state  <= S_WR_RESP;
          end
        end
        S_WR_RESP: begin
          if (bvalid) begin
            bready <= 1'b0;
            state  <= S_WR_NEXT;
          end
        end
        S_WR_NEXT: begin
          if (idx == (IW+1)'(NLINES - 1)) begin
            led[1]    <= 1'b1;
            pend      <= "W";
            ret_state <= S_PUT_W;
            state     <= S_PUTC_CHK;
          end else begin
            idx   <= idx + 1'b1;
            state <= S_WR_ADDR;
          end
        end
        S_PUT_W: begin
          idx   <= '0;
          state <= S_RD_ADDR;
        end

        // --------------------------------------------------------- read pass
        S_RD_ADDR: begin
          arvalid <= 1'b1;
          if (arvalid && arready) begin
            arvalid <= 1'b0;
            rready  <= 1'b1;
            state   <= S_RD_DATA;
          end
        end
        S_RD_DATA: begin
          if (rvalid) begin
            rready <= 1'b0;
            if (rdata !== pattern(idx)) errors <= errors + 1'b1;
            state <= S_RD_NEXT;
          end
        end
        S_RD_NEXT: begin
          if (idx == (IW+1)'(NLINES - 1)) begin
            pend      <= (errors == 16'd0) ? "P" : "F";
            led[2]    <= (errors == 16'd0);
            led[3]    <= (errors != 16'd0);
            ret_state <= S_PUT_PF;
            state     <= S_PUTC_CHK;
          end else begin
            idx   <= idx + 1'b1;
            state <= S_RD_ADDR;
          end
        end
        S_PUT_PF: begin
          nib       <= 2'd0;
          pend      <= hexdigit(errors[15:12]);
          ret_state <= S_HEX;
          state     <= S_PUTC_CHK;
        end

        // ------------------------------------------------------- error count
        S_HEX: begin
          if (nib == 2'd3) begin
            pend      <= 8'h0D;
            ret_state <= S_CR;
            state     <= S_PUTC_CHK;
          end else begin
            nib  <= nib + 1'b1;
            case (nib)
              2'd0: pend <= hexdigit(errors[11:8]);
              2'd1: pend <= hexdigit(errors[7:4]);
              default: pend <= hexdigit(errors[3:0]);
            endcase
            ret_state <= S_HEX;
            state     <= S_PUTC_CHK;
          end
        end
        S_CR: begin
          pend      <= 8'h0A;
          ret_state <= S_LF;
          state     <= S_PUTC_CHK;
        end
        S_LF:   state <= S_DONE;
        S_DONE: state <= S_DONE;

        // ------------------------------------------------- one character out
        // Two states rather than one: checking readiness drives the UART's
        // address to the status port, and writing drives it to the data port.
        // Deciding both in the same cycle would be a combinational loop.
        S_PUTC_CHK: begin
          ch_status_sel <= 1'b1;
          if (ch_ready) state <= S_PUTC_WR;
        end
        S_PUTC_WR: begin
          ch_status_sel <= 1'b0;
          ch            <= pend;
          ch_wr         <= 1'b1;
          state         <= ret_state;
        end

        default: state <= S_CALIB;
      endcase
    end
  end

endmodule

`endif
