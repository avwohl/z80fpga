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
    input  logic [7:0] sw
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

  z80_core #(
      .UCODE_MEM (UCODE_MEM),
      .DISP_MEM  (DISP_MEM)
  ) u_cpu (
      .clk (clk), .rst_n (rst_n), .clk_en (clk_en),
      .a (a), .din (din), .dout (dout),
      .mreq_n (mreq_n), .iorq_n (iorq_n), .rd_n (rd_n), .wr_n (wr_n),
      .m1_n (m1_n), .rfsh_n (rfsh_n), .halt_n (halt_n), .busak_n (busak_n),
      .wait_n (1'b1), .int_n (1'b1), .nmi_n (1'b1), .busrq_n (1'b1)
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
      .cpu_addr (a), .port_addr (a[7:0]), .port_wdata (dout),
      .port_wr (port_wr && clk_en),
      .port_rdata (mmu_rdata), .port_hit (mmu_hit),
      .phys_addr (phys), .sel_rom (sel_rom), .bank_valid (bank_valid)
  );

  // ----------------------------------------------------------------- the memory
  logic [7:0] rom_rdata, ram_rdata;
  logic       mem_we;

  assign mem_we = !mreq_n && !wr_n;

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
    end else begin : g_bram
      sync_ram #(.AW (RAM_AW)) u_ram (
          .clk (clk), .en (1'b1), .addr (phys[RAM_AW-1:0]),
          .wdata (dout), .we (mem_we && !sel_rom && clk_en), .rdata (ram_rdata)
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

  // ------------------------------------------------------------- read data mux
  logic [7:0] port_rdata;
  always_comb begin
    if (uart_hit)                port_rdata = uart_rdata;
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
