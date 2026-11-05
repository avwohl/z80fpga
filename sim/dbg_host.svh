// The host side of the debug unit's serial protocol, as tasks for a bench.
// tb_debug.sv and tb_romwbw_dbg.sv include this file.  The including module
// declares: clk, dbg_rx, dbg_tx, DDIV (clocks per serial bit) and NBP (the
// number of breakpoints the unit was built with).

  // --------------------------------------------------------- serial, host side
  logic [7:0] rxq [$];

  task automatic rx_one(output logic [7:0] c);
    integer i;
    begin
      @(negedge dbg_tx);
      repeat (DDIV + DDIV / 2) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        c[i] = dbg_tx;
        repeat (DDIV) @(posedge clk);
      end
    end
  endtask

  logic [7:0] rch;
  initial forever begin
    rx_one(rch);
    rxq.push_back(rch);
  end

  task automatic put(input logic [7:0] b);
    integer i;
    begin
      dbg_rx = 0;
      repeat (DDIV) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        dbg_rx = b[i];
        repeat (DDIV) @(posedge clk);
      end
      dbg_rx = 1;
      repeat (DDIV) @(posedge clk);
    end
  endtask

  integer fails = 0;
  integer checks = 0;

  task automatic get(output logic [7:0] b);
    integer t;
    begin
      t = 0;
      while (rxq.size() == 0 && t < 400000) begin
        @(posedge clk);
        t = t + 1;
      end
      if (rxq.size() == 0) begin
        $display("FAIL: no reply byte after %0d clocks", t);
        fails = fails + 1;
        b = 8'h00;
      end else begin
        b = rxq.pop_front();
      end
    end
  endtask

  task automatic chk(input string what, input integer got, input integer exp);
    begin
      checks = checks + 1;
      if (got !== exp) begin
        $display("FAIL: %s: got %0h, expected %0h", what, got, exp);
        fails = fails + 1;
      end
    end
  endtask

  // ---------------------------------------------------------- the commands
  logic [7:0] b0, b1, b2, b3;

  task automatic echo_cmd(input logic [7:0] op, input string what);
    begin
      put(op);
      get(b0);
      chk(what, b0, op);
    end
  endtask

  task automatic do_status(output logic [7:0] st);
    begin
      put("S");
      get(b0); get(b1); get(b2); get(b3);
      chk("status echo", b0, "S");
      chk("status: breakpoints", b2, NBP);
      chk("status: protocol revision", b3, 1);
      st = b1;
    end
  endtask

  task automatic wait_stopped(input string what);
    logic [7:0] st;
    integer n;
    begin
      n = 0;
      st = 0;
      while (!st[0] && n < 400) begin
        do_status(st);
        n = n + 1;
      end
      chk({what, ": stopped"}, st[0], 1);
    end
  endtask

  task automatic rd_reg(input integer n, output logic [15:0] v);
    begin
      put("R"); put(n[7:0]);
      get(b0); get(b1); get(b2);
      chk("reg read echo", b0, "R");
      v = {b2, b1};
    end
  endtask

  task automatic wr_reg(input integer n, input logic [15:0] v);
    begin
      put("W"); put(n[7:0]); put(v[7:0]); put(v[15:8]);
      get(b0);
      chk("reg write echo", b0, "W");
    end
  endtask

  task automatic chk_reg(input string what, input integer n, input integer exp);
    logic [15:0] v;
    begin
      rd_reg(n, v);
      chk(what, v, exp);
    end
  endtask

  logic [7:0] mbuf [0:255];

  task automatic rd_mem(input integer addr, input integer len);
    integer i;
    begin
      put("M"); put(addr[7:0]); put(addr[15:8]); put(len[7:0]);
      get(b0);
      chk("mem read echo", b0, "M");
      for (i = 0; i < ((len == 0) ? 256 : len); i = i + 1) begin
        get(b3);
        mbuf[i] = b3;
      end
    end
  endtask

  task automatic wr_mem(input integer addr, input integer len);
    integer i;
    begin
      put("P"); put(addr[7:0]); put(addr[15:8]); put(len[7:0]);
      for (i = 0; i < len; i = i + 1) put(mbuf[i]);
      get(b0);
      chk("mem write echo", b0, "P");
    end
  endtask

  task automatic chk_byte(input string what, input integer addr, input integer exp);
    begin
      rd_mem(addr, 1);
      chk(what, mbuf[0], exp);
    end
  endtask

  task automatic set_bp(input integer i, input integer addr, input integer bank,
                        input integer flags);
    begin
      put("B"); put(i[7:0]); put(addr[7:0]); put(addr[15:8]);
      put(bank[7:0]); put(flags[7:0]);
      get(b0);
      chk("bp echo", b0, "B");
    end
  endtask

  task automatic set_ovr(input integer en, input integer bank);
    begin
      put("K"); put(en[7:0]); put(bank[7:0]);
      get(b0);
      chk("override echo", b0, "K");
    end
  endtask

