// The debug unit's JTAG byte link (rtl/soc/dbg_jtag_link.sv) alone, with a
// host that scans the data register the way a TAP would: Select-DR, Capture-DR,
// ten Shift-DR, Exit1-DR, Update-DR, then some Run-Test/Idle cycles, with tck
// low between states and the host changing tdi and the state while it is low.
//
// Four fixtures run side by side, each with its own clock of the unit, its own
// TCK and its own copy of the link, so TCK is faster than the clock in two of
// them and slower in two:
//   fast6     clk 1 MHz,         TCK 5.88 MHz   (TCK about 6x faster)
//   fillbox   clk 270 kHz,       TCK 10 MHz     (TCK 37x faster: the host
//                                                mailbox is still full when
//                                                the next scan captures)
//   board     clk 81.25 MHz,     TCK 6 MHz      (the Nexys build)
//   close     clk 58.8 MHz,      TCK 43.5 MHz   (nearly the same rate)
//
// Each fixture runs directed tests, then a random run of NB bytes each way
// with the unit's side sending at random times and the host sending in
// batches of 1 to 5 scans.  The rules of the file header are the model of the
// bench: expected RJ and FV are computed from the link's own handshake state
// seen from outside the scan (hierarchical reads of the TCK-domain flops), and
// every byte is compared in order, so a byte lost, duplicated or changed in
// either direction fails.
//
// Time is in ps.

`timescale 1ps/1ps

module jl_fix #(
    parameter int CLKP = 1000000,
    parameter int TCKP = 170000,
    parameter int NB   = 600,
    parameter int SEED = 1,
    parameter bit EXPECT_FULL = 1'b0,        // the mailbox must be seen full
    parameter string NAME = "x"
) (
    output int  nerr,
    output int  nchk,
    output int  nfull,                       // rejects because the mailbox was full
    output int  nsticky,                     // rejects because of the sticky flag
    output int  nrx,                         // bytes host to FPGA
    output int  ntx,                         // bytes FPGA to host
    output logic done
);

  logic clk = 0, tck = 0, rst_n = 0;
  logic rx_valid;
  logic [7:0] rx_data;
  logic tx_start = 0;
  logic [7:0] tx_data = 8'h00;
  logic tx_busy;
  logic sel = 1, capture = 0, shift = 0, update = 0, tdi = 0, treset = 0, tdo;

  dbg_jtag_link dut (
      .clk (clk), .rst_n (rst_n),
      .rx_valid (rx_valid), .rx_data (rx_data),
      .tx_start (tx_start), .tx_data (tx_data), .tx_busy (tx_busy),
      .tck (tck), .sel (sel), .capture (capture), .shift (shift),
      .update (update), .tdi (tdi), .reset (treset), .tdo (tdo)
  );

  always begin #(CLKP / 2) clk = 1; #(CLKP - CLKP / 2) clk = 0; end

  int errs = 0, checks = 0, n_full = 0, n_sticky = 0;
  assign nerr = errs, nchk = checks, nfull = n_full, nsticky = n_sticky;

  task automatic chk(input bit ok, input string msg);
    begin
      checks++;
      if (!ok) begin
        errs++;
        if (errs <= 10) $display("FAIL [%s] t=%0t: %s", NAME, $time, msg);
      end
    end
  endtask

  logic [31:0] rs = 32'd2463534242 + SEED;
  function automatic int rnd(input int n);
    begin
      rs = rs ^ (rs << 13);
      rs = rs ^ (rs >> 17);
      rs = rs ^ (rs << 5);
      rnd = int'(rs % 32'(n));
    end
  endfunction

  // ---------------------------------------------- the unit's side: a source
  logic [7:0] sent [0:4095];
  int  ns = 0, ns_limit = 0, src_gap = 0, src_gapmax = 20;
  bit  src_en = 0;
  always @(posedge clk) begin
    tx_start <= 1'b0;
    if (src_en && ns < ns_limit && !tx_busy && !tx_start) begin
      if (src_gap > 0) src_gap--;
      else begin
        tx_data  <= 8'(rnd(256));
        tx_start <= 1'b1;
        src_gap  = rnd(src_gapmax + 1);
      end
    end
  end
  // sent[] is filled where the link takes the byte, so a bug in the source
  // cannot make the two lists agree by accident
  always @(posedge clk) if (tx_start && !tx_busy) begin sent[ns] = tx_data; ns++; end

  // ------------------------------------------------ the unit's side: a sink
  logic [7:0] got [0:4095];
  int  ng = 0;
  logic rv_prev = 0;
  always @(posedge clk) begin
    rv_prev <= rx_valid;
    if (rx_valid) begin
      got[ng] = rx_data;
      ng++;
      if (rv_prev) chk(0, "rx_valid is high for two clocks in a row");
    end
  end

  // -------------------------------------------------------------- the host
  logic [7:0] acc [0:4095];       // host bytes the scans were told were accepted
  int  na = 0, nf = 0;
  bit  m_sticky = 0;
  assign nrx = na, ntx = nf;

  task automatic cyc(input logic c, input logic s, input logic u,
                     input logic r, input logic td, output logic b);
    begin
      capture = c; shift = s; update = u; treset = r; tdi = td;
      #(TCKP / 2);
      b = tdo;                    // what the TAP clocks out of tdo on this tck
      tck = 1;
      #(TCKP - TCKP / 2);
      tck = 0;
    end
  endtask

  task automatic idle(input int n);
    logic b;
    int i;
    begin
      for (i = 0; i < n; i++) cyc(0, 0, 0, 0, 0, b);
    end
  endtask

  task automatic tap_reset;
    logic b;
    int i;
    begin
      for (i = 0; i < 5; i++) cyc(0, 0, 0, 1, 0, b);
      m_sticky = 0;
    end
  endtask

  // One full scan with the model's checks.  w is the word shifted in.
  task automatic scan(input logic [9:0] w, input int idl, output logic [9:0] r);
    logic b, exp_rj, exp_fv, full;
    int i;
    begin
      cyc(0, 0, 0, 0, 0, b);                         // Select-DR
      full   = (dut.h_tog != dut.ha_sync[1]);
      exp_rj = full | m_sticky;
      exp_fv = (dut.f_sync[1] != dut.f_ack);
      cyc(1, 0, 0, 0, 0, b);                         // Capture-DR
      for (i = 0; i < 10; i++) begin
        cyc(0, 1, 0, 0, w[i], b);                    // Shift-DR
        r[i] = b;
      end
      cyc(0, 0, 0, 0, 0, b);                         // Exit1-DR
      cyc(0, 0, 1, 0, 0, b);                         // Update-DR
      idle(idl);                                     // Run-Test/Idle
      chk(r[9] === exp_rj, $sformatf("RJ is %b, expected %b (full %b sticky %b)", r[9], exp_rj, full, m_sticky));
      chk(r[8] === exp_fv, $sformatf("FV is %b, expected %b", r[8], exp_fv));
      if (exp_fv) begin
        chk(nf < ns, "a byte is captured that the unit never sent");
        chk(r[7:0] === sent[nf], $sformatf("captured byte %02x, expected %02x (#%0d)", r[7:0], sent[nf], nf));
        nf++;
      end
      if (w[8]) begin
        if (!exp_rj) begin
          acc[na] = w[7:0];
          na++;
        end else begin
          if (m_sticky) n_sticky++; else n_full++;
          m_sticky = 1;
        end
      end else begin
        m_sticky = 0;
      end
      chk(dut.sticky === m_sticky, "sticky flag differs from the model");
    end
  endtask

  // a scan that stops after nshift shifts and goes to Test-Logic-Reset
  task automatic scan_abort(input logic [9:0] w, input int nshift);
    logic b;
    int i;
    begin
      cyc(0, 0, 0, 0, 0, b);
      cyc(1, 0, 0, 0, 0, b);
      for (i = 0; i < nshift; i++) cyc(0, 1, 0, 0, w[i], b);
      tap_reset;
    end
  endtask

  // host byte queue and the batch sender
  logic [7:0] hq [0:4095];
  int hn = 0, hi = 0;
  task automatic host_send(input int cnt);
    logic [9:0] r;
    int k, first_rej;
    begin
      first_rej = -1;
      k = 0;
      while (k < cnt && hi + k < hn) begin
        scan({1'b0, 1'b1, hq[hi + k]}, rnd(3), r);
        if (r[9] && first_rej < 0) first_rej = k;
        k++;
      end
      if (first_rej >= 0) begin
        hi += first_rej;
        scan({1'b0, 1'b0, 8'(rnd(256))}, rnd(3), r);   // HV = 0: clear the flag
      end else begin
        hi += k;
      end
    end
  endtask

  task automatic wait_clks(input int n);
    begin
      #(n * CLKP);
    end
  endtask

  // -------------------------------------------------------------- the tests
  logic [9:0] r, r2;
  int iter, op, ga, gb, gc, base_ng;
  initial begin
    done = 0;
    rst_n = 0;
    idle(3);
    wait_clks(4);
    rst_n = 1;
    wait_clks(2);
    tap_reset;

    // D1: nothing waiting and nothing sent
    scan(10'h000, 2, r);
    chk(r[9:8] == 2'b00, "a fresh link captures RJ=0 FV=0");
    chk(!tx_busy, "tx_busy low at the start");

    // D2: one byte from the unit
    ns_limit = 1; src_en = 1;
    while (ns < 1) wait_clks(1);
    chk(tx_busy, "tx_busy rises after tx_start");
    wait_clks(8); idle(6);
    scan(10'h000, 2, r);
    chk(r[8] === 1'b1, "the waiting byte is captured with FV=1");
    scan(10'h000, 2, r2);
    chk(r2[8] === 1'b0, "the byte is not captured twice");
    wait_clks(8); idle(6);
    chk(!tx_busy, "tx_busy low after the host took the byte");

    // D3: scans that never reach Update-DR take and deliver nothing
    ns_limit = 2;
    while (ns < 2) wait_clks(1);
    wait_clks(8); idle(6);
    ga = na;
    scan_abort(10'h000, 3);                 // would have taken the byte
    wait_clks(8); idle(6);
    chk(tx_busy, "a scan reset before Update-DR leaves the byte waiting");
    scan_abort({1'b0, 1'b1, 8'hA5}, 10);    // would have sent 0xA5
    wait_clks(12);
    chk(ng == na, "a host byte shifted in but not updated is not delivered");
    chk(na == ga, "model: nothing accepted");
    scan(10'h000, 2, r);
    chk(r[8] === 1'b1, "the byte that was not taken is captured after the reset");

    // D4: a host byte; the mailbox, the sticky flag and its clearing
    hq[0] = 8'h11; hq[1] = 8'h22; hq[2] = 8'h33; hq[3] = 8'h44; hq[4] = 8'h55;
    hn = 5; hi = 0;
    scan({1'b0, 1'b1, hq[0]}, 0, r);
    chk(r[9] === 1'b0, "the first host byte is accepted");
    scan({1'b0, 1'b1, hq[1]}, 0, r);          // right behind it
    if (EXPECT_FULL) chk(r[9] === 1'b1, "the second byte is rejected: mailbox full");
    gb = r[9];
    wait_clks(40); idle(10);                        // mailbox empty again
    scan({1'b0, 1'b1, hq[2]}, 0, r);
    if (gb) chk(r[9] === 1'b1, "the sticky flag rejects a byte with the mailbox empty");
    scan({1'b0, 1'b0, 8'h00}, 0, r);          // HV = 0 clears it
    wait_clks(40); idle(10);
    scan({1'b0, 1'b1, hq[3]}, 0, r);
    chk(r[9] === 1'b0, "after an HV=0 scan a byte is accepted");
    wait_clks(40); idle(10);
    if (gb) begin
      // sticky flag, then a TAP reset clears it
      scan({1'b0, 1'b1, hq[4]}, 0, r);
      scan({1'b0, 1'b1, hq[4]}, 0, r);
      wait_clks(40); idle(10);
      scan({1'b0, 1'b1, hq[4]}, 0, r);
      chk(r[9] === 1'b1, "sticky again before the reset");
      tap_reset;
      scan({1'b0, 1'b1, hq[4]}, 0, r);
      chk(r[9] === 1'b0, "a TAP reset clears the sticky flag");
    end
    wait_clks(40); idle(10);
    chk(ng == na, "directed host bytes all delivered, none extra");
    for (ga = 0; ga < na; ga++) chk(got[ga] === acc[ga], $sformatf("host byte %0d is %02x, accepted %02x", ga, got[ga], acc[ga]));

    // D5: sel low: the TAP is looking at another instruction
    ga = na; gb = int'(dut.h_tog); gc = int'(dut.f_ack);
    sel = 0;
    scan_abort(10'h000, 0);                 // tap_reset also runs with sel low
    begin
      logic bb; int i;
      cyc(0, 0, 0, 0, 0, bb);
      cyc(1, 0, 0, 0, 0, bb);
      for (i = 0; i < 10; i++) cyc(0, 1, 0, 0, 1'b1, bb);
      cyc(0, 0, 0, 0, 0, bb);
      cyc(0, 0, 1, 0, 0, bb);
    end
    sel = 1;
    wait_clks(12);
    chk(int'(dut.h_tog) == gb && int'(dut.f_ack) == gc && ng == ga, "nothing happens while sel is low");

    // D6: rst_n low drops a host byte that is still in the mailbox
    wait_clks(40); idle(10);
    ga = ng;
    rst_n = 0;
    scan({1'b0, 1'b1, 8'hC3}, 0, r);
    chk(r[9] === 1'b0, "D6: the byte is accepted into the mailbox");
    wait_clks(12);
    rst_n = 1;
    wait_clks(40); idle(10);
    chk(ng == ga, "D6: a byte in the mailbox while rst_n is low is never delivered");
    na--;                                    // the model counted it; the unit dropped it
    scan(10'h000, 2, r);
    chk(r[9] === 1'b0, "D6: RJ falls after the dropped byte");

    // E: the random run, both directions at once
    for (ga = 0; ga < NB; ga++) hq[hn + ga] = 8'(rnd(256));
    hn += NB;
    base_ng = ng;
    ns_limit = ns + NB;
    src_gapmax = 30;
    src_en = 1;
    iter = 0;
    while ((hi < hn || nf < ns_limit || ng < na) && iter < 200000) begin
      iter++;
      op = rnd(10);
      if (op < 5 && hi < hn) host_send(1 + rnd(5));
      else if (op < 9)       scan({1'(rnd(2)), 1'b0, 8'(rnd(256))}, rnd(4), r);
      else                   idle(rnd(40));
      if (ng < na && rnd(4) == 0) wait_clks(rnd(30));
    end
    chk(iter < 200000, "the random run finished");
    wait_clks(80); idle(8);
    chk(hi == hn, "every host byte was sent");
    chk(nf == ns && ns == ns_limit, $sformatf("every unit byte was received (sent %0d, received %0d)", ns, nf));
    chk(ng == na, $sformatf("host bytes delivered %0d, accepted %0d", ng, na));
    for (ga = 0; ga < na && ga < ng; ga++)
      if (got[ga] !== acc[ga]) begin chk(0, $sformatf("host byte %0d is %02x, accepted %02x", ga, got[ga], acc[ga])); ga = na; end
    chk(1, "end");
    if (EXPECT_FULL) chk(n_full > 0 && n_sticky > 0, $sformatf("the random run saw a full mailbox (%0d) and the sticky flag (%0d)", n_full, n_sticky));
    done = 1;
  end

endmodule

module tb_jtag_link;

  int  e0, e1, e2, e3, c0, c1, c2, c3;
  int  f0, f1, f2, f3, s0, s1, s2, s3, r0, r1, r2, r3, t0, t1, t2, t3;
  logic d0, d1, d2, d3;

  jl_fix #(.CLKP(1000000), .TCKP(170000), .SEED(1), .NAME("fast6"))
      u0 (.nerr(e0), .nchk(c0), .nfull(f0), .nsticky(s0), .nrx(r0), .ntx(t0), .done(d0));
  jl_fix #(.CLKP(3700000), .TCKP(100000), .SEED(2), .EXPECT_FULL(1'b1), .NAME("fillbox"))
      u1 (.nerr(e1), .nchk(c1), .nfull(f1), .nsticky(s1), .nrx(r1), .ntx(t1), .done(d1));
  jl_fix #(.CLKP(12308), .TCKP(166667), .SEED(3), .NAME("board"))
      u2 (.nerr(e2), .nchk(c2), .nfull(f2), .nsticky(s2), .nrx(r2), .ntx(t2), .done(d2));
  jl_fix #(.CLKP(17000), .TCKP(23000), .SEED(4), .NAME("close"))
      u3 (.nerr(e3), .nchk(c3), .nfull(f3), .nsticky(s3), .nrx(r3), .ntx(t3), .done(d3));

  initial begin
    wait (d0 && d1 && d2 && d3);
    $display("  fast6:   %0d checks, %0d bytes in, %0d bytes out, %0d full, %0d sticky", c0, r0, t0, f0, s0);
    $display("  fillbox: %0d checks, %0d bytes in, %0d bytes out, %0d full, %0d sticky", c1, r1, t1, f1, s1);
    $display("  board:   %0d checks, %0d bytes in, %0d bytes out, %0d full, %0d sticky", c2, r2, t2, f2, s2);
    $display("  close:   %0d checks, %0d bytes in, %0d bytes out, %0d full, %0d sticky", c3, r3, t3, f3, s3);
    if (e0 + e1 + e2 + e3 == 0)
      $display("PASS: %0d checks, JTAG link (TCK faster and slower than the unit clock)", c0 + c1 + c2 + c3);
    else
      $display("FAIL: %0d of %0d checks failed", e0 + e1 + e2 + e3, c0 + c1 + c2 + c3);
    $finish;
  end

  initial begin
    repeat (200) #1_000_000_000;
    $display("FAIL: bench timed out");
    $finish;
  end

endmodule
