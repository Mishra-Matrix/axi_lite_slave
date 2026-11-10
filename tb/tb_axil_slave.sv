//-----------------------------------------------------------------------------
// Testbench   : tb_axil_slave
// Description : Self-checking testbench for axil_slave.
//               - AXI4-Lite master BFM tasks (write with selectable AW/W
//                 ordering and delays, read)
//               - Random BREADY / RREADY back-pressure
//               - Register model as scoreboard: every BRESP, RDATA, RRESP,
//                 ctrl_o and irq_o value is checked
//               - Directed tests + constrained-random traffic + concurrent
//                 read/write streams
//               - Functional coverage (register x AW/W ordering, strobes,
//                 responses)
//               Run with +SEED=<n> to change the random seed.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_axil_slave;

  //---------------------------------------------------------------------------
  // Parameters
  //---------------------------------------------------------------------------
  localparam int          ADDR_WIDTH = 8;
  localparam logic [31:0] ID_VALUE   = 32'h4158_4C01;

  localparam logic [1:0] OKAY   = 2'b00;
  localparam logic [1:0] SLVERR = 2'b10;

  // AW / W ordering for writes
  localparam int SAME     = 0;
  localparam int AW_FIRST = 1;
  localparam int W_FIRST  = 2;

  // Register addresses
  localparam logic [ADDR_WIDTH-1:0] A_CTRL       = 8'h00;
  localparam logic [ADDR_WIDTH-1:0] A_STATUS     = 8'h04;
  localparam logic [ADDR_WIDTH-1:0] A_SCRATCH    = 8'h08;
  localparam logic [ADDR_WIDTH-1:0] A_IRQ_STATUS = 8'h0C;
  localparam logic [ADDR_WIDTH-1:0] A_IRQ_ENABLE = 8'h10;
  localparam logic [ADDR_WIDTH-1:0] A_ID         = 8'h14;

  //---------------------------------------------------------------------------
  // Clock and signals
  //---------------------------------------------------------------------------
  logic clk = 1'b0;
  always #5 clk = ~clk;                       // 100 MHz

  logic                  aresetn = 1'b0;
  logic [ADDR_WIDTH-1:0] awaddr  = '0;
  logic [2:0]            awprot  = '0;
  logic                  awvalid = 1'b0;
  logic                  awready;
  logic [31:0]           wdata   = '0;
  logic [3:0]            wstrb   = '0;
  logic                  wvalid  = 1'b0;
  logic                  wready;
  logic [1:0]            bresp;
  logic                  bvalid;
  logic                  bready  = 1'b0;
  logic [ADDR_WIDTH-1:0] araddr  = '0;
  logic [2:0]            arprot  = '0;
  logic                  arvalid = 1'b0;
  logic                  arready;
  logic [31:0]           rdata;
  logic [1:0]            rresp;
  logic                  rvalid;
  logic                  rready  = 1'b0;
  logic [31:0]           ctrl_o;
  logic [31:0]           status_i  = 32'hCAFE_0001;
  logic [31:0]           irq_set_i = '0;
  logic                  irq_o;

  //---------------------------------------------------------------------------
  // DUT
  //---------------------------------------------------------------------------
  axil_slave #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .ID_VALUE   (ID_VALUE)
  ) dut (
    .s_axi_aclk    (clk),
    .s_axi_aresetn (aresetn),
    .s_axi_awaddr  (awaddr),
    .s_axi_awprot  (awprot),
    .s_axi_awvalid (awvalid),
    .s_axi_awready (awready),
    .s_axi_wdata   (wdata),
    .s_axi_wstrb   (wstrb),
    .s_axi_wvalid  (wvalid),
    .s_axi_wready  (wready),
    .s_axi_bresp   (bresp),
    .s_axi_bvalid  (bvalid),
    .s_axi_bready  (bready),
    .s_axi_araddr  (araddr),
    .s_axi_arprot  (arprot),
    .s_axi_arvalid (arvalid),
    .s_axi_arready (arready),
    .s_axi_rdata   (rdata),
    .s_axi_rresp   (rresp),
    .s_axi_rvalid  (rvalid),
    .s_axi_rready  (rready),
    .ctrl_o        (ctrl_o),
    .status_i      (status_i),
    .irq_set_i     (irq_set_i),
    .irq_o         (irq_o)
  );

  //---------------------------------------------------------------------------
  // Random back-pressure on the response channels
  //---------------------------------------------------------------------------
  int bready_pct = 100;
  int rready_pct = 100;

  always @(negedge clk) begin
    bready <= ($urandom_range(99) < bready_pct);
    rready <= ($urandom_range(99) < rready_pct);
  end

  //---------------------------------------------------------------------------
  // Register model (scoreboard)
  //---------------------------------------------------------------------------
  logic [31:0] m_ctrl, m_scratch, m_irq_status, m_irq_en;

  int unsigned n_writes, n_reads, n_okay, n_slverr, n_errors;
  int unsigned n_order[3];

  function automatic void report_error(string msg);
    n_errors++;
    $error("[%0t] %s", $time, msg);
  endfunction

  function automatic logic [31:0] strb_mask(input logic [3:0] strb);
    return {{8{strb[3]}}, {8{strb[2]}}, {8{strb[1]}}, {8{strb[0]}}};
  endfunction

  function automatic void model_reset();
    m_ctrl       = '0;
    m_scratch    = '0;
    m_irq_status = '0;
    m_irq_en     = '0;
  endfunction

  function automatic void model_write(input  logic [ADDR_WIDTH-1:0] addr,
                                      input  logic [31:0]           data,
                                      input  logic [3:0]            strb,
                                      output logic [1:0]            resp);
    logic [31:0] mask;
    mask = strb_mask(strb);
    resp = OKAY;
    case (int'(addr[ADDR_WIDTH-1:2]))
      0:       m_ctrl       = (m_ctrl    & ~mask) | (data & mask);
      1:       ;                                        // STATUS: read-only
      2:       m_scratch    = (m_scratch & ~mask) | (data & mask);
      3:       m_irq_status = m_irq_status & ~(data & mask);   // W1C
      4:       m_irq_en     = (m_irq_en  & ~mask) | (data & mask);
      5:       ;                                        // ID: read-only
      default: resp = SLVERR;
    endcase
  endfunction

  function automatic void model_read(input  logic [ADDR_WIDTH-1:0] addr,
                                     output logic [31:0]           data,
                                     output logic [1:0]            resp);
    resp = OKAY;
    case (int'(addr[ADDR_WIDTH-1:2]))
      0:       data = m_ctrl;
      1:       data = status_i;
      2:       data = m_scratch;
      3:       data = m_irq_status;
      4:       data = m_irq_en;
      5:       data = ID_VALUE;
      default: begin data = '0; resp = SLVERR; end
    endcase
  endfunction

  //---------------------------------------------------------------------------
  // Functional coverage
  //---------------------------------------------------------------------------
  covergroup cg_write_t with function sample(int idx, int order, logic [3:0] strb, logic [1:0] resp);
    cp_reg: coverpoint idx {
      bins ctrl       = {0};
      bins status     = {1};
      bins scratch    = {2};
      bins irq_status = {3};
      bins irq_enable = {4};
      bins id         = {5};
      bins unmapped   = {[6:63]};
    }
    cp_order: coverpoint order {
      bins same     = {SAME};
      bins aw_first = {AW_FIRST};
      bins w_first  = {W_FIRST};
    }
    cp_strb: coverpoint strb {
      bins none    = {4'h0};
      bins partial = {[4'h1:4'hE]};
      bins full    = {4'hF};
    }
    cp_resp: coverpoint resp {
      bins okay   = {OKAY};
      bins slverr = {SLVERR};
    }
    x_reg_order: cross cp_reg, cp_order;
  endgroup

  covergroup cg_read_t with function sample(int idx, logic [1:0] resp);
    cp_reg: coverpoint idx {
      bins ctrl       = {0};
      bins status     = {1};
      bins scratch    = {2};
      bins irq_status = {3};
      bins irq_enable = {4};
      bins id         = {5};
      bins unmapped   = {[6:63]};
    }
    cp_resp: coverpoint resp {
      bins okay   = {OKAY};
      bins slverr = {SLVERR};
    }
  endgroup

  cg_write_t cg_w = new();
  cg_read_t  cg_r = new();

  //---------------------------------------------------------------------------
  // AXI4-Lite master BFM
  //---------------------------------------------------------------------------
  task automatic axi_write(input  logic [ADDR_WIDTH-1:0] addr,
                           input  logic [31:0]           data,
                           input  logic [3:0]            strb,
                           input  int                    order,
                           output logic [1:0]            resp);
    int         aw_dly, w_dly;
    logic [1:0] b_resp;
    case (order)
      AW_FIRST: begin aw_dly = 0; w_dly = $urandom_range(1, 4); end
      W_FIRST:  begin w_dly = 0; aw_dly = $urandom_range(1, 4); end
      default:  begin aw_dly = 0; w_dly = 0; end
    endcase
    @(negedge clk);
    fork
      begin : aw_channel
        repeat (aw_dly) @(negedge clk);
        awaddr  = addr;
        awvalid = 1'b1;
        do @(posedge clk); while (!awready);
        @(negedge clk);
        awvalid = 1'b0;
      end
      begin : w_channel
        repeat (w_dly) @(negedge clk);
        wdata  = data;
        wstrb  = strb;
        wvalid = 1'b1;
        do @(posedge clk); while (!wready);
        @(negedge clk);
        wvalid = 1'b0;
      end
      begin : b_channel
        do @(posedge clk); while (!(bvalid && bready));
        b_resp = bresp;
      end
    join
    resp = b_resp;
  endtask

  task automatic axi_read(input  logic [ADDR_WIDTH-1:0] addr,
                          output logic [31:0]           data,
                          output logic [1:0]            resp);
    @(negedge clk);
    araddr  = addr;
    arvalid = 1'b1;
    do @(posedge clk); while (!arready);
    @(negedge clk);
    arvalid = 1'b0;
    do @(posedge clk); while (!(rvalid && rready));
    data = rdata;
    resp = rresp;
  endtask

  //---------------------------------------------------------------------------
  // Checked operations
  //---------------------------------------------------------------------------
  task automatic check_write(input logic [ADDR_WIDTH-1:0] addr,
                             input logic [31:0]           data,
                             input logic [3:0]            strb,
                             input int                    order);
    logic [1:0] resp, exp_resp;
    axi_write(addr, data, strb, order, resp);
    model_write(addr, data, strb, exp_resp);
    n_writes++;
    n_order[order]++;
    if (resp === SLVERR) n_slverr++; else n_okay++;
    cg_w.sample(int'(addr[ADDR_WIDTH-1:2]), order, strb, resp);
    if (resp !== exp_resp)
      report_error($sformatf("WRITE 0x%02h: BRESP %02b, expected %02b", addr, resp, exp_resp));
    if (ctrl_o !== m_ctrl)
      report_error($sformatf("ctrl_o 0x%08h, expected 0x%08h", ctrl_o, m_ctrl));
    if (irq_o !== |(m_irq_status & m_irq_en))
      report_error($sformatf("irq_o %0b, expected %0b", irq_o, |(m_irq_status & m_irq_en)));
  endtask

  task automatic check_read(input logic [ADDR_WIDTH-1:0] addr);
    logic [31:0] data, exp_data;
    logic [1:0]  resp, exp_resp;
    axi_read(addr, data, resp);
    model_read(addr, exp_data, exp_resp);
    n_reads++;
    if (resp === SLVERR) n_slverr++; else n_okay++;
    cg_r.sample(int'(addr[ADDR_WIDTH-1:2]), resp);
    if (resp !== exp_resp || data !== exp_data)
      report_error($sformatf("READ 0x%02h: got 0x%08h/%02b, expected 0x%08h/%02b",
                             addr, data, resp, exp_data, exp_resp));
  endtask

  //---------------------------------------------------------------------------
  // Helpers
  //---------------------------------------------------------------------------
  task automatic apply_reset();
    @(negedge clk);
    aresetn = 1'b0;
    repeat (5) @(negedge clk);
    aresetn = 1'b1;
    repeat (2) @(negedge clk);
    model_reset();
  endtask

  task automatic pulse_irq(input logic [31:0] bits);
    @(negedge clk);
    irq_set_i = bits;
    @(negedge clk);
    irq_set_i = '0;
    m_irq_status = m_irq_status | bits;
  endtask

  task automatic end_test(input string name, input int unsigned err_before);
    if (n_errors == err_before)
      $display("[%0t] PASS: %s", $time, name);
    else
      $display("[%0t] FAIL: %s (%0d errors)", $time, name, n_errors - err_before);
  endtask

  function automatic logic [ADDR_WIDTH-1:0] rand_addr();
    case ($urandom_range(9))
      0, 1, 2, 3, 4, 5, 6: return ADDR_WIDTH'($urandom_range(0, 5) * 4);   // mapped
      7:                   return ADDR_WIDTH'($urandom_range(6, 15) * 4);  // just past the map
      default:             return ADDR_WIDTH'($urandom());                 // anywhere, any alignment
    endcase
  endfunction

  function automatic logic [3:0] rand_strb();
    return ($urandom_range(3) == 0) ? 4'($urandom()) : 4'hF;
  endfunction

  //---------------------------------------------------------------------------
  // Test sequence
  //---------------------------------------------------------------------------
  int unsigned seed;
  int unsigned e;
  int          order;

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, tb_axil_slave);

    if ($value$plusargs("SEED=%d", seed)) void'($urandom(seed));
    $display("Running axil_slave test, ADDR_WIDTH=%0d", ADDR_WIDTH);

    model_reset();
    apply_reset();

    // T1: reset values of every register
    e = n_errors;
    check_read(A_CTRL);
    check_read(A_STATUS);
    check_read(A_SCRATCH);
    check_read(A_IRQ_STATUS);
    check_read(A_IRQ_ENABLE);
    check_read(A_ID);
    if (ctrl_o !== '0 || irq_o !== 1'b0) report_error("T1: outputs not cleared by reset");
    end_test("T1 reset values", e);

    // T2: write/read every RW register with all three AW/W orderings
    e = n_errors;
    for (order = SAME; order <= W_FIRST; order++) begin
      check_write(A_CTRL,       $urandom(), 4'hF, order);  check_read(A_CTRL);
      check_write(A_SCRATCH,    $urandom(), 4'hF, order);  check_read(A_SCRATCH);
      check_write(A_IRQ_ENABLE, $urandom(), 4'hF, order);  check_read(A_IRQ_ENABLE);
    end
    end_test("T2 RW registers, AW+W same cycle / AW first / W first", e);

    // T3: byte strobes
    e = n_errors;
    check_write(A_SCRATCH, 32'hFFFF_FFFF, 4'b1111, SAME);
    check_write(A_SCRATCH, 32'h0000_0000, 4'b0101, AW_FIRST);   // -> 0xFF00_FF00
    check_read (A_SCRATCH);
    check_write(A_SCRATCH, 32'h1234_5678, 4'b0000, W_FIRST);    // no bytes -> unchanged
    check_read (A_SCRATCH);
    check_write(A_SCRATCH, 32'hA5A5_A5A5, 4'b1000, SAME);       // -> 0xA500_FF00
    check_read (A_SCRATCH);
    if (m_scratch !== 32'hA500_FF00) report_error("T3: unexpected strobe result in model");
    end_test("T3 WSTRB byte enables", e);

    // T4: read-only registers ignore writes, STATUS follows status_i
    e = n_errors;
    check_write(A_STATUS, 32'hDEAD_BEEF, 4'hF, SAME);
    check_write(A_ID,     32'hDEAD_BEEF, 4'hF, AW_FIRST);
    check_read (A_STATUS);
    check_read (A_ID);
    @(negedge clk) status_i = 32'h1357_9BDF;
    check_read (A_STATUS);
    end_test("T4 read-only registers (STATUS, ID)", e);

    // T5: unmapped addresses -> SLVERR, read data 0
    e = n_errors;
    check_write(8'h18, 32'h1111_1111, 4'hF, SAME);
    check_write(8'h1C, 32'h2222_2222, 4'hF, AW_FIRST);
    check_write(8'h80, 32'h3333_3333, 4'hF, W_FIRST);
    check_write(8'hFC, 32'h4444_4444, 4'hF, SAME);
    check_read (8'h18);
    check_read (8'h1C);
    check_read (8'h80);
    check_read (8'hFC);
    end_test("T5 unmapped addresses return SLVERR", e);

    // T6: interrupt status (W1C) and irq_o masking
    e = n_errors;
    check_write(A_IRQ_ENABLE, 32'h0000_00FF, 4'hF, SAME);
    pulse_irq(32'h0000_0105);                                 // bits 0, 2, 8
    if (irq_o !== 1'b1) report_error("T6: irq_o not raised");
    check_read (A_IRQ_STATUS);                                // 0x105
    check_write(A_IRQ_STATUS, 32'h0000_0001, 4'hF, AW_FIRST); // clear bit 0
    check_read (A_IRQ_STATUS);                                // 0x104
    check_write(A_IRQ_STATUS, 32'h0000_0004, 4'h0, W_FIRST);  // WSTRB=0: nothing cleared
    check_read (A_IRQ_STATUS);                                // 0x104
    check_write(A_IRQ_STATUS, 32'h0000_0004, 4'hF, SAME);     // clear bit 2
    if (irq_o !== 1'b0) report_error("T6: irq_o high with only a masked bit pending");
    check_read (A_IRQ_STATUS);                                // 0x100 (bit 8 masked)
    check_write(A_IRQ_STATUS, 32'hFFFF_FFFF, 4'hF, SAME);     // clear everything
    check_read (A_IRQ_STATUS);                                // 0x0
    end_test("T6 IRQ_STATUS write-1-to-clear and irq_o masking", e);

    // T7: hardware set in the same cycle as a software clear -> set wins
    e = n_errors;
    check_write(A_IRQ_ENABLE, 32'h0, 4'hF, SAME);
    pulse_irq(32'h0000_0008);
    fork
      check_write(A_IRQ_STATUS, 32'h0000_0008, 4'hF, SAME);
      begin
        // Fire the hardware event exactly in the cycle the write is performed
        @(negedge clk iff (dut.aw_hold && dut.w_hold));
        irq_set_i = 32'h0000_0008;
        @(negedge clk);
        irq_set_i = '0;
      end
    join
    m_irq_status = m_irq_status | 32'h0000_0008;              // new event kept
    check_read (A_IRQ_STATUS);                                // bit 3 still set
    check_write(A_IRQ_STATUS, 32'h0000_0008, 4'hF, SAME);
    check_read (A_IRQ_STATUS);                                // now clear
    end_test("T7 hardware set wins over simultaneous W1C clear", e);

    // T8: constrained-random traffic with random back-pressure
    e = n_errors;
    bready_pct = 50;
    rready_pct = 50;
    repeat (2000) begin
      if ($urandom_range(1))
        check_write(rand_addr(), $urandom(), rand_strb(), $urandom_range(2));
      else
        check_read(rand_addr());
    end
    end_test("T8 2000 random transactions with BREADY/RREADY back-pressure", e);

    // T9: independent read and write streams running at the same time
    e = n_errors;
    bready_pct = 70;
    rready_pct = 70;
    fork
      begin : writer
        logic [ADDR_WIDTH-1:0] a;
        repeat (300) begin
          case ($urandom_range(2))
            0:       a = A_CTRL;
            1:       a = A_SCRATCH;
            default: a = A_IRQ_ENABLE;
          endcase
          check_write(a, $urandom(), rand_strb(), $urandom_range(2));
        end
      end
      begin : reader
        repeat (300) check_read($urandom_range(1) ? A_ID : A_STATUS);
      end
    join
    bready_pct = 100;
    rready_pct = 100;
    check_read(A_CTRL);
    check_read(A_SCRATCH);
    check_read(A_IRQ_ENABLE);
    end_test("T9 concurrent read and write streams", e);

    // T10: reset returns every register to its reset value
    e = n_errors;
    check_write(A_CTRL,    32'hFFFF_FFFF, 4'hF, SAME);
    check_write(A_SCRATCH, 32'hFFFF_FFFF, 4'hF, SAME);
    apply_reset();
    check_read(A_CTRL);
    check_read(A_SCRATCH);
    check_read(A_IRQ_STATUS);
    check_read(A_IRQ_ENABLE);
    if (ctrl_o !== '0) report_error("T10: ctrl_o not cleared by reset");
    end_test("T10 reset clears registers", e);

    //-------------------------------------------------------------------------
    // Summary
    //-------------------------------------------------------------------------
    $display("");
    $display("================ AXI4-LITE SLAVE TEST SUMMARY ================");
    $display(" Writes checked            : %0d", n_writes);
    $display("   AW+W same cycle         : %0d", n_order[SAME]);
    $display("   AW first                : %0d", n_order[AW_FIRST]);
    $display("   W first                 : %0d", n_order[W_FIRST]);
    $display(" Reads checked             : %0d", n_reads);
    $display(" OKAY / SLVERR responses   : %0d / %0d", n_okay, n_slverr);
    $display(" Write coverage            : %0.2f %%", cg_w.get_coverage());
    $display(" Read coverage             : %0.2f %%", cg_r.get_coverage());
    $display(" Errors                    : %0d", n_errors);
    if (n_errors == 0)
      $display(" RESULT                    : *** TEST PASSED ***");
    else
      $display(" RESULT                    : *** TEST FAILED ***");
    $display("==============================================================");
    $finish;
  end

  // Watchdog
  initial begin
    #5_000_000;
    $fatal(1, "Simulation timeout");
  end

endmodule
