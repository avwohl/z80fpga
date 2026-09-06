// A minimal Z80 system: the core, the RomWBW-compatible banked memory, a
// UART, and an LED/switch port.  This is what the board targets instantiate.
//
// I/O map
//   0x00       read   UART status: bit 0 RX ready, bit 1 TX idle
//   0x01       r/w    UART data
//   0x78, 0x7C r/w    bank select (see rtl/soc/z80_mmu.sv)
//   0xFF       r/w    write: LEDs, read: switches
//
// CPU_DIV divides the fabric clock down to one T-state per enable, so the
// Z80 runs at CLK_HZ / CPU_DIV.  The UART's baud divisor is taken from the
// undivided clock.

`ifndef Z80_SOC_SV
`define Z80_SOC_SV

module z80_soc #(
    parameter int CLK_HZ    = 100_000_000,
    parameter int CPU_DIV   = 25,           // 100 MHz / 25 = 4 MHz Z80
    parameter int BAUD      = 115200,
    parameter bit CONSOLE_SSER = 1'b0,      // 1: RomWBW SSER console at 0x68/0x6D
    parameter int MEM_WAIT   = 0,           // extra T-states per memory cycle
    parameter bit USE_HDSK   = 1'b0,        // SIMH HDSK on port 0xFD, backed by microSD
    parameter bit USE_DDR2   = 1'b0,        // RAM banks live in DDR2, not block RAM
    parameter int DDR2_BASE  = 0,           // byte offset of the RAM in DDR2
    parameter int ROM_BANKS = 1,            // x 32 KB
    parameter int RAM_BANKS = 2,
    // Backing store size, as an address width.  Defaults to the whole bank
    // space; make it smaller when the part has less memory than the bank map
    // implies and the top of each bank may simply mirror.
    parameter int ROM_AW_P  = 0,
    parameter int RAM_AW_P  = 0,
    parameter bit USE_SPRAM = 1'b0,         // iCE40 UltraPlus: RAM in SPRAM
    parameter     ROM_INIT  = "",
    parameter     UCODE_MEM = "z80_ucode.mem",
    parameter     DISP_MEM  = "z80_dispatch.mem"
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [7:0] led,
    input  logic [7:0] sw,

    // AXI4 to the MIG.  Only driven when USE_DDR2; leave unconnected otherwise.
    output logic [26:0]  m_axi_awaddr,
    output logic         m_axi_awvalid,
    input  logic         m_axi_awready,
    output logic [127:0] m_axi_wdata,
    output logic [15:0]  m_axi_wstrb,
    output logic         m_axi_wvalid,
    input  logic         m_axi_wready,
    input  logic         m_axi_bvalid,
    output logic         m_axi_bready,
    // microSD, only driven when USE_HDSK
    output logic         sd_sck,
    output logic         sd_mosi,
    input  logic         sd_miso,
    output logic         sd_cs,

    output logic [26:0]  m_axi_araddr,
    output logic         m_axi_arvalid,
    input  logic         m_axi_arready,
    input  logic [127:0] m_axi_rdata,
    input  logic         m_axi_rvalid,
    output logic         m_axi_rready
);

  localparam int ROM_AW = (ROM_AW_P != 0) ? ROM_AW_P : 15 + $clog2(ROM_BANKS);
  localparam int RAM_AW = (RAM_AW_P != 0) ? RAM_AW_P : 15 + $clog2(RAM_BANKS);

  // --------------------------------------------------------------- clock enable
  localparam int DIVW = $clog2(CPU_DIV) + 1;

  logic [DIVW-1:0] divcnt;
  logic            clk_en;

  always_ff @(posedge clk) begin
    if (!rst_n) divcnt <= '0;
    else        divcnt <= (divcnt == DIVW'(CPU_DIV - 1)) ? '0 : divcnt + 1'b1;
  end
  assign clk_en = (CPU_DIV == 1) ? 1'b1 : (divcnt == DIVW'(CPU_DIV - 1));

  // ------------------------------------------------------------------- the core
  logic [15:0] a;
  logic  [7:0] din, dout;
  logic mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n, busak_n;

  // ------------------------------------------------------------ wait states
  // Memory that cannot answer in one T-state stretches the cycle by holding
  // wait_n low at the strobe T-state; the core freezes tcnt there.  MEM_WAIT
  // inserts a fixed number of them, which is how the path gets tested without
  // real slow memory attached.  A DDR2-backed bank drives the same signal from
  // its own ready instead.
  // Declared here rather than where they are driven: this block and the MMU
  // instantiation both come before the memory and HDSK sections that assign
  // them, and a signal has to be declared before it is used.
  logic        wait_n;
  logic        ram_ready, ram_cycle;
  logic [7:0]  hdsk_rdata;
  logic        hdsk_hit, hdsk_wait;
  logic        dma_req, dma_we, dma_ack;
  logic [15:0] dma_addr;
  logic [7:0]  dma_wdata, dma_rdata;
  logic [15:0] mem_addr;
  logic        mem_wr_eff;
  logic [7:0]  mem_wdata;

  generate
    if (USE_DDR2) begin : g_ddrwait
      assign wait_n = !((ram_cycle && !ram_ready) || hdsk_wait);
    end else if (MEM_WAIT == 0) begin : g_nowait
      assign wait_n = !hdsk_wait;
    end else begin : g_wait
      localparam int WW = $clog2(MEM_WAIT + 1);
      logic [WW-1:0] wcnt;
      logic          mem_cycle;
      assign mem_cycle = !mreq_n && (!rd_n || !wr_n);
      always_ff @(posedge clk) begin
        if (!rst_n)               wcnt <= '0;
        else if (!mem_cycle)      wcnt <= '0;
        else if (clk_en && wcnt != WW'(MEM_WAIT)) wcnt <= wcnt + 1'b1;
      end
      assign wait_n = !((mem_cycle && wcnt != WW'(MEM_WAIT)) || hdsk_wait);
    end
    if (!USE_DDR2) begin : g_noready
      assign ram_ready = 1'b1;
    end
  endgenerate

  z80_core #(
      .UCODE_MEM (UCODE_MEM),
      .DISP_MEM  (DISP_MEM)
  ) u_cpu (
      .clk (clk), .rst_n (rst_n), .clk_en (clk_en),
      .a (a), .din (din), .dout (dout),
      .mreq_n (mreq_n), .iorq_n (iorq_n), .rd_n (rd_n), .wr_n (wr_n),
      .m1_n (m1_n), .rfsh_n (rfsh_n), .halt_n (halt_n), .busak_n (busak_n),
      .wait_n (wait_n), .int_n (1'b1), .nmi_n (1'b1), .busrq_n (1'b1)
  );

  // -------------------------------------------------------------------- the MMU
  logic [18:0] phys;
  logic        sel_rom, bank_valid, mmu_hit;
  logic  [7:0] mmu_rdata;
  logic        port_wr, port_rd;

  assign port_wr = !iorq_n && !wr_n && m1_n;
  assign port_rd = !iorq_n && !rd_n && m1_n;

  z80_mmu #(.ROM_BANKS (ROM_BANKS), .RAM_BANKS (RAM_BANKS)) u_mmu (
      .clk (clk), .rst_n (rst_n),
      .cpu_addr (mem_addr), .port_addr (a[7:0]), .port_wdata (dout),
      .port_wr (port_wr && clk_en),
      .port_rdata (mmu_rdata), .port_hit (mmu_hit),
      .phys_addr (phys), .sel_rom (sel_rom), .bank_valid (bank_valid)
  );

  // ----------------------------------------------------------------- the memory
  logic [7:0] rom_rdata, ram_rdata;
  logic       mem_we;

  assign mem_we    = !mreq_n && !wr_n;

  // The HDSK controller borrows the memory port while it has the CPU stalled
  // on an I/O wait.  That is safe precisely because the core excludes I/O from
  // mem_cycle: mreq_n stays high for the whole stretched cycle, so the CPU is
  // not using memory and cannot be surprised by the address moving.
  assign mem_addr   = dma_req ? dma_addr : a;
  assign mem_wr_eff = dma_req ? dma_we   : (mem_we && !sel_rom);
  assign mem_wdata  = dma_req ? dma_wdata : dout;
  assign dma_rdata  = sel_rom ? rom_rdata : ram_rdata;

  assign ram_cycle = dma_req ? !sel_rom
                             : (!mreq_n && (!rd_n || !wr_n) && !sel_rom);

  sync_ram #(.AW (ROM_AW), .READ_ONLY (1'b1), .INIT_FILE (ROM_INIT)) u_rom (
      .clk (clk), .en (1'b1), .addr (phys[ROM_AW-1:0]),
      .wdata (dout), .we (1'b0), .rdata (rom_rdata)
  );

  generate
    if (USE_SPRAM) begin : g_spram
      spram_ice40 u_ram (
          .clk (clk), .addr (17'(phys[RAM_AW-1:0])), .wdata (dout),
          .we (mem_we && !sel_rom && clk_en), .rdata (ram_rdata)
      );
    end else if (USE_DDR2) begin : g_ddr2
      // The RAM banks live in DDR2 and cannot answer in a T-state, so this one
      // drives wait_n instead of pretending to be fast.  Note the write is NOT
      // gated by clk_en the way the block RAM's is: ddr2_ram latches the cycle
      // itself and acknowledges it once, and gating here would hand it a
      // request that vanishes between enable ticks.
      ddr2_ram #(.AW (RAM_AW), .BASE (DDR2_BASE)) u_ram (
          .clk (clk), .rst_n (rst_n),
          .req (ram_cycle), .we (mem_wr_eff),
          .addr (phys[RAM_AW-1:0]), .wdata (mem_wdata),
          .rdata (ram_rdata), .ready (ram_ready),
          .awaddr (m_axi_awaddr), .awvalid (m_axi_awvalid), .awready (m_axi_awready),
          .wdata_axi (m_axi_wdata), .wstrb (m_axi_wstrb),
          .wvalid (m_axi_wvalid), .wready (m_axi_wready),
          .bvalid (m_axi_bvalid), .bready (m_axi_bready),
          .araddr (m_axi_araddr), .arvalid (m_axi_arvalid), .arready (m_axi_arready),
          .rdata_axi (m_axi_rdata), .rvalid (m_axi_rvalid), .rready (m_axi_rready)
      );
    end else begin : g_bram
      sync_ram #(.AW (RAM_AW)) u_ram (
          .clk (clk), .en (1'b1), .addr (phys[RAM_AW-1:0]),
          .wdata (mem_wdata), .we (mem_wr_eff && (clk_en || dma_req)),
          .rdata (ram_rdata)
      );
    end
  endgenerate

  // ------------------------------------------------------------------ the ports
  logic [7:0] uart_rdata;
  logic       uart_hit;

  uart #(.CLK_HZ (CLK_HZ), .BAUD (BAUD), .CONSOLE_SSER (CONSOLE_SSER)) u_uart (
      .clk (clk), .rst_n (rst_n),
      .port_addr (a[7:0]), .port_wdata (dout),
      .port_wr (port_wr && clk_en), .port_rd (port_rd && clk_en),
      .port_rdata (uart_rdata), .port_hit (uart_hit),
      .rx (uart_rx), .tx (uart_tx)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) led <= 8'h00;
    else if (port_wr && clk_en && a[7:0] == 8'hFF) led <= dout;
  end

  // ------------------------------------------------------------------- HDSK
  generate
    if (USE_HDSK) begin : g_hdsk
      logic [8:0] sdb_addr;
      logic [7:0] sdb_wdata, sdb_rdata;
      logic       sdb_we, sd_rd, sd_wr, sd_busy, sd_err, sd_rdy;
      logic [31:0] sd_lba;

      // The memory answers a DMA byte in one clock when it is block RAM and
      // when ram_ready says so for DDR2.
      logic dma_req_d;
      always_ff @(posedge clk) dma_req_d <= dma_req;
      assign dma_ack = !dma_req                      ? 1'b0
                     : (!sel_rom && USE_DDR2)        ? ram_ready
                                                     : dma_req_d;

      hdsk u_hdsk (
          .clk (clk), .rst_n (rst_n),
          .port_addr (a[7:0]), .port_wdata (dout),
          // Both strobes are gated by clk_en so every path from the core into
          // this block is launched and captured on enable ticks, which is what
          // makes the twelve-cycle exception on them legitimate.  The reply is
          // still in time: io_wait rises one clock later, and the core does not
          // re-examine wait_n until its next enable tick, twelve clocks away.
          .port_wr (port_wr && clk_en), .port_rd (port_rd && clk_en),
          .port_rdata (hdsk_rdata), .port_hit (hdsk_hit), .io_wait (hdsk_wait),
          .dma_req (dma_req), .dma_we (dma_we), .dma_addr (dma_addr),
          .dma_wdata (dma_wdata), .dma_rdata (dma_rdata), .dma_ack (dma_ack),
          .sd_start_rd (sd_rd), .sd_start_wr (sd_wr), .sd_lba (sd_lba),
          .sd_busy (sd_busy), .sd_err (sd_err), .sd_ready (sd_rdy),
          .sd_buf_addr (sdb_addr), .sd_buf_wdata (sdb_wdata),
          .sd_buf_we (sdb_we), .sd_buf_rdata (sdb_rdata)
      );

      sd_spi #(.CLK_HZ (CLK_HZ)) u_sd (
          .clk (clk), .rst_n (rst_n),
          .start_rd (sd_rd), .start_wr (sd_wr), .lba (sd_lba),
          .busy (sd_busy), .err (sd_err), .ready (sd_rdy),
          .buf_addr (sdb_addr), .buf_wdata (sdb_wdata), .buf_we (sdb_we),
          .buf_rdata (sdb_rdata),
          .sd_sck (sd_sck), .sd_mosi (sd_mosi), .sd_miso (sd_miso),
          .sd_cs (sd_cs)
      );
    end else begin : g_nohdsk
      assign hdsk_rdata = 8'hFF;
      assign hdsk_hit   = 1'b0;
      assign hdsk_wait  = 1'b0;
      assign dma_req    = 1'b0;
      assign dma_we     = 1'b0;
      assign dma_addr   = 16'd0;
      assign dma_wdata  = 8'd0;
      assign dma_ack    = 1'b0;
      assign sd_sck     = 1'b0;
      assign sd_mosi    = 1'b1;
      assign sd_cs      = 1'b1;
    end
  endgenerate

  // ------------------------------------------------------------- read data mux
  logic [7:0] port_rdata;
  always_comb begin
    if (uart_hit)                port_rdata = uart_rdata;
    else if (hdsk_hit)           port_rdata = hdsk_rdata;
    else if (mmu_hit)            port_rdata = mmu_rdata;
    else if (a[7:0] == 8'hFF)    port_rdata = sw;
    else                         port_rdata = 8'hFF;
  end

  assign din = !iorq_n    ? port_rdata
             : !bank_valid ? 8'hFF
             : sel_rom     ? rom_rdata
                           : ram_rdata;

  // pins this SoC has no use for, tied off so lint does not complain
  logic unused;
  assign unused = &{1'b0, halt_n, rfsh_n, busak_n, phys[18:15]};

endmodule

`endif
