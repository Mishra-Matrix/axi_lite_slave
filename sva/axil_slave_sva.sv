//-----------------------------------------------------------------------------
// Module      : axil_slave_sva
// Description : Assertions for axil_slave, attached with `bind`.
//               - AXI4-Lite slave protocol rules (valid/ready, stability,
//                 response ordering, legal responses, reset)
//               - Register-file rules (who may change which register,
//                 W1C behaviour, interrupt output)
//               - Assumptions on the master (checked in simulation, usable
//                 as constraints in formal verification)
//               - Cover properties for the interesting corner cases
//-----------------------------------------------------------------------------
module axil_slave_sva #(
  parameter int ADDR_WIDTH = 8
) (
  input logic                  s_axi_aclk,
  input logic                  s_axi_aresetn,
  input logic [ADDR_WIDTH-1:0] s_axi_awaddr,
  input logic                  s_axi_awvalid,
  input logic                  s_axi_awready,
  input logic [31:0]           s_axi_wdata,
  input logic [3:0]            s_axi_wstrb,
  input logic                  s_axi_wvalid,
  input logic                  s_axi_wready,
  input logic [1:0]            s_axi_bresp,
  input logic                  s_axi_bvalid,
  input logic                  s_axi_bready,
  input logic [ADDR_WIDTH-1:0] s_axi_araddr,
  input logic                  s_axi_arvalid,
  input logic                  s_axi_arready,
  input logic [31:0]           s_axi_rdata,
  input logic [1:0]            s_axi_rresp,
  input logic                  s_axi_rvalid,
  input logic                  s_axi_rready,
  input logic [31:0]           ctrl_o,
  input logic [31:0]           irq_set_i,
  input logic                  irq_o,
  // Internal DUT signals
  input logic                  do_write,
  input logic [ADDR_WIDTH-3:0] wr_idx,
  input logic [31:0]           reg_scratch,
  input logic [31:0]           reg_irq_status,
  input logic [31:0]           reg_irq_en
);

  localparam logic [1:0] OKAY   = 2'b00;
  localparam logic [1:0] SLVERR = 2'b10;

  default clocking cb @(posedge s_axi_aclk); endclocking

  // Handshakes
  logic aw_hs, w_hs, b_hs, ar_hs, r_hs;
  assign aw_hs = s_axi_awvalid & s_axi_awready;
  assign w_hs  = s_axi_wvalid  & s_axi_wready;
  assign b_hs  = s_axi_bvalid  & s_axi_bready;
  assign ar_hs = s_axi_arvalid & s_axi_arready;
  assign r_hs  = s_axi_rvalid  & s_axi_rready;

  // Transaction counters (used to check response ordering)
  int unsigned aw_cnt, w_cnt, b_cnt, ar_cnt, r_cnt;
  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      aw_cnt <= 0; w_cnt <= 0; b_cnt <= 0; ar_cnt <= 0; r_cnt <= 0;
    end else begin
      if (aw_hs) aw_cnt <= aw_cnt + 1;
      if (w_hs)  w_cnt  <= w_cnt  + 1;
      if (b_hs)  b_cnt  <= b_cnt  + 1;
      if (ar_hs) ar_cnt <= ar_cnt + 1;
      if (r_hs)  r_cnt  <= r_cnt  + 1;
    end
  end

  //===========================================================================
  // Reset
  //===========================================================================
  a_reset_valids_low: assert property (!s_axi_aresetn |=> (!s_axi_bvalid && !s_axi_rvalid))
    else $error("SVA: BVALID/RVALID not low after reset");

  //===========================================================================
  // Write response channel
  //===========================================================================
  a_bvalid_hold: assert property (disable iff (!s_axi_aresetn)
    (s_axi_bvalid && !s_axi_bready) |=> s_axi_bvalid)
    else $error("SVA: BVALID dropped before BREADY");

  a_bresp_stable: assert property (disable iff (!s_axi_aresetn)
    (s_axi_bvalid && !s_axi_bready) |=> $stable(s_axi_bresp))
    else $error("SVA: BRESP changed while waiting for BREADY");

  a_bresp_legal: assert property (disable iff (!s_axi_aresetn)
    s_axi_bvalid |-> (s_axi_bresp == OKAY || s_axi_bresp == SLVERR))
    else $error("SVA: illegal BRESP %0b", s_axi_bresp);

  a_b_after_aw_and_w: assert property (disable iff (!s_axi_aresetn)
    s_axi_bvalid |-> (aw_cnt > b_cnt && w_cnt > b_cnt))
    else $error("SVA: write response before both AW and W were received");

  a_aw_outstanding: assert property (disable iff (!s_axi_aresetn)
    (aw_cnt - b_cnt) <= 2 && (w_cnt - b_cnt) <= 2)
    else $error("SVA: too many outstanding write requests accepted");

  //===========================================================================
  // Read data channel
  //===========================================================================
  a_rvalid_hold: assert property (disable iff (!s_axi_aresetn)
    (s_axi_rvalid && !s_axi_rready) |=> s_axi_rvalid)
    else $error("SVA: RVALID dropped before RREADY");

  a_rdata_stable: assert property (disable iff (!s_axi_aresetn)
    (s_axi_rvalid && !s_axi_rready) |=> ($stable(s_axi_rdata) && $stable(s_axi_rresp)))
    else $error("SVA: RDATA/RRESP changed while waiting for RREADY");

  a_rresp_legal: assert property (disable iff (!s_axi_aresetn)
    s_axi_rvalid |-> (s_axi_rresp == OKAY || s_axi_rresp == SLVERR))
    else $error("SVA: illegal RRESP %0b", s_axi_rresp);

  a_r_after_ar: assert property (disable iff (!s_axi_aresetn)
    s_axi_rvalid |-> (ar_cnt == r_cnt + 1))
    else $error("SVA: read response without a matching read request");

  a_ar_outstanding: assert property (disable iff (!s_axi_aresetn)
    (ar_cnt - r_cnt) <= 1)
    else $error("SVA: more than one outstanding read");

  a_slverr_rdata_zero: assert property (disable iff (!s_axi_aresetn)
    (s_axi_rvalid && s_axi_rresp == SLVERR) |-> (s_axi_rdata == '0))
    else $error("SVA: SLVERR read returned non-zero data");

  //===========================================================================
  // X checks
  //===========================================================================
  a_ctrl_known: assert property (disable iff (!s_axi_aresetn)
    !$isunknown({s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid, irq_o}))
    else $error("SVA: X/Z on handshake or irq outputs");

  a_bresp_known: assert property (disable iff (!s_axi_aresetn)
    s_axi_bvalid |-> !$isunknown(s_axi_bresp))
    else $error("SVA: X/Z on BRESP");

  a_rdata_known: assert property (disable iff (!s_axi_aresetn)
    s_axi_rvalid |-> !$isunknown({s_axi_rdata, s_axi_rresp}))
    else $error("SVA: X/Z on RDATA/RRESP");

  //===========================================================================
  // Register-file rules
  //===========================================================================
  a_ctrl_only_by_write: assert property (disable iff (!s_axi_aresetn)
    !(do_write && wr_idx == 0) |=> $stable(ctrl_o))
    else $error("SVA: CTRL changed without a write to CTRL");

  a_scratch_only_by_write: assert property (disable iff (!s_axi_aresetn)
    !(do_write && wr_idx == 2) |=> $stable(reg_scratch))
    else $error("SVA: SCRATCH changed without a write to SCRATCH");

  a_irq_en_only_by_write: assert property (disable iff (!s_axi_aresetn)
    !(do_write && wr_idx == 4) |=> $stable(reg_irq_en))
    else $error("SVA: IRQ_ENABLE changed without a write to IRQ_ENABLE");

  a_irq_set_wins: assert property (disable iff (!s_axi_aresetn)
    (irq_set_i != '0) |=> ((reg_irq_status & $past(irq_set_i)) == $past(irq_set_i)))
    else $error("SVA: hardware interrupt event was lost");

  a_irq_bits_only_set_by_hw: assert property (disable iff (!s_axi_aresetn)
    1'b1 |=> ((reg_irq_status & ~$past(reg_irq_status) & ~$past(irq_set_i)) == '0))
    else $error("SVA: IRQ_STATUS bit set without a hardware event");

  a_irq_bits_only_cleared_by_w1c: assert property (disable iff (!s_axi_aresetn)
    !(do_write && wr_idx == 3) |=> ((reg_irq_status & $past(reg_irq_status)) == $past(reg_irq_status)))
    else $error("SVA: IRQ_STATUS bit cleared without a W1C write");

  a_irq_out: assert property (disable iff (!s_axi_aresetn)
    irq_o == |(reg_irq_status & reg_irq_en))
    else $error("SVA: irq_o does not match IRQ_STATUS & IRQ_ENABLE");

  //===========================================================================
  // Assumptions on the master (AXI rule: once VALID is high, it and its
  // payload stay stable until READY)
  //===========================================================================
  m_aw_stable: assume property (disable iff (!s_axi_aresetn)
    (s_axi_awvalid && !s_axi_awready) |=> (s_axi_awvalid && $stable(s_axi_awaddr)))
    else $error("SVA: master changed AW channel before handshake");

  m_w_stable: assume property (disable iff (!s_axi_aresetn)
    (s_axi_wvalid && !s_axi_wready) |=> (s_axi_wvalid && $stable({s_axi_wdata, s_axi_wstrb})))
    else $error("SVA: master changed W channel before handshake");

  m_ar_stable: assume property (disable iff (!s_axi_aresetn)
    (s_axi_arvalid && !s_axi_arready) |=> (s_axi_arvalid && $stable(s_axi_araddr)))
    else $error("SVA: master changed AR channel before handshake");

  //===========================================================================
  // Coverage
  //===========================================================================
  c_aw_before_w:        cover property (disable iff (!s_axi_aresetn) (aw_hs && !w_hs) ##[1:8] w_hs);
  c_w_before_aw:        cover property (disable iff (!s_axi_aresetn) (w_hs && !aw_hs) ##[1:8] aw_hs);
  c_aw_w_same_cycle:    cover property (disable iff (!s_axi_aresetn) aw_hs && w_hs);
  c_b_backpressure:     cover property (disable iff (!s_axi_aresetn) s_axi_bvalid && !s_axi_bready);
  c_r_backpressure:     cover property (disable iff (!s_axi_aresetn) s_axi_rvalid && !s_axi_rready);
  c_read_write_overlap: cover property (disable iff (!s_axi_aresetn) (aw_hs || w_hs) && ar_hs);
  c_write_slverr:       cover property (disable iff (!s_axi_aresetn) b_hs && s_axi_bresp == SLVERR);
  c_read_slverr:        cover property (disable iff (!s_axi_aresetn) r_hs && s_axi_rresp == SLVERR);
  c_irq_set_and_clear:  cover property (disable iff (!s_axi_aresetn) do_write && wr_idx == 3 && irq_set_i != '0);

endmodule

//-----------------------------------------------------------------------------
// Bind the checker into every instance of axil_slave
//-----------------------------------------------------------------------------
bind axil_slave axil_slave_sva #(
  .ADDR_WIDTH (ADDR_WIDTH)
) u_axil_slave_sva (
  .s_axi_aclk     (s_axi_aclk),
  .s_axi_aresetn  (s_axi_aresetn),
  .s_axi_awaddr   (s_axi_awaddr),
  .s_axi_awvalid  (s_axi_awvalid),
  .s_axi_awready  (s_axi_awready),
  .s_axi_wdata    (s_axi_wdata),
  .s_axi_wstrb    (s_axi_wstrb),
  .s_axi_wvalid   (s_axi_wvalid),
  .s_axi_wready   (s_axi_wready),
  .s_axi_bresp    (s_axi_bresp),
  .s_axi_bvalid   (s_axi_bvalid),
  .s_axi_bready   (s_axi_bready),
  .s_axi_araddr   (s_axi_araddr),
  .s_axi_arvalid  (s_axi_arvalid),
  .s_axi_arready  (s_axi_arready),
  .s_axi_rdata    (s_axi_rdata),
  .s_axi_rresp    (s_axi_rresp),
  .s_axi_rvalid   (s_axi_rvalid),
  .s_axi_rready   (s_axi_rready),
  .ctrl_o         (ctrl_o),
  .irq_set_i      (irq_set_i),
  .irq_o          (irq_o),
  .do_write       (do_write),
  .wr_idx         (wr_idx),
  .reg_scratch    (reg_scratch),
  .reg_irq_status (reg_irq_status),
  .reg_irq_en     (reg_irq_en)
);
