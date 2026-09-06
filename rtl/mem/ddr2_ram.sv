// A byte-wide memory for the Z80, backed by DDR2 through the MIG's AXI port.
//
// The Z80 wants one byte per bus cycle and the MIG deals in sixteen at a time
// (Digilent's mig.prj sets C0_S_AXI_SUPPORTS_NARROW_BURST = 0, so every
// transfer is a single beat of the full 128-bit width), and it takes far
// longer than a T-state to answer.  Both problems are solved the way a real
// Z80 system solves them: hold wait_n low until the data is there.  The core
// freezes tcnt at the strobe T-state while `ready` is low, so no cache is
// needed for correctness -- only for speed.
//
// There is a one-line read cache, which is worth having because it is nearly
// free and instruction fetch is sequential: sixteen consecutive fetches from
// the same line cost one DDR2 read instead of sixteen.  A write invalidates
// the line rather than trying to merge into it; writes are comparatively rare
// and correctness is easier to see this way.
//
// Writes go straight out with a byte strobe.  Narrow bursts being disabled
// does not stop that: AWSIZE stays at the full sixteen bytes and WSTRB picks
// the one byte that is really being written.

`ifndef DDR2_RAM_SV
`define DDR2_RAM_SV

module ddr2_ram #(
    parameter int AW        = 19,        // byte address bits the Z80 side uses
    parameter int AXI_AW    = 27,
    parameter int BASE      = 0          // byte offset of this bank in DDR2
) (
    input  logic            clk,
    input  logic            rst_n,

    // Z80 side.  req is held for the whole bus cycle; ready pulses when the
    // access has completed and rdata is valid for a read.
    input  logic            req,
    input  logic            we,
    input  logic [AW-1:0]   addr,
    input  logic [7:0]      wdata,
    output logic [7:0]      rdata,
    output logic            ready,

    // AXI4 to the MIG
    output logic [AXI_AW-1:0] awaddr,
    output logic              awvalid,
    input  logic              awready,
    output logic [127:0]      wdata_axi,
    output logic [15:0]       wstrb,
    output logic              wvalid,
    input  logic              wready,
    input  logic              bvalid,
    output logic              bready,

    output logic [AXI_AW-1:0] araddr,
    output logic              arvalid,
    input  logic              arready,
    input  logic [127:0]      rdata_axi,
    input  logic              rvalid,
    output logic              rready
);

  localparam int LINE_LSB = 4;                       // 16 bytes per line
  localparam int TAG_W    = AW - LINE_LSB;

  logic [TAG_W-1:0] tag;
  logic [127:0]     line;
  logic             line_valid;

  wire [TAG_W-1:0]  req_tag = addr[AW-1:LINE_LSB];
  wire [3:0]        req_off = addr[LINE_LSB-1:0];
  wire              hit     = line_valid && (tag == req_tag);

  // byte out of the cached line
  assign rdata = line[8*req_off +: 8];

  typedef enum logic [2:0] {
    S_IDLE, S_RD_ADDR, S_RD_DATA, S_WR_ADDR, S_WR_DATA, S_WR_RESP, S_ACK
  } state_t;

  state_t state;
  logic   seen;          // this bus cycle has already been serviced

  assign awaddr = AXI_AW'(BASE + {addr[AW-1:LINE_LSB], {LINE_LSB{1'b0}}});
  assign araddr = AXI_AW'(BASE + {addr[AW-1:LINE_LSB], {LINE_LSB{1'b0}}});

  // The byte replicated across the 128-bit beat; WSTRB decides which copy
  // actually lands.
  assign wdata_axi = {16{wdata}};

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      line_valid <= 1'b0;
      tag        <= '0;
      line       <= '0;
      seen       <= 1'b0;
      ready      <= 1'b0;
      awvalid    <= 1'b0;
      wvalid     <= 1'b0;
      wstrb      <= '0;
      bready     <= 1'b0;
      arvalid    <= 1'b0;
      rready     <= 1'b0;
    end else begin
      if (!req) begin
        seen  <= 1'b0;
        ready <= 1'b0;
      end

      case (state)
        S_IDLE: begin
          if (req && !seen) begin
            if (we) begin
              // invalidate before the write so a hit cannot go stale
              if (hit) line_valid <= 1'b0;
              wstrb   <= 16'(1) << req_off;
              awvalid <= 1'b1;
              state   <= S_WR_ADDR;
            end else if (hit) begin
              ready <= 1'b1;
              seen  <= 1'b1;
              state <= S_ACK;
            end else begin
              arvalid <= 1'b1;
              state   <= S_RD_ADDR;
            end
          end
        end

        // -------------------------------------------------------------- read
        S_RD_ADDR: begin
          if (arready) begin
            arvalid <= 1'b0;
            rready  <= 1'b1;
            state   <= S_RD_DATA;
          end
        end
        S_RD_DATA: begin
          if (rvalid) begin
            rready     <= 1'b0;
            line       <= rdata_axi;
            tag        <= req_tag;
            line_valid <= 1'b1;
            ready      <= 1'b1;
            seen       <= 1'b1;
            state      <= S_ACK;
          end
        end

        // ------------------------------------------------------------- write
        S_WR_ADDR: begin
          if (awready) begin
            awvalid <= 1'b0;
            wvalid  <= 1'b1;
            state   <= S_WR_DATA;
          end
        end
        S_WR_DATA: begin
          if (wready) begin
            wvalid <= 1'b0;
            bready <= 1'b1;
            state  <= S_WR_RESP;
          end
        end
        S_WR_RESP: begin
          if (bvalid) begin
            bready <= 1'b0;
            ready  <= 1'b1;
            seen   <= 1'b1;
            state  <= S_ACK;
          end
        end

        // Hold ready until the core drops the cycle, so it is seen whatever
        // T-state the clock enable lands on.
        S_ACK: begin
          if (!req) begin
            ready <= 1'b0;
            state <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

`endif
