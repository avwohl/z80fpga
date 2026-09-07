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
    parameter bit FLOW_CTRL  = 1'b0,        // RTS/CTS on the console
    parameter bit USE_HDSK   = 1'b0,        // SIMH HDSK on port 0xFD, backed by microSD
    // How sd_spi shapes its sector buffer.  The default is the portable one;
    // rtl/soc/sd_spi.sv says at length why the Nexys RomWBW build is the
    // exception and pins it to 0.
    parameter bit SD_BUF_MUX = 1'b1,
    parameter bit USE_DDR2   = 1'b0,        // RAM banks live in DDR2, not block RAM
    parameter int DDR2_BASE  = 0,           // byte offset of the RAM in DDR2
    parameter bit USE_SDRAM  = 1'b0,        // RAM banks live in SDR SDRAM
    // The ROM banks live in SDRAM too, staged off the microSD at power-up by
    // rtl/soc/rom_loader.sv.  Needs USE_SDRAM and USE_HDSK: the loader shares
    // the latter's sd_spi.  With this set, ROM_INIT is not used -- the image
    // comes from the card, not from the bitstream.
    parameter bit SDRAM_ROM  = 1'b0,
    parameter logic [31:0] ROM_LBA = 32'h0040_0000,   // its first block
    parameter int ROM_BLOCKS = 1024,                  // 512 KB of it
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
    input  logic       uart_cts_n,        // board pin uart_rts
    output logic       uart_rts_n,        // board pin uart_cts
    output logic [7:0] led,
    input  logic [7:0] sw,

    // AXI4 to the MIG.  Meaningful only when USE_DDR2, tied off otherwise, so
    // a board that does not use them can leave them unconnected.
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

    // SDR SDRAM.  Meaningful only when USE_SDRAM, tied off otherwise.  DQ is
    // split rather than being an inout so that the tristate stays in the board
    // top, where the pad is.
    output logic [12:0]  sdram_a,
    output logic  [1:0]  sdram_ba,
    output logic  [1:0]  sdram_dqm,
    output logic         sdram_cs_n,
    output logic         sdram_ras_n,
    output logic         sdram_cas_n,
    output logic         sdram_we_n,
    output logic         sdram_cke,
    output logic [15:0]  sdram_dq_o,
    output logic         sdram_dq_oe,
    input  logic [15:0]  sdram_dq_i,
    // The chip's power-up sequence has finished.  Nothing has to wait for it --
    // an access before then simply holds wait_n low -- but it is the first
    // thing worth putting on an LED if a board is mute.  High when there is no
    // SDRAM to initialise.
    output logic         sdram_init_done,
    // The staged ROM is in memory (rom_done) or never will be (rom_failed).
    // Both low means the card has not come up yet.  High and low respectively
    // when there is no staging to do.
    output logic         rom_done,
    output logic         rom_failed,

    output logic [26:0]  m_axi_araddr,
    output logic         m_axi_arvalid,
    input  logic         m_axi_arready,
    input  logic [127:0] m_axi_rdata,
    input  logic         m_axi_rvalid,
    output logic         m_axi_rready
);

  localparam int ROM_AW = (ROM_AW_P != 0) ? ROM_AW_P : 15 + $clog2(ROM_BANKS);
  localparam int RAM_AW = (RAM_AW_P != 0) ? RAM_AW_P : 15 + $clog2(RAM_BANKS);

  // With the ROM in the chip as well, the physical address grows the bit that
  // says which of the two spaces it is: ROM at the bottom of the megabyte,
  // RAM at the top.
  localparam int SDRAM_AW = SDRAM_ROM ? 20 : RAM_AW;

  // synthesis translate_off
  initial if (SDRAM_ROM && !(USE_SDRAM && USE_HDSK))
    $fatal(1, "z80_soc: SDRAM_ROM needs USE_SDRAM and USE_HDSK -- the loader stages into the one and shares the other's sd_spi");
  // synthesis translate_on

  // The loader's side of the memory, and its two flags.  Tied off below when
  // there is no loader.
  logic          ldr_req, ldr_we;
  logic [19:0]   ldr_addr;
  logic  [7:0]   ldr_wdata;
  logic          loading;

  assign loading = SDRAM_ROM && !rom_done;

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
  // real slow memory attached.  A bank in DDR2 or in SDRAM drives the same
  // signal from its own ready instead.
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
    if (USE_DDR2 || USE_SDRAM) begin : g_ddrwait
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
    if (!USE_DDR2 && !USE_SDRAM) begin : g_noready
      assign ram_ready = 1'b1;
    end
  endgenerate

  // The core, and only the core, waits for the staged ROM.  Everything else
  // comes out of reset with the rest of the design: the loader needs sd_spi
  // running, and hdsk cannot do anything until a port write reaches it, which
  // cannot happen while this is low.
  logic core_rst_n;
  assign core_rst_n = rst_n && rom_done;

  z80_core #(
      .UCODE_MEM (UCODE_MEM),
      .DISP_MEM  (DISP_MEM)
  ) u_cpu (
      .clk (clk), .rst_n (core_rst_n), .clk_en (clk_en),
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
  // !sel_rom on both arms, not just the CPU's.  A DMA write while a ROM bank
  // is selected has no business landing anywhere, and with the ROM in SDRAM
  // it would be overwriting the firmware rather than merely shadowing it.
  // Unreachable before this: the only build with a DMA had its RAM in DDR2,
  // whose req is ram_cycle, which did carry the guard.
  assign mem_wr_eff = (dma_req ? dma_we : mem_we) && !sel_rom;
  assign mem_wdata  = dma_req ? dma_wdata : dout;
  assign dma_rdata  = (sel_rom && !SDRAM_ROM) ? rom_rdata : ram_rdata;

  // With the ROM in the chip, every memory cycle is a cycle of the one memory,
  // so sel_rom stops excusing anything from it.
  assign ram_cycle = dma_req ? (SDRAM_ROM || !sel_rom)
                             : (!mreq_n && (!rd_n || !wr_n) &&
                                (SDRAM_ROM || !sel_rom));

  // ROM at the bottom of the megabyte, RAM at the top.  Without SDRAM_ROM the
  // top bit is not there and this is the plain physical address.
  logic [19:0] sdram_addr;
  assign sdram_addr = {SDRAM_ROM ? ~sel_rom : 1'b0, phys[18:0]};

  // The block RAM ROM is always instantiated, and shrunk to two bytes rather
  // than removed when the image lives in the SDRAM instead.  Removing it would
  // mean a generate block, which puts that block's name into every cell
  // underneath it -- and the Nexys RomWBW build's ROM is 128 RAMB36 tiles that
  // Vivado cascades in pairs, which is delicate enough already.  Two bytes
  // costs nothing and leaves that build's hierarchy exactly as it was.
  localparam int ROM_INST_AW = SDRAM_ROM ? 1 : ROM_AW;

  sync_ram #(.AW (ROM_INST_AW), .READ_ONLY (1'b1), .INIT_FILE (ROM_INIT)) u_rom (
      .clk (clk), .en (1'b1), .addr (phys[ROM_INST_AW-1:0]),
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
    end else if (USE_SDRAM) begin : g_sdram
      // Same bargain as the DDR2 bank and for the same reason: the chip cannot
      // answer in a T-state, so it holds wait_n low until it has.  The request
      // is the ungated bus cycle here too.
      // While the loader is running it owns the port outright.  Nothing else
      // wants it: the core is in reset and hdsk answers only the core.
      sdram_ram #(.CLK_HZ (CLK_HZ), .AW (SDRAM_AW)) u_ram (
          .clk (clk), .rst_n (rst_n),
          .req   (loading ? ldr_req   : ram_cycle),
          .we    (loading ? ldr_we    : mem_wr_eff),
          .addr  (loading ? SDRAM_AW'(ldr_addr) : sdram_addr[SDRAM_AW-1:0]),
          .wdata (loading ? ldr_wdata : mem_wdata),
          .rdata (ram_rdata), .ready (ram_ready), .init_done (sdram_init_done),
          .sd_a (sdram_a), .sd_ba (sdram_ba), .sd_dqm (sdram_dqm),
          .sd_cs_n (sdram_cs_n), .sd_ras_n (sdram_ras_n),
          .sd_cas_n (sdram_cas_n), .sd_we_n (sdram_we_n), .sd_cke (sdram_cke),
          .sd_dq_o (sdram_dq_o), .sd_dq_oe (sdram_dq_oe), .sd_dq_i (sdram_dq_i)
      );
    end else begin : g_bram
      sync_ram #(.AW (RAM_AW)) u_ram (
          .clk (clk), .en (1'b1), .addr (phys[RAM_AW-1:0]),
          .wdata (mem_wdata), .we (mem_wr_eff && (clk_en || dma_req)),
          .rdata (ram_rdata)
      );
    end

    if (!USE_DDR2) begin : g_noddr2
      assign m_axi_awaddr  = 27'd0;
      assign m_axi_awvalid = 1'b0;
      assign m_axi_wdata   = 128'd0;
      assign m_axi_wstrb   = 16'd0;
      assign m_axi_wvalid  = 1'b0;
      assign m_axi_bready  = 1'b0;
      assign m_axi_araddr  = 27'd0;
      assign m_axi_arvalid = 1'b0;
      assign m_axi_rready  = 1'b0;
    end

    if (!USE_SDRAM) begin : g_nosdram
      assign sdram_a         = 13'd0;
      assign sdram_ba        = 2'd0;
      assign sdram_dqm       = 2'b11;
      assign sdram_cs_n      = 1'b1;
      assign sdram_ras_n     = 1'b1;
      assign sdram_cas_n     = 1'b1;
      assign sdram_we_n      = 1'b1;
      assign sdram_cke       = 1'b0;
      assign sdram_dq_o      = 16'd0;
      assign sdram_dq_oe     = 1'b0;
      assign sdram_init_done = 1'b1;
    end
  endgenerate

  // ------------------------------------------------------------------ the ports
  logic [7:0] uart_rdata;
  logic       uart_hit;

  uart #(.CLK_HZ (CLK_HZ), .BAUD (BAUD), .CONSOLE_SSER (CONSOLE_SSER),
         .FLOW_CTRL (FLOW_CTRL)) u_uart (
      .clk (clk), .rst_n (rst_n),
      .port_addr (a[7:0]), .port_wdata (dout),
      .port_wr (port_wr && clk_en), .port_rd (port_rd && clk_en),
      .port_rdata (uart_rdata), .port_hit (uart_hit),
      .rx (uart_rx), .tx (uart_tx),
      .cts_n (uart_cts_n), .rts_n (uart_rts_n)
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
      logic [7:0] sd_dbg;
      logic [4:0] sd_dbg_state;
      logic [31:0] sd_lba;

      // The memory answers a DMA byte in one clock when it is block RAM, and
      // when ram_ready says so when it is off-chip.
      logic dma_req_d;
      always_ff @(posedge clk) dma_req_d <= dma_req;
      assign dma_ack = !dma_req ? 1'b0
                     : ((SDRAM_ROM || !sel_rom) && (USE_DDR2 || USE_SDRAM))
                         ? ram_ready
                         : dma_req_d;

      hdsk u_hdsk (
          .clk (clk), .rst_n (rst_n),
          .port_addr (a[7:0]), .port_wdata (dout),
          // Both strobes are gated by clk_en so every path from the core into
          // this block is launched and captured on enable ticks, which is what
          // makes the twelve-cycle exception on them legitimate.  The reply is
          // still in time: io_wait rises one clock later, and the core does not
          // re-examine wait_n until its next enable tick, twelve clocks away.
          .port_wr (port_wr && clk_en), .port_active (port_wr),
          .port_rd (port_rd && clk_en), .port_rd_active (port_rd),
          .port_rdata (hdsk_rdata), .port_hit (hdsk_hit), .io_wait (hdsk_wait),
          .dma_req (dma_req), .dma_we (dma_we), .dma_addr (dma_addr),
          .dma_wdata (dma_wdata), .dma_rdata (dma_rdata), .dma_ack (dma_ack),
          .sd_start_rd (sd_rd), .sd_start_wr (sd_wr), .sd_lba (sd_lba),
          .sd_busy (sd_busy), .sd_err (sd_err), .sd_ready (sd_rdy),
          .sd_dbg (sd_dbg), .sd_dbg_state (sd_dbg_state),
          .sd_buf_addr (sdb_addr), .sd_buf_wdata (sdb_wdata),
          .sd_buf_we (sdb_we), .sd_buf_rdata (sdb_rdata)
      );

      // ------------------------------------------------- staging the ROM
      // The loader and hdsk share one sd_spi, and the handover needs no
      // arbitration because it is not a handover: the loader runs to
      // completion while the core is in reset, and hdsk cannot ask for
      // anything until the core is out of it.  `loading` is that boundary.
      logic  [8:0] ldr_bufa;
      logic        ldr_rd;
      logic [31:0] ldr_lba;

      if (SDRAM_ROM) begin : g_loader
        rom_loader #(
            .BLOCKS (ROM_BLOCKS), .LBA (ROM_LBA), .AW (20)
        ) u_loader (
            .clk (clk), .rst_n (rst_n),
            .done (rom_done), .failed (rom_failed),
            .sd_start_rd (ldr_rd), .sd_lba (ldr_lba),
            .sd_busy (sd_busy), .sd_err (sd_err), .sd_ready (sd_rdy),
            .sd_buf_addr (ldr_bufa), .sd_buf_rdata (sdb_rdata),
            .mem_req (ldr_req), .mem_we (ldr_we), .mem_addr (ldr_addr),
            .mem_wdata (ldr_wdata), .mem_ready (ram_ready)
        );
      end else begin : g_noloader
        assign rom_done   = 1'b1;
        assign rom_failed = 1'b0;
        assign ldr_rd     = 1'b0;
        assign ldr_lba    = 32'd0;
        assign ldr_bufa   = 9'd0;
        assign ldr_req    = 1'b0;
        assign ldr_we     = 1'b0;
        assign ldr_addr   = 20'd0;
        assign ldr_wdata  = 8'd0;
      end

      sd_spi #(.CLK_HZ (CLK_HZ), .BUF_MUX (SD_BUF_MUX)) u_sd (
          .clk (clk), .rst_n (rst_n),
          .start_rd (loading ? ldr_rd  : sd_rd),
          .start_wr (loading ? 1'b0    : sd_wr),
          .lba      (loading ? ldr_lba : sd_lba),
          .busy (sd_busy), .err (sd_err), .ready (sd_rdy), .dbg (sd_dbg), .dbg_state (sd_dbg_state),
          .buf_addr  (loading ? ldr_bufa : sdb_addr),
          .buf_wdata (sdb_wdata),
          .buf_we    (loading ? 1'b0 : sdb_we),
          .buf_rdata (sdb_rdata),
          .sd_sck (sd_sck), .sd_mosi (sd_mosi), .sd_miso (sd_miso),
          .sd_cs (sd_cs)
      );
    end else begin : g_nohdsk
      assign rom_done   = 1'b1;
      assign rom_failed = 1'b0;
      assign ldr_req    = 1'b0;
      assign ldr_we     = 1'b0;
      assign ldr_addr   = 20'd0;
      assign ldr_wdata  = 8'd0;
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

  assign din = !iorq_n                   ? port_rdata
             : !bank_valid               ? 8'hFF
             : (sel_rom && !SDRAM_ROM)   ? rom_rdata
                                         : ram_rdata;

  // pins this SoC has no use for, tied off so lint does not complain
  logic unused;
  assign unused = &{1'b0, halt_n, rfsh_n, busak_n, phys[18:15]};

endmodule

`endif
