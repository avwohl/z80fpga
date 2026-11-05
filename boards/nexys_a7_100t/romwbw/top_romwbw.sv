// RomWBW on the Nexys A7-100T: the full 512 KB + 512 KB map.
//
// The split is the one the part forces. Only one of the two banks can live in
// block RAM, and it has to be the ROM, because the ROM is the only one whose
// contents must survive to the first instruction fetch: DDR2 is volatile and
// there is nothing to load it from at reset. So the RAM goes to DDR2, which
// suits it, since RAM starts undefined anyway.
//
// The ROM is the whole 512 KB image, which is 128 of the part's 135 RAMB36
// tiles. That occupancy looks alarming and is not the problem it appears to
// be: halving it to 256 KB made timing *worse*, not better. What actually
// failed was the Z80's write data crossing into the MIG, and that is fixed
// where it should be, in the constraints.
//
// The RAM then cannot answer in a T-state, and does not pretend to: ddr2_ram
// holds wait_n low until the AXI transaction finishes and the core freezes at
// the strobe T-state. No cache is needed for correctness. There is a one-line
// read cache all the same, because instruction fetch is sequential and it
// turns sixteen DDR2 reads into one.
//
// Everything runs on the MIG's ui_clk at 81.25 MHz. CPU_DIV stays at 12, both
// because 81.25/12 = 6.8 MHz is a sensible Z80 and because it keeps the
// multicycle constraints identical to the block RAM build.

module top_romwbw (
    input  logic        CLK100MHZ,
    input  logic        CPU_RESETN,      // active low
    output logic [3:0]  led,
    input  logic        uart_txd_in,
    output logic        uart_rxd_out,
    input  logic        uart_rts,        // bridge drives this: our CTS
    output logic        uart_cts,        // we drive this: our RTS

    // microSD, SPI mode: CS is DAT3, MOSI is CMD, MISO is DAT0
    output logic        sd_reset,
    input  logic        sd_cd,
    output logic        sd_sck,
    output logic        sd_cmd,
    inout  wire  [3:0]  sd_dat,

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
`ifdef WITH_DEBUG_UART
    ,
    // The debug unit's serial line (docs/debug_unit.md), on Pmod JA pins 1 and
    // 2 by romwbw_dbg.xdc.  build_romwbw.tcl defines WITH_DEBUG_UART only when
    // Z80_DEBUG_UNIT is 1 and Z80_DEBUG_LINK is uart.  With the default link,
    // JTAG, and without the unit, these lines do not exist.
    input  logic        dbg_rx,
    output logic        dbg_tx
`endif
);

  localparam int UI_CLK_HZ = 81_250_000;   // 325 MHz / 4

`ifdef WITH_DEBUG_UNIT
`ifndef WITH_DEBUG_UART
  // The debug unit over JTAG (docs/debug_unit.md): the user data register of
  // USER3, through the configuration JTAG pins, so the unit needs no pin.
  // build_romwbw.tcl defines WITH_DEBUG_UNIT, and leaves WITH_DEBUG_UART
  // undefined, by default.  No Vivado has run this.
  logic jt_tck, jt_sel, jt_capture, jt_shift, jt_update, jt_tdi, jt_reset, jt_tdo;

  dbg_bscan_xilinx u_dbg_bscan (
      .tck (jt_tck), .sel (jt_sel), .capture (jt_capture), .shift (jt_shift),
      .update (jt_update), .tdi (jt_tdi), .reset (jt_reset), .tdo (jt_tdo)
  );
`endif
`endif

  logic clk200, clk100, mmcm_locked;

  clk_wiz_0 u_clk (
      .clk_in1  (CLK100MHZ),
      .clk_out1 (clk200),
      .clk_out2 (clk100),
      .locked   (mmcm_locked)
  );

  logic ui_clk, ui_clk_sync_rst, init_calib_complete, aresetn;

  logic [26:0]  axi_awaddr,  axi_araddr;
  logic         axi_awvalid, axi_awready;
  logic [127:0] axi_wdata,   axi_rdata;
  logic [15:0]  axi_wstrb;
  logic         axi_wvalid,  axi_wready;
  logic         axi_bvalid,  axi_bready;
  logic         axi_arvalid, axi_arready;
  logic         axi_rvalid,  axi_rready;

  always_ff @(posedge ui_clk) aresetn <= ~ui_clk_sync_rst;

  mig_7series_0 u_mig (
      .ddr2_addr (ddr2_addr), .ddr2_ba (ddr2_ba),
      .ddr2_cas_n (ddr2_cas_n), .ddr2_ras_n (ddr2_ras_n), .ddr2_we_n (ddr2_we_n),
      .ddr2_ck_n (ddr2_ck_n), .ddr2_ck_p (ddr2_ck_p), .ddr2_cke (ddr2_cke),
      .ddr2_dq (ddr2_dq), .ddr2_dqs_n (ddr2_dqs_n), .ddr2_dqs_p (ddr2_dqs_p),
      .ddr2_cs_n (ddr2_cs_n), .ddr2_dm (ddr2_dm), .ddr2_odt (ddr2_odt),
      .init_calib_complete (init_calib_complete),

      .ui_clk (ui_clk), .ui_clk_sync_rst (ui_clk_sync_rst),
      .ui_addn_clk_0 (), .ui_addn_clk_1 (), .ui_addn_clk_2 (),
      .ui_addn_clk_3 (), .ui_addn_clk_4 (), .mmcm_locked (),
      .aresetn (aresetn),

      .app_sr_req (1'b0), .app_ref_req (1'b0), .app_zq_req (1'b0),
      .app_sr_active (), .app_ref_ack (), .app_zq_ack (),

      .s_axi_awid (4'd0), .s_axi_awaddr (axi_awaddr), .s_axi_awlen (8'd0),
      .s_axi_awsize (3'd4), .s_axi_awburst (2'b01), .s_axi_awlock (1'b0),
      .s_axi_awcache (4'b0011), .s_axi_awprot (3'b000), .s_axi_awqos (4'd0),
      .s_axi_awvalid (axi_awvalid), .s_axi_awready (axi_awready),
      .s_axi_wdata (axi_wdata), .s_axi_wstrb (axi_wstrb), .s_axi_wlast (1'b1),
      .s_axi_wvalid (axi_wvalid), .s_axi_wready (axi_wready),
      .s_axi_bid (), .s_axi_bresp (), .s_axi_bvalid (axi_bvalid),
      .s_axi_bready (axi_bready),

      .s_axi_arid (4'd0), .s_axi_araddr (axi_araddr), .s_axi_arlen (8'd0),
      .s_axi_arsize (3'd4), .s_axi_arburst (2'b01), .s_axi_arlock (1'b0),
      .s_axi_arcache (4'b0011), .s_axi_arprot (3'b000), .s_axi_arqos (4'd0),
      .s_axi_arvalid (axi_arvalid), .s_axi_arready (axi_arready),
      .s_axi_rid (), .s_axi_rdata (axi_rdata), .s_axi_rresp (),
      .s_axi_rlast (), .s_axi_rvalid (axi_rvalid), .s_axi_rready (axi_rready),

      .sys_clk_i (clk100), .clk_ref_i (clk200), .sys_rst (CPU_RESETN)
  );

  // The Z80 is held in reset until the MIG has calibrated, so its very first
  // RAM access cannot arrive before the memory can answer it.
  logic [3:0] rst_sync;
  logic       rst_n;
  always_ff @(posedge ui_clk)
    rst_sync <= {rst_sync[2:0], ~ui_clk_sync_rst & mmcm_locked & init_calib_complete};
  assign rst_n = rst_sync[3];

  logic [7:0] led8;
  logic       sd_cs;

  // The Nexys A7 needs sd_reset driven low to power the slot.
  assign sd_reset  = 1'b0;
  assign sd_dat[3] = sd_cs;
  assign sd_dat[2] = 1'b1;
  assign sd_dat[1] = 1'b1;

  z80_soc #(
      .CLK_HZ       (UI_CLK_HZ),
      .CPU_DIV      (12),                 // 6.8 MHz Z80
      .BAUD         (115200),
      .CONSOLE_SSER (1'b1),               // stock RomWBW drives SSER
      .FLOW_CTRL    (1'b1),               // RTS/CTS on the console
      .USE_HDSK     (1'b1),               // HDSK0:/HDSK1: on port 0xFD
      // Pinned to the sector-buffer shape this board was verified with.  The
      // portable one is better everywhere else and is the default; here it
      // makes place_design fail on a design at 94.81% of the part's block RAM.
      // rtl/soc/sd_spi.sv has the whole of it.
      .SD_BUF_MUX   (1'b0),
`ifdef WITH_DEBUG_UNIT
      .DEBUG_UNIT   (1'b1),
      .DBG_BAUD     (115200),
`ifndef WITH_DEBUG_UART
      .DBG_JTAG     (1'b1),
`endif
      .DBG_BP_N     (4),
      .DBG_HALT_ON_RESET (1'b0),         // 1: stopped at 0000H, before the ROM runs
`endif
      .USE_DDR2     (1'b1),
      .DDR2_BASE    (0),
      .ROM_BANKS    (16),                 // 512 KB in block RAM
      .RAM_BANKS    (16),                 // 512 KB in DDR2
      .ROM_INIT     ("romwbw512k.hex"),
      .UCODE_MEM    ("z80_ucode.mem"),
      .DISP_MEM     ("z80_dispatch.mem")
  ) u_soc (
      .clk (ui_clk), .rst_n (rst_n),
      .uart_rx (uart_txd_in), .uart_tx (uart_rxd_out),
      // The crossover is real: the pin called uart_rts feeds our cts_n, and
      // the pin called uart_cts is driven by our rts_n.  Digilent names them
      // from the bridge's end.
      .uart_cts_n (uart_rts), .uart_rts_n (uart_cts),
      .led (led8), .sw (8'h00),
`ifdef WITH_DEBUG_UART
      .dbg_rx (dbg_rx), .dbg_tx (dbg_tx),
`elsif WITH_DEBUG_UNIT
      .dbg_rx (1'b1), .dbg_tx (),
      .dbg_jt_tck (jt_tck), .dbg_jt_sel (jt_sel),
      .dbg_jt_capture (jt_capture), .dbg_jt_shift (jt_shift),
      .dbg_jt_update (jt_update), .dbg_jt_tdi (jt_tdi),
      .dbg_jt_reset (jt_reset), .dbg_jt_tdo (jt_tdo),
`endif

      .sd_sck (sd_sck), .sd_mosi (sd_cmd), .sd_miso (sd_dat[0]), .sd_cs (sd_cs),

      .m_axi_awaddr (axi_awaddr), .m_axi_awvalid (axi_awvalid),
      .m_axi_awready (axi_awready),
      .m_axi_wdata (axi_wdata), .m_axi_wstrb (axi_wstrb),
      .m_axi_wvalid (axi_wvalid), .m_axi_wready (axi_wready),
      .m_axi_bvalid (axi_bvalid), .m_axi_bready (axi_bready),
      .m_axi_araddr (axi_araddr), .m_axi_arvalid (axi_arvalid),
      .m_axi_arready (axi_arready),
      .m_axi_rdata (axi_rdata), .m_axi_rvalid (axi_rvalid),
      .m_axi_rready (axi_rready)
  );

  // led[3] is the one to look at if the console is silent: calibration.
  assign led = {init_calib_complete, ~sd_cd, led8[1:0]};

endmodule
