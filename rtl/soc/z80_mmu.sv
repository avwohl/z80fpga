// RomWBW-compatible banked memory manager.
//
// The scheme is the one avwohl/romwbw_emu emulates and the RomWBW SBC/MBC
// boards implement in hardware, so a ROM image built for those boots here
// unchanged:
//
//   * 32 KB banks.  Bank id bit 7 picks the space - 0x00..0x0F are ROM banks,
//     0x80..0x8F are RAM banks.
//   * The CPU's low 32 KB window shows the selected bank; the high 32 KB
//     always shows the common bank, which is the highest RAM bank - 0x8F on
//     a full 16-bank build, and COMMON_BANK on a smaller one.
//   * Writing port 0x78 or 0x7C selects a bank; reading either returns the
//     current selection.
//
// After reset the low window shows ROM bank 0, which is where the CPU starts.
//
// ROM_BANKS and RAM_BANKS trade capacity against block RAM.  A part with room
// for the full 512 KB + 512 KB takes 16 and 16; an iCE40UP5K takes 4 RAM banks
// in its SPRAM and however much ROM its EBRs can hold.

`ifndef Z80_MMU_SV
`define Z80_MMU_SV

module z80_mmu #(
    parameter int ROM_BANKS = 16,
    parameter int RAM_BANKS = 16,
    parameter logic [7:0] COMMON_BANK = 8'h80 | 8'(RAM_BANKS - 1),
    parameter logic [7:0] RESET_BANK  = 8'h00
) (
    input  logic        clk,
    input  logic        rst_n,

    // CPU side
    input  logic [15:0] cpu_addr,
    input  logic  [7:0] port_addr,
    input  logic  [7:0] port_wdata,
    input  logic        port_wr,
    output logic  [7:0] port_rdata,
    output logic        port_hit,

    // memory side
    output logic [18:0] phys_addr,     // byte address inside the chosen space
    output logic        sel_rom,
    output logic        bank_valid     // 0 when the id names a bank we lack
);

  logic [7:0] cur_bank;
  logic [7:0] bank;

  always_ff @(posedge clk) begin
    if (!rst_n)
      cur_bank <= RESET_BANK;
    else if (port_wr && ((port_addr == 8'h78) || (port_addr == 8'h7C)))
      cur_bank <= port_wdata;
  end

  // low 32 KB is banked, high 32 KB is the common bank
  assign bank       = cpu_addr[15] ? COMMON_BANK : cur_bank;
  assign sel_rom    = ~bank[7];
  assign phys_addr  = {bank[3:0], cpu_addr[14:0]};
  assign bank_valid = sel_rom ? (bank[3:0] < ROM_BANKS[3:0] || ROM_BANKS == 16)
                              : (bank[3:0] < RAM_BANKS[3:0] || RAM_BANKS == 16);

  assign port_hit   = (port_addr == 8'h78) || (port_addr == 8'h7C);
  assign port_rdata = cur_bank;

endmodule

`endif
