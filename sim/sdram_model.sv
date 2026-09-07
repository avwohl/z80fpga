// A behavioural MT48LC16M16-alike, for testing rtl/mem/sdram_ram.sv.
//
// The point of a model rather than a plain array is that it is unforgiving:
// it decodes the command bus the way the chip does and stops the simulation
// on anything the chip would have quietly turned into garbage.  A controller
// that reads before tRCD, or reads a bank it never opened, or lets a row go
// unrefreshed, fails here loudly instead of on the bench intermittently.
//
// Modelled: the power-up sequence, the mode register, ACTIVE / READ / WRITE /
// PRECHARGE / AUTO REFRESH, CAS latency, auto-precharge on A10, DQM byte
// masking, tRCD, tRP and tRC, and the refresh interval.  Not modelled: bursts
// longer than one (the controller programmes length 1 and the model insists
// on it), power-down, self-refresh, and CKE ever being low.
//
// ROWS is how many rows the model actually has, and it is deliberately NOT
// the chip's 8192 by default -- 32 MB of storage is more than a simulation
// wants, and a controller that presents a row outside the window it is
// supposed to address has a decode bug that this turns into a failure rather
// than into silent aliasing.  Give it the number of rows the design can
// really reach and no more.

`timescale 1ns/1ps

module sdram_model #(
    parameter int ROWS    = 128,      // rows modelled; see above
    parameter int COLS    = 512,
    parameter int T_RCD   = 20,       // ns
    parameter int T_RP    = 20,
    parameter int T_RC    = 66,
    parameter int T_REFI  = 7800,     // ns per row refresh interval
    parameter bit CHECK_REFRESH = 1'b1
) (
    input  logic        clk,          // the chip's own clock
    input  logic        cke,
    input  logic        cs_n,
    input  logic        ras_n,
    input  logic        cas_n,
    input  logic        we_n,
    input  logic [12:0] a,
    input  logic  [1:0] ba,
    input  logic  [1:0] dqm,
    input  logic [15:0] dq_in,
    input  logic        dq_oe,        // the controller is driving dq
    output logic [15:0] dq_out,
    output logic        dq_drive
);

  localparam int WORDS = 4 * ROWS * COLS;

  // ------------------------------------------------------------------ state
  logic [15:0] mem [0:WORDS-1];

  logic        initialised = 1'b0;
  integer      cas_lat     = 0;

  logic        row_open [0:3];
  logic [12:0] open_row [0:3];
  time         act_time [0:3];             // when the row was opened
  time         pre_time [0:3];             // when the bank was last precharged
  time         last_refresh;

  integer      init_pre = 0, init_ref = 0;

  // Read pipeline: a word becomes visible cas_lat chip clocks after the READ.
  logic [15:0] rd_pipe [0:7];
  logic        rd_val  [0:7];

  integer      i, k;
  integer      widx;
  logic [15:0] cur;

  initial begin
    for (i = 0; i < 4; i = i + 1) begin
      row_open[i] = 1'b0;
      open_row[i] = 13'd0;
      act_time[i] = 0;
      pre_time[i] = 0;
    end
    for (i = 0; i < 8; i = i + 1) begin
      rd_pipe[i] = 16'h0000;
      rd_val[i]  = 1'b0;
    end
    for (i = 0; i < WORDS; i = i + 1) mem[i] = 16'h0000;
    last_refresh = 0;
  end

  assign dq_out   = rd_pipe[0];
  assign dq_drive = rd_val[0];

  // --------------------------------------------------------------- commands
  localparam logic [3:0] C_NOP     = 4'b0111;
  localparam logic [3:0] C_ACTIVE  = 4'b0011;
  localparam logic [3:0] C_READ    = 4'b0101;
  localparam logic [3:0] C_WRITE   = 4'b0100;
  localparam logic [3:0] C_PRE     = 4'b0010;
  localparam logic [3:0] C_REFRESH = 4'b0001;
  localparam logic [3:0] C_MRS     = 4'b0000;

  wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};

  task automatic die(input [8*64-1:0] why);
    begin
      $display("FAIL: sdram_model at %0t: %0s", $time, why);
      $finish;
    end
  endtask

  always @(posedge clk) begin
    if (cke !== 1'b1) die("CKE is not high");

    // advance the CAS pipeline
    for (k = 0; k < 7; k = k + 1) begin
      rd_pipe[k] = rd_pipe[k+1];
      rd_val[k]  = rd_val[k+1];
    end
    rd_val[7] = 1'b0;

    if (cs_n === 1'b0) begin
      case (cmd)
        C_NOP: ;

        C_MRS: begin
          if (init_pre == 0 || init_ref < 2)
            die("LOAD MODE REGISTER before PRECHARGE ALL and two AUTO REFRESH");
          if (a[2:0] !== 3'b000) die("burst length is not 1");
          if (a[3]   !== 1'b0)   die("burst type is not sequential");
          if (a[6:4] !== 3'd2 && a[6:4] !== 3'd3) die("CAS latency is not 2 or 3");
          cas_lat     = a[6:4];
          initialised = 1'b1;
        end

        C_PRE: begin
          if (a[10]) begin                       // precharge all
            init_pre = init_pre + 1;
            for (k = 0; k < 4; k = k + 1) begin
              row_open[k] = 1'b0;
              pre_time[k] = $time;
            end
          end else begin
            row_open[ba] = 1'b0;
            pre_time[ba] = $time;
          end
        end

        C_REFRESH: begin
          for (k = 0; k < 4; k = k + 1)
            if (row_open[k]) die("AUTO REFRESH with a row still open");
          init_ref     = init_ref + 1;
          last_refresh = $time;
        end

        C_ACTIVE: begin
          if (!initialised) die("ACTIVE before the mode register was loaded");
          if (row_open[ba]) die("ACTIVE on a bank that is already open");
          if ($time - pre_time[ba] < T_RP) die("ACTIVE too soon after PRECHARGE (tRP)");
          if (act_time[ba] != 0 && $time - act_time[ba] < T_RC)
            die("ACTIVE to ACTIVE on the same bank inside tRC");
          if (a >= ROWS) die("row address outside the modelled window");
          row_open[ba] = 1'b1;
          open_row[ba] = a;
          act_time[ba] = $time;
        end

        C_READ, C_WRITE: begin
          if (!initialised)  die("column command before the mode register was loaded");
          if (!row_open[ba]) die("column command on a bank with no open row");
          if ($time - act_time[ba] < T_RCD) die("column command inside tRCD");
          if (a[8:0] >= COLS) die("column address out of range");

          widx = ((ba * ROWS) + open_row[ba]) * COLS + a[8:0];

          if (cmd == C_WRITE) begin
            if (dq_oe !== 1'b1) die("WRITE with the controller not driving DQ");
            cur = mem[widx];
            if (!dqm[0]) cur[7:0]  = dq_in[7:0];
            if (!dqm[1]) cur[15:8] = dq_in[15:8];
            mem[widx] = cur;
          end else begin
            rd_pipe[cas_lat] = mem[widx];
            rd_val[cas_lat]  = 1'b1;
          end

          if (a[10]) begin                       // auto precharge
            row_open[ba] = 1'b0;
            pre_time[ba] = $time;
          end
        end

        default: die("unknown command on the bus");
      endcase
    end

    if (CHECK_REFRESH && initialised && last_refresh != 0 &&
        $time - last_refresh > T_REFI * 4)
      die("no AUTO REFRESH for four refresh intervals");
  end

endmodule
