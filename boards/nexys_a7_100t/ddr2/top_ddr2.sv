// DDR2 bring-up for the Nexys A7-100T.
//
// This is not the SoC.  It is the smallest design that proves the board's
// 128 MiB of DDR2 works and that we can drive it: the MIG, a clock wizard to
// feed it, the SoC's own UART for reporting, and ddr2_bist to do the writing
// and reading.  Once this passes on hardware the memory is available and the
// Z80 can be pointed at it behind a cache.
//
// Clocking.  Digilent's mig.prj asks for a 100 MHz system clock and a
// separate 200 MHz reference with "No Buffer", so the reference has to come
// from outside the MIG - hence clk_wiz_0, which makes both from the board's
// 100 MHz on E3.  The memory clock is 325 MHz (TimePeriod 3077 ps) at a 4:1
// PHY ratio, so the MIG hands back a 81.25 MHz ui_clk, and everything on this
// side of the AXI port runs on that.  The UART's divisor is computed from
// 81.25 MHz rather than 100 MHz for the same reason; get that wrong and the
// console prints mojibake even though the memory is fine.
//
// Reset.  MIG generates with RST_ACT_LOW = 1, so sys_rst is active low and
// CPU_RESETN drives it directly.  aresetn is held low until the MIG's own
// ui_clk_sync_rst has cleared, which is the only ordering the AXI port cares
// about.

module top_ddr2 (
    input  logic        CLK100MHZ,
    input  logic        CPU_RESETN,      // active low
    output logic [3:0]  led,
    input  logic        uart_txd_in,
    output logic        uart_rxd_out,

    // DDR2 - pins come from the MIG's own generated constraints
    output logic [12:0] ddr2_addr,
    output logic [2:0]  ddr2_ba,
    output logic        ddr2_ras_n,
    output logic        ddr2_cas_n,
    output logic        ddr2_we_n,
    output logic [0:0]  ddr2_ck_p,
    output logic [0:0]  ddr2_ck_n,
    output logic [0:0]  ddr2_cke,
    output logic [0:0]  ddr2_cs_n,
    output logic [1:0]  ddr2_dm,
    output logic [0:0]  ddr2_odt,
    inout  wire  [15:0] ddr2_dq,
    inout  wire  [1:0]  ddr2_dqs_p,
    inout  wire  [1:0]  ddr2_dqs_n
);

  localparam int UI_CLK_HZ = 81_250_000;   // 325 MHz / 4

  // ------------------------------------------------------------------ clocks
  logic clk200, clk100, mmcm_locked;

  clk_wiz_0 u_clk (
      .clk_in1  (CLK100MHZ),
      .clk_out1 (clk200),
      .clk_out2 (clk100),
      .locked   (mmcm_locked)
  );

  // --------------------------------------------------------------------- MIG
  logic ui_clk, ui_clk_sync_rst, init_calib_complete;
  logic aresetn;

  logic [26:0]  s_axi_awaddr,  s_axi_araddr;
  logic         s_axi_awvalid, s_axi_awready;
  logic [127:0] s_axi_wdata,   s_axi_rdata;
  logic         s_axi_wvalid,  s_axi_wready;
  logic         s_axi_bvalid,  s_axi_bready;
  logic         s_axi_arvalid, s_axi_arready;
  logic         s_axi_rvalid,  s_axi_rready;
  logic [1:0]   s_axi_bresp,   s_axi_rresp;
  logic [3:0]   s_axi_bid,     s_axi_rid;
  logic         s_axi_rlast;

  // aresetn releases once the MIG's user-side reset has gone away
  always_ff @(posedge ui_clk) aresetn <= ~ui_clk_sync_rst;

  mig_7series_0 u_mig (
      .ddr2_addr           (ddr2_addr),
      .ddr2_ba             (ddr2_ba),
      .ddr2_cas_n          (ddr2_cas_n),
      .ddr2_ck_n           (ddr2_ck_n),
      .ddr2_ck_p           (ddr2_ck_p),
      .ddr2_cke            (ddr2_cke),
      .ddr2_ras_n          (ddr2_ras_n),
      .ddr2_we_n           (ddr2_we_n),
      .ddr2_dq             (ddr2_dq),
      .ddr2_dqs_n          (ddr2_dqs_n),
      .ddr2_dqs_p          (ddr2_dqs_p),
      .init_calib_complete (init_calib_complete),
      .ddr2_cs_n           (ddr2_cs_n),
      .ddr2_dm             (ddr2_dm),
      .ddr2_odt            (ddr2_odt),

      .ui_clk              (ui_clk),
      .ui_clk_sync_rst     (ui_clk_sync_rst),
      .ui_addn_clk_0       (),
      .ui_addn_clk_1       (),
      .ui_addn_clk_2       (),
      .ui_addn_clk_3       (),
      .ui_addn_clk_4       (),
      .mmcm_locked         (),
      .aresetn             (aresetn),

      .app_sr_req          (1'b0),
      .app_ref_req         (1'b0),
      .app_zq_req          (1'b0),
      .app_sr_active       (),
      .app_ref_ack         (),
      .app_zq_ack          (),

      .s_axi_awid          (4'd0),
      .s_axi_awaddr        (s_axi_awaddr),
      .s_axi_awlen         (8'd0),          // one beat
      .s_axi_awsize        (3'd4),          // 16 bytes, the full data width
      .s_axi_awburst       (2'b01),         // INCR
      .s_axi_awlock        (1'b0),
      .s_axi_awcache       (4'b0011),
      .s_axi_awprot        (3'b000),
      .s_axi_awqos         (4'd0),
      .s_axi_awvalid       (s_axi_awvalid),
      .s_axi_awready       (s_axi_awready),
      .s_axi_wdata         (s_axi_wdata),
      .s_axi_wstrb         (16'hFFFF),
      .s_axi_wlast         (1'b1),
      .s_axi_wvalid        (s_axi_wvalid),
      .s_axi_wready        (s_axi_wready),
      .s_axi_bid           (s_axi_bid),
      .s_axi_bresp         (s_axi_bresp),
      .s_axi_bvalid        (s_axi_bvalid),
      .s_axi_bready        (s_axi_bready),

      .s_axi_arid          (4'd0),
      .s_axi_araddr        (s_axi_araddr),
      .s_axi_arlen         (8'd0),
      .s_axi_arsize        (3'd4),
      .s_axi_arburst       (2'b01),
      .s_axi_arlock        (1'b0),
      .s_axi_arcache       (4'b0011),
      .s_axi_arprot        (3'b000),
      .s_axi_arqos         (4'd0),
      .s_axi_arvalid       (s_axi_arvalid),
      .s_axi_arready       (s_axi_arready),
      .s_axi_rid           (s_axi_rid),
      .s_axi_rdata         (s_axi_rdata),
      .s_axi_rresp         (s_axi_rresp),
      .s_axi_rlast         (s_axi_rlast),
      .s_axi_rvalid        (s_axi_rvalid),
      .s_axi_rready        (s_axi_rready),

      .sys_clk_i           (clk100),
      .clk_ref_i           (clk200),
      .sys_rst             (CPU_RESETN)     // RST_ACT_LOW = 1
  );

  // ------------------------------------------------------------------- reset
  logic [3:0] rst_sync;
  logic       rst_n;
  always_ff @(posedge ui_clk) rst_sync <= {rst_sync[2:0], ~ui_clk_sync_rst & mmcm_locked};
  assign rst_n = rst_sync[3];

  // ----------------------------------------------------------------- console
  logic [7:0] ch, uart_rdata;
  logic       ch_wr, ch_status_sel, uart_hit;

  uart #(.CLK_HZ (UI_CLK_HZ), .BAUD (115200)) u_uart (
      .clk        (ui_clk),
      .rst_n      (rst_n),
      .port_addr  (ch_status_sel ? 8'h00 : 8'h01),
      .port_wdata (ch),
      .port_wr    (ch_wr),
      .port_rd    (1'b0),
      .port_rdata (uart_rdata),
      .port_hit   (uart_hit),
      .rx         (uart_txd_in),
      .tx         (uart_rxd_out)
  );

  // -------------------------------------------------------------------- test
  ddr2_bist #(.NLINES (1024), .ADDR_STEP (4096)) u_bist (
      .clk           (ui_clk),
      .rst_n         (rst_n),
      .calib_done    (init_calib_complete),

      .awaddr        (s_axi_awaddr),
      .awvalid       (s_axi_awvalid),
      .awready       (s_axi_awready),
      .wdata         (s_axi_wdata),
      .wvalid        (s_axi_wvalid),
      .wready        (s_axi_wready),
      .bvalid        (s_axi_bvalid),
      .bready        (s_axi_bready),

      .araddr        (s_axi_araddr),
      .arvalid       (s_axi_arvalid),
      .arready       (s_axi_arready),
      .rdata         (s_axi_rdata),
      .rvalid        (s_axi_rvalid),
      .rready        (s_axi_rready),

      .ch            (ch),
      .ch_wr         (ch_wr),
      .ch_status_sel (ch_status_sel),
      .ch_ready      (uart_rdata[1]),   // status bit 1 = transmitter idle

      .led           (led)
  );

endmodule
