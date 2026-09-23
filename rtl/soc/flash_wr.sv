// Write one byte into the configuration flash, so a board with no console
// can still say something a host can read.
//
// The Tang Nano's UART bridge dies and stays dead, and its LEDs need a pair
// of eyes.  What it still has is the SPI flash it configures from:
// `gowin_pack --mspi_as_gpio` hands those pins to user logic after
// configuration, and `openFPGALoader --dump-flash` reads them back.  A byte
// written here comes off the board over JTAG.
//
// Deliberately minimal, because this drives the pins the board boots from:
//
//   * It can only Page Program (02h).  There is no erase command anywhere in
//     it, so the worst it can do is clear bits in one page.
//   * The address comes in with the byte and is latched at start.  Point it
//     well past the bitstream, which is about 7.3 MB; 7F0000h upwards reads
//     back all FFh on this board, so those pages are erased and a program
//     lands cleanly.  A page program can only clear bits, so every distinct
//     answer wants its own page.
//   * It ignores MI entirely and never polls the status register.  The gap
//     after the program is a fixed wait, longer than any page-program time
//     in the datasheets, because nothing here is in a hurry.
//
// SPI mode 0: MOSI is set while SCLK is low, and the flash samples it on the
// rising edge.
module flash_wr #(
    parameter int          HALF = 8            // SCLK half period, in clocks
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,                 // one clock wide
    input  logic [23:0] addr,                  // latched at start
    input  logic  [7:0] data,
    output logic       cs_n,
    output logic       sclk,
    output logic       mosi,
    output logic       busy
);

  localparam int CW = $clog2(HALF);

  // Reset it.  Without that it starts x, x + 1 is x forever, tick never
  // fires and the whole thing sits in state 1 looking alive.
  logic [CW-1:0] hc;
  wire           tick = (hc == CW'(HALF - 1));
  always_ff @(posedge clk)
    if (!rst_n) hc <= '0;
    else        hc <= tick ? '0 : hc + 1'b1;

  logic [47:0] sr;          // 06h, or 02h + 24-bit address + the byte
  logic  [5:0] left;
  logic  [2:0] st;
  logic [19:0] gap;
  logic        phase;       // 0 = write enable, 1 = page program
  logic  [7:0] hold;
  logic [23:0] hold_a;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st    <= 3'd0;
      cs_n  <= 1'b1;
      sclk  <= 1'b0;
      mosi  <= 1'b0;
      busy  <= 1'b0;
      phase <= 1'b0;
    end else begin
      case (st)
        3'd0: begin                               // idle
          cs_n <= 1'b1;
          sclk <= 1'b0;
          if (start) begin
            hold   <= data;
            hold_a <= addr;
            sr    <= {8'h06, 40'h0};              // WREN
            left  <= 6'd8;
            phase <= 1'b0;
            busy  <= 1'b1;
            st    <= 3'd1;
          end else begin
            busy <= 1'b0;
          end
        end

        3'd1: if (tick) begin                     // select, present the first bit
          cs_n <= 1'b0;
          mosi <= sr[47];
          st   <= 3'd2;
        end

        3'd2: if (tick) begin                     // rising edge: the flash samples
          sclk <= 1'b1;
          st   <= 3'd3;
        end

        3'd3: if (tick) begin                     // falling edge: next bit out
          sclk <= 1'b0;
          sr   <= {sr[46:0], 1'b0};
          left <= left - 1'b1;
          if (left == 6'd1) begin
            st <= 3'd4;
          end else begin
            mosi <= sr[46];
            st   <= 3'd2;
          end
        end

        3'd4: if (tick) begin                     // deselect
          cs_n <= 1'b1;
          gap  <= '0;
          st   <= 3'd5;
        end

        3'd5: begin                               // wait, then the next phase
          gap <= gap + 1'b1;
          if (&gap) begin
            if (!phase) begin
              // left-aligned: the shifter sends sr[47] first, so the
              // payload has to sit at the top or a zero byte goes out ahead
              // of the command
              sr    <= {8'h02, hold_a, hold, 8'h00};  // page program, one byte
              left  <= 6'd40;
              phase <= 1'b1;
              st    <= 3'd1;
            end else begin
              st <= 3'd0;
            end
          end
        end

        default: st <= 3'd0;
      endcase
    end
  end
endmodule
